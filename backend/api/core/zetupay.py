"""ZetuPay: M-PESA collection for money users pay BROKA.

Listing fees, premium plans, featured boosts and verification badges - the
platform's own revenue. Never deal money: a buyer pays a seller through
E-Confirm (core/econfirm_client.py), and nothing here may be used for it.
api/domains/payments/ is the only caller.

The contract, as ZetuPay documents it (pay.zetupay.co.ke/docs: stk-push,
payment-status, callbacks, authentication, errors; read 2026-10-01):

  base URL   https://pay.zetupay.co.ke/api/v1 (ZETUPAY_BASE_URL)
  auth       Authorization: Bearer <Secret Key>, from the server only
  STK push   POST /payment/stk-push, Idempotency-Key header;
             {amount: whole KES 1-250,000, phoneNumber, reference (<= 100)}
             -> 202 {success: true, data: {paymentKey, waveTransactionId,
             status: "processing", ...}}. The 202 is not a payment.
  status     GET /payment/stk-push/{paymentKey} -> {success, data: {status,
             amount, currency, reference, waveTransactionId, receiptNumber,
             resultCode, resultDesc, ...}}; 404 unknown (kept 24 hours).
             status: pending | processing | success | failed | cancelled |
             expired.
  webhook    POSTed to the Transaction Callback Endpoint for successful
             payments only (failures are only seen by asking). The body is
             the bare transaction {status: "success", amount, reference,
             waveTransactionId, receiptNumber, ...}. Signed:
             x-zetupay-signature: t=<unix>,v1=<hex HMAC-SHA256 of
             "<t>.<raw body>" keyed with the wallet's LIVE Secret Key>.
             Subscription events share the URL as {event, data}.
  errors     {success: false, error, message}: 400 401 402 403 409 422 429
             500 502.

Callers get ZetuPayUnavailable for anything that means "no prompt reached
the phone", and ZetuPayTimeout - a subclass - when ZetuPay did not answer in
time and a prompt may have gone out after all. ZetuPay's error bodies are
never passed to users, and the key is never logged.
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import math
import time
from dataclasses import dataclass
from typing import Optional

import httpx

from api.core.config import settings

logger = logging.getLogger(__name__)

# True once every path and field here was checked against ZetuPay's API
# reference (see above). Set it back to False if the contract is ever in
# doubt: ZETUPAY_ENABLED is then ignored and BROKA's charges stay on Daraja
# (payments/service.enabled) instead of sending real prompts to a request
# format ZetuPay may not accept.
CONTRACT_VERIFIED = True

STK_PUSH_PATH = "/payment/stk-push"
STATUS_PATH = "/payment/stk-push/{payment_key}"

# A signed webhook older than this is refused, so a captured one can't be
# replayed. ZetuPay re-signs its retries with a fresh timestamp.
SIGNATURE_TOLERANCE_SECONDS = 300

SUCCESS = "success"
FAILED = "failed"
PENDING = "pending"

_FAILED = {"failed", "cancelled", "expired"}


class ZetuPayUnavailable(Exception):
    """No STK prompt was sent, or ZetuPay could not be asked."""


class ZetuPayTimeout(ZetuPayUnavailable):
    """ZetuPay did not answer in time: the prompt may have gone out anyway,
    so a payment for it can still arrive."""


def normalize_status(raw: object) -> str:
    """SUCCESS only for ZetuPay's "success"; FAILED for failed, cancelled and
    expired; everything else - pending, processing, or a word ZetuPay adds
    later - is PENDING: an unknown word must never read as money received."""
    value = str(raw or "").strip().lower()
    if value == "success":
        return SUCCESS
    if value in _FAILED:
        return FAILED
    return PENDING


def _str(fields: dict, name: str) -> Optional[str]:
    value = fields.get(name)
    return None if value in (None, "") else str(value).strip()


def _amount(fields: dict) -> Optional[float]:
    try:
        value = float(fields.get("amount"))
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


@dataclass(frozen=True)
class ZetuPayEvent:
    """A payment as ZetuPay reports it - the webhook's body, or the status
    endpoint's `data`. Its amount is checked against the amount BROKA asked
    for before anything is applied."""
    reference: Optional[str]
    status: str
    raw_status: str
    amount: Optional[float]
    currency: Optional[str]
    wave_transaction_id: Optional[str]
    payment_key: Optional[str]
    receipt: Optional[str]
    reason: str


def parse_event(payload: Optional[dict]) -> ZetuPayEvent:
    """The webhook's bare transaction, or a status answer's `data`."""
    payload = payload if isinstance(payload, dict) else {}
    fields = payload["data"] if isinstance(payload.get("data"), dict) else payload
    raw_status = _str(fields, "status") or ""
    return ZetuPayEvent(
        reference=_str(fields, "reference"),
        status=normalize_status(raw_status),
        raw_status=raw_status,
        amount=_amount(fields),
        currency=_str(fields, "currency"),
        wave_transaction_id=_str(fields, "waveTransactionId"),
        payment_key=_str(fields, "paymentKey"),
        receipt=_str(fields, "receiptNumber"),
        reason=(_str(fields, "resultDesc") or raw_status or "not completed")[:200],
    )


def is_subscription_event(payload: dict) -> bool:
    """Plans & subscriptions events share the payment webhook's URL, wrapped
    as {event, data}; ZetuPay says to check for `event` first."""
    return "event" in payload


def amount_matches(event: ZetuPayEvent, expected: float) -> bool:
    # The webhook carries no currency; ZetuPay's M-Pesa payments are KES.
    if event.currency and event.currency.upper() != "KES":
        return False
    return event.amount is not None and abs(event.amount - float(expected)) < 0.01


def signature_ok(raw_body: bytes, header: Optional[str], now: Optional[float] = None) -> bool:
    """x-zetupay-signature: t=<unix>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">,
    keyed with the Secret Key, compared in constant time and refused when
    more than five minutes from now.

    Not the older x-zetupay-secret header: that carries the key itself, so
    anyone who saw one request could forge any other, and it says nothing
    about the body. Refuses everything while no key is configured.
    """
    key = settings.zetupay_secret_key
    if not key or not header:
        return False
    parts: dict[str, list[str]] = {}
    for item in header.split(","):
        name, _, value = item.strip().partition("=")
        parts.setdefault(name, []).append(value)
    stamp = (parts.get("t") or [""])[0]
    try:
        signed_at = int(stamp)
    except ValueError:
        return False
    if abs((time.time() if now is None else now) - signed_at) > SIGNATURE_TOLERANCE_SECONDS:
        return False
    expected = hmac.new(key.encode(), stamp.encode() + b"." + raw_body, hashlib.sha256).hexdigest()
    return any(hmac.compare_digest(expected, given) for given in parts.get("v1", []))


@dataclass(frozen=True)
class Accepted:
    """ZetuPay took the request (its 202): the prompt is on its way to the
    phone. Not a payment - only a success webhook or status answer is."""
    payment_key: str
    wave_transaction_id: Optional[str]


def _headers(idempotency_key: Optional[str] = None) -> dict:
    if not settings.zetupay_secret_key:
        raise ZetuPayUnavailable("ZetuPay is not configured")
    headers = {
        "Authorization": f"Bearer {settings.zetupay_secret_key}",
        "Accept": "application/json",
    }
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key
    return headers


def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(base_url=settings.zetupay_base_url,
                             timeout=settings.zetupay_timeout_seconds)


def _json(response: httpx.Response) -> dict:
    try:
        body = response.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


async def stk_push(phone: str, amount: int, reference: str) -> Accepted:
    """Ask ZetuPay to prompt `phone` for `amount` KES under `reference`.

    The reference is also the Idempotency-Key: if this request is ever sent
    again, ZetuPay returns the first payment instead of prompting twice.
    """
    headers = _headers(idempotency_key=reference)
    body = {"amount": int(amount), "phoneNumber": phone, "reference": reference}
    try:
        async with _client() as client:
            response = await client.post(STK_PUSH_PATH, json=body, headers=headers)
    except httpx.TimeoutException as exc:
        raise ZetuPayTimeout(f"STK push timed out ({type(exc).__name__})") from exc
    except httpx.HTTPError as exc:
        raise ZetuPayUnavailable(f"STK push failed: {type(exc).__name__}") from exc

    answer = _json(response)
    data = answer.get("data") if isinstance(answer.get("data"), dict) else {}
    if response.status_code not in (200, 201, 202) or answer.get("success") is not True:
        logger.warning("[zetupay] push refused: HTTP %s %s: %s", response.status_code,
                       answer.get("error") or "", answer.get("message") or "")
        raise ZetuPayUnavailable(f"STK push refused with HTTP {response.status_code}")
    payment_key = _str(data, "paymentKey")
    if not payment_key or normalize_status(data.get("status")) == FAILED:
        logger.warning("[zetupay] push answered without a live payment: status=%s",
                       data.get("status"))
        raise ZetuPayUnavailable("STK push not accepted")
    return Accepted(payment_key=payment_key, wave_transaction_id=_str(data, "waveTransactionId"))


async def transaction_status(payment_key: str, reference: str) -> Optional[ZetuPayEvent]:
    """Ask ZetuPay how the payment `payment_key` stands. None when ZetuPay no
    longer knows it (404, or 410 just after it expired). Our own
    authenticated question, so its answer is as good as a webhook's - and it
    is the only way to learn of a failure, which sends no webhook."""
    headers = _headers()
    try:
        async with _client() as client:
            response = await client.get(STATUS_PATH.format(payment_key=payment_key), headers=headers)
    except httpx.HTTPError as exc:
        raise ZetuPayUnavailable(f"status query failed: {type(exc).__name__}") from exc
    if response.status_code in (404, 410):
        return None
    answer = _json(response)
    if response.status_code != 200 or answer.get("success") is not True:
        raise ZetuPayUnavailable(f"status query answered HTTP {response.status_code}")
    event = parse_event(answer)
    if event.reference != reference:
        # Never apply an answer about some other payment to this one.
        raise ZetuPayUnavailable("status query answered for another reference")
    return event
