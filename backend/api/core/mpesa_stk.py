"""M-Pesa Express (STK push) for money that is BROKA's own: listing fees.

Deal money goes through E-Confirm, not here. The older routers
(routers/mpesa.py, verify.py, featured.py) each carry their own copy of
these helpers; this one reads the shared settings and is what new payment
code uses.

Callers get MpesaUnavailable for anything that means "no prompt reached the
phone" - Daraja down, credentials missing, the request refused - so they
can say so without guessing at Safaricom's error bodies, which are never
passed on to users.
"""
from __future__ import annotations

import base64
import logging
import re
from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx

from api.core.config import settings

logger = logging.getLogger(__name__)


class MpesaUnavailable(Exception):
    """No STK prompt was sent, or Safaricom could not be asked."""


# A Kenyan mobile number: 07xx or 01xx. Whether the line has M-Pesa only
# Daraja can tell, and it refuses the rest itself.
_KENYAN_MOBILE = re.compile(r"^254(7\d{8}|1\d{8})$")


def normalize_phone(phone: str) -> Optional[str]:
    """07XX XXX XXX / +2547... / 2547... -> 2547XXXXXXXX, or None.

    Checked before any prompt is sent: an STK push goes to whatever number
    it is given, and a mistyped one prompts a stranger for money.
    """
    digits = re.sub(r"[^\d]", "", phone or "")
    if digits.startswith("0"):
        digits = "254" + digits[1:]
    elif len(digits) == 9 and digits[0] in "71":
        digits = "254" + digits
    return digits if _KENYAN_MOBILE.match(digits) else None


def _password() -> tuple[str, str]:
    # Daraja wants the timestamp in Nairobi time (UTC+3); servers run UTC.
    timestamp = (datetime.now(timezone.utc) + timedelta(hours=3)).strftime("%Y%m%d%H%M%S")
    raw = f"{settings.mpesa_shortcode}{settings.mpesa_passkey}{timestamp}"
    return timestamp, base64.b64encode(raw.encode()).decode()


async def _token(client: httpx.AsyncClient) -> str:
    if not (settings.mpesa_consumer_key and settings.mpesa_consumer_secret):
        raise MpesaUnavailable("M-Pesa is not configured")
    creds = base64.b64encode(
        f"{settings.mpesa_consumer_key}:{settings.mpesa_consumer_secret}".encode()
    ).decode()
    r = await client.get(
        f"{settings.mpesa_base_url}/oauth/v1/generate?grant_type=client_credentials",
        headers={"Authorization": f"Basic {creds}"},
    )
    if r.status_code != 200:
        raise MpesaUnavailable(f"OAuth failed with HTTP {r.status_code}")
    return r.json()["access_token"]


async def stk_push(
    phone: str, amount: int, account_reference: str, description: str, callback_url: str,
) -> dict:
    """Send the prompt. Returns Daraja's reply (CheckoutRequestID, MerchantRequestID)."""
    timestamp, password = _password()
    payload = {
        "BusinessShortCode": settings.mpesa_shortcode,
        "Password": password,
        "Timestamp": timestamp,
        "TransactionType": "CustomerPayBillOnline",
        "Amount": int(amount),
        "PartyA": phone,
        "PartyB": settings.mpesa_shortcode,
        "PhoneNumber": phone,
        "CallBackURL": callback_url,
        # Daraja caps these at 12 and 13 characters.
        "AccountReference": account_reference[:12],
        "TransactionDesc": description[:13],
    }
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            token = await _token(client)
            r = await client.post(
                f"{settings.mpesa_base_url}/mpesa/stkpush/v1/processrequest",
                json=payload, headers={"Authorization": f"Bearer {token}"},
            )
        body = r.json()
    except MpesaUnavailable:
        raise
    except Exception as exc:
        raise MpesaUnavailable(f"STK push failed: {type(exc).__name__}") from exc
    if str(body.get("ResponseCode")) != "0" or not body.get("CheckoutRequestID"):
        logger.warning("[mpesa_stk] push refused: %s", body.get("ResponseDescription") or body.get("errorMessage"))
        raise MpesaUnavailable("STK push refused")
    return body


async def stk_query(checkout_request_id: str) -> dict:
    """Ask Safaricom how a prompt ended. Our own authenticated call, so its
    answer can be trusted where a callback's cannot."""
    timestamp, password = _password()
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            token = await _token(client)
            r = await client.post(
                f"{settings.mpesa_base_url}/mpesa/stkpushquery/v1/query",
                json={
                    "BusinessShortCode": settings.mpesa_shortcode,
                    "Password": password,
                    "Timestamp": timestamp,
                    "CheckoutRequestID": checkout_request_id,
                },
                headers={"Authorization": f"Bearer {token}"},
            )
        return r.json()
    except MpesaUnavailable:
        raise
    except Exception as exc:
        raise MpesaUnavailable(f"STK query failed: {type(exc).__name__}") from exc
