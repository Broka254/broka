"""
BROKA - Mobitech SMS Router (Delivery Report webhook)
─────────────────────────────────────────────────────────────────────────────
Receives delivery reports (DLRs) from Mobitech Technologies for SMS sent via
api.core.sms.MobitechSMS. Configure this URL as the "Delivery Webhook" in
the Mobitech dashboard (Developers / Settings -> Delivery Webhook):

    https://<your-domain>/sms/dlr

BROKA doesn't currently persist a message_id when it sends an OTP/nudge
(api.core.sms.MobitechSMS.send only returns bool, not the provider's
message_id), so there's no row to match a DLR back to yet. This endpoint
logs each report so delivery failures are visible in the logs/observability
pipeline; wiring it to update a per-message status column is a follow-up if
BROKA starts tracking that.

No secret-guarding on this route (unlike /mpesa/callback, /verify/callback,
/featured/callback): those move money or flip a verified flag if forged, so
they're worth protecting behind MPESA_CALLBACK_SECRET. A forged DLR here
just produces a misleading log line - there is no state change to protect,
so the extra ceremony isn't worth it.
"""
from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter
from pydantic import BaseModel

logger = logging.getLogger(__name__)
router = APIRouter()


class MobitechDLR(BaseModel):
    """Field names match Mobitech's documented DLR payload. Everything but
    messageId is optional, and all typed as str: their own example payload
    quotes every value (including dlrStatus, which the docs table calls
    "Integer") so this stays lenient about the wire format rather than
    risking a 422 on a real delivery report over a documentation mismatch.
    """
    messageId: str
    dlrTime: Optional[str] = None
    dlrStatus: Optional[str] = None
    dlrDesc: Optional[str] = None
    tat: Optional[str] = None
    network: Optional[str] = None
    destaddr: Optional[str] = None
    sourceaddr: Optional[str] = None
    origin: Optional[str] = None


@router.post("/dlr")
async def mobitech_dlr(report: MobitechDLR) -> dict:
    logger.info(
        "[sms:mobitech:dlr] message_id=%s status=%s (%s) to=%s from=%s network=%s time=%s",
        report.messageId, report.dlrStatus, report.dlrDesc,
        report.destaddr, report.sourceaddr, report.origin, report.dlrTime,
    )
    return {"received": True}
