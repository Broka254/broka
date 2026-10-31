"""Launch offers: first 50 listings free, first 10 stores free, one each per user.

Why a claim table rather than counting listings/stores (models/launch_offer.py):
counting breaks the moment a free listing is deleted (its slot would be
handed out again) and races the moment two sellers post at once. A claim
is written inside the creation transaction, ranked by the unique
(offer_type, rank) index, and never recycled.

Eligibility, beyond the global limit:
  * one per user - a second listing/store never qualifies, even after the
    first is deleted (the per-user unique index, checked here for a clean
    answer instead of an IntegrityError);
  * personal listings only - a store listing is already covered by its
    store's plan and must not burn a launch slot (listings/paid.fee_applies).

Claims are NOT gated on the billing switches. While fees are off every
listing is free anyway, but the claim still matters: it stamps the
listing's/store's 60-day live window (paid_until), which is what the
countdown, the "goes offline" date and the 2-day SMS all read. Gating on
the switches left the offer inert until billing day - counts frozen at
50/10, every listing on "No expiry", no SMS ever firing - which is exactly
the dead launch this module exists to prevent. A claim made while billing
is off buys visibility window, not a fee waiver; when billing turns on,
unclaimed listings keep their grandfathered free status and claimed ones
renew normally.

`peek_*` answers "would this qualify?" for quotes and badges without
consuming anything. `claim_*` is the only writer, called by the creation
paths with the new row's id, in their transaction.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.models.launch_offer import LaunchOfferClaim, LaunchOfferType

logger = logging.getLogger(__name__)

# Claim retries: two creators racing for the last slot collide on the rank
# index; the loser re-counts and either takes the next rank or finds the
# offer exhausted. A handful of attempts covers realistic contention.
_MAX_CLAIM_ATTEMPTS = 5


@dataclass(frozen=True)
class OfferStatus:
    offer_type: str
    limit: int
    claimed: int
    days: int

    @property
    def remaining(self) -> int:
        return max(0, self.limit - self.claimed)

    def to_dict(self, eligible: Optional[bool] = None,
                already_claimed: Optional[bool] = None,
                enabled: Optional[bool] = None) -> dict:
        out = {
            "limit": self.limit,
            "claimed": self.claimed,
            "remaining": self.remaining,
            "free_days": self.days,
            "one_per_user": True,
        }
        if enabled is not None:
            # False means the matching billing switch is off (or the limit
            # is 0): the offer is paused, not exhausted. A client that
            # only read `remaining` would tease "3 left!" for an offer
            # nobody can claim, or hide one that is merely paused.
            out["enabled"] = enabled
        if eligible is not None:
            out["eligible"] = eligible
        if already_claimed is not None:
            out["already_claimed"] = already_claimed
        return out


def _limit_and_days(offer_type: str) -> tuple[int, int]:
    if offer_type == LaunchOfferType.LISTING_FREE:
        return settings.free_listing_offer_limit, settings.free_listing_offer_days
    return settings.free_store_offer_limit, settings.free_store_offer_days


async def _claimed_count(db: AsyncSession, offer_type: str) -> int:
    return int((await db.execute(
        select(func.count(LaunchOfferClaim.id)).where(
            LaunchOfferClaim.offer_type == offer_type)
    )).scalar() or 0)


async def _user_claim(db: AsyncSession, offer_type: str, user_id: str) -> Optional[LaunchOfferClaim]:
    return (await db.execute(
        select(LaunchOfferClaim).where(
            LaunchOfferClaim.offer_type == offer_type,
            LaunchOfferClaim.user_id == user_id)
    )).scalar_one_or_none()


async def status(db: AsyncSession, offer_type: str,
                 user_id: Optional[str] = None) -> OfferStatus:
    limit, days = _limit_and_days(offer_type)
    return OfferStatus(offer_type, limit, await _claimed_count(db, offer_type), days)


async def _peek(db: AsyncSession, offer_type: str, user_id: str) -> bool:
    limit, _ = _limit_and_days(offer_type)
    if limit <= 0:
        return False
    if await _user_claim(db, offer_type, user_id) is not None:
        return False
    return await _claimed_count(db, offer_type) < limit


async def peek_listing_offer(db: AsyncSession, user_id: str) -> bool:
    """Would this seller's next PERSONAL listing take a launch slot? Never claims."""
    return await _peek(db, LaunchOfferType.LISTING_FREE, user_id)


async def peek_store_offer(db: AsyncSession, user_id: str) -> bool:
    return await _peek(db, LaunchOfferType.STORE_FREE, user_id)


async def _claim(db: AsyncSession, offer_type: str, user_id: str,
                 entity_id: str,
                 now: datetime) -> Optional[LaunchOfferClaim]:
    limit, days = _limit_and_days(offer_type)
    if limit <= 0:
        return None
    if await _user_claim(db, offer_type, user_id) is not None:
        return None
    expires_at = now + timedelta(days=days)
    for _ in range(_MAX_CLAIM_ATTEMPTS):
        rank = await _claimed_count(db, offer_type) + 1
        if rank > limit:
            return None
        claim = LaunchOfferClaim(
            offer_type=offer_type, user_id=user_id, entity_id=entity_id,
            rank=rank, expires_at=expires_at, claimed_at=now,
        )
        try:
            async with db.begin_nested():
                db.add(claim)
        except IntegrityError:
            # Lost a race on (offer_type, rank) - or this user claimed from
            # a second device mid-flight. Re-check both, then retry/exhaust.
            if await _user_claim(db, offer_type, user_id) is not None:
                return None
            continue
        return claim
    logger.warning("[launch_offers] claim contention for %s user=%s", offer_type, user_id)
    return None


async def claim_listing_offer(db: AsyncSession, user_id: str, listing_id: str,
                              now: Optional[datetime] = None) -> Optional[LaunchOfferClaim]:
    """Take a free-listing slot for `listing_id`, in the caller's transaction."""
    return await _claim(db, LaunchOfferType.LISTING_FREE, user_id, listing_id,
                        now or datetime.utcnow())


async def claim_store_offer(db: AsyncSession, user_id: str, store_id: str,
                            now: Optional[datetime] = None) -> Optional[LaunchOfferClaim]:
    return await _claim(db, LaunchOfferType.STORE_FREE, user_id, store_id,
                        now or datetime.utcnow())


async def claim_for_entity(db: AsyncSession, offer_type: str,
                           entity_id: str) -> Optional[LaunchOfferClaim]:
    """The claim that paid for this listing/store, if the launch offer did."""
    return (await db.execute(
        select(LaunchOfferClaim).where(
            LaunchOfferClaim.offer_type == offer_type,
            LaunchOfferClaim.entity_id == entity_id)
    )).scalar_one_or_none()


async def offers_status(db: AsyncSession, user_id: Optional[str] = None) -> dict:
    """Both offers for GET /pricing/launch-offers and the sell/store screens."""
    out: dict = {}
    for key, offer_type, peek, billing_on in (
        ("listing_free", LaunchOfferType.LISTING_FREE, peek_listing_offer,
         settings.listing_fees_enabled),
        ("store_free", LaunchOfferType.STORE_FREE, peek_store_offer,
         settings.store_billing_enabled),
    ):
        st = await status(db, offer_type, user_id)
        eligible = await peek(db, user_id) if user_id else None
        already = None
        if user_id:
            already = await _user_claim(db, offer_type, user_id) is not None
        out[key] = st.to_dict(eligible=eligible, already_claimed=already,
                              enabled=bool(billing_on and st.limit > 0))
    return out
