"""
BROKA v6.3 - SMS Provider (phone OTP delivery)
─────────────────────────────────────────────────────────────────────────────
Sends the registration/login OTP by SMS. Follows the same
external-dependency house style as api.core.circuit_breaker (used for
Gemini/Groq) - wrap the network call, fail soft, never let an SMS-provider
outage take down registration.

Providers, in priority order (see get_sms_provider):
  1. Texin BulkSMS — Kenyan bulk SMS gateway (https://sms.texin.co.ke/api).
     Configure via TEXIN_API_KEY. No sandbox mode; sends are live and
     billed (KES 0.29/unit) from the first call, so this is only picked
     when the key is actually set.
  2. Africa's Talking — optional fallback. Configure via
     AT_USERNAME / AT_API_KEY.

Dev/CI fallback: if neither provider is configured, OTPs are logged
instead of sent, so registration is fully testable without a live SMS
account. This mirrors how GEMINI_API_KEY / GROQ_API_KEY being unset doesn't
crash the AI broker - it degrades to the next thing in the chain.

Mobitech Technologies was the primary before Texin and is now deprecated:
MobitechSMS below still works (and its /sms/dlr webhook stays live for
in-flight reports), but get_sms_provider() never selects it, so stale
MOBITECH_* values left in Railway/Render cannot override Texin.
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import logging
import random
import re
from typing import Any, Optional, Protocol

import httpx

from api.core.config import settings
from api.core.circuit_breaker import CircuitBreaker, CircuitOpenError

logger = logging.getLogger(__name__)

_PHONE_RE = re.compile(r"(?<!\d)(?:\+?254|0)7\d{8}(?!\d)")


def _redact_phone_text(value: str) -> str:
    """Provider diagnostics are useful; customer phone numbers are not."""
    return _PHONE_RE.sub("<phone-redacted>", value or "")


def _redact_result(value):
    if isinstance(value, dict):
        return {
            key: ("<redacted>" if key.lower() in {
                "mobile", "phone", "msisdn", "recipient", "message", "to",
            } else _redact_result(item))
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_redact_result(item) for item in value]
    if isinstance(value, str):
        return _redact_phone_text(value)
    return value

_mobitech_breaker = CircuitBreaker("mobitech_sms", failure_threshold=5, recovery_timeout=30)
_at_breaker       = CircuitBreaker("africas_talking_sms", failure_threshold=5, recovery_timeout=30)
_texin_breaker    = CircuitBreaker("texin_sms", failure_threshold=5, recovery_timeout=30)


# ── Kenyan phone-number normalization ─────────────────────────────────────────
# BROKA hands every provider a number normalized here, so no provider (and no
# caller) reformats phones its own way. Accepted inputs:
#   "0706462869"   (local 0-prefixed)  -> "254706462869"
#   "254706462869" (already normalized) -> unchanged
#   "+254706462869"                    -> "254706462869"
# Anything else Kenyan-shaped is rejected (None): a malformed recipient must
# fail before a billed send, not after. Non-Kenyan international numbers are
# preserved only as far as BROKA's existing validation goes — which is light
# (auth/service.py only prepends "+"), so a "+"-prefixed 7-15 digit number is
# passed through with the "+" stripped, and anything else is rejected.

_KE_MOBILE_RE = re.compile(r"^254[17]\d{8}$")


def normalize_ke_phone(phone: Optional[str]) -> Optional[str]:
    """Normalize `phone` to Texin's expected digit format, or None.

    Kenyan mobiles (07…/01… local, 254…/​+254… international) become
    254…; anything Kenyan-shaped but invalid is rejected before a billed
    send. Other digit strings are preserved as-is (existing BROKA
    validation is light — see module comment) and only rejected when
    they cannot be a phone number at all.
    """
    if not phone or not isinstance(phone, str):
        return None
    p = re.sub(r"[\s\-().]", "", phone.strip())
    if p.startswith("+"):
        p = p[1:]
    # A second leading "+" (e.g. "++254...") is a typo, not a number.
    if not p.isdigit():
        return None
    if len(p) == 10 and p.startswith("0"):
        p = "254" + p[1:]
    if p.startswith("0") or p.startswith("254"):
        # Kenyan-shaped: valid KE mobile or nothing (a mistyped KE
        # number must fail here, not as a billed provider rejection).
        return p if _KE_MOBILE_RE.match(p) else None
    if 7 <= len(p) <= 15:
        return p
    return None


# ── GSM-7 message compatibility ───────────────────────────────────────────────
# Texin's account documentation specifies GSM 03.38 (GSM-7) only — Unicode
# (emoji, curly quotes, smart dashes) is not supported. OTP/notification
# bodies are normalized to plain ASCII here, for the SMS copy only: the
# original in-app notification text is never modified, and messages are
# never truncated — a longer text simply bills as multiple units, which
# Texin reports back as units_used (recorded by the cost ledger).

_UNICODE_FALLBACKS = {
    "\u2018": "'", "\u2019": "'", "\u201a": "'", "\u201b": "'",
    "\u201c": '"', "\u201d": '"', "\u201e": '"', "\u201f": '"',
    "\u00ab": '"', "\u00bb": '"',
    "\u2013": "-", "\u2014": "-", "\u2212": "-",
    "\u2026": "...", "\u2022": "*", "\u00b7": "*",
    "\u00a0": " ", "\u2007": " ", "\u202f": " ",
    "\u2713": "v", "\u2714": "v", "\u2717": "x", "\u2718": "x",
}


def sms_to_gsm7(text: str) -> str:
    """Return a GSM-7-safe ASCII rendering of `text` for the SMS copy.

    Curly quotes/dashes map to their ASCII counterparts; emoji and any
    other non-ASCII characters are removed (not replaced, not truncated).
    """
    out: list[str] = []
    for ch in text or "":
        if ch in _UNICODE_FALLBACKS:
            out.append(_UNICODE_FALLBACKS[ch])
        elif ord(ch) < 128:
            out.append(ch)
        # else: unsupported character (emoji, accented letter, …) — dropped.
    return "".join(out)


# GSM-7 extension-table characters cost two septets each; everything else
# ASCII costs one. A single SMS holds 160 septets, each concatenated part
# 153 — so the segment count (and hence the billed units) follows from the
# septet count, not the character count.
_GSM7_EXTENSION = set("[]{}|^\\€~")


def sms_gsm7_segments(text: str) -> int:
    """Number of SMS segments a GSM-7-normalized `text` bills as."""
    septets = sum(2 if ch in _GSM7_EXTENSION else 1 for ch in text or "")
    if septets <= 160:
        return 1
    return -(-septets // 153)  # ceil without importing math


# ── Texin delivery tracking ───────────────────────────────────────────────────
# Texin reports per-message status ("sent" / "delivered" / "failed" /
# "rejected") via /check_status and the /sms/texin/dlr webhook. "sent" only
# means accepted by Texin — never treat it as "delivered". Entries land here
# only from real provider responses, never fabricated; the admin dashboard
# reads them via get_texin_delivery_status()/get_texin_metrics().

TEXIN_DELIVERY_STATUSES = ("sent", "delivered", "failed", "rejected")

TEXIN_DELIVERY_CACHE: dict[str, str] = {}

_TEXIN_METRICS = {
    "submitted": 0,   # provider accepted (HTTP ok + success + message_id)
    "delivered": 0,   # a "delivered" report arrived
    "failed": 0,      # a "failed"/"rejected" report arrived
    "units": 0,       # total billed units from accepted sends
    "amount_minor": 0,  # total confirmed spend (KES cents)
}


def record_texin_delivery(message_id: str, status: str, *, count: bool = True) -> Optional[str]:
    """Record a real Texin delivery status; returns it normalized, or None
    for an unrecognized status (never stored, never counted).

    Counting is transition-based: a message moving into "delivered" (or
    "failed"/"rejected") counts once, no matter how often the same status
    is replayed by webhooks or re-polled via check_status. Counters only
    ever reflect real provider responses — never fabricated."""
    norm = (status or "").strip().lower()
    if norm not in TEXIN_DELIVERY_STATUSES or not message_id:
        return None
    prev = TEXIN_DELIVERY_CACHE.get(str(message_id))
    TEXIN_DELIVERY_CACHE[str(message_id)] = norm
    if count and norm != prev:
        if norm == "delivered":
            _TEXIN_METRICS["delivered"] += 1
        elif norm in ("failed", "rejected"):
            _TEXIN_METRICS["failed"] += 1
    return norm


def get_texin_delivery_status(message_id: str) -> Optional[str]:
    """Last known Texin status for `message_id`, or None if never reported."""
    return TEXIN_DELIVERY_CACHE.get(str(message_id))


def get_texin_metrics() -> dict:
    """Process-local Texin counters (submissions, reports, units, spend) for
    the admin dashboard. Delivery counts only cover reports actually
    received — no reports means no delivery claims."""
    return dict(_TEXIN_METRICS)


def verify_texin_signature(raw_body: bytes, signature: str, secret: str) -> bool:
    """Check Texin's `X-Texin-Signature` header value.

    Expected format: "sha256=<HMAC-SHA256 hex of the raw request body>"
    keyed with the webhook signing secret. Constant-time comparison; any
    malformed input (or an unconfigured secret) fails closed.
    """
    if not raw_body and raw_body != b"":
        return False
    if not signature or not secret:
        return False
    sig = signature.strip()
    if not sig.lower().startswith("sha256="):
        return False
    provided = sig.split("=", 1)[1].strip()
    if not provided:
        return False
    expected = hmac.new(secret.encode(), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(provided.lower(), expected.lower())


class SMSProvider(Protocol):
    async def send(self, phone: str, message: str) -> bool: ...


class ConsoleSMS:
    """Dev/CI fallback — logs instead of sending. Never raises.

    In production it refuses instead. "Logged instead of sent" is worse than
    a failed send there: the caller reports success, the recipient never
    gets the message, and a one-time code lands in log storage, where anyone
    with log access could use it to verify a phone number they don't hold.
    Returning False makes every caller take its existing send-failed path
    (e.g. /auth/otp/request answers 503), and the body is never logged.
    """

    async def send(self, phone: str, message: str) -> bool:
        if settings.is_production:
            logger.error(
                "[sms:console] no SMS provider configured in production — "
                "message NOT sent (set TEXIN_API_KEY "
                "or AT_USERNAME/AT_API_KEY)"
            )
            return False
        logger.warning("[sms:console] no SMS provider configured (checked "
                        "TEXIN_API_KEY, then "
                        "AT_USERNAME/AT_API_KEY) — logging instead of "
                        "sending. recipient and body redacted")
        return True


class AfricasTalkingSMS:
    """Fallback provider — Africa's Talking SMS API."""

    _BASE_URL = "https://api.africastalking.com/version1/messaging"
    _SANDBOX_URL = "https://api.sandbox.africastalking.com/version1/messaging"

    async def _send_once(self, phone: str, message: str) -> bool:
        url = self._SANDBOX_URL if settings.at_username == "sandbox" else self._BASE_URL
        headers = {
            "apiKey": settings.at_api_key,
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        }
        data = {
            "username": settings.at_username,
            "to": phone,
            "message": message,
            **({"from": settings.at_sender_id} if settings.at_sender_id else {}),
        }
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, headers=headers, data=data)
            resp.raise_for_status()
            body = resp.json()
        recipients = body.get("SMSMessageData", {}).get("Recipients", [])
        return bool(recipients) and all(
            r.get("status", "").lower() in ("success", "sent") for r in recipients
        )

    async def send(self, phone: str, message: str) -> bool:
        try:
            # One cost row per actual provider handoff: only a True from
            # _send_once means Africa's Talking accepted the message, and a
            # retry that fails here costs nothing. The row is written after
            # the fact on a detached session so accounting can never fail
            # the send itself.
            ok = await _at_breaker.call(self._send_once, phone, message)
            if ok:
                from api.core.cost_ledger import record_sms_cost
                await record_sms_cost(provider="africas_talking")
            return ok
        except (CircuitOpenError, httpx.HTTPError) as e:
            logger.error("[sms:africastalking] send failed err=%s", type(e).__name__)
            return False


