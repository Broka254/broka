"""
BROKA v6.2 - SMS Provider (phone OTP delivery)
─────────────────────────────────────────────────────────────────────────────
Sends the registration/login OTP by SMS. Follows the same
external-dependency house style as api.core.circuit_breaker (used for
Gemini/Groq) - wrap the network call, fail soft, never let an SMS-provider
outage take down registration.

Providers, in priority order (see get_sms_provider):
  1. Mobitech Technologies — Kenyan bulk SMS gateway. Configure via
     MOBITECH_API_KEY / MOBITECH_SENDER_NAME. No sandbox mode; sends are
     live and billed against the account's credit balance from the first
     call, so this is only picked when both are actually set.
  2. Africa's Talking — kept as a fallback (the same provider already
     referenced for the logistics-layer station OTPs). Configure via
     AT_USERNAME / AT_API_KEY.

Dev/CI fallback: if neither provider is configured, OTPs are logged
instead of sent, so registration is fully testable without a live SMS
account. This mirrors how GEMINI_API_KEY / GROQ_API_KEY being unset doesn't
crash the AI broker - it degrades to the next thing in the chain.
"""
from __future__ import annotations

import logging
import random
from typing import Optional, Protocol

import httpx

from api.core.config import settings
from api.core.circuit_breaker import CircuitBreaker, CircuitOpenError

logger = logging.getLogger(__name__)

_mobitech_breaker = CircuitBreaker("mobitech_sms", failure_threshold=5, recovery_timeout=30)
_at_breaker       = CircuitBreaker("africas_talking_sms", failure_threshold=5, recovery_timeout=30)


class SMSProvider(Protocol):
    async def send(self, phone: str, message: str) -> bool: ...


class ConsoleSMS:
    """Dev/CI fallback — logs instead of sending. Never raises."""

    async def send(self, phone: str, message: str) -> bool:
        logger.warning("[sms:console] no SMS provider configured (checked "
                        "MOBITECH_API_KEY/MOBITECH_SENDER_NAME, then "
                        "AT_USERNAME/AT_API_KEY) — logging instead of "
                        "sending. to=%s body=%r", phone, message)
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
            return await _at_breaker.call(self._send_once, phone, message)
        except (CircuitOpenError, httpx.HTTPError) as e:
            logger.error("[sms:africastalking] send failed to=%s err=%s", phone, e)
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
    """Primary provider — Mobitech Technologies bulk SMS API (Kenya).

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
        raw_text = (resp.text or "")[:2000]
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
                "mobile": mobitech_phone,
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
                "[sms:mobitech] send failed to=%s http_status=%s status=%s (%s)%s response=%r",
                phone, http_status, status_code, desc, hint, result,
            )
            return False
        return True

    async def send(self, phone: str, message: str) -> bool:
        try:
            return await _mobitech_breaker.call(self._send_once, phone, message)
        except (CircuitOpenError, httpx.HTTPError) as e:
            logger.error("[sms:mobitech] send failed to=%s err=%s", phone, e)
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
            logger.error("[sms:mobitech] validate_mobile failed to=%s err=%s", phone, e)
            return None


def get_sms_provider() -> SMSProvider:
    if settings.mobitech_api_key and settings.mobitech_sender_name:
        return MobitechSMS()
    if settings.at_username and settings.at_api_key:
        return AfricasTalkingSMS()
    return ConsoleSMS()
