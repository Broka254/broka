# BROKA Calling — Architecture & Status

This documents BROKA's buyer↔seller audio/video calling system as of the
production-hardening pass described in CHANGES.md. It exists because
ARCHITECTURE.md doesn't currently cover calling at all.

## Architecture overview

WebRTC peer-to-peer media, with the backend acting purely as a signaling
relay plus authoritative call-session state:

- **`backend/api/core/call_state.py`** — the authoritative session store.
  Redis-backed in production (falls back to an in-memory store if
  `REDIS_URL` is unset, e.g. local dev), with an explicit state machine
  (see below) and an O(1) secondary index for the "is there a call waiting
  for me on this listing" poll.
- **`backend/api/routers/calls.py`** — REST endpoints (initiate, get a
  room-scoped token, TURN credentials, log a call's outcome, poll for a
  pending call) plus the `/calls/ws/{room_id}` WebSocket that relays SDP
  offers/answers and ICE candidates between exactly two authenticated
  participants. Live WebSocket connections are held in a process-local
  dict — see **Multi-instance limitation** below.
- **`backend/api/core/cloudflare_turn_client.py`** — generates short-lived
  Cloudflare Realtime TURN credentials on request. A real circuit breaker
  wraps the Cloudflare API call; on any failure the client falls back to
  STUN-only rather than failing the call.
- **`flutter_app/lib/services/webrtc_service.dart`** — the client-side
  peer connection, signaling, and recovery logic (generation-guarded
  against stale async callbacks, bounded reconnect/ICE-restart with
  backoff, a WebSocket heartbeat, queued ICE candidates, offer/answer
  caching for replay after a reconnect).
- **`flutter_app/lib/screens/voip_call_screen.dart`** — the call UI
  (ringing/accept/decline, in-call controls, outcome logging).
- **`flutter_app/lib/services/notification_service.dart`** — the *active*
  local-notification system (see **Incoming-call delivery** below).
- **`flutter_app/lib/services/call_foreground_service.dart`** +
  **`android/.../CallForegroundService.kt`** — keeps the mic/camera alive
  through backgrounding and screen lock via a real Android foreground
  service, for both the caller (from the moment they call) and the callee
  (from the moment they accept).

## Authoritative state machine

```
initiating → ringing → accepted → connecting → connected
                                                    ↕ disconnected (recovering)
ringing     → declined | missed | expired
any active  → failed
any active  → ended
```

All transitions are validated server-side (`call_state.is_valid_transition`);
duplicate same-state events are harmless no-ops, and terminal states
(`declined`, `missed`, `expired`, `failed`, `ended`) never transition back
to an active state. `connected` sessions use a separate, longer,
auto-renewing TTL from `ringing`/`connecting` sessions specifically so a
call lasting well over 2 minutes doesn't have its server-side session
disappear out from under it.

Call **outcomes** (for history/logging, via `POST /calls/log-result`) are
a business-level classification layered on top of the state machine, not
new states: `completed`, `declined`, `missed`, and `cancelled` (caller
hung up before any answer — distinct from `missed`, which means the
*callee* never responded; both map to the same underlying `missed`
CallState). Outcome recording is idempotent — whichever side's client
reports first wins, and the backend derives caller/callee/listing/call
type from the authoritative session rather than trusting the reporting
client's claims about any of them.

## Signaling protocol

Messages on `/calls/ws/{room_id}`:

| Type | Direction | Meaning |
|---|---|---|
| `offer` / `answer` / `ice` | peer → peer (relayed) | WebRTC negotiation. `offer`/`answer` carry `restart: true` during an ICE restart. |
| `hangup` | peer → peer (relayed), or server → caller | Somebody **deliberately** ended the call. Always terminal. |
| `ready` | server → both | Both peers are in the room; the caller sends (or resends) its offer. |
| `ping` / `pong` | server ↔ client | Liveness. |
| `busy` | server → client | A genuinely different second participant holds the room. |
| `peer_state` | server → client | The other side's *signaling socket* went away (`disconnected`) or came back (`reconnected`). **Not** a hangup. |
| `state` | client → server | Client-observed WebRTC peer-connection state (`connected`/`disconnected`/`failed`) — the one thing only the client can see. |