# Mobitech's documented response codes (used for logging only — send() just
# needs to know 1000-vs-everything-else, but a real description in the log
# line saves a trip to the docs when something fails at 2am).
_MOBITECH_STATUS_DESCRIPTIONS = {
    "1000": "Success",
    "1001": "Invalid short code",
    "1002": "Network not allowed",
    "1003": "Invalid mobile number",
    "1004": "Low bulk credits",
    "1005": "Internal system error",
    "1006": "Invalid credentials",
    "1007": "Db connection failed",
    "1008": "Db selection failed",
    "1009": "Data type not supported",
    "1010": "Request type not supported",
    "1011": "Invalid user state or account suspended",
    "1012": "Mobile number in DND",
    "1013": "Invalid API Key",
    "1014": "IP not allowed",
    "1015": "Missing Parameter",
    "1016": "Monthly credit limit reached",
}


class MobitechSMS:
    """DEPRECATED — Mobitech Technologies bulk SMS API (Kenya).

    Replaced by TexinSMS as BROKA's primary provider. Kept working (and
    its /sms/dlr webhook stays live) for in-flight delivery reports only —
    get_sms_provider() never selects it, so stale MOBITECH_* environment
    values cannot override Texin. Do not add new call sites.

    Docs: https://textapi.mobitechtechnologies.com (account dashboard ->
    Developers / API Documentation). No sandbox environment — sends are
    live from the first call and billed against the account's credit
    balance, so this class is only reachable via get_sms_provider() when
    both MOBITECH_API_KEY and MOBITECH_SENDER_NAME are actually set.

    Uses /sms/sendsms (2026-08-31, second correction). This shipped
    first against /sms/sendsms's originally-documented sender_name/
    service_id fields, then switched to /sms/sendmultiple's shortcode/
    messages[] shape after a 1001 "Invalid short code" suggested this
    account needed that contract - reasonable at the time, but wrong: a
    manual request straight against /sms/sendsms using shortcode/
    serviceId field names (not sendmultiple's nested messages[] array)
    returned status_code 1000 for this exact account and credentials,
    which is the only actual ground truth here. So: /sms/sendsms stays,
    but with serviceId/shortcode field names rather than the originally-
    documented service_id/sender_name - Mobitech's docs and this
    account's real behavior disagree on that point, and the account's
    behavior wins.

    That same production incident also turned up a config bug unrelated
    to any of the above: MOBITECH_BASE_URL had a path baked into it
    (".../sms/sendsms" instead of just the domain), which combined with
    this class appending its own endpoint path produced a literal
    doubled-up URL. See mobitech_send_endpoint in config.py and
    validate_startup()'s check for it.

    Residual risk worth knowing about: Mobitech's own docs describe
    shortcodes as something that must be explicitly requested and then
    approved by Mobitech staff before they're active - separate from
    which endpoint/field name is used to send. If 1001 ever shows up
    again, the next thing to check isn't the code, it's whether
    MOBITECH_SENDER_NAME's value is actually approved+active on the
    account tied to this specific MOBITECH_API_KEY.
    """

    def __init__(self) -> None:
        self._base_url = settings.mobitech_base_url.rstrip("/")

    def _headers(self) -> dict:
        return {
            "h_api_key": settings.mobitech_api_key,
            "Content-Type": "application/json",
        }

    @staticmethod
    def _safe_json(resp: httpx.Response) -> Optional[dict]:
        """resp.json() as a dict, or None if the body isn't valid JSON at
        all - not unusual for a raw 500 (a gateway/proxy in front of
        Mobitech's app server can return an HTML or plain-text error page
        that never reaches Mobitech's own JSON-emitting code)."""
        try:
            parsed = resp.json()
        except ValueError:  # httpx raises a ValueError subclass on bad JSON
            return None
        return parsed if isinstance(parsed, dict) else None

    def _log_http_error(self, url: str, sanitized_payload: dict, resp: httpx.Response) -> None:
        """Logs everything useful for diagnosing a non-2xx Mobitech
        response BEFORE raise_for_status() discards the body - a bare
        exception string ("Server error '500 Internal Server Error' for
        url '...'") carries none of what Mobitech actually said back.

        Never logs the API key (not part of this data at all - it's a
        request header, not response data) or OTP/message text: the
        request payload passed in here is pre-redacted by the caller, and
        Mobitech's response schema (confirmed for both endpoints against
        their docs) never echoes the original message back, so logging
        the response body in full can't leak it either.
        """
        content_type = resp.headers.get("content-type", "")
        body_json = self._safe_json(resp)
        # Cap defensively - a badly broken upstream (e.g. a gateway
        # returning a full HTML error page) shouldn't be able to dump an
        # unbounded body into the logs. 2000 chars comfortably covers any
        # JSON error object or short HTML/text page.
        raw_text = _redact_phone_text((resp.text or "")[:2000])
        mobitech_status = body_json.get("status_code") if body_json else None
        mobitech_desc = body_json.get("status_desc") if body_json else None

        logger.error(
            "[sms:mobitech] HTTP error from Mobitech — endpoint=%s http_status=%s "
            "content_type=%r mobitech_status_code=%r mobitech_status_desc=%r "
            "sent_payload=%r response_body=%s",
            url, resp.status_code, content_type,
            mobitech_status, mobitech_desc,
            sanitized_payload, raw_text,
        )

    async def _send_once(self, phone: str, message: str) -> bool:
        # client_ref just needs to exist and look like their own examples
        # (bare integers: 6481, 60970...) - it's an opaque delivery-report
        # correlation id, nothing downstream keys off a specific value or
        # format, so a random int is enough.
        client_ref = random.randint(100000, 999999)
        # Mobitech empirically expects 254XXXXXXXXX, not +254XXXXXXXXX
        # (a manual /sms/sendsms request without the leading + returned
        # status_code 1000; production, sending the shared +254... format
        # every provider gets from auth/service.py's _normalize_phone(),
        # was never itself confirmed against this specific requirement).
        # Only strips a leading +, deliberately - full phone validation/
        # reformatting is auth/service.py's job, not this provider's;
        # this only adapts the already-normalized number to what this
        # one endpoint is confirmed to want.
        mobitech_phone = phone[1:] if phone.startswith("+") else phone
        payload = {
            "serviceId": "0",
            "shortcode": settings.mobitech_sender_name,
            "mobile": mobitech_phone,
            "message": message,
            "client_ref": client_ref,
        }
        # mobitech_base_url and mobitech_send_endpoint are joined
        # explicitly and only here - see config.py's comment on
        # mobitech_send_endpoint for why they're two separate settings
        # rather than one URL a caller could accidentally bake a path
        # into (exactly what broke this in production).
        url = f"{self._base_url}{settings.mobitech_send_endpoint}"

        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, headers=self._headers(), json=payload)

        # Inspect the response BEFORE raise_for_status(): on a 4xx/5xx,
        # raise_for_status() throws immediately, and this diagnostic
        # detail would be lost the moment it does - collapsing into
        # send()'s generic "err=..." with no visibility into what
        # Mobitech (or a gateway in front of it) actually said. The
        # exception still gets raised right after logging, so the
        # circuit breaker's own failure counting and send()'s existing
        # fail-soft behavior are both completely unchanged.
        if resp.status_code >= 400:
            sanitized_payload = {
                "serviceId": payload["serviceId"],
                "shortcode": payload["shortcode"],
                "mobile": "<redacted>",
                "message": "<redacted>",
                "client_ref": client_ref,
            }
            self._log_http_error(url, sanitized_payload, resp)
            resp.raise_for_status()

        http_status = resp.status_code
        raw = None
        try:
            raw = resp.json()
        except ValueError:
            pass
        # /sms/sendsms's own docs show this wrapped in a JSON array (even
        # for one recipient); the empirical Termux test that confirmed
        # this endpoint works only reported the two fields it extracted,
        # not the raw shape - handled defensively for both a bare object
        # and an array-wrapped one rather than assuming either away.
        if isinstance(raw, list):
            result = raw[0] if raw else {}
        elif isinstance(raw, dict):
            result = raw
        else:
            result = {}

        status_code = str(result.get("status_code", ""))
        if status_code != "1000":
            desc = result.get("status_desc") or _MOBITECH_STATUS_DESCRIPTIONS.get(status_code, "unknown error")
            hint = (
                " — check MOBITECH_SENDER_NAME is APPROVED+ACTIVE on the Mobitech "
                "account tied to this API key (Mobitech requires shortcodes to be "
                "requested and approved before use), not just correctly configured here"
                if status_code == "1001" else ""
            )
            # Mobitech's response schema never echoes the original
            # message text back, so logging the full result here can't
            # leak the OTP - only the request payload (never logged in
            # full - see sanitized_payload above) contains that.
            logger.error(
                "[sms:mobitech] send failed http_status=%s status=%s (%s)%s response=%r",
                http_status, status_code, desc, hint, _redact_result(result),
            )
            return False
        return True

    async def send(self, phone: str, message: str) -> bool:
        try:
            # Same one-row-per-handoff rule as AfricasTalkingSMS above: only
            # a provider-accepted send (status_code 1000 inside _send_once)
            # writes a KES 0.35 Mobitech row, billed per message whatever its
            # length (PRICING.md §1).
            ok = await _mobitech_breaker.call(self._send_once, phone, message)
            if ok:
                from api.core.cost_ledger import record_sms_cost
                await record_sms_cost(provider="mobitech")
            return ok
        except (CircuitOpenError, httpx.HTTPError) as e:
            logger.error("[sms:mobitech] send failed err=%s", type(e).__name__)
            return False

    # ── Extra, documented Mobitech endpoints ────────────────────────────────
    # Not part of the SMSProvider protocol (nothing in the app calls these
    # yet) - exposed here so they're a one-line call away for an admin
    # balance check or a pre-send validation, without a second round trip
    # through the circuit breaker plumbing above.

    async def get_balance(self) -> Optional[dict]:
        """GET /sms/getbalance -> {"credit_balance": ..., ...} or None on failure."""
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                resp = await client.get(
                    f"{self._base_url}/sms/getbalance",
                    headers=self._headers(),
                    params={"response_type": "json"},
                )
                resp.raise_for_status()
                return resp.json()
        except httpx.HTTPError as e:
            logger.error("[sms:mobitech] get_balance failed err=%s", e)
            return None

    async def validate_mobile(self, phone: str) -> Optional[dict]:
        """GET /sms/mobile -> network/validity info for `phone`, or None on failure."""
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                resp = await client.get(
                    f"{self._base_url}/sms/mobile",
                    headers=self._headers(),
                    params={"mobile": phone, "return": "json"},
                )
                resp.raise_for_status()
                return resp.json()
        except httpx.HTTPError as e:
            logger.error("[sms:mobitech] validate_mobile failed err=%s", type(e).__name__)
            return None


