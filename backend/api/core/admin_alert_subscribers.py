"""Admin alert subscribers — turn platform events into ops alerts.

Registered on the catalog bus (@subscribe_to) and wired by import in
main.py next to the other subscriber modules. Each handler opens its own
session: emit() hands handlers only the envelope, never a transaction, and
the alert must land even when the emitter's own commit later rolls back.
Every failure is logged and swallowed — a broken ops alert must never break
the dispute, fraud or payment path that raised it.
"""
from __future__ import annotations

import logging

from api.core.event_catalog import EventEnvelope, EventType, subscribe_to

_log = logging.getLogger(__name__)


async def _create(kind: str, severity: str, title: str, **kwargs) -> None:
    from api.core.admin_alerts import create_alert
    from api.database import AsyncSessionLocal

    try:
        async with AsyncSessionLocal() as db:
            await create_alert(
                db, kind=kind, severity=severity, title=title, **kwargs
            )
            await db.commit()
    except Exception as exc:
        _log.warning("[admin_alerts] subscriber %s failed (non-fatal): %s", kind, exc)


@subscribe_to(EventType.DISPUTE_OPENED)
async def alert_on_dispute_opened(envelope: EventEnvelope) -> None:
    """A buyer/seller dispute needs a human sooner than any queue review."""
    payload = envelope.payload or {}
    dispute_id = payload.get("dispute_id") or envelope.aggregate_id
    deal_id = payload.get("deal_id", "")
    await _create(
        "dispute_opened",
        "high",
        f"Dispute opened on deal {deal_id or dispute_id}",
        body=f"Dispute {dispute_id} opened by {payload.get('opener_id', 'a party')}"
        + (f" (deal {deal_id})" if deal_id else ""),
        href=f"/disputes/{dispute_id}",
        meta={"dispute_id": dispute_id, **({"deal_id": deal_id} if deal_id else {})},
    )


@subscribe_to(EventType.DISPUTE_RESOLVED)
async def alert_on_dispute_resolved(envelope: EventEnvelope) -> None:
    """The fact cleared itself — close the matching open alert, if any."""
    from api.core.admin_alerts import resolve_by_ref
    from api.database import AsyncSessionLocal

    payload = envelope.payload or {}
    dispute_id = payload.get("dispute_id") or envelope.aggregate_id
    if not dispute_id:
        return
    try:
        async with AsyncSessionLocal() as db:
            resolved = await resolve_by_ref(
                db, kind="dispute_opened", ref={"dispute_id": dispute_id}
            )
            await db.commit()
            if resolved:
                _log.info(
                    "[admin_alerts] auto-resolved %d alert(s) for dispute %s",
                    resolved, dispute_id,
                )
    except Exception as exc:
        _log.warning("[admin_alerts] auto-resolve failed (non-fatal): %s", exc)


@subscribe_to(EventType.FRAUD_FLAGGED)
async def alert_on_fraud_flagged(envelope: EventEnvelope) -> None:
    """A fraud flag is the highest-urgency ops signal on the bus."""
    payload = envelope.payload or {}
    user_id = payload.get("user_id") or envelope.aggregate_id
    await _create(
        "fraud_flagged",
        "critical",
        f"Fraud flag on user {user_id}",
        body=str(payload.get("reason", "")) or None,
        href=f"/users/{user_id}",
        meta={"user_id": user_id},
    )


@subscribe_to(EventType.PAYMENT_FAILED)
async def alert_on_payment_failed(envelope: EventEnvelope) -> None:
    """BROKA income that never arrived — worth ops attention, not a page."""
    payload = envelope.payload or {}
    reference = payload.get("reference") or envelope.aggregate_id
    await _create(
        "payment_failed",
        "medium",
        f"Payment failed ({payload.get('purpose', 'unknown purpose')})",
        body=f"Reference {reference}: {payload.get('reason', 'no reason given')}",
        href="/payments",
        meta={"reference": reference},
    )
