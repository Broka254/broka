"""A store plan's places, for its owner's own listings (PRICING.md §5).

An online store's plan is bought for a number of listings
(StoreSubscription.listings). Listings posted into the store never pay a
listing fee (listings/paid.fee_applies), and the plan's places cover the
owner's OWN listings too - posted under "No Store", or from before the
store - while it has places to spare: a seller who paid for 20 listings
pays no listing fee until they have 20 up (the founder, 2026-11-20). Before
this, every listing outside the store paid from the first one, whatever the
plan still had free.

Which listings a plan covers:
  * every live listing in the store (billing.live_listings_count);
  * the owner's own listings whose paid time IS the plan's: paid_until equal
    to the subscription's paid_until. That equality is the record - no
    column was added for it. A covered listing is given exactly the plan's
    end when it is posted (ListingService.create_listing) or put up on the
    plan (pricing/payments.renew_free), and a payment for the plan moves
    both together (carry_forward), so they stay equal for as long as the
    listing is on the plan. A listing paid with its own fee runs from its
    payment in whole 30-day months and never lands on the plan's end to the
    microsecond.

Only listings the store may hold (stores/categories.may_hold): a shop's
places are priced for goods - KES 60 a listing for two months - and a car,
a plot or a house on one would undercut its own listing fee, exactly as
posting it into the store would.

Nothing here reads a setting: callers ask only while listing fees are on.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Optional

from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, ListingStatus, ListingType
from api.models.store import Store
from api.models.store_billing import StoreSubscription


@dataclass(frozen=True)
class PlanCover:
    store_id: str
    store_name: str
    places: int          # listings the plan in force covers
    in_use: int          # of those, taken (the listing asked about counted when covered)
    until: datetime      # the plan's paid end, which a covered listing's paid_until equals
    covered: bool        # the listing asked about is already one of them

    @property
    def free(self) -> int:
        return max(0, self.places - self.in_use)

    def to_dict(self) -> dict:
        return {
            "store_id": self.store_id,
            "store_name": self.store_name,
            "places": self.places,
            "in_use": self.in_use,
            "free": self.free,
            "until": self.until.isoformat(),
            "covered": self.covered,
        }


def _owners_listings_on(seller_id: str, until: datetime) -> list:
    """SQL conditions: the owner's own (not in a store) active listings whose
    paid time is a plan's ending `until` - the plan's covered listings."""
    return [
        Listing.seller_id == seller_id,
        Listing.store_id.is_(None),
        Listing.status == ListingStatus.active,
        # IS NULL kept: NULL != 'auction' is NULL in SQL (listings/paid.py).
        or_(Listing.listing_type.is_(None), Listing.listing_type != ListingType.auction),
        Listing.paid_until == until,
    ]


async def _in_use(db: AsyncSession, store_id: str, seller_id: str, until: datetime,
                  now: datetime) -> int:
    from api.domains.stores.billing import live_listings_count

    in_store = await live_listings_count(db, store_id, now)
    # Counted like the store's own: a listing a buyer reported sold out
    # holds no place until its seller says it is still there.
    covered = (await db.execute(
        select(func.count(Listing.id)).where(
            *_owners_listings_on(seller_id, until),
            Listing.sold_out_reported_at.is_(None),
        )
    )).scalar_one()
    return int(in_store) + int(covered)


async def plan_cover(
    db: AsyncSession, seller_id: str, category: Optional[str], *,
    listing: Optional[Listing] = None, now: Optional[datetime] = None, lock: bool = False,
) -> Optional[PlanCover]:
    """The seller's paid store plan that covers `listing` (one of their own
    listings, filed under `category`), or that still has a place for a
    listing in `category` - None when no plan does.

    A plan counts while it is paid for (paid_until ahead) and has places: a
    grace row (no plan_id, 0 listings) covers nothing. A listing already paid
    beyond the plan's end is left alone: putting it on the plan would only
    shorten its time.

    `lock` takes the subscription row's lock, so two listings posted at once
    can't both take a plan's last place: the second waits for the first's
    commit, then counts it."""
    from api.domains.stores import categories as store_categories

    now = now or datetime.utcnow()
    query = (
        select(Store.id, Store.name, Store.category,
               StoreSubscription.listings, StoreSubscription.paid_until)
        .join(StoreSubscription, StoreSubscription.store_id == Store.id)
        .where(
            Store.owner_id == seller_id,
            Store.deleted_at.is_(None),
            StoreSubscription.plan_id.is_not(None),
            StoreSubscription.listings > 0,
            StoreSubscription.paid_until.is_not(None),
            StoreSubscription.paid_until > now,
        )
        # The plan paid furthest ahead first: the longest a listing can stay up.
        .order_by(StoreSubscription.paid_until.desc(), Store.id)
    )
    if lock:
        query = query.with_for_update(of=StoreSubscription)
    for store_id, name, store_category, places, until in (await db.execute(query)).all():
        if not store_categories.may_hold(store_category, category):
            continue
        paid_until = getattr(listing, "paid_until", None)
        covered = listing is not None and paid_until == until
        if not covered and paid_until is not None and paid_until > until:
            continue
        in_use = await _in_use(db, store_id, seller_id, until, now)
        if covered or in_use < places:
            return PlanCover(store_id=store_id, store_name=name, places=int(places),
                             in_use=in_use, until=until, covered=covered)
    return None


async def is_covered(db: AsyncSession, listing: Listing, now: Optional[datetime] = None) -> bool:
    """Whether this listing of the seller's own is on their store plan now."""
    if getattr(listing, "store_id", None) or getattr(listing, "paid_until", None) is None:
        return False
    cover = await plan_cover(db, listing.seller_id, listing.category, listing=listing, now=now)
    return cover is not None and cover.covered


async def carry_forward(
    db: AsyncSession, store_id: str, old_until: Optional[datetime],
    new_until: Optional[datetime], places: int, now: Optional[datetime] = None,
) -> int:
    """A payment for the store's plan moved its paid end from `old_until` to
    `new_until`: move the owner's listings the plan covers with it, so they
    stay up exactly as long as the store's own listings do - and come back
    with them when a lapsed plan is paid again. Never more of them than the
    plan has places for beside the store's own listings (a smaller plan
    bought after a bigger one lapsed): the oldest keep theirs. Runs in the
    payment's transaction (billing._settle). Returns how many moved."""
    if old_until is None or new_until is None or old_until == new_until:
        return 0
    store = await db.get(Store, store_id)
    if store is None or store.deleted_at is not None:
        return 0
    from api.domains.stores.billing import live_listings_count

    room = int(places or 0) - await live_listings_count(db, store_id, now)
    if room <= 0:
        return 0
    ids = (await db.execute(
        select(Listing.id).where(*_owners_listings_on(store.owner_id, old_until))
        .order_by(Listing.created_at, Listing.id).limit(room)
    )).scalars().all()
    if ids:
        await db.execute(
            update(Listing).where(Listing.id.in_(ids)).values(paid_until=new_until)
            .execution_options(synchronize_session=False)
        )
    return len(ids)
