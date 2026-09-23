"""
BROKA - Email Provider (email OTP delivery)
─────────────────────────────────────────────────────────────────────────────
Sends the email-verification OTP during registration. Deliberately mirrors
api/core/sms.py: same Protocol shape, same circuit breaker, same fail-soft
console fallback, so the two delivery channels behave identically under a
provider outage and can be reasoned about together.

Provider: Resend (https://resend.com). Configure via RESEND_API_KEY and
RESEND_FROM.

RESEND_FROM must be an address on a domain verified in the Resend
dashboard. Resend rejects a send from an unverified domain outright, and it
is the single most common reason for "the code never arrived" - so
validate_startup() warns when a production deployment is missing it, and
send() logs the API's own error body rather than a bare failure.

Dev/CI fallback: with no API key configured, the message is logged instead
of sent, so registration is fully testable without a live Resend account -
matching how ConsoleSMS keeps phone signup testable.
"""
from __future__ import annotations

import logging
from typing import Optional, Protocol

import httpx

from api.core.config import settings
from api.core.circuit_breaker import CircuitBreaker, CircuitOpenError

logger = logging.getLogger(__name__)

_resend_breaker = CircuitBreaker("resend_email", failure_threshold=5, recovery_timeout=30)


class EmailProvider(Protocol):
    async def send(self, to: str, subject: str, html: str, text: str) -> bool: ...


class ConsoleEmail:
    """Dev/CI fallback — logs instead of sending. Never raises.

    Refuses in production for the same reason ConsoleSMS does: logging a
    verification code and reporting success would let anyone with log access
    mark any address as verified, while the real owner never gets the code.
    False sends /auth/email/otp/request down its existing 503 path.
    """

    async def send(self, to: str, subject: str, html: str, text: str) -> bool:
        if settings.is_production:
            logger.error(
                "[email:console] no email provider configured in production — "
                "email NOT sent (set RESEND_API_KEY and RESEND_FROM)"
            )
            return False
        logger.warning(
            "[email:console] no email provider configured (checked "
            "RESEND_API_KEY) — logging instead of sending. to=%s subject=%r "
            "body=%r",
            to, subject, text,
        )
        return True


class ResendEmail:
    """Resend transactional email API."""

    _URL = "https://api.resend.com/emails"

    async def _send_once(self, to: str, subject: str, html: str, text: str) -> bool:
        payload = {
            "from": settings.resend_from,
            "to": [to],
            "subject": subject,
            "html": html,
            # Every message carries a plain-text alternative. Without one,
            # spam filters score the mail worse, and a one-time code that
            # lands in spam is indistinguishable to the user from one that
            # was never sent.
            "text": text,
        }
        if settings.resend_reply_to:
            payload["reply_to"] = settings.resend_reply_to

        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(
                self._URL,
                headers={
                    "Authorization": f"Bearer {settings.resend_api_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )

        if resp.status_code >= 400:
            # Resend explains refusals in the body (unverified domain,
            # invalid from-address, rate limit). Surfacing it turns a silent
            # "code never arrived" into something diagnosable. The body
            # describes the request, never the code itself, which lives only
            # in `html`/`text` and is not echoed back.
            logger.error(
                "[email:resend] send rejected to=%s status=%s body=%s",
                to, resp.status_code, resp.text[:500],
            )
            resp.raise_for_status()

        # A 200 carries the queued message id. Its absence means the request
        # was accepted but nothing was queued, which is not a success.
        message_id = (resp.json() or {}).get("id")
        if not message_id:
            logger.error("[email:resend] accepted but no message id to=%s", to)
            return False
        logger.info("[email:resend] queued to=%s id=%s", to, message_id)
        return True

    async def send(self, to: str, subject: str, html: str, text: str) -> bool:
        try:
            return await _resend_breaker.call(self._send_once, to, subject, html, text)
        except (CircuitOpenError, httpx.HTTPError) as e:
            logger.error("[email:resend] send failed to=%s err=%s", to, e)
            return False


def get_email_provider() -> EmailProvider:
    if settings.resend_api_key and settings.resend_from:
        return ResendEmail()
    return ConsoleEmail()


# ── OTP message body ─────────────────────────────────────────────────────────

def build_otp_email(code: str, expires_minutes: int) -> tuple[str, str, str]:
    """Returns (subject, html, text) for a verification-code email.

    The code is repeated in the subject line because most clients preview it
    there, which often saves opening the mail at all.
    """
    subject = f"{code} is your BROKA verification code"

    text = (
        f"{code} is your BROKA verification code.\n\n"
        f"It expires in {expires_minutes} minutes. "
        "If you didn't ask to verify this address, you can ignore this email.\n\n"
        "— BROKA"
    )

    # Inline styles only, and a table-free single-column layout: Gmail strips
    # <style> blocks and Outlook ignores much of flexbox, so anything fancier
    # degrades unpredictably across clients.
    html = f"""<!doctype html>
<html>
  <body style="margin:0;padding:0;background:#03040a;">
    <div style="max-width:480px;margin:0 auto;padding:40px 24px;
                font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
                color:#e3d9f7;">
      <div style="font-size:22px;font-weight:700;letter-spacing:3px;
                  color:#8b5cf6;margin-bottom:4px;">BROKA</div>
      <div style="font-size:11px;letter-spacing:2px;color:#8a9bbf;
                  margin-bottom:32px;">INTELLIGENT COMMERCE</div>

      <div style="font-size:18px;font-weight:600;margin-bottom:8px;
                  color:#e3d9f7;">Verify your email</div>
      <div style="font-size:14px;line-height:1.6;color:#8a9bbf;
                  margin-bottom:24px;">
        Enter this code in the app to confirm this address.
      </div>

      <div style="font-size:34px;font-weight:700;letter-spacing:10px;
                  color:#ffffff;background:#111d35;border-radius:12px;
                  padding:18px 0;text-align:center;margin-bottom:24px;">
        {code}
      </div>

      <div style="font-size:13px;line-height:1.6;color:#8a9bbf;">
        It expires in {expires_minutes} minutes. If you didn't ask to verify
        this address, you can ignore this email.
      </div>
    </div>
  </body>
</html>"""

    return subject, html, text
