# Notifications — calls and messages with the app closed (2026-10-07)

Raised by the owner: an incoming call reached someone only while they were
using the app; the caller's screen assumed a person who wasn't "active"
couldn't be reached; and messages sent while someone was away weren't
there for them until they opened BROKA. Asked for: calls and messages that
arrive whether or not the app is running, the way WhatsApp's do.

This document is the review of the notification system as it stood, what
was changed, and what has to be set up outside the repository for any of it
to reach a phone.

## 1. What was wrong

Two faults meant **no push could ever reach a phone**. Everything else was
built on top of a delivery path that did not exist.

1. **Released APKs have no Firebase.** `android/app/google-services.json`
   is git-ignored (rightly), and CI never wrote it from a secret, so every
   APK on the releases page was built without it. `Firebase.initializeApp()`
   throws at start-up, `main.dart` catches it, and the app runs on its
   seven-second poller, which runs only while the app process is alive.
   That is exactly the reported behaviour: calls ring only while the app is
   open.
2. **The server never stored a device token.** `POST /calls/register-token`
   wrote `current.fcm_token = ...`, but `current` is the dict
   `get_current_user` returns, not a `User` row. Every registration raised
   `AttributeError` and returned 500, which the app swallowed. Even with
   Firebase in the APK, the server had no token to push to. Reproduced
   before the fix: `500 {"detail":"Internal server error..."}`.

The rest of the design had these gaps:

3. **Chat messages were never pushed.** No code path sent a push for a
   `NegotiationMessage`. A message reached the other person only through
   the thread's WebSocket (open only while that exact chat was on screen)
   or the app's own inbox sweep (alive only while the app was). That
   included Zeno relaying a buyer's question to the seller.
4. **One token per user.** `users.fcm_token` held one device. Someone
   signed in on two phones got everything on one of them. Nothing removed a
   token from the previous account either: after a second person signed in
   on a shared phone, the first person's calls, messages and payment alerts
   went on arriving there. Sign-out didn't unregister anything.
5. **The caller's "Ringing…" was a guess from presence.** The call screen
   said "Trying to reach them… / They were last seen offline - they may not
   pick up" whenever the callee's `last_seen` was stale. A closed app is
   always "offline", and it rings perfectly well from a push. Nothing
   reported whether the callee's phone actually had the call.
6. **The caller's ring was cut off at 30 seconds, as a failure.** The
   caller enters `calling` as soon as its socket is up, and that state armed
   WebRtcService's 30s *connect* timeout. Every unanswered call therefore
   ended at 30s with "Call timed out while connecting", while the callee's
   phone rang for 45.
7. **A call nobody answered and no phone reported left nothing behind.**
   Missed-call notifications and call cards were written only when a client
   called `/calls/log-result`. If the caller's app died or lost signal
   mid-ring while the callee's app was closed, there was no missed call and
   no card in the chat.
8. **Polling cost grew with the inbox.** Every 7s the app fetched the inbox
   and then made one `GET /calls/pending/{listing_id}` request *per
   thread*. Someone with 40 conversations made 41 requests every 7 seconds,
   in the background as well. A buyer who called a seller they had never
   messaged had no thread, so that poll never found their call.
9. **Two FCM senders.** `api/core/push.py` (a hand-rolled JWT client) sent
   deal and auction alerts to a channel the app never creates
   (`broka_deals`, which Android files under "Miscellaneous") and never
   cleared dead tokens. `routers/calls.py` had the correct sender.
10. **Smaller things.** The status-bar icon was the launcher's full-colour
    square, which renders as a white blob. A notification tapped on a cold
    start opened the screen on top of the splash, so Back led to the
    splash. Local and pushed notifications for one conversation used
    different identities and could stack.

## 2. How it works now

### Devices (`api/models/push_device.py`, `api/core/push_devices.py`)

- `push_devices` has one row per phone token, with the token as the primary
  key, so a phone belongs to one account at a time. Registering a token
  moves it to the new account, here and in the legacy `users.fcm_token`
  column. Up to five phones per user and kind.
- `POST /calls/register-token` stores the token (the 500 is fixed) and
  answers `push_enabled`, which says whether the server can push at all.
  `POST /calls/unregister-token` is called on sign-out; "sign out
  everywhere" removes every phone.
- `push_user()` pushes every phone of a user concurrently. A token that FCM
  reports as unregistered is deleted everywhere.

### Messages (`api/core/message_push.py`)

- A SQLAlchemy session hook sees every committed `NegotiationMessage`,
  whichever of the twenty-odd code paths wrote it: `after_flush` collects,
  `after_commit` dispatches, and a rollback discards.
- Who gets a message follows `/history`'s visibility rules
  (`recipients_of`). The other side gets direct messages; each side gets
  Zeno's messages addressed to it. A buyer's private words to Zeno are
  never pushed, and a call card is not a message.
- Pushes are debounced per thread (1s). The text is built from the database
  when the push is sent: the recipient's unread count, using the inbox's own
  `_thread_unread_and_seen` / `_zeno_unread`, and the newest message they
  may see. So "3 new messages · Last price?" is always right, and nothing is
  sent once they have read it.