class TexinSMS:
    """Primary provider — Texin BulkSMS API (Kenya).

    Sends BROKA's own OTP/notification text through Texin's /send_sms.
    BROKA keeps its full OTP lifecycle (generation, storage, expiry,
    attempt limits, verification) — Texin's /send_otp and /verify_otp
    endpoints are deliberately NOT used, so there is exactly one OTP
    lifecycle and authentication behavior is unchanged.

    Acceptance contract (all required for True):
      - HTTP request succeeds (2xx).
      - JSON body parses with "success" true.
      - "simulation_mode" is not true (a simulated send reached nobody).
      - A non-empty message_id is present (kept for delivery tracking).

    Anything else — provider errors, insufficient balance, auth failures,
    4xx/5xx, timeouts, malformed JSON, missing message_id, simulation
    mode — returns False. An HTTP 200 alone never counts as submitted.

    Billing: Texin reports units_used/cost per send; the confirmed charge
    is recorded (estimated=False) after acceptance. Accounting failures
    never flip an accepted send to False. One cost row per provider
    handoff, so a fallback chain hands the same text to two providers only
    via two separate send() calls, each recorded once.

    Retries: at most ONE retry, and only for an explicit transient
    rejection (HTTP 429, or a 5xx carrying a JSON success=false body —
    proof Texin did NOT accept). Timeouts and connection errors are NEVER
    retried: after an ambiguous timeout Texin may already have accepted
    and billed, and a retry would double-charge and (for OTPs) mint a
    second valid code. Retries never resend automatically in a way that
    produces duplicate charges — see send() callers, which surface False
    and let the user request a new code instead.

    Rate limits: no status/balance polling on the send path; balance and
    sender IDs are on-demand admin helpers below.
    """

    def __init__(self) -> None:
        self._base_url = (settings.texin_base_url or "https://sms.texin.co.ke/api").rstrip("/")
        timeout = settings.texin_timeout_seconds or 15
        self._timeout = float(timeout) if float(timeout) > 0 else 15.0
        self.last_message_id: Optional[str] = None

    def _headers(self) -> dict:
        return {
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    @staticmethod
    def _safe_json(resp: httpx.Response) -> Optional[dict]:
        try:
            parsed = resp.json()
        except ValueError:  # httpx raises a ValueError subclass on bad JSON
            return None
        return parsed if isinstance(parsed, dict) else None

    def _send_payload(self, recipient: str, message: str) -> dict:
        payload: dict[str, Any] = {
            "api_key": settings.texin_api_key,
            "recipient": recipient,
            "message": message,
        }
        # Empty TEXIN_SENDER_ID means "use the account default" (currently
        # "Texin") — the key is omitted entirely rather than sent empty.
        if settings.texin_sender_id:
            payload["sender_id"] = settings.texin_sender_id
        return payload

    @staticmethod
    def _extract_billing(body: dict) -> tuple[Optional[int], Optional[float], Optional[str]]:
        """(units_used, cost_kes, message_id) from a /send_sms body."""
        units: Optional[int] = None
        cost: Optional[float] = None
        message_id: Optional[str] = None
        try:
            raw_units = body.get("units_used")
            if raw_units is not None:
                units = int(raw_units)
                if units is not None and units <= 0:
                    units = None
        except (TypeError, ValueError):
            units = None
        try:
            raw_cost = body.get("cost")
            if raw_cost is not None:
                cost = float(raw_cost)
        except (TypeError, ValueError):
            cost = None
        raw_mid = body.get("message_id")
        if raw_mid is not None and str(raw_mid).strip():
            message_id = str(raw_mid).strip()
        return units, cost, message_id

    def _log_http_error(self, url: str, resp: httpx.Response) -> None:
        content_type = resp.headers.get("content-type", "")
        body_json = self._safe_json(resp)
        raw_text = _redact_phone_text((resp.text or "")[:2000])
        logger.error(
            "[sms:texin] HTTP error — endpoint=%s http_status=%s "
            "content_type=%r success=%r response_body=%s",
            url, resp.status_code, content_type,
            body_json.get("success") if body_json else None,
            _redact_result(raw_text),
        )

    async def _post(self, path: str, payload: dict) -> httpx.Response:
        url = f"{self._base_url}{path}"
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            return await client.post(url, headers=self._headers(), json=payload)

    async def _attempt_send(self, recipient: str, gsm_text: str) -> Optional[dict]:
        """One /send_sms attempt. Returns the billing dict on acceptance,
        None on explicit rejection, and raises httpx.HTTPError on transport
        failures or non-2xx responses (the breaker counts those)."""
        resp = await self._post("/send_sms", self._send_payload(recipient, gsm_text))
        if resp.status_code == 429:
            # Explicit transient rejection (rate limited) — retryable.
            self._log_http_error(f"{self._base_url}/send_sms", resp)
            raise _TransientTexinError("rate limited (429)")
        if resp.status_code >= 400:
            body_json = self._safe_json(resp)
            self._log_http_error(f"{self._base_url}/send_sms", resp)
            # A 5xx carrying a JSON success=false body is proof Texin did
            # NOT accept — retryable. Anything else (auth, balance,
            # gateway HTML pages, ambiguous states) is final.
            if resp.status_code >= 500 and isinstance(body_json, dict) \
                    and body_json.get("success") is False:
                raise _TransientTexinError(f"transient 5xx: {resp.status_code}")
            resp.raise_for_status()
            return None  # unreachable — raise_for_status() threw
        body = self._safe_json(resp)
        if not body:
            logger.error("[sms:texin] send failed: non-JSON success response")
            return None
        if body.get("success") is not True:
            logger.error(
                "[sms:texin] send rejected success=%r response=%r",
                body.get("success"), _redact_result(body),
            )
            return None
        if body.get("simulation_mode") is True:
            # Accepted by the simulator, delivered to nobody — not a send.
            logger.error("[sms:texin] send failed: simulation_mode=true, message NOT delivered")
            return None
        units, cost, message_id = self._extract_billing(body)
        if not message_id:
            logger.error("[sms:texin] send failed: success=true but no message_id")
            return None
        return {"message_id": message_id, "units": units, "cost": cost}

    async def _send_once(self, phone: str, message: str) -> Optional[dict]:
        recipient = normalize_ke_phone(phone)
        if not recipient:
            logger.error("[sms:texin] send failed: malformed phone number")
            return None
        gsm_text = sms_to_gsm7(message)
        if not gsm_text:
            logger.error("[sms:texin] send failed: message has no GSM-7 content")
            return None
        try:
            return await self._attempt_send(recipient, gsm_text)
        except _TransientTexinError:
            # Bounded: exactly one retry, only for explicit transient
            # rejections (never for timeouts — see class docstring).
            await asyncio.sleep(1)
            return await self._attempt_send(recipient, gsm_text)

    async def send(self, phone: str, message: str) -> bool:
        try:
            info = await _texin_breaker.call(self._send_once, phone, message)
        except (CircuitOpenError, httpx.HTTPError, _TransientTexinError) as e:
            # _TransientTexinError here means the single bounded retry also
            # met an explicit transient rejection — still a soft False, and
            # only one message was ever (possibly) submitted.
            logger.error("[sms:texin] send failed err=%s", type(e).__name__)
            return False
        if not info:
            return False
        # Provider accepted the message — retain the ID for delivery
        # tracking, then record the CONFIRMED charge. Accounting runs on a
        # detached session and can never flip this accepted send to False.
        self.last_message_id = info["message_id"]
        TEXIN_DELIVERY_CACHE[info["message_id"]] = "sent"
        units = info.get("units")
        _TEXIN_METRICS["submitted"] += 1
        if units:
            _TEXIN_METRICS["units"] += units
        try:
            from api.core.cost_ledger import record_sms_cost
            row = await record_sms_cost(
                provider="texin",
                units=units,
                amount_minor=(
                    int(round(float(info["cost"]) * 100))
                    if info.get("cost") is not None else None
                ),
                message_id=info["message_id"],
            )
            if row is not None:
                _TEXIN_METRICS["amount_minor"] += row.amount_minor
        except Exception as exc:  # never fail the send on accounting
            logger.warning("[sms:texin] cost record failed (non-fatal): %s", exc)
        return True

    # ── Extra, documented Texin endpoints ─────────────────────────────────
    # Not part of the SMSProvider protocol — on-demand helpers for delivery
    # tracking and admin checks, never polled on the send path.

    async def check_status(self, message_id: str) -> Optional[str]:
        """POST /check_status -> normalized status ("sent" / "delivered" /
        "failed" / "rejected"), recorded in the delivery cache. None when
        the lookup itself fails or the status is unrecognized."""
        try:
            resp = await self._post(
                "/check_status",
                {"api_key": settings.texin_api_key, "message_id": message_id},
            )
            resp.raise_for_status()
            body = self._safe_json(resp)
            if not body:
                return None
            # Documented shape carries the status under "status"; accept the
            # common aliases defensively without inventing new semantics.
            status = (
                body.get("status") or body.get("delivery_status")
                or body.get("dlrStatus") or body.get("state")
            )
            return record_texin_delivery(message_id, str(status) if status is not None else "")
        except httpx.HTTPError as e:
            logger.error("[sms:texin] check_status failed err=%s", type(e).__name__)
            return None

    async def get_balance(self) -> Optional[dict]:
        """POST /get_balance -> balance body, or None on failure."""
        try:
            resp = await self._post("/get_balance", {"api_key": settings.texin_api_key})
            resp.raise_for_status()
            return self._safe_json(resp)
        except httpx.HTTPError as e:
            logger.error("[sms:texin] get_balance failed err=%s", type(e).__name__)
            return None

    async def get_sender_ids(self) -> Optional[Any]:
        """POST /get_sender_ids -> sender-ID list/body, or None on failure."""
        try:
            resp = await self._post("/get_sender_ids", {"api_key": settings.texin_api_key})
            resp.raise_for_status()
            try:
                return resp.json()
            except ValueError:
                return None
        except httpx.HTTPError as e:
            logger.error("[sms:texin] get_sender_ids failed err=%s", type(e).__name__)
            return None

    async def test_connection(self) -> bool:
        """GET /test_connection -> True when the API answers 2xx."""
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                resp = await client.get(
                    f"{self._base_url}/test_connection", headers=self._headers()
                )
                return 200 <= resp.status_code < 300
        except httpx.HTTPError as e:
            logger.error("[sms:texin] test_connection failed err=%s", type(e).__name__)
            return False


class _TransientTexinError(Exception):
    """Internal: an explicit transient rejection worth exactly one retry."""


def get_sms_provider() -> SMSProvider:
    # Texin is primary: TEXIN_API_KEY alone selects it — stale MOBITECH_*
    # values are deliberately NOT consulted, so they can never override it.
    if settings.texin_api_key:
        return TexinSMS()
    if settings.at_username and settings.at_api_key:
        return AfricasTalkingSMS()
    return ConsoleSMS()


def current_sms_provider_name() -> str:
    """Machine-readable name of the provider get_sms_provider() would pick
    right now — for the admin dashboard and diagnostics."""
    if settings.texin_api_key:
        return "texin"
    if settings.at_username and settings.at_api_key:
        return "africas_talking"
    return "console"
