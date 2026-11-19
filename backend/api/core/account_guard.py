"""Refuse requests from a suspended account, whichever route they address.

Blocking sign-in is not enough. A phone that is already signed in holds a
valid access token for up to ACCESS_TOKEN_EXPIRE_MINUTES, and nothing in
`get_current_user` reads the account row - it only verifies the token. So a
suspension that only checked the login form would leave the account fully
usable for another fifteen minutes, and refreshed forever if its refresh token
survived.

This middleware closes both gaps for HTTP requests:

* a blocked account is answered 403 with a machine-readable code, and
* an access token minted before `users.sessions_revoked_at` is answered 401,
  so "sign out everywhere" and a suspension take effect on the next request
  rather than at token expiry.

It is a plain ASGI middleware, not Starlette's BaseHTTPMiddleware: the alert
stream is a `StreamingResponse`, and BaseHTTPMiddleware runs the application
behind an anyio memory stream that delays those chunks - an SSE client waiting
for its first event timed out (tests/test_admin_alerts.py::test_sse_smoke)
even though nothing about the suspension guard was involved in the stream.
Here the guard either answers before the app or calls it and passes `send`
straight through, untouched.

The lookup is cached for VERDICT_TTL_SECONDS per account per process, so an
ordinary request costs a dictionary hit, not a query. A failure inside the
guard is logged and the request continues to the route's own authorization:
an availability problem must not become a lockout, and this guard only ever
adds a refusal, never a permission.
"""
from __future__ import annotations

import logging
from datetime import datetime

from api.core import moderation
from api.security import decode_access_token

logger = logging.getLogger(__name__)


class AccountStatusMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        # Lifespan and WebSockets have their own handlers (each WebSocket
        # already authenticates its token); only HTTP carries the bearer
        # header this guard reads.
        if scope.get("type") != "http":
            return await self.app(scope, receive, send)

        headers = dict(scope.get("headers") or [])
        authorization = headers.get(b"authorization", b"").decode("latin-1")
        refusal = None
        if authorization[:7].lower() == "bearer ":
            payload = decode_access_token(authorization[7:].strip())
            if payload and payload.get("sub"):
                refusal = await self._refusal(payload)

        if refusal is not None:
            status_code, body = refusal
            payload = (
                b'{"detail":"This account is suspended.","code":"ACCOUNT_SUSPENDED"}'
                if status_code == 403
                else b'{"detail":"This session has been revoked. Sign in again.","code":"SESSION_REVOKED"}'
            )
            await send(
                {
                    "type": "http.response.start",
                    "status": status_code,
                    "headers": [
                        (b"content-type", b"application/json"),
                        (b"content-length", str(len(payload)).encode()),
                        (b"cache-control", b"no-store"),
                        (b"www-authenticate", b"Bearer"),
                    ],
                }
            )
            await send({"type": "http.response.body", "body": payload})
            return

        return await self.app(scope, receive, send)

    async def _refusal(self, payload: dict):
        user_id = payload.get("sub")
        verdict = None
        try:
            verdict = await moderation.blocked_verdict(user_id)
        except Exception:
            logger.exception(
                "[account-guard] could not read the account state; "
                "falling through to route authorization"
            )
        if verdict is None:
            return None
        if verdict.get("blocked"):
            return 403, None
        revoked_before = verdict.get("revoked_before")
        issued_at = payload.get("iat")
        if revoked_before is not None and issued_at is not None:
            try:
                # create_access_token writes milliseconds; tokens minted
                # before that carry whole seconds. Split on magnitude (a
                # seconds value is ~1.7e9 today) so both kinds land on the
                # right instant.
                raw = float(issued_at)
                seconds = raw / 1000.0 if raw > 10_000_000_000 else raw
                issued = datetime.utcfromtimestamp(seconds)
            except (TypeError, ValueError, OverflowError):
                issued = None
            if issued is not None and issued < revoked_before:
                return 401, None
        return None