- Each push is a visible notification that Android draws with the app
  closed, on the `broka_messages` channel, tagged `thread_<listing>_<buyer>`.
  The app posts its own notifications under the same tag, so a conversation
  is one notification that updates. Messages have no TTL: a phone that was
  off gets them when it comes back. On iOS, `thread-id` groups them.
- The push task runs in a fresh `contextvars.Context`. Starlette's HTTP
  middleware cancels whatever is left of a request's task group after the
  response, and a task that inherited the request's context was cancelled
  with it, before sending. The tests caught this.

### Calls (`api/routers/calls.py`, `api/core/call_state.py`)

- `/calls/initiate` rings **every** phone of the callee's (data-only, TTL
  60s). The push carries the callee's room-scoped `callToken`.
- **Delivery receipt.** The phone posts `POST /calls/{room_id}/alerted`
  with that call token as soon as it is ringing. It does this from the FCM
  background isolate too, where the access token is usually expired. The
  server marks the session `callee_alerted` and sends `callee_ringing` to
  the caller's socket, or sends it when the caller's socket joins if the ack
  came first. A call that is already over answers 410, and the phone stops
  ringing at once.
- **Answered or declined on one phone**: the others get a data-only
  `call_over` push and stop ringing.
- **No-answer watchdog.** Each ringing call is added to a sorted set in
  Redis (`broka:call:ringing`), so it survives a restart. Every 5 seconds
  `ring_watchdog_tick` settles calls that are still unanswered after 55s.
  It records them as missed through the same `_record_outcome` as
  `/log-result`: call card, missed-call push, and `hangup` with reason
  `no_answer` to the caller. `mark_result_logged` keeps it from
  double-recording a call a phone already reported.
- `GET /calls/incoming` answers "is anyone calling me, on any listing" in
  one lookup. It includes the thread's `buyer_id` and the listing name,
  because a buyer can call a seller they have never messaged.

### Deal and auction alerts (`api/core/push_subscribers.py`)

These go through `push_devices.push_user` on a real channel,
`broka_updates`.

### The app

- `main.dart`'s background handler delegates to
  `NotificationService.handleBackgroundMessage`:
  - `incoming_call` rings first (insistent, full-screen), then acknowledges
    the call.
  - `call_over` and `missed_call` stop the ring.
  - `new_message` records the message as announced, so the sweep doesn't
    announce it again.
- In the foreground (`handleForegroundFcmMessage`), a message push is shown
  under the conversation's tag unless that conversation is on screen.
  Opening a conversation removes its notification.
- `GlobalPollerService` now:
  - asks `/calls/incoming` once per sweep, falling back to per-thread
    checks on an older server;
  - reloads preferences before announcing anything, because the background
    isolate writes its own copy;
  - stops sweeping in the background once the server confirms
    `push_enabled`, so it no longer costs battery and data behind the user;
  - still sweeps in the foreground and on resume.
- Token registration goes through `ApiClient`, which renews an expired
  session; the raw request ignored the 401. Sign-out unregisters the phone.
- The call screen says **"Calling…"** until a phone of the callee's has the
  call, then **"Ringing… / Their phone is ringing"**. Presence is used only
  for the green dot. The caller now has its own 45s no-answer window, ending
  as "No answer · They'll see that you called" rather than an error. The 30s
  connect timeout starts only once the callee has answered. A decline reads
  "Call declined".
- Once pushes work, the app asks once, with an explanation, to be left out
  of battery optimisation. On Tecno, Infinix and Xiaomi builds an optimised
  closed app often gets pushes late or not at all.
- Android shell: a white status-bar icon (`drawable/ic_stat_broka`), and
  FCM default icon, colour and channel in the manifest. A tap on a cold
  start puts Home underneath the conversation or call.

## 3. Setup that only the owner can do

None of this reaches a phone until these are in place:

1. **Firebase project.** In the Firebase console, add an Android app with
   package `com.broka.app` and download `google-services.json`.
2. **GitHub secret `GOOGLE_SERVICES_JSON`**, in the repository whose
   release you install: the secret is per repository, and a fork does not
   have it. Store the file's contents, or base64 of it
   (`base64 -w0 google-services.json`). The `Firebase config` step in
   `.github/workflows/build.yml` writes it into the APK build and checks
   that it is for `com.broka.app`. Without it the step prints a warning,
   the release notes open with "this APK has no push notifications", and
   the APK still has no push.
3. **Backend `FIREBASE_SERVICE_ACCOUNT_JSON`** on the API host. Get it from
   Project settings → Service accounts → Generate new private key, from the
   same project. This is the server's credential, not the app's file.
4. Push to `main` and install the new APK. The first sign-in registers the
   phone. The API log shows `PUSH_TOKEN_REGISTERED`, and the app stops
   polling in the background once `push_enabled` comes back `true`.
5. iOS additionally needs the APNs VoIP key (`IOS_CALLING_SETUP.md`).

**First build with the secret set.** The Google Services Gradle plugin has
never run in CI, because the file never existed there. If that first build
fails, the plugin (4.4.2, `android/settings.gradle`) is the first thing to
check.