Only `offer`, `answer`, `ice` and `hangup` are ever relayed between peers.
Everything else is server-authored, so a participant can't forge a
`ready`/`busy`/`hangup` at the other side. Frames above 128KB are dropped
(the connection survives).

`peer_state` exists because a transient signaling drop and a deliberate
hangup are completely different events that were previously reported
identically. An established WebRTC call does not need its signaling channel
— media keeps flowing peer-to-peer — so the surviving side now holds the
call open (up to 30s) while its peer reconnects, instead of tearing down.

## Incoming-call delivery

Two mechanisms now work together, with clearly defined roles:

- **FCM (primary — background/terminated delivery).** Wired up this
  pass: `main.dart` initializes Firebase and registers foreground
  (`onMessage`), background (`onBackgroundMessage`, a required top-level
  entry-point function), tap (`onMessageOpenedApp`), and cold-start
  (`getInitialMessage`) handlers. The incoming-call push is sent
  **data-only** (no FCM `notification` block) specifically so the app's
  own code decides what to show — not a generic OS-displayed banner —
  regardless of foreground/background/terminated state. A device's FCM
  token is (re-)registered every time `GlobalPollerService.start()` runs,
  which already happens at every login/session-restore path, and again
  on token refresh.
- **Polling (foreground fallback).** `GlobalPollerService` polls
  `GET /calls/pending/{listing_id}` while the app is foregrounded (any
  screen, not just the negotiation screen for that listing), **for both
  roles** — the endpoint already scopes its answer to the authenticated
  user as callee, so no client-side role gate is needed or correct. Both paths
  converge on the same `NotificationService.showIncomingCall` /
  `navigateFromPayload` — one call-routing mechanism regardless of which
  detected the call. The notification's ID is derived from `room_id`
  (not a fixed constant), so two different incoming calls get distinct
  notification slots while the same call detected through both paths
  still correctly collapses into one.

Tapping the notification (from either mechanism) re-verifies the call is
still live via `checkIncomingCall` and routes to `/voip-call` with a
fresh room-scoped token — never trusting the notification payload alone
for authorization, and never requiring the negotiation screen to already
be open.

**Everything above is wired up in code but not yet functional in
practice**: it depends on a real Firebase project + `google-services.json`
that don't exist in this repo (can't be committed) and haven't been set
up yet. See FCM_SETUP_REMAINING.md for exactly what's left, all of it
external configuration + device verification, none of it more code.

## TURN / ICE

`GET /calls/turn-credentials` returns short-lived Cloudflare-generated
credentials; Flutter never holds a static TURN secret. TURN is used only
as a relay fallback when direct/STUN connectivity fails, and the
connection-path diagnostic (`direct` / `stun` / `turn`) is derived from
the actual selected ICE candidate pair's type, not from whether TURN was
merely configured. Credentials are refreshed pre-emptively before an ICE
restart if they're within 2 minutes of expiry (not a continuous mid-call
refresh loop — BROKA's calls are short 1-to-1 sessions well under
Cloudflare's TTL, so that wasn't judged necessary).

## Video

The remote video surface is gated on a remote **video** track that is
actually decoding frames (`onRemoteVideoChanged`), not on "any remote media
arrived". Previously it flipped on the first remote track of any kind — on a
video call that's almost always the audio track — so the UI swapped to an
`RTCVideoView` with nothing in it and hid the avatar behind it. The visible
result was a black screen, permanently so if the far camera never came up.

Outgoing video is capped at 320kbps / 24fps via `RTCRtpSender` parameters
(`b=AS:` is honoured inconsistently, and a getUserMedia constraint only
bounds capture, not what the encoder spends). Uncapped, libwebrtc ramps a
640x480 stream past 1Mbps and starves the audio sharing the same connection.

