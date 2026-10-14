# BROKA - Firebase Push Notifications Setup

Incoming VoIP call alerts require a Firebase project. This takes ~10 minutes.

---

## Step 1 - Create Firebase project

1. Go to https://console.firebase.google.com
2. Click **Add project** → name it `broka` → disable Google Analytics → **Create project**

---

## Step 2 - Add Android app

1. In Firebase Console → **Project settings** → **Add app** → Android icon
2. Android package name: `com.broka.app`
3. App nickname: `BROKA`
4. Click **Register app**
5. Download **google-services.json**
6. Move it to: `android/app/google-services.json`  ← replace the placeholder

---

## Step 3 - Backend service account

1. Firebase Console → **Project settings** → **Service accounts** tab
2. Click **Generate new private key** → confirm → download the JSON file
3. Copy the entire JSON content
4. Set it as an environment variable on your backend server:
   ```
   FIREBASE_SERVICE_ACCOUNT_JSON={"type":"service_account","project_id":...}
   ```
   On Render/Railway: paste it as a single-line env var in the dashboard.

---

## Step 4 - Enable Cloud Messaging

1. Firebase Console → **Cloud Messaging** (left sidebar)
2. It should already be enabled. If not, click **Enable**.

---

## Step 5 - Build & run

```bash
flutter pub get
flutter run
```

---

## How it works

| Event | What happens |
|---|---|
| Buyer taps **Call** | App calls `POST /calls/initiate` on backend |
| Backend | Looks up seller's FCM token → sends push notification |
| Seller's phone | Receives "📞 Incoming call" notification |
| Seller taps notification | App opens VoIP screen as callee |
| Both connected | Peer-to-peer WebRTC audio begins |

Push notifications also work when the seller's app is **in the background or killed**.

---

## Troubleshooting

- **"Firebase init failed"** in logs → `google-services.json` is missing or wrong package name
- **Calls work but no push notification** → check `FIREBASE_SERVICE_ACCOUNT_JSON` env var on backend
- **iOS push notifications** → also requires APNs certificate in Firebase Console → Project settings → Cloud Messaging → Apple app configuration
