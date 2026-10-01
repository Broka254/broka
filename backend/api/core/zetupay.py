"""ZetuPay: M-PESA collection for money users pay BROKA.

Listing fees, premium plans, featured boosts and verification badges - the
platform's own revenue. Never deal money: a buyer pays a seller through
E-Confirm (core/econfirm_client.py), and nothing here may be used for it.
api/domains/payments/service.py is the only caller.

Everything about ZetuPay's wire format lives in this file, so it is the one
place to change when the API does:

  confirmed by BROKA      the base URL; a secret key (sk_live_...) that
                          authenticates our calls; a 202 "processing" answer
                          to an STK push, which is not a payment; webhooks
                          carrying an x-zetupay-secret header and a
                          waveTransactionId.
  to check against the    the paths (STK_PUSH_PATH, STATUS_PATH), the key
  API reference           travelling as a Bearer token, and the request and
                          response field names below. ZetuPay's
                          documentation could not be reached when this was
                          written; the readers accept the usual spellings
                          of each field, so a webhook still parses if a
                          name differs, but the request body must match.

Callers get ZetuPayUnavailable for anything that means "no prompt reached
the phone", and ZetuPayTimeout - a subclass - when ZetuPay did not answer in
time and a prompt may have gone out after all. ZetuPay's own error bodies
are never passed to users, and the key is never logged.
"""
from __future__ import annotations

import dataclasses
import hmac
import logging
import math
from dataclasses import dataclass
from typing import Any, Optional

import httpx

from api.core.config import settings

logger = logging.getLogger(__name__)

# False until every path and field below has been checked against ZetuPay's
# API reference. Until then ZETUPAY_ENABLED is ignored and BROKA's charges
# stay on Daraja (payments/service.enabled): a guessed request format would
# turn every listing fee, plan, boost and badge into a failed prompt - or a
# prompt for the wrong thing - the moment someone switched the flag on.
CONTRACT_VERIFIED = False

STK_PUSH_PATH = "/mpesa/stk-push"
STATUS_PATH = "/transactions/{reference}"

SUCCESS = "success"
FAILED = "failed"
PENDING = "pending"

_SUCCESS = {"success", "successful", "succeeded", "completed", "complete", "paid"}
_FAILED = {"failed", "failure", "cancelled", "canceled", "rejected", "declined",
           "expired", "timeout", "timed_out", "error"}

_REFERENCE = ("reference", "externalReference", "external_reference",
              "accountReference", "account_reference", "merchantReference")
_STATUS = ("status", "transactionStatus", "transaction_status", "state")
_AMOUNT = ("amount",)
_CURRENCY = ("currency",)
_WAVE_ID = ("waveTransactionId", "wave_transaction_id")
_RECEIPT = ("mpesaReceiptNumber", "mpesa_receipt_number", "mpesaReceipt", "mpesa_receipt",
            "receiptNumber", "receipt")
_REASON = ("failureReason", "failure_reason", "reason", "resultDesc", "message")
_PROVIDER_ID = ("transactionId", "transaction_id", "id", "paymentId", "checkoutRequestId")


class ZetuPayUnavailable(Exception):
    """No STK prompt was sent, or ZetuPay could not be asked."""


class ZetuPayTimeout(ZetuPayUnavailable):
    """ZetuPay did not answer in time: the prompt may have gone out anyway,
    so a payment for it can still arrive."""


def normalize_status(raw: Any) -> str:
    """SUCCESS, FAILED or PENDING. Anything unrecognised is PENDING - an
    unknown word must never read as money received."""
    value = str(raw or "").strip().lower()
    if value in _SUCCESS:
        return SUCCESS
    if value in _FAILED:
        return FAILED
    return PENDING


def _fields(payload: Optional[dict]) -> dict:
    """The event's fields: flat, or under "data"/"transaction"."""
    payload = payload if isinstance(payload, dict) else {}
    merged = dict(payload)
    for key in ("data", "transaction"):
        inner = payload.get(key)
        if isinstance(inner, dict):
            merged.update(inner)
    return merged


def _pick(fields: dict, names: tuple[str, ...]) -> Optional[str]:
    for name in names:
        value = fields.get(name)
        if value not in (None, ""):
            return str(value).strip()
    return None


def _amount(fields: dict) -> Optional[float]:
    try:
        value = float(_pick(fields, _AMOUNT))
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


