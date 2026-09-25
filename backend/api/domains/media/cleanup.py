"""Removing uploads nothing ever used.

Photos are uploaded the moment they are picked (POST /media/images), before
the listing or store they are for exists. A seller who picks six photos and
then abandons the wizard leaves six uploads behind, each stored in three
sizes, forever - and nothing bounded how many a script could leave.

An upload is "pending" until a listing, store or profile references it
(api/domains/media/service.py marks it "attached" then; see AttachState).
One still pending ABANDONED_AFTER after it was uploaded is removed:

  1. claim  pending -> deleting, a compare-and-swap. Attaching is the same
            swap from pending, so an upload can't be both attached and
            removed: whichever commits first wins, and the loser is told
            to upload again.
  2. purge  delete every stored size, then deleting -> purged. A storage
            failure leaves the row "deleting"; the next pass retries it
            (deleting a missing object is not an error).

Attached and legacy assets are never touched. A listing's replaced photos
stay attached on purpose: what a listing showed can matter to a dispute.

Runs a bounded pass from the 5-minute sweep (api/core/workers.py).
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import select, update

from api.core.media_storage import StorageError, storage_named
from api.database import AsyncSessionLocal
from api.models.media import AttachState, MediaAsset

logger = logging.getLogger(__name__)

# Long enough that a sell or store-setup draft saved with its upload ids
# (both wizards keep one) is still good when the seller comes back to it.
ABANDONED_AFTER = timedelta(days=7)
BATCH = 100


def _keys(variants: Optional[str]) -> list[str]:
    try:
        stored = json.loads(variants or "{}")
    except (TypeError, ValueError):
        return []
    if not isinstance(stored, dict):
        return []
    return [e["key"] for e in stored.values() if isinstance(e, dict) and e.get("key")]


async def collect_abandoned_uploads(
    batch: int = BATCH, older_than: timedelta = ABANDONED_AFTER, now: Optional[datetime] = None,
) -> dict:
    """One bounded pass. Returns {"claimed", "purged", "failed"}."""
    now = now or datetime.utcnow()
    cutoff = now - older_than
    done = {"claimed": 0, "purged": 0, "failed": 0}

    async with AsyncSessionLocal() as db:
        # 1. Claim.
        ids = (await db.execute(
            select(MediaAsset.id)
            .where(MediaAsset.attach_state == AttachState.PENDING, MediaAsset.created_at < cutoff)
            .order_by(MediaAsset.created_at)
            .limit(batch)
        )).scalars().all()
        if ids:
            result = await db.execute(
                update(MediaAsset)
                .where(MediaAsset.id.in_(ids), MediaAsset.attach_state == AttachState.PENDING)
                .values(attach_state=AttachState.DELETING, deleted_at=now)
                .execution_options(synchronize_session=False)
            )
            await db.commit()
            done["claimed"] = result.rowcount

        # 2. Purge: this pass's claims, and any an earlier pass didn't finish.
        rows = (await db.execute(
            select(MediaAsset.id, MediaAsset.storage, MediaAsset.variants)
            .where(MediaAsset.attach_state == AttachState.DELETING)
            .order_by(MediaAsset.created_at)
            .limit(batch)
        )).all()
        for asset_id, storage_name, variants in rows:
            try:
                storage = storage_named(storage_name)
                for key in _keys(variants):
                    await storage.delete(key)
            except StorageError as exc:
                # Storage is down: stop, rather than fail every row in turn.
                done["failed"] += 1
                logger.error("[media-cleanup] stopped: storage unavailable (%s)", exc)
                break
            await db.execute(
                update(MediaAsset)
                .where(MediaAsset.id == asset_id, MediaAsset.attach_state == AttachState.DELETING)
                .values(attach_state=AttachState.PURGED)
                .execution_options(synchronize_session=False)
            )
            await db.commit()
            done["purged"] += 1

    if done["claimed"] or done["purged"] or done["failed"]:
        logger.info("[media-cleanup] pass done %s", done)
    return done
