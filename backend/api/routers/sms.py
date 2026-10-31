"""
BROKA - SMS Delivery Report webhooks
─────────────────────────────────────────────────────────────────────────────
Two endpoints, one per provider generation:

* POST /sms/texin/dlr — Texin BulkSMS (current primary). Configure this URL
  as the delivery webhook in the Texin dashboard, plus TEXIN_WEBHOOK_SECRET.
  Every report is HMAC-verified (X-Texin-Signature:
  sha256=<HMAC-SHA256 of the raw request body>); forged or unsigned
  reports are rejected. Delivery events are processed idempotently: a
  repeated (message_id, status) pair is acknowledged without double
  counting. Never logs OTP contents or customer phone numbers.

* POST /sms/dlr — Mobitech (DEPRECATED, kept live). In-flight Mobitech
  reports may still arrive after the Texin migration; the endpoint only
  logs them, as before. No secret-guarding (a forged DLR here only
  produces a misleading log line — there is no state change to protect).

Neither provider replaces BROKA's own OTP lifecycle: BROKA generates,
stores, expires and verifies OTPs internally, and Texin only carries the
message via /send_sms (its /send_otp and /verify_otp endpoints are not
used). So there is no per-message row to match a DLR back to yet — each
report is recorded in api.core.sms's delivery cache (message_id ->
status) for the admin dashboard, and delivery statistics are only ever
reported from reports actually received, never fabricated.
"""
from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, Header, Request, Response
from pydantic import BaseModel

from api.core.config import settings

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


# Reports already processed (message_id, normalized status): replays are
# acknowledged without touching counters twice. Bounded in practice — one
# entry per (message, status) pair, and statuses are terminal quickly.
_TEXIN_DLR_SEEN: set[tuple[str, str]] = set()


def _extract_texin_report(body: dict) -> tuple[Optional[str], Optional[str]]:
    """Pull (message_id, status) out of a Texin delivery payload.

    Follows Texin's documented /check_status vocabulary ("sent" /
    "delivered" / "failed" / "rejected"); field aliases are accepted
    defensively without inventing new event behavior.
    """
    if not isinstance(body, dict):
        return None, None
    message_id = (
        body.get("message_id") or body.get("messageId")
        or body.get("messageid") or body.get("id")
    )
    status = (
        body.get("status") or body.get("delivery_status")
        or body.get("dlrStatus") or body.get("state")
    )
    mid = str(message_id).strip() if message_id is not None else None
    st = str(status).strip() if status is not None else None
    return (mid or None), (st or None)


@router.post("/texin/dlr")
async def texin_dlr(
    request: Request,
    response: Response,
    x_texin_signature: Optional[str] = Header(default=None, alias="X-Texin-Signature"),
) -> dict:
    """Texin delivery-report webhook: HMAC-verified, idempotent, redacted."""
    from api.core.sms import record_texin_delivery, verify_texin_signature

    raw_body = await request.body()
    secret = settings.texin_webhook_secret
    if not secret:
        # Fail closed: without the signing secret nothing can be verified,
        # so nothing is accepted (a 200 here would silently drop reports).
        logger.error("[sms:texin:dlr] rejected: TEXIN_WEBHOOK_SECRET not configured")
        response.status_code = 503
        return {"received": False, "error": "webhook not configured"}
    if not verify_texin_signature(raw_body, x_texin_signature or "", secret):
        logger.warning("[sms:texin:dlr] rejected: invalid signature")
        response.status_code = 401
        return {"received": False, "error": "invalid signature"}
    try:
        import json as _json

        body = _json.loads(raw_body.decode("utf-8") if raw_body else "")
    except (ValueError, UnicodeDecodeError):
        logger.warning("[sms:texin:dlr] rejected: malformed JSON body")
        response.status_code = 400
        return {"received": False, "error": "malformed JSON"}
    message_id, status = _extract_texin_report(body)
    if not message_id or not status:
        logger.warning("[sms:texin:dlr] rejected: missing message_id/status")
        response.status_code = 400
        return {"received": False, "error": "missing message_id/status"}
    normalized = record_texin_delivery(message_id, status)
    if normalized is None:
        logger.warning("[sms:texin:dlr] rejected: unrecognized status for message_id=%s", message_id)
        response.status_code = 400
        return {"received": False, "error": "unrecognized status"}
    key = (message_id, normalized)
    if key in _TEXIN_DLR_SEEN:
        # Idempotent replay: acknowledged, counted once (the first time).
        logger.info("[sms:texin:dlr] duplicate message_id=%s status=%s (already recorded)", message_id, normalized)
        return {"received": True, "duplicate": True}
    _TEXIN_DLR_SEEN.add(key)
    # Redacted by design: message IDs and statuses only — never the OTP
    # text or the recipient phone number.
    logger.info("[sms:texin:dlr] message_id=%s status=%s", message_id, normalized)
    return {"received": True}
