"""
BROKA - Audit Log
Records who did what, when, on which resource.
Covers: escrow releases, dispute resolutions, admin actions, status changes.

All write operations that affect funds or user standing should call record_audit().
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)


async def record_audit(
    db: AsyncSession,
    actor_id: str,
    action: str,
    resource_type: str,
    resource_id: str,
    detail: Optional[str] = None,
    ip_address: Optional[str] = None,
) -> None:
    """
    Write an audit log entry.

    Args:
        db:            SQLAlchemy async session (does NOT commit — caller commits).
        actor_id:      User ID who performed the action.
        action:        Machine-readable action code, e.g. "escrow_released".
        resource_type: "deal" | "dispute" | "user" | "listing" etc.
        resource_id:   UUID of the affected resource.
        detail:        Optional human-readable note (verdict text, amount, etc.)
        ip_address:    Client IP (optional, from request.client.host).
    """
    from api.database import AuditLog  # avoid circular import at module level
    entry = AuditLog(
        actor_id=actor_id,
        action=action,
        resource_type=resource_type,
        resource_id=resource_id,
        detail=(detail or "")[:2000],
        ip_address=ip_address,
        created_at=datetime.utcnow(),
    )
    db.add(entry)
    logger.info(
        "[audit] actor=%s action=%s resource=%s/%s detail=%s",
        actor_id, action, resource_type, resource_id,
        (detail or "")[:120],
    )
