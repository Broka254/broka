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

- ~~**Reply and Mark-as-read from the notification.**~~ Done on
  2026-11-11 with a thread token in the push - see "Reply and Mark as
  read" below.
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



## Incoming calls with the app in front (2026-10-09)

A call that arrives while BROKA is on screen opens its call screen at once,
ringing, instead of a notification. Where a call notification is posted
while the app's own ringer is ringing, it goes on `broka_calls_in_app_v1`,
a channel with no sound: Android 8+ plays a channel's sound whatever the
notification asks, and the call channel's ringtone played over the app's
ring and on after Accept. CALLING.md has the rest.


## Honest "Ringing", and a second try at the receipt (2026-10-25)

Two gaps remained in the call path.

* **A silent phone could be reported as ringing.** From a closed app the
  local notification is the ring; with Android 13+'s notification
  permission denied (or the app's notifications switched off), `show()`
  still reports success while drawing nothing, so the phone acknowledged
  the call and the caller read "Ringing…" for a phone that never made a
  sound. `NotificationService.showIncomingCall` now asks
  `areNotificationsEnabled()` whenever neither the call screen nor the
  in-app ringer is making the call audible, and answers `false` - no
  `/alerted` - when the answer is a definite "off". An unknown answer (no
  Android implementation, a plugin error) still rings: a swallowed call is
  worse than a rare false ring. A per-channel block (Android 8+ lets the
  user silence just "Incoming Calls") is not visible through the plugin's
  API and is not detected.

* **One transient failure left the caller on "Calling…".** The app's
  poller retried an unconfirmed `/alerted` on its next sweep, but a closed
  app has no poller. `acknowledgeIncomingCall` now retries once,
  immediately; the endpoint is idempotent (a repeated alert for a room
  that is still ringing is a no-op).

Diagnostics now carry the room through every hop: `PUSH_NO_DEVICES` and
`PUSH_RESULT` in `push_devices.py` name it, and the app logs
`CALL_PUSH_RECEIVED` (foreground/background), `CALL_RING_SHOWN`,
`CALL_ALERT_RESULT` and `CALL_RING_CLEARED` with the room id. No token,
title, body or call token is logged. This pass, like the earlier ones, is
code and unit-test evidence only - it has not been run on a phone.


## Offline recovery, and the Inbox telling the truth (2026-10-27)

Reported: a message sent while the recipient was offline was never
displayed when they came back online; the Inbox said "You're offline"
on a working connection; a missed call sat in the Inbox as a
notification-style "Missed call received" line; listing groups showed
generic category icons instead of the listing's photo; and the bare
phone icon that opens call history did not say so.

* **A push that reached no phone was recorded as pushed.**
  `message_push.push_thread` wrote `_last_pushed` before sending, so a
  message whose push accepted zero phones (offline, token not yet
  registered, transient FCM failure) could never be announced again for
  that thread. It is recorded only after a phone accepts it.
* **Registering a phone now announces what is already waiting.** A
  phone this account has never pushed to gets one re-push of every
  unread thread (`push_unread_for_user`, scheduled from
  `POST /calls/register-token`); read threads stay silent because the
  notification is built from the unread state, and the same phone
  registering again (every app start) is not re-buzzed.
* **The sweep's first pass is no longer silent.** Priming records each
  thread's baseline without firing one notification per thread; it now
  also posts one catch-up summary ("N unread messages", tag
  `broka_catchup`, tap opens the Inbox) for what it recorded, so an
  offline stretch ends with one summary - never a storm, never silence.
* **The Inbox banner only claims "offline" for a network failure.**
  Painting the on-device cache no longer declares the user offline, a
  server error reads "Couldn't refresh", and a stale inbox retries
  every 15s in the foreground and on resume until a fetch lands.
  Overlapping loads are sequenced so a slow older answer cannot
  overwrite a fresher one.
* **A missed call in the Inbox is a conversation row, not a
  notification.** It shows a call icon and "Missed call", bold with the
  unread badge while unseen and plain once seen, with sent / delivered
  / read ticks for the user's own calls - exactly the states a message
  row carries. (The system missed-call notification and the Calls
  screen are unchanged.)
* **Listing groups show the listing's photo.** `GET /negotiate/inbox`
  carries `listing_image` (showcase/first-photo thumb URL, else the
  first legacy inline photo, resolved in one batched media lookup);
  the app draws it in the same 46dp circle, with the category emoji
  only as the no-photo fallback.
* **Call history says so.** The Inbox header's bare phone icon is a
  labelled "Call history" pill (shortened to "Calls" under 360dp,
  full name kept for tooltip and screen readers).


## Reply and Mark as read, and the delivered tick from a closed app (2026-11-11)

Asked for: a message notification should offer Reply, which answers
without opening the app, and Mark as read, also without opening it. And
"delivered" never showed - only sent and seen.

### The thread token

Both needed a request the server would accept from a closed app. The
access token has usually expired by the time a notification is acted on
(it lasts 15 minutes), and renewing it from the background isolate races
the app's own renewal for the same refresh token (section 5). The same was
true of the delivered receipt the background isolate posted when a push
arrived: it went with the expired token and failed, which is why a
message read "Sent" until the chat was opened and then jumped to "Seen".

Each phone's copy of a message push now carries `threadToken`
(`api/security.py` `create_thread_token`; built per phone by
`message_push.per_phone_data` through `push_devices.push_user`'s
`data_for_token`). It names:

- one conversation (`lid` or `sid`, and `bid`, the buyer),
- the side its holder is on there (`role`),
- the phone it was pushed to (`dev`, `push_devices.token_fingerprint` of
  that phone's push token),

and expires after `THREAD_TOKEN_EXPIRE_HOURS` (168: a phone that was off
gets its pushes days later, and a notification can sit in the shade as
long again). Every use is checked against the database as well
(`negotiate._notification_thread`): the phone must still be signed in to
the account (`push_devices.device_signed_in`) and the account still on
that side of the conversation. Signing out, or signing out everywhere,
ends what a notification left behind can do. It opens nothing else: it is
not an access token, and no other route accepts it.

| Route | What it does |
|---|---|
| `POST /negotiate/notification/delivered` | This phone has the conversation: the sender's tick becomes the double tick. Sent as the push arrives. |
| `POST /negotiate/notification/read` | Mark as read: read up to now, and the sender sees "Seen". |
| `POST /negotiate/notification/reply` | Reply: stored and delivered as a direct message (`direct_message`'s checks, broadcast, push and contact-leak audit; `message_limiter`, keyed on the account), with the phone's `client_msg_id` so a retry is stored once. The conversation is marked read. |

Each takes `{"thread_token": ...}` (and `content`, `client_msg_id` for a
reply). 401 means expired, or the phone signed out; 403 the account is no
longer on that side; 404 the listing or store is gone; for a reply, 400 is
an empty message and 429 too many.

### The app

- The other person's message notification has **Reply** (Android's inline
  reply) and **Mark as read** (`NotificationService.messageDetails`). Zeno's
  room's notifications have neither: Zeno is read in its own room.
- What Android draws from a push has no buttons, so the background handler
  draws every direct message push again with them
  (`addFaceToPushed`, which before only redrew one that had a face). The
  push stays a notification + data message: if the app's isolate fails to
  start, Android's own drawing is still there.
- Pressed with the app running, the action is handed to the main isolate;
  with the app closed, `notificationActionBackgroundHandler` handles it
  itself (`handleActionWithoutApp`). Either way the notification goes, the
  request is sent with the thread token, and - for a notification the app
  drew from its own sweep, which has no token, or a token refused - with
  the signed-in session instead.
- A reply that could not be sent is posted back as "Your reply was not
  sent", with the words, and opens the chat when tapped.
- The Inbox's count catches up at once (`onThreadRead`, wired to the
  poller's `nudge`).
- **Delivered.** `markDeliveredFromPush` posts the token first. Without one
  (an older server) it uses the saved session as it is and never renews it
  from the background (`markThreadDelivered(renew: false)`). A push whose
  newest message is Zeno's but which counts the other person's messages
  too (`directUnread`) now delivers those.

### Not covered

- iOS: no actions are registered for message notifications.
- A notification is not taken down on the user's other phones when one of
  them reads the thread.
- Nothing here can work in an APK built without `GOOGLE_SERVICES_JSON`
  (section 3): there are no pushes to carry the token.

Tests: `backend/tests/test_notification_actions.py`,
`flutter_app/test/notification_actions_test.dart`.

## A listing marked unavailable: a text and a push to the seller (2026-11-12)

Raised by the owner: when a buyer marked a listing unavailable it
disappeared at once, and the seller had no way to say it was still for
sale. The listing left every list buyers browse, and the seller's own
dashboard too, since the dashboard reads the same live listings. The only
word of it was a push (`listing_sold_out_reported`) whose tap opened
nothing. Asked for: an SMS to the seller straight away, an FCM push as
well, and a way to revoke the report.

The first report of a listing (`listings/sold_out.py`) still hides it at
once, and after the reporter has their answer (the request's
`BackgroundTasks`) it:

- **pushes the seller**: "A buyer marked your listing unavailable" /
  `"<name>" is hidden from buyers. Still for sale? Open your dashboard and
  tap "Still available".`, data `{type: listing_sold_out_reported,
  listing_id, listing_name, title, body}`. A tap opens the Seller Dashboard
  (`/seller-dashboard`; on a signed-out phone, sign-in). With the app in
  front the app draws it itself on the Updates channel, one per listing
  (`NotificationService.showListingReportedFromPush`).
- **texts the seller**, one 160-character GSM-7 part: `Hey <first name>,
  it's Zeno from BROKA. A buyer marked your listing "<name>" unavailable, so
  it's hidden. Not true? Revoke it on your BROKA dashboard.` A long listing
  name is shortened to keep it to one part. The text goes at any hour:
  unlike the availability nudge, which waits out quiet hours, every hour it
  waits is an hour the listing is hidden from every buyer. The listing's
  "SMS me" switch (`Listing.sms_alerts`) is honoured; turned off, the push
  and the dashboard still tell the seller.
- **once per report**: the text is claimed on
  `Listing.sold_out_texted_at` before it is sent, so the request's task and
  the sweep cannot both send it. A text the provider did not take gives the
  claim back, and the one-minute nudge loop (`send_due_texts`) tries again
  for 24 hours. The seller revoking clears the claim, so a later report is
  texted again. A seller with no number that can take a text is skipped.

The dashboard lists the seller's reported listings above the catalogue
(`GET /listings/reported-unavailable`, `ReportedUnavailablePanel`):
**Still available** revokes every open report
(`DELETE /listings/{id}/sold-out`) and puts the listing back in front of
buyers; **It's sold** removes it, after asking.

Tests: `backend/tests/test_sold_out_reports.py` (`TestTellingTheSeller`),
`flutter_app/test/listing_unavailable_test.dart`.


## "Delivered" means the phone has it (2026-11-12)

Asked for: the double tick must mean the recipient's phone received the
message, with the app in the background, closed, or the phone locked.
Firebase accepting a push is not delivery, a receipt that failed must
never pass for one, and a notification arriving is never "Seen".

The tick ladder, unchanged: one grey tick is "Sent" (the server has it),
two grey ticks are "Delivered" (the other side's delivery watermark is at
or after the message), two purple ticks are "Seen" (their read watermark
is). `receiptFor` in `flutter_app/lib/widgets/message_receipt.dart`
computes all three from the two watermarks. Nothing turns FCM's message
id into a watermark (`FcmResult.message_id` is logged, never stored).

### What was wrong

1. **One try, then nothing.** The push handler posted
   `POST /negotiate/notification/delivered` once. A phone woken from Doze
   for a high-priority push often has no network for its first request
   (the call receipt found the same, 2026-10-25). From a closed app
   nothing reports the receipt again until the app next runs in front,
   and by then the chat is usually opened, so the sender went from one
   tick straight to "Seen".
2. **The watermark went to the moment the receipt landed, not to the
   message the push announced.** A receipt that landed late (a retry, a
   slow phone, or the handler run again when its notification is
   dismissed, [flutterfire#12326](https://github.com/firebase/flutterfire/issues/12326))
   marked as delivered everything the sender had written since, which
   this phone had not been shown to have. The sender's open chat was sent
   the same instant, and the chat applies receipts forward only and saves
   them, so the false tick stayed.
3. **A refused token fell back to the saved session, whoever's it was.**
   With two BROKA accounts on one phone, a push for the account signed out
   that arrived after the switch was refused (the phone is no longer that
   account's) and then reported by the other account's session, which
   moved a watermark on that account's own thread for a message it never
   got. The same fallback ran after a network failure, where it could not
   succeed either.
4. **The same push acknowledged twice was announced to the sender twice.**
5. **Nothing was logged.** The server wrote no line for a receipt,
   accepted or refused; the phone wrote "refused: HTTP 401" with no
   conversation or message.
6. With the app in front, the notification waited on the receipt (up to
   15 s on a bad connection). With it closed, the redrawn notification
   with Reply and Mark as read waited too.

### What changed

**Server** (`api/routers/negotiate.py`):

- `POST /negotiate/notification/delivered` takes an optional
  `message_id`, the push's `messageId`. The message must be news for that
  side of that conversation (`visible_to_role_clause`, the push's own
  audience rule); one from another thread, or one this side wrote,
  answers 404 and moves nothing. The delivery watermark moves up to that
  message's `created_at`, never past it and never back
  (`_move_watermark`'s `delivered_up_to`). Without `message_id` (app
  builds from before this) it moves to now, as before.
- The sender's open chat is sent the watermark the row now holds, and only
  when it moved. The answer says the same: `last_delivered_at`,
  `advanced`.
- A refusal is logged with its reason: `token_expired` (named by the
  token's verified claims), `token_invalid`, `device_signed_out`,
  `listing_gone` / `store_gone`, `not_on_that_side`,
  `message_not_in_thread`.
- Never a read: this endpoint moves only the delivery watermark.

**App** (`NotificationService.markDeliveredFromPush`):

- The receipt names the message (`ApiService.notificationDelivered`).
- No answer, a timeout, 408, 429 or 5xx is tried again after 1, 3 and 6
  seconds (`deliveryAckRetryDelays`), within 20 seconds in all
  (`deliveryAckBudget`), each try timing out at 8. Firebase guarantees a
  push handler about ten seconds before Android may stop the process
  ([Firebase blog](https://firebase.blog/posts/2017/03/using-firebase-cloud-messaging-with/));
  a try cut off by that is not claimed. Any other answer is final.
- A token the server refused is final: no session fallback. Only an older
  server's push (no token) uses the saved session, and only when that
  session is the account the push was for (a buyer's push is the buyer's;
  a seller's is never the buyer's). From the background isolate it is
  still never renewed.
- A token that cannot be one (empty, over 4096 characters, with spaces) is
  not sent. Expiry is the server's to judge, not the phone clock's.
- The same push handled twice at once sends one receipt.
- The notification and the receipt run side by side, in front and in the
  background.
- `markDeliveredFromPush` answers a `DeliveryAckOutcome`: `acknowledged`,
  `skipped`, `refused` or `failed`. Only `acknowledged` came from the
  server recording the receipt. A receipt that failed or was refused stays
  undelivered until the app's own sweep reports the thread when it next
  runs in front (`GlobalPollerService`, unchanged), or the chat is read.

### Logs

Phone (`debugPrint`, which reaches logcat in release builds as `flutter`),
one line per step, each with `at=` (UTC), the conversation, buyer, side,
message id and `transport=background|foreground`:

```
[Push] PUSH_RECEIVED type=new_message thread=<listing> buyer=<id> role=seller message=<id> fcm_id=<FCM message id> latency_ms=840 has_token=true transport=background
[Push] DELIVERY_ACK_STARTED ... via=thread_token attempt=1
[Push] DELIVERY_ACK_RETRY ... status=- reason=no_answer:SocketException attempt=2 after_ms=1000
[Push] DELIVERY_ACK_SUCCESS ... status=200 attempt=2 advanced=true watermark=2026-11-12T09:00:00.123456Z
[Push] DELIVERY_WATERMARK_UPDATED ... last_delivered_at=2026-11-12T09:00:00.123456Z
[Push] DELIVERY_ACK_FAILED ... status=401 reason=token_rejected attempt=1 final=true
[Push] DELIVERY_ACK_SKIPPED ... reason=zeno_only
```

API (`api.routers.negotiate`, INFO):

```
[negotiate] DELIVERY_WATERMARK_UPDATED thread=<listing>:<buyer> role=seller user=<id> message=<id> from=- to=2026-11-12T09:00:00.123456Z source=push_receipt
[negotiate] DELIVERY_ACK_SUCCESS thread=<listing>:<buyer> role=seller user=<id> device=<fingerprint> message=<id> bounded=True advanced=True watermark=...
[negotiate] DELIVERY_ACK_FAILED action=delivered status=401 reason=device_signed_out user=<id> device=<fingerprint> role=seller thread=<listing>:<buyer>
```

Never logged: the thread token, a push token (only its
`token_fingerprint`), an access token, or what a message says.

### Checking a phone

Not device-tested: there was no Android device or SDK where this was
written, so all of the above is code and unit-test evidence. On two
phones, with `adb logcat -s flutter` on the recipient and the API log
open, send a message to the recipient and expect `PUSH_RECEIVED`,
`DELIVERY_ACK_SUCCESS` on the phone and `DELIVERY_WATERMARK_UPDATED` on
the API, and the sender's tick turning to "Delivered" (not "Seen") within
seconds, in each of these cases:

| Case | Expect |
|---|---|
| App in front | `transport=foreground`; the notification shows at once |
| App in background | `transport=background`; the notification is redrawn with Reply and Mark as read |
| Swiped away (not force-stopped) | as in the background. A force-stopped app gets no pushes at all until reopened ([Firebase docs](https://firebase.google.com/docs/cloud-messaging/flutter/receive)) |
| Screen locked for 30+ min (Doze) | `latency_ms` small for a high-priority push; possibly `DELIVERY_ACK_RETRY ... no_answer` before the success |
| Network off, then on | nothing until the network is back; then the push arrives and is acknowledged. A message sent while offline stays "Sent" |
| Signed in long ago (expired session) | still acknowledged: `via=thread_token` needs no session |
| Account A signed out, B signed in on the same phone | a push for A still in flight is refused (`reason=device_signed_out` on the API, `status=401 ... final=true` on the phone), and B's session sends nothing for it |
| Push more than 7 days late | `reason=token_expired`; delivered when the app next runs |

On Tecno, Infinix and Xiaomi builds, also test with and without the
battery exemption (section 2). Android's per-app "background data" switch
blocks the receipt's request even when the push arrives; it shows as
`DELIVERY_ACK_FAILED ... reason=no_answer:...`.

### Not covered

- iOS: the message push is an alert push without `content-available`, so
  the app's handler does not run for it with the app in the background,
  and no receipt is sent until the app is opened.
- A receipt that has used up its 20 seconds is not kept for a later try;
  the next push for the same conversation covers it (its receipt names a
  newer message), and the app's sweep covers the rest when the app runs.
- The sweep's own `mark-delivered` (and the chat's) still moves the
  watermark to now: those follow a fresh fetch, but a message written in
  the instant between the fetch and the receipt is counted.
- FlutterFire may not run the handler for every push when many arrive at
  once for a killed app
  ([flutterfire#9549](https://github.com/firebase/flutterfire/issues/9549));
  a later push's receipt covers the earlier messages.

Tests: `backend/tests/test_push_delivery_receipts.py`,
`flutter_app/test/background_delivery_receipt_test.dart`,
`flutter_app/test/delivery_receipt_retry_test.dart`.


## No message lost to an offline recipient, and a log that says so (2026-11-12)

Asked for: a message sent while its recipient is offline (no signal, phone
off, BROKA closed or the phone locked) must reach them, and show, when they
reconnect and open or resume the app, whatever happened to its push. The
API log on Render must show, per message, whether it was saved, pushed,
delivered or read, without a phone's logcat. "Delivered" must be the
recipient's app saying it has the message. Firebase accepting a push is
not delivery.

### What was wrong

1. **Nothing about a push was stored.** The debounced push lived in memory.
   A push that reached no phone (FCM unavailable, the phone offline, no
   token registered yet) was only tried again if another message arrived in
   the same thread or a phone registered. A restart lost every push still
   waiting out its debounce. The only trace was one line per thread,
   `MESSAGE_PUSHED phones=0`, with no message id.
2. **"Delivered" was a guess.** The app's Inbox sweep posted
   `mark-delivered` for a whole thread as soon as its inbox row showed
   something unread. That was before it had fetched a single message, and
   the watermark moved to "now". A conversation the user never opened was
   never on the phone.
3. **No record per message.** Delivery and read lived only in the
   per-thread watermarks (ThreadReadState), so "what happened to message X?"
   had no answer, in the database or the log.
4. **Nothing caught a phone up when it came back.** Each conversation
   loaded its history only when opened. Nothing ran when the network
   returned.

### How it works now

**Server.** The `message_deliveries` table (`api/models/message_delivery.py`,
schema revision 17) has one row per message and recipient. The session hook
in `message_push.py` writes it in the message's own transaction, so a
saved message is a tracked message, whichever code path wrote it. On
PostgreSQL the INSERT runs in a savepoint: if tracking fails, the message
still saves and `MESSAGE_TRACKING_FAILED` is logged. Who gets a row follows
`recipients_of`: the other side gets direct messages, and each side gets
Zeno's messages addressed to it. A buyer's private words to Zeno and call
cards get no row.

| Status | Set when |
|---|---|
| `SAVED` | The message committed. |
| `PUSH_PENDING` | A push attempt claimed it (`message_delivery.claim_for_push`). |
| `PUSH_ACCEPTED` | FCM accepted the push for at least one phone. Not delivery. |
| `PUSH_FAILED` | No phone accepted. `push_error` is FCM's code (`UNAVAILABLE`, `UNREGISTERED`...) or ours (`NO_DEVICES`, `PUSH_NOT_CONFIGURED`, `NOT_ANNOUNCED`). |
| `DELIVERED` | The app said it has the message: `POST /negotiate/sync/ack` (the offline sync stored it, or an open chat holds it), or the push receipt `POST /negotiate/notification/delivered` naming that message. |
| `READ` | A read receipt: the chat opened (`mark-read`), Zeno's room (`zeno-read`, Zeno's messages only), or Mark as read / Reply on the notification. |

A row only moves up that ladder. The one way back is a failed push being
tried again. A push result that lands after the app has acknowledged the
message leaves `DELIVERED` alone, and a delivery receipt after `READ`
changes nothing. A push receipt delivers only the message it names. The
"3 new messages" it counted were announced to the phone, not given to it;
the sync delivers those. The legacy `mark-delivered` still moves the
sender's tick, as older app builds expect, but records no delivery. The
chat socket's connect-time watermark is unchanged too.

**Retries.** `workers._message_delivery_loop` runs every 30 seconds, under
an advisory lease so only one replica runs it:

- A transient failure (`UNAVAILABLE`, `INTERNAL`, `QUOTA_EXCEEDED`, a
  timeout, a lookup error) is retried 30 s, 1 min, 2 min and 4 min later.
  There are five attempts in all.
- A permanent failure is not retried. That covers `NO_DEVICES`,
  `UNREGISTERED` (the token is deleted, as before), `SENDER_ID_MISMATCH`,
  `INVALID_ARGUMENT` and `PUSH_NOT_CONFIGURED`. A phone that registers later
  still gets the register-time re-push.
- A row the debounced push never took, because of a restart or an error,
  is due 20 seconds after it was saved.

Each retry goes through the same `push_thread`, under the same lock, as
the first try. The rows are the queue, so a restart loses nothing, and no
worker service or paid queue is needed. A message whose push was given up
is still delivered by the sync.

**The offline sync.**

- `GET /negotiate/sync` hands out the caller's undelivered messages:
  - every conversation, oldest first, a page at a time (`limit` up to 200);
  - pages run in (sent time, id) order through `after=<next_cursor>`, so
    messages with the same timestamp are neither skipped nor repeated;
  - the shape is `/history`'s, plus `listing_id`/`store_id`, `buyer_id`,
    `my_role` and `room` (`direct` or `zeno`);
  - each row must also pass `visible_to_role_clause` for its side.
- Handing a message out is not delivery. It stays in these pages until
  `POST /negotiate/sync/ack {message_ids, source, sync_id, final}`. That
  marks each one `DELIVERED` once, and moves the sender's double tick up to
  the newest message acknowledged in each conversation, never further.
- An id that is not the caller's own message is answered as `unknown` and
  changes nothing.
- The server keeps the "undelivered" record, not a cursor on the phone.
  So a message that committed after a later one, a sync cut off half way,
  and a sync run twice are all covered by asking again.

**The app** (`lib/services/message_sync_service.dart`):

- **When it runs:**
  - sign-in or app start (`GlobalPollerService.start`);
  - return to the foreground (`catchUp`);
  - the network coming back (`ConnectivityMonitor`, and the Inbox sweep
    reaching the server after failing);
  - a conversation opening, in either chat screen;
  - a message push arriving with the app in front;
  - the Inbox sweep finding news it has not seen. This replaces the
    sweep's thread-wide `mark-delivered`.
- **Storing before acknowledging.** Each page is stored in the
  conversation's own on-device cache, `direct_<listing | store:<id>>_<buyer>`
  or `ai_<listing>_<buyer>`. `LocalChatStore.mergeMessages` keeps each
  message once, by id, in time order, and reports a failed save. Only then
  is the page acknowledged. A message that could not be stored is not
  acknowledged and comes back on the next pass.
- **Open conversations.** An open conversation takes its own messages
  through `MessageSyncService.attach`. It draws them through the same
  `_absorb` as the socket and the poll, so a message that arrives by two
  routes is one bubble.
- **Retries and overlap.** One sync runs at a time; asking during one
  queues one more pass. A failed sync is retried while the app is in front
  (2 s, 5 s, 15 s, 30 s, then every minute). The next request says which
  try it is and why the last one failed (`attempt`, `previous_error`), so
  the API log shows the failures once one gets through.
- **Older servers.** A server without the sync answers 404. The app then
  goes back to the sweep's own receipts and asks again 10 minutes later.
- **A chat open but not looked at** (the app behind the home screen)
  acknowledges the other side's messages by id (`source=chat`). It used to
  post "delivered up to now".
- **Connectivity events.** `ConnectivityMonitor` gets them from
  `ConnectivityBridge.kt` (ConnectivityManager's default-network callback,
  `ACCESS_NETWORK_STATE`). It is a plain channel because connectivity_plus
  7.x does not build with the pinned Flutter 3.24.5. A test APK build with
  connectivity_plus 7.3.1 failed with "Could not get unknown property
  'flutter'", the same break that pins `geolocator_android`.

### The log (Render)

Every event is one INFO line from `api.core.message_delivery`. It starts
with the event name and carries ids only: never a message's words, a push
token, a thread token or a credential. In production the line is the
`msg` of the JSON log record. Each per-message event carries
`message_id conversation_id sender_id recipient_id recipient_role
delivery_status attempt timestamp`. Push events add `device_count`, and
failures add `error`.

| Event | Means |
|---|---|
| `MESSAGE_SAVED` | Committed. `kind`, `from_zeno`. |
| `MESSAGE_PUSH_STARTED` | A push attempt for it. `trigger=message\|retry\|device_registered`. |
| `MESSAGE_PUSH_ACCEPTED` | FCM took it (`accepted` phones of `device_count`). |
| `MESSAGE_PUSH_FAILED` | No phone took it: `error`, `retryable`, `next_retry_in_s`, `final`. |
| `MESSAGE_DELIVERY_RETRY` | Another attempt: `previous_status`, `previous_error`. |
| `MESSAGE_PUSH_SKIPPED` | Nothing left to announce (`reason=NOTHING_UNREAD`): read already. |
| `OFFLINE_SYNC_STARTED` | A phone began a sync: `trigger`, `attempt`, `sync_id`. |
| `MESSAGE_SYNCED_TO_CLIENT` | The sync handed it out (`page`). Not delivery. |
| `MESSAGE_DELIVERY_ACK_RECEIVED` | The app acknowledged it: `source=sync\|chat\|push_receipt`, `result=delivered\|already_delivered\|already_read\|unknown`. |
| `MESSAGE_DELIVERED` | Now `DELIVERED`: `delivered_via`, `since_saved_ms`. A message read before any receipt logs this with `delivered_via=read` just before `MESSAGE_READ`. |
| `MESSAGE_READ` | Now `READ`: `source=chat_open\|zeno_room\|notification_mark_read\|notification_reply`. |
| `OFFLINE_SYNC_COMPLETED` | The last page was acknowledged (`final=true`), or there was nothing to send. |
| `OFFLINE_SYNC_FAILED` | `source=server`: the endpoint failed. `source=client_report`: the phone's earlier try failed (`error`), as it reported on its next one. |
| `MESSAGE_DELIVERY_SUMMARY` | Every 15 minutes: counts by status for the last 24 h, `undelivered_over_10m`, `oldest_undelivered_age_s`. |
| `MESSAGE_TRACKING_FAILED` | ERROR: a tracking write failed; the message itself is unaffected. |

An offline recipient, from the test run (ids shortened):

```
MESSAGE_SAVED message_id=33e1… conversation_id=listing:3065…:40ae… sender_id=40ae… recipient_id=7e4e… recipient_role=seller delivery_status=SAVED attempt=0 kind=text from_zeno=false timestamp=…
MESSAGE_PUSH_STARTED message_id=33e1… … delivery_status=PUSH_PENDING attempt=1 device_count=1 trigger=message
MESSAGE_PUSH_FAILED message_id=33e1… … delivery_status=PUSH_FAILED attempt=1 device_count=1 error=UNAVAILABLE retryable=true next_retry_in_s=30 final=false trigger=message
OFFLINE_SYNC_STARTED recipient_id=7e4e… trigger=connectivity_restored attempt=1
MESSAGE_SYNCED_TO_CLIENT message_id=33e1… … delivery_status=PUSH_FAILED page=1
MESSAGE_DELIVERY_ACK_RECEIVED message_id=33e1… … source=sync result=delivered
MESSAGE_DELIVERED message_id=33e1… … delivery_status=DELIVERED delivered_via=sync since_saved_ms=57
OFFLINE_SYNC_COMPLETED recipient_id=7e4e… acknowledged=1 delivered=1 already_delivered=0 unknown=0
```

To follow one message, search for `message_id=<id>`; for one phone's
syncs, `recipient_id=<id>` with `OFFLINE_SYNC_`. A message whose last line
is `MESSAGE_PUSH_ACCEPTED` or `MESSAGE_PUSH_FAILED final=true` has not
reached the recipient's app yet. The summary line says how many such
messages are older than ten minutes. Rows are kept 60 days.

### What needs the new APK

- **Server only, with today's APK:**
  - the tracking itself;
  - `MESSAGE_SAVED`, the push events, the retries and the summary;
  - `MESSAGE_READ`;
  - `MESSAGE_DELIVERED` from a push receipt, since the current APK already
    names the message.
- **The new APK:**
  - the offline sync (`OFFLINE_SYNC_*`, `MESSAGE_SYNCED_TO_CLIENT`, and
    `DELIVERED` via `sync`/`chat`);
  - running it when the network returns;
  - acknowledging by id from an open chat.

  A phone on an older APK keeps working as before. Its messages show
  `DELIVERED` only through a push receipt or a read.

### Not covered

- **Messages from before this deployment** have no rows. They are not
  synced or logged, but they are still in the Inbox and each chat's
  history.
- **A closed app syncs when it next runs.** Until then a push receipt
  delivers the one message the push named. The sync does not run in the
  FCM background isolate: its access token has usually expired there, and
  renewing it races the app (see "Reply and Mark as read").
- **iOS** has no connectivity events (the sync runs on start, resume and
  when the sweep gets through again), and still sends no background push
  receipt.
- **Ticks versus the record.** The chat socket's connect-time watermark and
  older builds' `mark-delivered` still move the sender's tick without a
  per-message delivery.
- **Not device-tested.** No Android device or SDK was available where this
  was written. On two phones, check each case in the table under "Checking
  a phone" above. The recipient's `OFFLINE_SYNC_STARTED trigger=…` should
  appear on reconnecting, then `MESSAGE_DELIVERED delivered_via=sync` for
  each message sent while it was offline.

Tests: `backend/tests/test_offline_delivery.py` (scenarios A-G, retries,
restarts, privacy), `flutter_app/test/message_sync_test.dart`,
`flutter_app/test/direct_chat_offline_sync_test.dart`.
