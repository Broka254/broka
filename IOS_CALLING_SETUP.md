# BROKA iOS calling — what's in the repo, what still needs Xcode

iOS calling is now implemented in code. This documents the parts that
**cannot** be done from a sandbox and need a Mac with Xcode plus an Apple
Developer account.

## What's in the repo now

| File | What it does |
|---|---|
| `flutter_app/ios/Runner/AppDelegate.swift` | CallKit provider + PushKit VoIP registry. Rings, answers, ends, mutes, owns the audio session, bridges to Dart. |
| `flutter_app/ios/Runner/Info.plist` | `UIBackgroundModes` (`voip`, `audio`, `remote-notification`, `fetch`), `NSUserActivityTypes` for CallKit, calling-specific mic/camera usage strings. |
| `flutter_app/ios/Runner/Runner.entitlements` | `aps-environment`. |
| `flutter_app/ios/Podfile` | iOS 13 deployment target (required by CallKit + flutter_webrtc), `permission_handler` macros scoped to the permissions BROKA actually uses. |
| `flutter_app/ios/Runner/Base.lproj/*.storyboard` | The `Main`/`LaunchScreen` storyboards `Info.plist` already referenced but that didn't exist. |
| `flutter_app/lib/services/callkit_service.dart` | Dart half of the bridge. No-op on Android. |
| `backend/api/routers/calls.py` | `_send_voip_push()` — APNs HTTP/2 VoIP push, plus `token_type` on `/calls/register-token`. |
| `backend/api/database.py` | `users.apns_voip_token` column + its `ALTER TABLE` entry. |

Architecture is deliberately the same as Android's: **native rings, Dart
calls.** No WebRTC or signaling logic is duplicated in Swift.

## Step 1 — regenerate the Xcode project (required)

The repo has no `Runner.xcodeproj`, no `Flutter/` xcconfig directory, and no
`Podfile.lock`. Those are machine-generated, UUID-keyed files; hand-writing a
`project.pbxproj` produces a project that *looks* fine and fails in obscure
ways, so it deliberately isn't attempted here.

```bash
cd flutter_app
flutter create --platforms=ios .
```

`flutter create` only fills in what's missing — it will **not** overwrite the
`AppDelegate.swift`, `Info.plist`, `Podfile`, storyboards, or entitlements
above. Then:

```bash
flutter pub get
cd ios && pod install
```

Open `ios/Runner.xcworkspace` (the **workspace**, not the project).

## Step 2 — Xcode capabilities

In Runner → Signing & Capabilities, add:

- **Push Notifications**
- **Background Modes** → tick *Voice over IP*, *Audio, AirPlay and Picture in
  Picture*, *Remote notifications*, *Background fetch*
- Confirm `Runner.entitlements` is picked up under *Code Signing Entitlements*

Set the team and a real bundle id. If it isn't `com.broka.app`, update
`APNS_BUNDLE_ID` in Step 4.

## Step 3 — APNs auth key

Apple Developer → Keys → new key with **Apple Push Notifications service
(APNs)** enabled. Download the `.p8` **once** (it cannot be re-downloaded).
Note the Key ID and your Team ID.

## Step 4 — backend environment

```
APNS_AUTH_KEY=<full contents of AuthKey_XXXX.p8, including BEGIN/END lines>
APNS_KEY_ID=<10-char key id>
APNS_TEAM_ID=<10-char team id>
APNS_BUNDLE_ID=com.broka.app
APNS_USE_PRODUCTION=false   # true for TestFlight/App Store builds
```

`APNS_USE_PRODUCTION` must match `aps-environment` in `Runner.entitlements`
(`development` ↔ false, `production` ↔ true). Mismatching them is the single
most common cause of "the push returns 200 but nothing rings" — Apple accepts
the request against the wrong environment and drops it.

Unset, iOS calls still work while the app is foregrounded (the poller finds
them); they just can't ring a terminated app.

## Step 5 — Firebase for iOS (separate from the above)

`GoogleService-Info.plist` from the Firebase console goes in `ios/Runner/`
and must be added to the Xcode target. This covers non-call notifications;
calls use the PushKit path above. See `FCM_SETUP_REMAINING.md`.

## Must be tested on a real device

PushKit and CallKit **do not work in the simulator** — the simulator has no
push token and no CallKit UI. Everything below needs two physical devices:

- [ ] Incoming audio + video call with the app **terminated** (the case only
      PushKit covers).
- [ ] Answering from the lock screen on a terminated app — exercises the
      `pendingAnsweredCall` cold-start replay in `AppDelegate.swift`.
- [ ] Ending from the native CallKit UI actually tears down the peer
      connection (mic light goes out).
- [ ] Muting from the native UI mutes the real audio track.
- [ ] Backgrounding and locking mid-call keeps audio flowing.
- [ ] An incoming cellular call during a BROKA call.
- [ ] Camera permission denied → the call still connects as audio-only.

One known constraint worth designing around: iOS requires that a VoIP push
report a call to CallKit **every time**. If the app receives a VoIP push and
doesn't, iOS kills the process and eventually revokes VoIP push delivery
entirely. `AppDelegate.swift` calls `reportNewIncomingCall` unconditionally,
before any parsing that could fail, for exactly this reason — don't move it
behind a validity check.
