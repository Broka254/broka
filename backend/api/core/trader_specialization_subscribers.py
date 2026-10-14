"""Increments user_specializations on every new listing, so a seller's
specializations are derived from what they actually sell (Ch.5), not
self-declared. Importing this module for its side effect (the
@subscribe_to decorator running at import time) is what wires it up — see
the main.py registration, same pattern as zeno_subscribers.py /
deal_hub_subscribers.py.

FIX (redesign-guide audit, 2026-08-11): was registered on the legacy
api.core.events @subscribe bus, which only calls in-process handlers when
REDIS_URL is unset — under Redis (the recommended production config) this
handler silently never ran, so specializations stopped updating with no
error anywhere. Moved to the Event Catalog (api.core.event_catalog), whose
handlers fire unconditionally on every emit() regardless of transport.
publish(ListingCreated(...)) (api/domains/listings/service.py) already
bridges to EventType.LISTING_CREATED for every call — no other file needs
to change.
"""
from __future__ import annotations

from sqlalchemy import select

from api.core.event_catalog import subscribe_to, EventType, EventEnvelope
from api.database import AsyncSessionLocal, UserSpecialization, Category


@subscribe_to(EventType.LISTING_CREATED)
async def on_listing_created_update_specialization(envelope: EventEnvelope) -> None:
    seller_id = envelope.payload.get("seller_id")
    category_name = envelope.payload.get("category")
    if not seller_id or not category_name:
        return
    async with AsyncSessionLocal() as db:
        # Category.name has no unique constraint (see api/database.py), so more
        # than one row can legitimately share a name. scalar_one_or_none() used
        # to raise MultipleResultsFound the moment that happened, which the old
        # event bus swallowed and logged - so the listing still got created but
        # the specialization update silently never ran. Prefer a top-level
        # category over a subcategory, then break any further tie by id, so the
        # pick is deterministic instead of crashing.
        category = (await db.execute(
            select(Category)
            .where(Category.name == category_name)
            .order_by(Category.parent_id.is_(None).desc(), Category.id)
        )).scalars().first()
        if not category:
            return  # free-text category with no canonical mapping yet - skip until the migrate script runs

        existing = (await db.execute(
            select(UserSpecialization).where(
                UserSpecialization.user_id == seller_id,
                UserSpecialization.category_id == category.id,
            )
        )).scalar_one_or_none()

        if existing:
            existing.listing_count += 1
        else:
            db.add(UserSpecialization(user_id=seller_id, category_id=category.id, listing_count=1))
        await db.commit()
