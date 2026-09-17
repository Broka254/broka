"""
BROKA v3.0 - FCM Push Notification Service
--------------------------------------------
Sends Firebase Cloud Messaging (FCM) v1 API notifications.
Falls back gracefully when credentials are not configured.

Setup:
  1. Download your Firebase service account JSON from the Firebase console.
  2. Set env var: GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceaccount.json
     OR set FIREBASE_SERVICE_ACCOUNT_JSON=<inline JSON string>

The service fetches an OAuth2 access token using the service account
credentials (no firebase-admin SDK required — just httpx + google-auth).

Usage:
    from api.core.push import push_service
    await push_service.send(
        fcm_token="device-token",
        title="Deal Update",
        body="Your funds have been released!",
        data={"deal_id": "abc-123", "status": "released"},
    )
"""
from __future__ import annotations

import json
import logging
import os
from typing import Optional

import httpx

logger = logging.getLogger(__name__)

FCM_ENDPOINT = "https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"


class PushService:
    def __init__(self):
        self._creds: dict | None    = None
        self._access_token: str | None = None
        self._token_expiry: float  = 0.0
        self._project_id: str | None = None
        self._ready = False
        self._load_credentials()

    def _load_credentials(self) -> None:
        """Load service account JSON from env or file."""
        # Option 1: inline JSON string
        inline = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON")
        if inline:
            try:
                self._creds     = json.loads(inline)
                self._project_id = self._creds.get("project_id")
                self._ready     = True
                logger.info("[push] FCM loaded from FIREBASE_SERVICE_ACCOUNT_JSON")
                return
            except json.JSONDecodeError as e:
                logger.error("[push] Invalid FIREBASE_SERVICE_ACCOUNT_JSON: %s", e)

        # Option 2: file path
        path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
        if path and os.path.exists(path):
            try:
                with open(path) as f:
                    self._creds = json.load(f)
                self._project_id = self._creds.get("project_id")
                self._ready     = True
                logger.info("[push] FCM loaded from %s", path)
                return
            except Exception as e:
                logger.error("[push] Could not load credentials from %s: %s", path, e)

        logger.warning("[push] No FCM credentials configured — push notifications disabled")
        self._ready = False

    async def _get_access_token(self) -> str | None:
        """Fetch / refresh OAuth2 access token for FCM v1 API."""
        import time
        if self._access_token and time.time() < self._token_expiry - 60:
            return self._access_token

        if not self._creds:
            return None

        try:
            # Build JWT assertion
            import base64
            import hashlib
            import struct

            iat  = int(time.time())
            exp  = iat + 3600
            header  = base64.urlsafe_b64encode(
                json.dumps({"alg": "RS256", "typ": "JWT"}).encode()
            ).rstrip(b"=")
            payload = base64.urlsafe_b64encode(json.dumps({
                "iss": self._creds["client_email"],
                "scope": FCM_SCOPE,
                "aud": TOKEN_ENDPOINT,
                "iat": iat,
                "exp": exp,
            }).encode()).rstrip(b"=")

            # Sign with RSA private key
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import padding as rsa_padding

            pem = self._creds["private_key"].encode()
            private_key = serialization.load_pem_private_key(pem, password=None)
            message = header + b"." + payload
            sig = private_key.sign(message, rsa_padding.PKCS1v15(), hashes.SHA256())
            signature = base64.urlsafe_b64encode(sig).rstrip(b"=")

            jwt = (message + b"." + signature).decode()

            async with httpx.AsyncClient(timeout=15) as c:
                resp = await c.post(TOKEN_ENDPOINT, data={
                    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    "assertion": jwt,
                })
            resp.raise_for_status()
            data = resp.json()
            self._access_token = data["access_token"]
            self._token_expiry = iat + data.get("expires_in", 3600)
            return self._access_token

        except ImportError:
            logger.warning("[push] cryptography package not installed — FCM auth unavailable")
            return None
        except Exception as e:
            logger.error("[push] Failed to get FCM access token: %s", e)
            return None

    async def send(
        self,
        fcm_token: str,
        title: str,
        body: str,
        data: Optional[dict] = None,
        image_url: Optional[str] = None,
    ) -> bool:
        """
        Send a push notification to a single device.
        Returns True on success, False on failure (never raises).
        """
        if not self._ready:
            logger.debug("[push] FCM not configured — skipping notification")
            return False

        if not fcm_token:
            logger.debug("[push] No FCM token provided")
            return False

        token = await self._get_access_token()
        if not token:
            return False

        # Build FCM v1 message
        message: dict = {
            "message": {
                "token": fcm_token,
                "notification": {
                    "title": title,
                    "body":  body,
                },
                "android": {
                    "priority": "high",
                    "notification": {
                        "channel_id": "broka_deals",
                        "sound":      "default",
                        "click_action": "FLUTTER_NOTIFICATION_CLICK",
                    },
                },
                "apns": {
                    "payload": {
                        "aps": {
                            "alert": {"title": title, "body": body},
                            "sound": "default",
                            "badge": 1,
                        }
                    }
                },
            }
        }

        if data:
            # FCM data values must be strings
            message["message"]["data"] = {k: str(v) for k, v in data.items()}

        if image_url:
            message["message"]["notification"]["image"] = image_url

        url = FCM_ENDPOINT.format(project_id=self._project_id)
        try:
            async with httpx.AsyncClient(timeout=15) as c:
                resp = await c.post(
                    url,
                    json=message,
                    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                )
            if resp.status_code == 200:
                logger.info("[push] ✅ Sent to %s... title='%s'", fcm_token[:20], title)
                return True
            else:
                logger.warning("[push] FCM error %d: %s", resp.status_code, resp.text[:200])
                return False
        except Exception as e:
            logger.error("[push] Send failed: %s", e)
            return False

    async def send_to_users(
        self,
        user_ids: list[str],
        title: str,
        body: str,
        data: Optional[dict] = None,
        db=None,
    ) -> int:
        """Look up FCM tokens for user IDs and batch-send. Returns success count."""
        if not self._ready or not db:
            return 0

        from sqlalchemy import select
        from api.database import User

        r = await db.execute(
            select(User.fcm_token).where(
                User.id.in_(user_ids),
                User.fcm_token.isnot(None),
            )
        )
        tokens = [row[0] for row in r.all() if row[0]]

        count = 0
        for token in tokens:
            ok = await self.send(token, title, body, data)
            if ok:
                count += 1
        return count

    @property
    def is_ready(self) -> bool:
        return self._ready


# Singleton
push_service = PushService()