The cap is applied **after negotiation completes** (from `_handleOffer`'s
answer and from `_handleAnswer`), reading the sender back through
`getSenders()`. It cannot be applied at `addTrack` time, which is where it
used to live and why it never actually took effect — see the 2026-09-18
pass below.

Mic and camera are requested explicitly before `getUserMedia`. A denied
camera degrades the call to audio-only rather than failing it.

## Audio path and bandwidth

Outgoing SDP is tuned before it's set locally (`WebRtcService._tuneSdp`):
Opus gets `usedtx=1` (stop transmitting during silence — a large real saving
in data and radio wake-ups on a two-way conversation), `useinbandfec=1`
(tolerate the 1–3% loss normal on a congested mobile uplink without audible
gaps), mono, and a `maxaveragebitrate` ceiling of 24kbps for voice / 32kbps
for video calls. Video capture is capped at 24fps. If the SDP doesn't have
the shape the tuner expects, the **original** description is used unchanged
— an untuned call is a minor inefficiency, a malformed SDP doesn't connect
at all.

The platform is put into communication/telephony audio mode at call start
(`Helper.setAndroidAudioConfiguration`), **awaited before `getUserMedia`**,
which is what makes the hardware volume keys control *call* volume, routes
through the voice-call stream, and engages the device's hardware echo
canceller — that last one only applies to a stream opened while the mode is
already in force, hence the await. The mode is put **back to `media` on
teardown**; the speaker flag alone never did that. Voice calls start on the
earpiece, video calls on the speaker.

Call quality shown in the UI is measured — inbound audio packet loss and
jitter sampled from `getStats()` every 4s — not inferred from how long the
call has been up.

## Android

A real foreground service (`microphone|camera` types) plus a partial wake
lock (with a 30-minute safety-timeout cap) keeps a call alive through
backgrounding and screen lock, for both parties. `usesCleartextTraffic`
is `false` in the shipped app (a debug-only manifest override keeps local
HTTP dev servers working). The incoming-call notification's
`fullScreenIntent` is backed by the `USE_FULL_SCREEN_INTENT` permission.
Native bridge calls (Dart ↔ Kotlin) fail safely on either side.

Known, deliberate non-goal: swiping the app away from Android's recents
list ends an active call rather than surviving it. True survive-anything
calling would need Android's Telecom/ConnectionService integration,
which is a real feature addition, not a hardening-pass fix.

## iOS

**Implemented** (2026-09-14). iOS can't ring like Android, so two OS
frameworks are mandatory rather than optional:

