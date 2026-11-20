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

Admin email (send_admin_email, at the end of this file) is a second, separate
path through the same Resend account: the dashboard's Email Reply tool, one
message to one address, from BROKA_ADMIN_EMAIL_FROM. It shares RESEND_API_KEY
and nothing else with the verification codes - not the circuit breaker, not
the sender, not the Reply-To - so a bad run of admin sends cannot stop a
verification code from going out.
"""
from __future__ import annotations

import hashlib
import logging
import re
from dataclasses import dataclass
from html import escape as _escape_html
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
            "RESEND_API_KEY) — logging instead of sending. recipient, "
            "subject and body redacted",
        )
        return True


class ResendEmail:
    """Resend transactional email API."""

    _URL = "https://api.resend.com/emails"

    async def _send_once(self, to: str, subject: str, html: str, text: str) -> Optional[str]:
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
            # A Resend error body can echo the recipient and request details.
            # Status plus the provider exception is enough to diagnose it
            # without putting customer identity in ordinary logs.
            logger.error("[email:resend] send rejected status=%s", resp.status_code)
            resp.raise_for_status()

        # A 200 carries the queued message id. Its absence means the request
        # was accepted but nothing was queued, which is not a success.
        message_id = (resp.json() or {}).get("id")
        if not message_id:
            logger.error("[email:resend] accepted but no message id (recipient redacted)")
            return None
        logger.info("[email:resend] queued id=%s (recipient redacted)", message_id)
        return str(message_id)

    async def send(self, to: str, subject: str, html: str, text: str) -> bool:
        try:
            message_id = await _resend_breaker.call(
                self._send_once, to, subject, html, text
            )
        except CircuitOpenError:
            # No request left this process: nothing was handed to the
            # provider and nothing can have been billed.
            logger.error("[email:resend] circuit open; email not sent")
            return False
        except httpx.HTTPError as e:
            logger.error("[email:resend] send failed err=%s", type(e).__name__)
            await self._record(status="failed", failure=type(e).__name__)
            return False

        if message_id:
            await self._record(status="success", message_id=message_id)
            return True
        # A 200 with no message id means Resend accepted the call but queued
        # nothing. It is not a send, and it is recorded as a failure.
        await self._record(status="failed", failure="no_message_id")
        return False

    @staticmethod
    async def _record(
        *, status: str, message_id: Optional[str] = None, failure: Optional[str] = None
    ) -> None:
        """Usage row for the production-cost catalogue. Never raises."""
        try:
            from api.domains.service_costs.service import record_usage

            kwargs = {
                "service_key": "email.resend",
                "operation_type": "email.send",
                "status": status,
                "quantity": 1,
                "metadata": {"category": "verification_otp"},
            }
            if message_id:
                kwargs["provider_reference"] = message_id
                kwargs["operation_id"] = f"email:resend:{message_id}"
            else:
                # A failed attempt has no provider id and no known charge.
                kwargs.update(
                    apply_pricing=False,
                    estimated_cost_minor=None,
                    cost_basis="unpriced",
                    cost_confidence="unknown",
                    metadata={"category": "verification_otp", "failure": failure},
                )
            await record_usage(**kwargs)
        except Exception as exc:  # pragma: no cover - defensive
            logger.warning("[email:resend] usage record failed: %s", type(exc).__name__)


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


# ── Admin email (the dashboard's Email Reply tool) ───────────────────────────
#
# One message to one address, from BROKA_ADMIN_EMAIL_FROM, with replies
# directed to that same address. Nothing here is shared with the verification
# codes above except RESEND_API_KEY: no circuit breaker (the OTP one counts a
# provider 4xx as a failure, so a run of rejected admin sends would have
# switched verification codes off for it), no sender, no Reply-To.
#
# Nothing in this section logs or returns an address, a subject or a body.
# Resend's own error bodies are not logged or passed on either: they can echo
# the recipient and the request.

ADMIN_EMAIL_RECIPIENT_MAX = 254
ADMIN_EMAIL_SUBJECT_MAX = 200
ADMIN_EMAIL_MESSAGE_MAX = 10_000

# One plain ASCII address and nothing else. No display name, no comma-separated
# list, no quoted or bracketed forms: the value goes to the provider as a
# single "to", and anything it could read as a second recipient would turn a
# reply to one person into a mailing. The local part leaves out the legal but
# unused specials (%, !, /, =...) for the same reason. The dashboard's Zod
# schema (lib/api/email-schemas.ts in broka-admin) holds the same rule.
_ADDRESS_ATOM = r"[A-Za-z0-9_+'-]+"
_ADDRESS_LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
_ADDRESS_RE = re.compile(
    rf"{_ADDRESS_ATOM}(?:\.{_ADDRESS_ATOM})*@(?:{_ADDRESS_LABEL}\.)+[A-Za-z]{{2,63}}"
)
_LOCAL_PART_MAX = 64

# A subject is one line: a line break in it is how a header gets a second
# header. A message may break lines and indent, but carries no other control
# characters.
_SUBJECT_CONTROL_RE = re.compile("[\x00-\x1f\x7f\u2028\u2029]")
_MESSAGE_CONTROL_RE = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def normalize_admin_recipient(value: str) -> str:
    """The address, trimmed and with its domain lowercased. ValueError (with a
    message fit to show an administrator, and that does not repeat the input)
    when it is not one plain address."""
    address = (value or "").strip()
    if (
        len(address) > ADMIN_EMAIL_RECIPIENT_MAX
        or not _ADDRESS_RE.fullmatch(address)
        or address.index("@") > _LOCAL_PART_MAX
    ):
        raise ValueError("Enter a valid email address, such as name@example.com")
    local, _, domain = address.partition("@")
    return f"{local}@{domain.lower()}"


def clean_admin_subject(value: str) -> str:
    subject = (value or "").strip()
    if not subject:
        raise ValueError("Enter a subject")
    if len(subject) > ADMIN_EMAIL_SUBJECT_MAX:
        raise ValueError(f"The subject can be at most {ADMIN_EMAIL_SUBJECT_MAX} characters")
    if _SUBJECT_CONTROL_RE.search(subject):
        raise ValueError("The subject must be a single line")
    return subject


def _normalize_newlines(value: str) -> str:
    return (value or "").replace("\r\n", "\n").replace("\r", "\n")


def clean_admin_message(value: str) -> str:
    message = _normalize_newlines(value).strip()
    if not message:
        raise ValueError("Write a message")
    if len(message) > ADMIN_EMAIL_MESSAGE_MAX:
        raise ValueError(f"The message can be at most {ADMIN_EMAIL_MESSAGE_MAX:,} characters")
    if _MESSAGE_CONTROL_RE.search(message):
        raise ValueError("The message contains characters that cannot be sent")
    return message


# "Name <address>" or a bare address, nothing more. The name is limited to
# characters that cannot end the header or start a second address.
_SENDER_RE = re.compile(
    r"(?:(?P<name>[A-Za-z0-9 .,'&_-]{1,64}?)\s*<(?P<addr>[^<>\s]+)>|(?P<bare>[^<>\s]+))"
)


def admin_email_sender() -> Optional[tuple[str, str]]:
    """(From header, Reply-To address) from BROKA_ADMIN_EMAIL_FROM, or None
    when that setting is not exactly one address. Replies go to the address
    the message came from, so the two cannot drift apart."""
    match = _SENDER_RE.fullmatch((settings.broka_admin_email_from or "").strip())
    if not match:
        return None
    try:
        address = normalize_admin_recipient(match.group("addr") or match.group("bare"))
    except ValueError:
        return None
    name = (match.group("name") or "").strip()
    return (f"{name} <{address}>" if name else address), address


def build_admin_email(message: str) -> tuple[str, str]:
    """Returns (html, text) for an administrator's message.

    The text part is the message as written. The HTML part is that same text,
    escaped, in paragraphs: the browser never supplies markup, so there is
    nothing to sanitise and nothing it could inject. Inline styles and no
    <style> block, for the same reason as the verification mail (Gmail strips
    it).
    """
    text = _normalize_newlines(message).strip()
    paragraphs = [p.strip("\n") for p in re.split(r"\n[ \t]*\n\s*", text) if p.strip()]
    body = "".join(
        '<p style="margin:0 0 16px 0;">' + _escape_html(p).replace("\n", "<br>") + "</p>"
        for p in paragraphs
    )
    html = (
        "<!doctype html>\n"
        '<html><head><meta charset="utf-8"></head>\n'
        '<body style="margin:0;padding:0;background:#ffffff;">\n'
        '<div style="max-width:560px;margin:0 auto;padding:24px;'
        "font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;"
        'font-size:15px;line-height:1.6;color:#1a1a1a;">\n'
        f"{body}\n"
        "</div>\n</body></html>"
    )
    return html, text


@dataclass(frozen=True)
class AdminEmailResult:
    """What became of one admin send. `failure` is one of the ADMIN_EMAIL_*
    slugs below, never provider text."""

    ok: bool
    message_id: Optional[str] = None
    failure: Optional[str] = None
    provider_status: Optional[int] = None


ADMIN_EMAIL_NOT_CONFIGURED = "not_configured"      # no key, or no usable sender
ADMIN_EMAIL_REJECTED = "rejected"                  # 400/422: the message itself
ADMIN_EMAIL_SENDER_REFUSED = "sender_refused"      # 401/403: key or sender domain
ADMIN_EMAIL_DUPLICATE = "duplicate_request"        # 409: idempotency key clash
ADMIN_EMAIL_PROVIDER_LIMIT = "provider_limit"      # 429: Resend's own limits
ADMIN_EMAIL_UNAVAILABLE = "provider_unavailable"   # 5xx, anything unexpected
ADMIN_EMAIL_TIMEOUT = "timeout"                    # no answer: outcome unknown
ADMIN_EMAIL_NO_MESSAGE_ID = "no_message_id"        # 2xx, nothing queued

# Shorter than the dashboard proxy's wait (BROKA_API_TIMEOUT, 10s by default),
# so this answers - with a failure - before the proxy gives up on it. Past
# that point the administrator would be told "could not be reached" about a
# message that may have gone out.
_ADMIN_SEND_TIMEOUT = httpx.Timeout(8.0, connect=3.0)

_MESSAGE_ID_MAX = 128


def _admin_http_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=_ADMIN_SEND_TIMEOUT)


def admin_email_provider_key(admin_id: str, client_key: str) -> str:
    """Resend's Idempotency-Key for one administrator's one logical send.

    Resend keeps a key for 24 hours and answers a repeat with the first
    response instead of sending again. That is what makes it safe for the
    dashboard to retry after "no answer": a send that did go out is not sent
    twice. Scoped to the administrator, and hashed, so the browser's value
    never reaches the provider as it was sent.
    """
    return hashlib.sha256(f"admin-email\n{admin_id}\n{client_key}".encode()).hexdigest()


def _classify_admin_status(status: int) -> str:
    if status in (400, 422):
        return ADMIN_EMAIL_REJECTED
    if status in (401, 403):
        return ADMIN_EMAIL_SENDER_REFUSED
    if status == 409:
        return ADMIN_EMAIL_DUPLICATE
    if status == 429:
        return ADMIN_EMAIL_PROVIDER_LIMIT
    return ADMIN_EMAIL_UNAVAILABLE


async def send_admin_email(
    *,
    to: str,
    subject: str,
    message: str,
    provider_key: Optional[str] = None,
) -> AdminEmailResult:
    """Send one admin message through Resend. Never raises for a provider or
    network failure: those come back as an AdminEmailResult.

    The sender and Reply-To come from BROKA_ADMIN_EMAIL_FROM only. `to`,
    `subject` and `message` are validated again here (a ValueError for a
    caller that skipped it), so no path reaches the provider with a value the
    rules above would have refused.
    """
    to = normalize_admin_recipient(to)
    subject = clean_admin_subject(subject)
    message = clean_admin_message(message)

    sender = admin_email_sender()
    if not settings.resend_api_key or sender is None:
        logger.error(
            "[admin-email] not configured: set RESEND_API_KEY and a valid "
            "BROKA_ADMIN_EMAIL_FROM - email NOT sent"
        )
        return AdminEmailResult(ok=False, failure=ADMIN_EMAIL_NOT_CONFIGURED)
    from_header, reply_to = sender

    html, text = build_admin_email(message)
    payload = {
        "from": from_header,
        "to": [to],
        "reply_to": reply_to,
        "subject": subject,
        "html": html,
        # A plain-text alternative on every message, as on the verification
        # mail: spam filters score a mail without one worse.
        "text": text,
    }
    headers = {
        "Authorization": f"Bearer {settings.resend_api_key}",
        "Content-Type": "application/json",
    }
    if provider_key:
        headers["Idempotency-Key"] = provider_key

    try:
        async with _admin_http_client() as client:
            resp = await client.post(ResendEmail._URL, headers=headers, json=payload)
    except httpx.TimeoutException:
        logger.error("[admin-email] no answer from the provider; outcome unknown")
        result = AdminEmailResult(ok=False, failure=ADMIN_EMAIL_TIMEOUT)
    except httpx.HTTPError as exc:
        logger.error("[admin-email] send failed err=%s", type(exc).__name__)
        result = AdminEmailResult(ok=False, failure=ADMIN_EMAIL_UNAVAILABLE)
    except Exception as exc:  # defensive: nothing else may escape with the payload in its frame
        logger.error("[admin-email] unexpected failure err=%s", type(exc).__name__)
        result = AdminEmailResult(ok=False, failure=ADMIN_EMAIL_UNAVAILABLE)
    else:
        result = _read_admin_response(resp)

    await _record_admin_usage(result)
    return result


def _read_admin_response(resp: httpx.Response) -> AdminEmailResult:
    status = resp.status_code
    if not 200 <= status < 300:
        failure = _classify_admin_status(status)
        logger.error("[admin-email] provider refused status=%s failure=%s", status, failure)
        return AdminEmailResult(ok=False, failure=failure, provider_status=status)

    try:
        body = resp.json()
    except ValueError:
        body = None
    message_id = body.get("id") if isinstance(body, dict) else None
    if not isinstance(message_id, str) or not message_id.strip():
        # Accepted but nothing queued: not a send, and recorded as a failure,
        # as for the verification mail.
        logger.error("[admin-email] accepted but no message id status=%s", status)
        return AdminEmailResult(
            ok=False, failure=ADMIN_EMAIL_NO_MESSAGE_ID, provider_status=status
        )
    message_id = message_id.strip()[:_MESSAGE_ID_MAX]
    logger.info("[admin-email] queued id=%s", message_id)
    return AdminEmailResult(ok=True, message_id=message_id, provider_status=status)


async def _record_admin_usage(result: AdminEmailResult) -> None:
    """Usage row for the production-cost catalogue, under its own category so
    admin mail is counted apart from verification codes. Never raises."""
    if result.failure == ADMIN_EMAIL_NOT_CONFIGURED:
        return  # nothing reached the provider, so nothing was used
    try:
        from api.domains.service_costs.service import record_usage

        kwargs = {
            "service_key": "email.resend",
            "operation_type": "email.send",
            "status": "success" if result.ok else "failed",
            "quantity": 1,
            "metadata": {"category": "admin_email"},
        }
        if result.ok:
            kwargs["provider_reference"] = result.message_id
            kwargs["operation_id"] = f"email:resend:{result.message_id}"
        else:
            # A failed attempt has no provider id and no known charge.
            kwargs.update(
                apply_pricing=False,
                estimated_cost_minor=None,
                cost_basis="unpriced",
                cost_confidence="unknown",
                metadata={"category": "admin_email", "failure": result.failure},
            )
        await record_usage(**kwargs)
    except Exception as exc:  # pragma: no cover - defensive
        logger.warning("[admin-email] usage record failed: %s", type(exc).__name__)