**Checking a phone.** Settings → Notifications says which case the
installed build is in: "built without push notifications" (no Firebase in
the APK), "until push notifications connect" (Firebase started, the server
has not accepted the phone's token yet), or "even with BROKA closed".

## 4. Verification

- Backend: `tests/test_notifications.py` (23 tests) covers the token bug,
  shared phones, multiple phones, sign-out, dead tokens, every-phone
  ringing, delivery receipts, who may acknowledge, late pushes, the
  incoming lookup, the watchdog's three cases, and message pushes (who gets
  what, bursts, read threads, private Zeno messages, call cards, rollbacks,
  photos). The full suite passes on PostgreSQL 16 and on SQLite, both with
  Redis. `tests/test_client_invariants.py`'s call-screen invariant now
  requires the delivery receipt rather than presence.
- App: `test/push_delivery_test.dart` (11 tests). `flutter analyze` reports
  no new issues, and the full `flutter test` passes (712).
- **Not device-tested.** There is no Android SDK or phone in the
  environment this was written in. The matrix to run on two real phones:
  app in front / in background / swiped away / phone rebooted, for a call
  each way, a message each way, a Zeno relay, and a missed call. Also check
  a Tecno or Infinix device with and without the battery exemption.

## 5. Still open

- **Reply and Mark-as-read from the notification.** Both need an
  authenticated request from the background isolate, where the access
  token is usually expired. Renewing it there races the main isolate's
  renewal for the same refresh token. The safe design is a short-lived,
  thread-scoped token in the push, like the call token.
- **Dismissing on the other phones when a thread is read** (a data-only
  push on mark-read).
- **Older senders still reach only the newest phone.** These call
  `_send_fcm(user.fcm_token)` directly: deal check-ins in
  `core/workers.py`, escrow protection, and buy-agent alerts.
- **OEM autostart** (Xiaomi, Tecno) cannot be requested from code. The
  battery exemption helps but doesn't guarantee delivery to a force-stopped
  app.
- **Multi-instance.** Message debounce and the call relay are
  per-process. The watchdog's ringing set is in Redis and safe; with two
  instances, a thread could be pushed twice, and the shared tag collapses
  it to one notification.
- **iOS "Ringing".** An iPhone rings through PushKit and CallKit
  (`AppDelegate.swift`), which doesn't post `/alerted` yet. A caller
  calling an iPhone sees "Calling…" until it is answered. The push already
  carries the `callToken` the native side would need.
- **Native calling.** Android's Telecom/ConnectionService (system call UI,
  Bluetooth headset answer) is still not integrated (CALLING.md).


## 6. Second pass (2026-10-08)

Reported after the first pass: calls still rang only with BROKA open;
calls arrived over a call in progress; missed calls and unread messages
showed only once the app was opened again, and "only missed call was
displayed despite there being an unread text message".

**Still no push: the installed APK had no Firebase.** Neither repository's
release APK contained Firebase's config (`google_app_id`). The secret was
set on `Broka254/broka`, but the APK in use was built by
`Xxavier-ml/broka`, which has no `GOOGLE_SERVICES_JSON`; and the API
(Railway, deployed from `Broka254/broka`) logged `CALL_NO_PUSH_ROUTE` on
every call and `MESSAGE_PUSHED phones=0`, with no phone ever registered.
`Broka254/broka`'s own build had not run since the sync, because the
synced head commit was "Update graphify.md [skip ci]", which skips the
whole workflow. The server side (`FIREBASE_SERVICE_ACCOUNT_JSON`) was fine.
Without push, the app's own sweep is the only path, and it runs only while
the app does - which is why everything arrived when BROKA was next opened.
The release notes and Settings now say when a build has no Firebase.

**A text and a missed call are both announced.** The inbox describes a
thread by its last row, and the sweep announced that row: a missed call
after a text hid the text, a text after a missed call hid the call. The
inbox now also names the other side's newest unread message and newest
unread missed call (`unread_message`, `unread_missed_call`, from
`_unread_by_kind`, queried only for threads with something unread), and
the sweep announces each once. A thread's announced ids are kept as a
short list (they were one slot, so announcing the call erased the text's
record). The missed-call push carries its call card's id, so the sweep
does not announce it again. The message push no longer counts call cards
("2 new messages" for one text and one missed call).

**The first sweep announced history.** "Announce nothing on an install's
first sweep" was set by the first thread with news, so that sweep silenced
one thread and announced every other. It is set once the sweep is over.

**One call at a time** is in CALLING.md.


## 7. Faces, and answering from the notification (2026-10-08)

Calls, missed calls and messages show the photo of the person calling or
writing, and Accept on an incoming call opens the call at once. Both are
described in CALLING.md ("Answering from a closed app, and faces on
notifications"). For this document: the pushes now carry the photo's URL
(`callerPhoto`, `senderPhoto`; never the image), the app turns it into the
notification's large icon, and a message or missed-call push that Android
drew by itself is drawn again with the face by the background handler,
which now also receives the push's title and body.

