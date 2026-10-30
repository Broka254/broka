"""SMS two days before a listing or online store goes offline.

The deadline is a plain fact (Listing.paid_until, StoreSubscription
.paid_until); this sweep is the only thing that texts about it. It runs
from the periodic sweep (core/workers.py) under the scheduler lease, and
is safe to run from several replicas at once anyway: expiry_notifications
holds one row per (entity, paid_until), claimed before the text is sent.

Rules that keep this from becoming spam or nonsense:
  * window: paid_until in (now, now + EXPIRY_SMS_DAYS_BEFORE days]. Entering
    the window IS the "two days before" moment; every later pass finds the
    dedup row and stays silent. Renewing moves paid_until, so the new
    period earns its own text - and only that one.
  * listings: personal, active, actually paid (paid_until > created_at -
    a never-paid draft is already offline, not "going offline"), and the
    seller left SMS alerts on for the listing. Store listings are skipped:
    their clock is the store's, and the store text covers them - texting
    both would warn twice about one deadline.
  * stores: active, not deleted, subscription paid_until in the window.
  * quiet hours (nudge_templates.is_quiet_hours): deferred, not dropped -
    no dedup row is written, so the morning pass sends it. A seller who
    renews overnight simply never gets a text about a deadline that moved.
  * a failed send keeps no dedup row, so the next pass retries. The cost
    ledger records the SMS inside the provider, as for every BROKA text.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.database import Listing, ListingStatus, ListingType, User
from api.models.expiry_notification import ExpiryEntity, ExpiryNotification
from api.models.store import Store
from api.models.store_billing import StoreSubscription

logger = logging.getLogger(__name__)

# Bounded per pass, like every other sweep: a backlog (the feature first
# switching on over thousands of listings) drains over a few passes
# instead of one pass texting the whole platform at once.
MAX_PER_PASS = 100


async def _claim(db: AsyncSession, entity_type: str, entity_id: str,
                 user_id: str, paid_until: datetime) -> bool:
    """Write the dedup row. False = already warned about this period."""
    try:
        async with db.begin_nested():
            db.add(ExpiryNotification(
                entity_type=entity_type, entity_id=entity_id,
                user_id=user_id, paid_until=paid_until, channel="sms",
            ))
    except IntegrityError:
        return False
    return True


async def _unclaim(db: AsyncSession, entity_type: str, entity_id: str,
                   paid_until: datetime) -> None:
    row = (await db.execute(
        select(ExpiryNotification).where(
            ExpiryNotification.entity_type == entity_type,
            ExpiryNotification.entity_id == entity_id,
            ExpiryNotification.paid_until == paid_until,
        )
    )).scalar_one_or_none()
    if row is not None:
        await db.delete(row)


def _days_left(paid_until: datetime, now: datetime) -> int:
    return max(1, round((paid_until - now).total_seconds() / 86400.0))


def listing_sms(name: str, paid_until: datetime, now: datetime) -> str:
    days = _days_left(paid_until, now)
    return (
        f"BROKA: Your listing '{name[:40]}' goes offline in {days} day"
        f"{'s' if days != 1 else ''} ({paid_until:%d %b}). "
        "Renew in the app to keep it live. It stays hidden until you do."
    )


def store_sms(name: str, paid_until: datetime, now: datetime) -> str:
    days = _days_left(paid_until, now)
    return (
        f"BROKA: Your store '{name[:40]}' goes offline in {days} day"
        f"{'s' if days != 1 else ''} ({paid_until:%d %b}). "
        "Renew its plan in the app to keep your shop and listings live."
    )


async def _send(phone: Optional[str], text: str) -> bool:
    if not phone:
        return False
    from api.core.sms import get_sms_provider

    try:
        return bool(await get_sms_provider().send(phone, text))
    except Exception as exc:  # provider raising must not kill the sweep
        logger.error("[expiry_alerts] SMS send raised: %s", exc)
        return False


async def send_due_expiry_alerts(db: AsyncSession,
                                 now: Optional[datetime] = None) -> dict:
    """One sweep pass. Returns {"listings": n, "stores": n} actually texted."""
    now = now or datetime.utcnow()
    sent = {"listings": 0, "stores": 0}
    if not settings.expiry_sms_enabled:
        return sent
    from api.core.nudge_templates import EAT, is_quiet_hours

    # is_quiet_hours reads a wall clock in EAT; `now` here is naive UTC, so
    # convert - passing it raw would shift the quiet window three hours.
    if is_quiet_hours(now.replace(tzinfo=timezone.utc).astimezone(EAT)):
        # Deferred: no claims written, the next daytime pass picks them up.
        return sent
    horizon = now + timedelta(days=settings.expiry_sms_days_before)

    # ── Listings ──────────────────────────────────────────────────────────
    listings = (await db.execute(
        select(Listing).where(
            Listing.status == ListingStatus.active,
            Listing.store_id.is_(None),
            Listing.listing_type != ListingType.auction,
            Listing.paid_until.is_not(None),
            Listing.paid_until > now,
            Listing.paid_until <= horizon,
            Listing.paid_until > Listing.created_at,
        ).order_by(Listing.paid_until).limit(MAX_PER_PASS)
    )).scalars().all()
    for listing in listings:
        if getattr(listing, "sms_alerts", True) is False:
            continue
        seller = await db.get(User, listing.seller_id)
        if seller is None or not seller.phone:
            # No number to text: claim the period so every later pass
            # doesn't re-claim, fail and unclaim the same listing for
            # the rest of the window. There is nobody to retry for.
            await _claim(db, ExpiryEntity.LISTING, listing.id,
                         listing.seller_id, listing.paid_until)
            continue
        if not await _claim(db, ExpiryEntity.LISTING, listing.id,
                            listing.seller_id, listing.paid_until):
            continue
        ok = await _send(
            seller.phone,
            listing_sms(listing.name or "your item", listing.paid_until, now),
        )
        if ok:
            sent["listings"] += 1
        else:
            await _unclaim(db, ExpiryEntity.LISTING, listing.id, listing.paid_until)

    # ── Stores ────────────────────────────────────────────────────────────
    rows = (await db.execute(
        select(StoreSubscription, Store)
        .join(Store, Store.id == StoreSubscription.store_id)
        .where(
            Store.is_active == True,  # noqa: E712 - a paused shop chose offline
            Store.deleted_at.is_(None),
            StoreSubscription.paid_until.is_not(None),
            StoreSubscription.paid_until > now,
            StoreSubscription.paid_until <= horizon,
        ).order_by(StoreSubscription.paid_until).limit(MAX_PER_PASS)
    )).all()
    for sub, store in rows:
        owner = await db.get(User, store.owner_id)
        if owner is None or not owner.phone:
            await _claim(db, ExpiryEntity.STORE, store.id,
                         store.owner_id, sub.paid_until)
            continue
        if not await _claim(db, ExpiryEntity.STORE, store.id,
                            store.owner_id, sub.paid_until):
            continue
        ok = await _send(
            owner.phone,
            store_sms(store.name or "your store", sub.paid_until, now),
        )
        if ok:
            sent["stores"] += 1
        else:
            await _unclaim(db, ExpiryEntity.STORE, store.id, sub.paid_until)

    await db.commit()
    if sent["listings"] or sent["stores"]:
        logger.info("[expiry_alerts] sent %s", sent)
    return sent