- **PushKit** — the only push type that wakes a *terminated* app for a call.
  A normal APNs/FCM alert can't. Delivered over APNs against its own token,
  stored separately in `users.apns_voip_token` (FCM can't address the
  PushKit `voip` topic, so it's a direct HTTP/2 call in `_send_voip_push`).
- **CallKit** — rings, shows the native full-screen UI over the lock screen,
  owns the audio session. Since iOS 13 an app that receives a VoIP push and
  doesn't report a call to CallKit is killed, and loses VoIP delivery
  entirely.

`ios/Runner/AppDelegate.swift` is a thin native shell: it rings, answers,
ends and mutes, then hands the decision to Dart over a MethodChannel. The
call itself — peer connection, signaling, media — stays in
`webrtc_service.dart`, identical to Android. `callkit_service.dart` is the
Dart half and is a no-op on Android, so callers never branch on platform.

Still requires a Mac: the Xcode project scaffolding is machine-generated and
is restored with `flutter create --platforms=ios .` (it won't overwrite the
files above). Capabilities, the APNs key, and the device test matrix are in
**IOS_CALLING_SETUP.md**. PushKit and CallKit do not work in the simulator.

## Multi-instance limitation

Call *state* is Redis-backed and already safe across multiple backend
instances. Live WebSocket *connections* are held in a process-local dict
(`_rooms` in `calls.py`), which is **single-instance only** — two peers
signaling through different backend instances would never reach each
other. This is fine for the current single-instance Render deployment and
is explicitly not being solved in this pass (per its own scope); the
state/connection split is deliberate so a Redis Pub/Sub (or similar)
relay layer could be added later without redesigning `call_state.py`.

## Required environment variables

| Variable | Purpose |
|---|---|
| `REDIS_URL` | Backs `call_state.py`'s session store and rate limiting. Falls back to in-memory (single-process only) if unset. |
| `CLOUDFLARE_TURN_KEY_ID`, `CLOUDFLARE_TURN_API_TOKEN` | Generate short-lived TURN credentials. Falls back to STUN-only if unset/failing. |
| `CLOUDFLARE_ACCOUNT_ID` | Optional, used alongside the above. |
| `CALL_TOKEN_EXPIRE_MINUTES` | Room-scoped call token lifetime (default 5). |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Backend FCM push capability (already implemented server-side; see FCM_SETUP_REMAINING.md for the still-missing client half). |
| `APNS_AUTH_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID` | iOS PushKit VoIP pushes. Unset -> iOS calls work foregrounded but can't ring a terminated app. See IOS_CALLING_SETUP.md. |
| `APNS_BUNDLE_ID` | Defaults to `com.broka.app`. Must match the Xcode bundle id. |
| `APNS_USE_PRODUCTION` | Must match `aps-environment` in `Runner.entitlements`. Mismatch = push accepted, nothing rings. |

## What device testing must still confirm

None of the following has been verified on a physical device as of this
pass — everything above was arrived at through direct code reading, a
standalone simulation of the event-loop fix, and static/syntax checks
only, in a sandboxed environment with no Flutter toolchain, no physical
device, and no live Redis/Cloudflare/FCM to test against:

- All four call directions (buyer/seller × audio/video) end to end.
- The WebSocket heartbeat and client watchdog under a real flaky/dropped
  connection, not a simulated one.
- The pre-restart TURN credential refresh (`setConfiguration()`) actually
  behaves as expected on-device.
- Foreground/background/screen-lock behavior on a real Android device.
- **FCM delivery end to end** — foreground, backgrounded, and fully
  terminated — once a real Firebase project + `google-services.json`
  exist (see FCM_SETUP_REMAINING.md). Nothing about the FCM wiring has
  been compiled, run, or confirmed to actually wake a terminated app.
- The full physical-device test matrix in the hardening pass's own spec
  (two devices, all call/network/lifecycle combinations).

See CHANGES.md for the full list of bugs found and fixed during this
pass, and its final report for exact readiness status per platform/
direction.

---

# Ringtone, notification and video-state pass (2026-09-15)

## The ringtone is now the user's own

`assets/audio/ringtone.mp3` was played for every incoming call on every
device. Beyond it not being the sound the user chose, it was wrong three
ways:

- **Ringer mode was ignored.** `AndroidUsageType.notificationRingtone`
  routes audio to the ring stream but does not implement silent/vibrate
  policy, so a phone deliberately set to silent still made noise.
- **It never vibrated.** A phone on vibrate got no indication at all.
- **It was unrecognisable.** Half of what a ringtone does is tell you it is
  *your* phone.

Android now resolves `RingtoneManager.getActualDefaultRingtoneUri(
TYPE_RINGTONE)` through a small platform channel
(`android/.../SystemRingtone.kt`, channel `com.broka.app/ringtone`): the
exact sound from Settings > Sound > Phone ringtone, looping, with the
standard buzz-pause vibrate cadence, silent when the ringer is silent,
vibrate-only when it is on vibrate. `Ringtone.isLooping` only exists from
API 28, so below that a 500ms watchdog restarts it — otherwise the phone
rings for four seconds and goes quiet while the caller is still waiting.

No new package. The pubspec already carries unverified version guesses and
one CI failure has already been caused by unpinned dependency resolution;
this is ~80 lines of the platform API any such package would be wrapping.

The notification channel carries the same sound for the case Dart cannot
reach — app killed, notification posted from an FCM background isolate
where `MainActivity`'s engine and therefore the channel do not exist. It
uses `content://settings/system/ringtone` (`Settings.System.
DEFAULT_RINGTONE_URI`), which needs no platform code and follows the user
if they change their ringtone later. Channel ID bumped `broka_calls_v2` ->
`_v3`: channel settings including sound are immutable once created, so
without a new ID nobody with the app already installed would ever hear the
change.

iOS keeps the bundled tone as its fallback. A local notification cannot
play the system ringtone there — only CallKit can, and that path is
already wired separately in `CallKitService`.

## Incoming-call notification

**Two sounds at once.** `negotiation_screen.dart` called
`showIncomingCall` (one-shot channel sound) *and* `RingtoneService.play`
(looping tone) on the same event. They overlapped on every incoming call
that arrived while the thread was open.

**No ring at all, elsewhere.** `GlobalPollerService` only posted the
notification. Android notification sounds do not loop, so a call arriving
while the user was anywhere other than that one screen produced a single
chirp — which is the entire reason an in-app looping player exists.

Ringing is now owned by `showIncomingCall`, which starts the ring and posts
the notification `playSound: !ringing`, so exactly one thing is ever
audible. `cancelIncomingCall` stops the ring symmetrically, before its
`_ready` guard and unconditionally — a ringtone that will not stop is the
worst failure available in this file.

`RingtoneService.play` now preserves a previously-registered `onTimeout`
when called without one. Two callers start the same ring for one call and
they race (`showIncomingCall` is not awaited), so a naive assignment let
the callback-free one land second and drop the screen's teardown, leaving
a dead incoming-call dialog on screen after the sound stopped.

Also added: `timeoutAfter` on the notification, so a stale entry removes
itself if every other teardown path is missed; `VIBRATE` in the manifest,
without which the vibrator call is a silent no-op and a phone on vibrate
gets no signal whatsoever.

## Camera mute was invisible to the peer

`toggleVideo()` set `track.enabled = false` and told nobody. Disabling a
track keeps the transceiver alive and keeps sending — black frames, not
nothing — so `onEnded` never fires on the receiving side and there is
nothing else in the protocol that would tell them. The visible result: you
turn your camera off, and the other person keeps looking at a frozen last
frame for the rest of the call, indistinguishable from a hung pipeline.

New `video_state` signal carrying one boolean, added to
`WS_RELAYABLE_TYPES` in `routers/calls.py`. Cosmetic only — it selects
which surface the UI shows and can never affect server-held call state,
which is why relaying it verbatim is safe, unlike `state`, which is
consumed server-side and stays value-restricted.

Re-announced on `ready`, which fires again after a WS reconnect: a
`video_state` sent while the socket was down is simply gone, and the peer's
picture would stay stuck on whatever it was before the drop. Defaults to
`true` for peers on older builds who never send it, so their behaviour is
unchanged.


---

# Calling audit (2026-09-18)

Seven defects, found by reading the call path against what this document
already claimed it did. Several were things the code *described* correctly
and did not actually do, which is why they survived the previous pass — the
comment explaining the intent sat directly above the line that missed it.

## Call quality

**The video bitrate cap never applied.** `_applyVideoBitrateCap` ran once
from `_createPc`, straight after `addTrack`. In that position it could not
work: it read the sender's `parameters`, which in flutter_webrtc is a Dart
field cached from `addTrack`'s response rather than a live read; before the
transceiver is negotiated that cache's `encodings` list is empty, so the old
code fabricated one; and libwebrtc rejects a `setParameters()` that changes
the *number* of encodings. So the call threw and was swallowed — and even
where it didn't, `setLocalDescription` re-derives the real parameters
immediately afterwards. The cap that exists specifically to stop video
starving the audio on the same uplink was a no-op. Now applied after
negotiation, against senders re-read from native.

**The audio mode switch was not awaited.** `Helper.setAndroidAudioConfiguration`
returns a Future that was dropped, so `getUserMedia` could open the mic
while the platform was still in MEDIA mode. Android engages its hardware
AEC/NS based on the mode in force *when the stream is opened*, so losing
that race gives a call with software echo cancellation only — the
speakerphone echo the call is configured to avoid. Dropping the Future also
meant the surrounding `try/catch` caught nothing.

**The audio mode was never restored.** Teardown called
`setSpeakerphoneOn(false)` under a comment claiming it handed the route back
"so the next media playback (a voice note, the ringtone) isn't stuck in
earpiece/communication mode". The speaker flag is not the audio *mode*: the
device stayed in `VOICE_COMMUNICATION` for the rest of the app session, so
the hardware volume keys kept adjusting call volume and later media played
on the voice-call stream.

**An ICE restart could strip TURN from a live call.** `_fetchIceConfiguration`
does not throw when the credential fetch fails — it returns the STUN-only
fallback. The pre-restart refresh then pushed *that* onto the live
connection via `setConfiguration()`, removing the relay from a call that was
in all likelihood only up because of the relay. On carrier-grade NAT (normal
on Kenyan mobile data) that turns a recovery attempt into a disconnect. The
refresh is now skipped unless real credentials came back.

**The quality meter reported `bad` on the second call of a session.**
`_lastPacketsReceived` / `_lastPacketsLost` / `_quality` survived teardown,
so the next call's first sample subtracted the previous call's cumulative
totals — a negative delta, which fell into the "no audio arrived" branch.
Reset on teardown, and deltas are clamped (an ICE restart re-creates the
inbound stream, and `packetsLost` is signed in the stats spec).

## Notifications

**Incoming-call pushes had no TTL**, so FCM's four-week default applied. A
phone that was off or out of coverage when someone called received the push
whenever it next reached the network and rang for a call that had ended
hours before. Now `CALL_PUSH_TTL_SECONDS` (60s), with the APNs equivalent
(`apns-expiration`). Foregrounded, the client additionally re-checks
`GET /calls/pending/{listing_id}` before ringing, and fails *open* — only a
definite "no call" suppresses the ring, since swallowing a real call is far
worse than an occasional late one.

**Every visible iOS notification was sent as a silent background push.**
`_send_fcm` hardcoded `apns-push-type: background` with `content_available`
regardless of the `data_only` argument. That is correct for an incoming call
(the app draws its own UI) and wrong for everything else: the deal reminders
and nudges in `core/workers.py` call this helper with `data_only=False` and
were delivered to iOS devices as pushes that display nothing. The push type
now follows the message.

## Signaling

**A reconnect could have its room deleted out from under it.** The relay's
`finally` popped `_rooms[room_id]` whenever *its own* captured room dict was
empty. Between removing itself and that check it awaits, and in that window
another handler can pop the room and a reconnecting peer can create a brand
new dict under the same key — which the stale handler then deleted, leaving
both peers registered in a dict nothing can find each other through. No
offer, answer, ICE candidate or restart crosses again, and the session is
marked `ended`. The pop and the terminal transition are now guarded by
`_owns_room()`, extracted so the invariant is testable without a live socket.

## Verification

`backend/tests/test_call_push_and_teardown.py` covers the push shaping and
the room-ownership predicate; five of its seven assertions fail against the
pre-fix code. The full backend suite passes (618), and `flutter analyze`
reports no errors.

The client-side fixes are **not device-verified** — same standing caveat as
the rest of this document. They are reasoned from the flutter_webrtc 0.11.7
source (`getSenders()` round-trips to native, `parameters` is a cached
field, `AndroidAudioConfiguration.media` exists) rather than from a call
placed on real hardware.
