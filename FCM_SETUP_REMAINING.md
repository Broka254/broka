# FCM Setup — Remaining Steps

All the code-side FCM client integration is now done (calling-hardening
pass, see CHANGES.md's "Round 22" entry for the full detail). What's left
is entirely **external configuration** that only Xavier can do — none of
it can be committed to this repo, and none of it can be completed from a
sandboxed coding environment with no Firebase account access, no network,
and no physical device.

## What's now in place (backend) — unchanged from before

- `backend/api/routers/calls.py`: `_get_fcm()` / `_send_fcm()` work using
  `firebase-admin` and the `FIREBASE_SERVICE_ACCOUNT_JSON` env var on
  Render.
- `POST /calls/register-token` stores a device's FCM token
  (`User.fcm_token`), overwriting whatever was there before — this is
  what keeps a token correctly associated with whichever user is
  currently authenticated on a given device.
- **Changed this pass:** the incoming-call push is now sent **data-only**
  (no FCM `notification` block) — see below for why.

## What's now in place (Flutter) — all newly wired up this pass

- `pubspec.yaml`: `firebase_core` and `firebase_messaging` added. **Not
  verified against a live pub.dev** (no network in the sandbox this was
  written in) — versions are a best-effort estimate compatible with this
  project's Flutter/Dart SDK constraint. Run `flutter pub get`; bump if
  it reports an incompatibility.
- `android/settings.gradle` + `android/app/build.gradle`: Google Services
  Gradle plugin declared and applied **conditionally** — only if
  `android/app/google-services.json` exists. The app builds exactly as
  it does today until that file is added; nothing breaks in the
  meantime.
- `lib/main.dart`: `Firebase.initializeApp()` (wrapped in try/catch — see
  below), the background message handler
  (`firebaseMessagingBackgroundHandler`, a top-level
  `@pragma('vm:entry-point')` function as required), `onMessage`
  (foreground), `onMessageOpenedApp` (background tap), `getInitialMessage()`
  (cold-start tap — stashed in `pendingColdStartCallData` and consumed by
  `SplashScreen`), and `onTokenRefresh`.
- `lib/services/notification_service.dart`: `handleForegroundFcmMessage()`
  reuses the same `showIncomingCall()` the poller already calls, so
  foreground behavior is identical regardless of which mechanism detected
  the call. `navigateFromPayload()` (unchanged from before this pass)
  handles taps from both local notifications and FCM.
- `lib/services/global_poller_service.dart`: registers (or re-registers)
  the device's FCM token every time a session begins — `start()` is
  already called from every login/registration/biometric-reauth/
  session-restore path, so this covers all of them from one place rather
  than duplicating the call at each site.
- `lib/services/api_service.dart`: `registerFcmToken()` already existed
  in this file before this pass but was never called from anywhere —
  it's now wired in via the above.
- The dormant, never-imported `lib/core/notifications/` (a complete but
  entirely unused parallel implementation) has been **removed** — it's
  now genuinely superseded by the above, and keeping it around would
  have been exactly the "duplicate notification handling" this pass was
  asked to avoid.

### Why the incoming-call push is now data-only

An FCM message with a `notification` block gets auto-displayed by the OS
using generic system styling whenever the app isn't in the foreground —
for an incoming call, that means a plain banner instead of our own rich
notification (full-screen intent, custom ringtone, call-specific
styling). Data-only messages always reach the app's own handlers
instead, which build the real thing. This only changes the one call
push in `calls.py` — other FCM sends elsewhere in the backend
(`workers.py`'s reminder/nudge notifications) are untouched.

### The Firebase.initializeApp() guard

Every bit of the above is wrapped so that **without** a real
`google-services.json`, the app runs exactly as it did before this
pass — local notifications via polling only, nothing crashes. This
matters because that file can't be committed and doesn't exist in this
repo; the app must keep working for anyone building it before Xavier's
own Firebase project is set up.

## What's genuinely still needed (external to this repo)

1. **Create a Firebase project** (Firebase console — free, no card
   needed for FCM on the Spark plan).
2. **Register the Android app** in that project with package name
   `com.broka.app`, download the resulting `google-services.json`, and
   place it at `flutter_app/android/app/google-services.json`. It's
   already git-ignored — never commit it.
3. **Set `FIREBASE_SERVICE_ACCOUNT_JSON`** on Render (backend push
   sending) — a *service account* JSON from the same Firebase project's
   project settings, not the Android app's `google-services.json` (they
   are different files serving different purposes).
4. **Run `flutter pub get`** and confirm the `firebase_core`/
   `firebase_messaging` versions above actually resolve for this
   project — adjust if not.
5. **Run `flutter analyze` and a real build** (debug at minimum, release
   if signing is set up) — none of the above has been compiled or run
   anywhere; it's been written and reasoned through carefully, not
   executed.
6. **Physical-device verification**: foreground, backgrounded, and fully
   terminated incoming-call delivery, on a real Android device with the
   real Firebase project connected. Nothing above has been confirmed to
   actually wake a terminated app or show the right notification — that
   can only be confirmed on a device.
7. **iOS**: none of the above touches iOS. See CALLING.md — iOS calling
   (PushKit/CallKit) remains a deferred, unimplemented platform target,
   not something this pass added partial support for.

## Once steps 1–3 are done and 4–6 pass

`GlobalPollerService` can be scaled back to a much longer interval (or
removed for calls specifically, keeping it for messages) — it's
currently still a full-strength foreground fallback since FCM's actual
delivery hasn't been device-verified yet, and stepping it down before
that would risk losing incoming-call delivery entirely if the untested
FCM path doesn't work as written.