@dataclass(frozen=True)
class ZetuPayEvent:
    """What ZetuPay says happened to a transaction - from its webhook or its
    status endpoint. The amount is checked against the amount BROKA asked
    for before anything is applied."""
    reference: Optional[str]
    status: str
    raw_status: str
    amount: Optional[float]
    currency: Optional[str]
    wave_transaction_id: Optional[str]
    receipt: Optional[str]
    reason: str


def parse_event(payload: Optional[dict]) -> ZetuPayEvent:
    fields = _fields(payload)
    raw_status = _pick(fields, _STATUS) or ""
    return ZetuPayEvent(
        reference=_pick(fields, _REFERENCE),
        status=normalize_status(raw_status),
        raw_status=raw_status,
        amount=_amount(fields),
        currency=_pick(fields, _CURRENCY),
        wave_transaction_id=_pick(fields, _WAVE_ID),
        receipt=_pick(fields, _RECEIPT),
        reason=(_pick(fields, _REASON) or raw_status or "not completed")[:200],
    )


def amount_matches(event: ZetuPayEvent, expected: float) -> bool:
    if event.currency and event.currency.upper() != "KES":
        return False
    return event.amount is not None and abs(event.amount - float(expected)) < 0.01


def webhook_secret_ok(presented: Optional[str]) -> bool:
    """The x-zetupay-secret header against ZETUPAY_WEBHOOK_SECRET.

    Refuses everything while no secret is configured: an unauthenticated
    webhook is a way to claim any payment succeeded.
    """
    expected = settings.zetupay_webhook_secret
    if not expected or not presented:
        return False
    return hmac.compare_digest(presented.encode(), expected.encode())


@dataclass(frozen=True)
class Accepted:
    """ZetuPay took the request: the prompt is on its way to the phone.
    Not a payment - only a verified webhook or status answer is."""
    provider_id: Optional[str]


def _headers() -> dict:
    if not settings.zetupay_secret_key:
        raise ZetuPayUnavailable("ZetuPay is not configured")
    return {
        "Authorization": f"Bearer {settings.zetupay_secret_key}",
        "Accept": "application/json",
    }


def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(base_url=settings.zetupay_base_url,
                             timeout=settings.zetupay_timeout_seconds)


def _json(response: httpx.Response) -> dict:
    try:
        body = response.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


async def stk_push(phone: str, amount: int, reference: str, description: str) -> Accepted:
    """Ask ZetuPay to send the M-PESA prompt for `amount` KES."""
    headers = _headers()
    body = {
        "phone": phone,
        "amount": int(amount),
        "reference": reference,
        "description": description[:60],
    }
    try:
        async with _client() as client:
            response = await client.post(STK_PUSH_PATH, json=body, headers=headers)
    except httpx.TimeoutException as exc:
        raise ZetuPayTimeout(f"STK push timed out ({type(exc).__name__})") from exc
    except httpx.HTTPError as exc:
        raise ZetuPayUnavailable(f"STK push failed: {type(exc).__name__}") from exc

    answer = _json(response)
    if response.status_code not in (200, 201, 202):
        logger.warning("[zetupay] push refused: HTTP %s %s", response.status_code,
                       _pick(_fields(answer), ("message", "error")) or "")
        raise ZetuPayUnavailable(f"STK push refused with HTTP {response.status_code}")
    if normalize_status(_pick(_fields(answer), _STATUS)) == FAILED:
        logger.warning("[zetupay] push refused: %s", _pick(_fields(answer), _REASON) or "")
        raise ZetuPayUnavailable("STK push refused")
    return Accepted(provider_id=_pick(_fields(answer), _PROVIDER_ID))


async def transaction_status(reference: str) -> Optional[ZetuPayEvent]:
    """Ask ZetuPay how the payment for `reference` stands. None when ZetuPay
    has no such transaction. Our own authenticated question, so its answer
    is as good as a webhook's."""
    headers = _headers()
    try:
        async with _client() as client:
            response = await client.get(STATUS_PATH.format(reference=reference), headers=headers)
    except httpx.HTTPError as exc:
        raise ZetuPayUnavailable(f"status query failed: {type(exc).__name__}") from exc
    if response.status_code == 404:
        return None
    if response.status_code != 200:
        raise ZetuPayUnavailable(f"status query answered HTTP {response.status_code}")
    event = parse_event(_json(response))
    if event.reference and event.reference != reference:
        raise ZetuPayUnavailable("status query answered for another reference")
    if not event.reference:
        event = dataclasses.replace(event, reference=reference)
    return event
