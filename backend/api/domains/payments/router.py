"""Payments router - money users pay BROKA, through ZetuPay.

  POST /payments/zetupay/webhook    ZetuPay's transaction result

Register https://api.broka.co.ke/payments/zetupay/webhook in ZetuPay's
dashboard. Charges start where they always have - POST
/pricing/listing-fee/pay, /premium/subscribe, /featured/boost and
/verify/purchase - and the app polls their own status routes.
"""
import logging
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import zetupay
from api.core.client_ip import client_ip
from api.database import get_db
from api.domains.payments import service

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/zetupay/webhook")
async def zetupay_webhook(
    request: Request,
    x_zetupay_secret: Optional[str] = Header(None, alias="x-zetupay-secret"),
    db: AsyncSession = Depends(get_db),
):
    """Checked before the body is read: without the secret, anyone who finds
    this URL could claim any payment succeeded."""
    if not zetupay.webhook_secret_ok(x_zetupay_secret):
        logger.warning("[zetupay] webhook refused: wrong or missing secret, from %s", client_ip(request))
        raise HTTPException(status_code=401, detail="Unauthorized")
    try:
        payload = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="The body must be JSON.")
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="The body must be a JSON object.")

    try:
        outcome = await service.apply_event(db, zetupay.parse_event(payload), source="webhook")
    except Exception:
        # A 500, unlike Safaricom's callbacks, so ZetuPay redelivers: either
        # none of this event was committed and the redelivery applies it, or
        # it was and the transaction ledger turns the redelivery away.
        logger.exception("[zetupay] webhook not processed")
        raise HTTPException(status_code=500, detail="Not processed")
    return {"received": True, "outcome": outcome}
