"""Listings Service v3.0"""
from __future__ import annotations

import json
from datetime import datetime, timedelta
from typing import Optional, List
from fastapi import HTTPException
from pydantic_core import PydanticCustomError
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, desc, case, or_

from api.database import Listing, ListingStatus, ListingType, User, Interest, Deal, DealStatus, Category, SellerMetrics
from api.models.store import Store
from api.core.events import publish, ListingCreated, InterestExpressed
from api.core.config import settings
from api.core.geo import distances_km, haversine_km
from api.core.text_search import matches_all_terms, search_terms, term_matches
from . import validation as rules
from .location import canonical_county, listing_point, tidy_place
from .paid import fee_applies, fee_state, is_live, live_clause
from .validation import load_attributes


def _coerce_dt(value) -> Optional[datetime]:
    """Accept a datetime or an ISO string from the request body.

    Listing creation takes a plain dict (not a validated model) at this
    layer, so a client can send either shape; anything unparseable is
    treated as absent rather than raising, matching how every other
    optional field in create_listing behaves.
    """
    from api.core.timeutil import parse_iso_to_naive_utc, to_naive_utc

    if value is None:
        return None
    if isinstance(value, datetime):
        return to_naive_utc(value)
    try:
        return parse_iso_to_naive_utc(str(value))
    except (TypeError, ValueError):
        return None


def _strict_dt(value, field: str) -> Optional[datetime]:
    """Parse a supplied auction timestamp, or 422.

    Distinct from _coerce_dt above, which turns anything unparseable into
    None. That is right for the optional listing fields it was written for
    and wrong for an auction window: silently discarding a malformed
    auction_ends_at does not reject the request, it CREATES A DIFFERENT
    AUCTION - one closing at the 72-hour default instead of when the seller
    said. The seller is told it worked and finds out otherwise when it
    closes.

    Omitted is still omitted; the caller supplies the default. Only a value
    that was SENT and cannot be read is an error.
    """
    from api.core.timeutil import parse_iso_to_naive_utc, to_naive_utc

    if value is None:
        return None
    if isinstance(value, datetime):
        return to_naive_utc(value)
    text = str(value).strip()
    if not text:
        return None
    try:
        # Converted to UTC before the zone is dropped - an offset is an
        # instant, not decoration. See api/core/timeutil.py.
        return parse_iso_to_naive_utc(text)
    except (TypeError, ValueError):
        from api.domains.auctions.lifecycle import AuctionError
        # Not one of validate_terms' codes: those describe a window that
        # parsed and is wrong, this one never parsed at all.
        raise AuctionError(
            422, "INVALID_TIMESTAMP",
            f"{field} must be an ISO 8601 date-time, e.g. 2026-10-01T14:30:00.",
        )


def _strict_float(value, field: str, code: str) -> Optional[float]:
    """Parse a supplied auction number, or 422. Same reasoning as _strict_dt:
    an unreadable increment used to fall back to the default silently."""
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        from api.domains.auctions.lifecycle import AuctionError
        raise AuctionError(422, code, f"{field} must be a number.")


def resolve_auction_terms(data: dict, price, auction_date, now: Optional[datetime] = None) -> dict:
    """The auction terms a creation request actually asks for, validated.

    Creation used to go straight to AuctionMeta without consulting
    lifecycle.validate_terms, so PATCH /auctions/{id}/terms enforced rules
    that POST /listings did not: an auction could be CREATED with an end
    before its start, or a reserve under its starting price, and only then
    become uneditable. The authority has to be the same on both doors.

    Defaults still apply where a field is genuinely absent - omitted start
    means now, omitted end means auction_date or the configured default
    duration - because the sell wizard legitimately omits them. What no
    longer happens is a SUPPLIED value being quietly replaced by one of
    those defaults because it could not be parsed.

    Raises AuctionError (422, with validate_terms' own codes) and returns
    the resolved values. Called before the Listing row is written, so a
    rejected auction leaves nothing behind.
    """
    from api.core.config import settings as _settings
    from api.domains.auctions import lifecycle

    now = now or datetime.utcnow()

    starts_at = _strict_dt(data.get("auction_starts_at"), "auction_starts_at") or now
    ends_at = (
        _strict_dt(data.get("auction_ends_at"), "auction_ends_at")
        or _strict_dt(auction_date, "auction_date")
        or now + timedelta(hours=_settings.auction_default_duration_hours)
    )

    increment = _strict_float(
        data.get("min_bid_increment"), "min_bid_increment", "INVALID_INCREMENT",
    )
    reserve = _strict_float(
        data.get("reserve_price"), "reserve_price", "INVALID_RESERVE",
    )
    starting_price = _strict_float(price, "price", "INVALID_STARTING_PRICE")

    lifecycle.validate_terms(
        starting_price=starting_price,
        min_bid_increment=increment,
        starts_at=starts_at,
        ends_at=ends_at,
        reserve_price=reserve,
        now=now,
    )

    return {
        "starts_at": starts_at,
        "ends_at": ends_at,
        "min_bid_increment": (
            increment if increment is not None
            else _settings.auction_default_min_increment
        ),
        "starting_price": starting_price,
        "reserve_price": reserve,
    }


def _derive_location_name(county: Optional[str], subcounty: Optional[str], fallback: Optional[str]) -> Optional[str]:
    """location_name is the single free-text field every existing reader
    (search .ilike() filter, negotiate.py prompts, buy_agent matching,
    trader profiles...) already expects, so the new structured 3-part
    location step still needs to produce one. County/subcounty win when
    given, since they're the new authoritative source; a directly-sent
    location_name is only a fallback for any caller not using the new
    fields yet."""
    parts = [p.strip() for p in (subcounty, county) if p and p.strip()]
    return ", ".join(parts) if parts else fallback


async def load_listing_media(db: AsyncSession, listings, sellers=()) -> dict:
    """Every image asset a page of listings refers to - photos, showcase
    images and the sellers' avatars - in one query, for _listing_dict."""
    from api.domains.media.service import load_assets, parse_id_list
    ids: set[str] = set()
    for listing in listings:
        ids.update(parse_id_list(listing.photo_ids))
        if listing.showcase_id:
            ids.add(listing.showcase_id)
    for seller in sellers:
        if seller is not None and seller.profile_photo_id:
            ids.add(seller.profile_photo_id)
    return await load_assets(db, ids)


class ListingService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def create_listing(
        self, seller_id: str, data: dict, client_ref: Optional[str] = None,
    ) -> dict:
        """Create a listing and return the owner's view of it.

        `client_ref` is the request's X-Idempotency-Key. Sent again - the
        response to the first attempt never reached the phone, and the
        seller tapped Activate again - it returns the listing that attempt
        created instead of a second copy of it.
        """
        # Check trust score — block high-risk users
        r = await self.db.execute(select(User).where(User.id == seller_id))
        seller = r.scalar_one_or_none()
        if seller is None:
            # A token outliving its account. Carrying on wrote a listing
            # for a seller who doesn't exist (a foreign-key 500 on
            # PostgreSQL) and skipped the trust check below.
            raise HTTPException(status_code=401, detail="Account not found. Please sign in again.")
        # `is not None`, not `or 100`: the lowest score there is, 0, read as
        # a perfect 100, so the most distrusted accounts were the ones this
        # never stopped. Same rule as api/core/permissions.py.
        if seller.trust_score is not None and seller.trust_score < 20:
            raise HTTPException(
                status_code=403,
                detail="Your account has been restricted due to trust score. Contact support.",
            )

        # A repeat of a create that already happened. Before the rate limit,
        # so the retry of a listing that exists is never refused for it.
        if client_ref:
            replay = await self._created_with_ref(seller_id, client_ref)
            if replay is not None:
                return replay

        await self._check_create_rate(seller_id)

        # AI Showcase/Cover Image, set at creation time (2026-08-29). The
        # wizard's Showcase step runs before the listing exists (see
        # domains/showcase/service.py's generate_showcase_preview_standalone
        # docstring for why), so unlike Edit Listing's per-listing
        # set_showcase_image() endpoint, a showcase chosen during listing
        # creation arrives bundled into this same call instead of a
        # separate one. Same two allowed values as that endpoint.
        showcase_url = data.get("showcase_image_url")
        showcase_id = data.get("showcase_id") or None
        showcase_source = data.get("showcase_image_source")
        if bool(showcase_url or showcase_id) != bool(showcase_source):
            raise HTTPException(
                status_code=400,
                detail="showcase_image_url (or showcase_id) and showcase_image_source must be given together",
            )
        if showcase_source and showcase_source not in ("gallery", "ai"):
            raise HTTPException(status_code=400, detail="showcase_image_source must be 'gallery' or 'ai'")

        # Image assets. Ownership and purpose are checked here, before the
        # listing exists, so a bad id leaves no half-created listing.
        from api.domains.media.service import (
            check_legacy_images, dump_id_list, require_owned_assets, split_legacy_photos,
        )
        from api.models.media import MediaPurpose
        # Base64 photos and showcase from older app builds: inline images
        # only (or the seller's own BROKA image URLs), never a link elsewhere.
        await check_legacy_images(
            self.db, seller_id, split_legacy_photos(data.get("verified_photos")),
            MediaPurpose.LISTING_PHOTO,
        )
        await check_legacy_images(
            self.db, seller_id, [showcase_url], MediaPurpose.LISTING_SHOWCASE,
        )
        photo_ids_json = None
        if data.get("photo_ids"):
            photo_ids_json = dump_id_list(await require_owned_assets(
                self.db, seller_id, data["photo_ids"], {MediaPurpose.LISTING_PHOTO},
            ))
        if showcase_id:
            await require_owned_assets(
                self.db, seller_id, [showcase_id],
                {MediaPurpose.LISTING_SHOWCASE, MediaPurpose.LISTING_PHOTO},
            )

        # subcategory_id is a foreign key. An id that isn't a category (a
        # draft saved before the taxonomy changed, say) used to reach the
        # INSERT: a 500 on PostgreSQL, and on SQLite, which doesn't enforce
        # the key, a listing filed under nothing.
        subcategory_id = data.get("subcategory_id") or None
        subcategory = await self.db.get(Category, subcategory_id) if subcategory_id else None
        if subcategory_id and subcategory is None:
            raise HTTPException(
                status_code=400,
                detail="That category is no longer available. Go back and choose it again.",
            )
        # The top-level category is the subcategory's parent, whatever name
        # the request carried: the two used to be taken separately, so a
        # draft could file a plot under "Electronics" - and the Land size
        # rule below keys on the category.
        category_name = data["category"]
        if subcategory is not None:
            top = (
                await self.db.get(Category, subcategory.parent_id)
                if subcategory.parent_id else subcategory
            )
            if top is not None:
                category_name = top.name

        attributes = data.get("attributes")
        if category_name.strip().lower() == rules.LAND_CATEGORY.lower():
            # Land must say how big it is (validation.clean_land_details).
            try:
                attributes = rules.clean_land_details(attributes)
            except PydanticCustomError as exc:
                raise HTTPException(status_code=400, detail=exc.message())

        # Store association (optional - spec §5/§11: "[No Store] / [My
        # Store]" at creation time). Ownership is checked server-side
        # against the AUTHENTICATED seller_id, never trusted from the
        # client just because a store_id was sent (spec §22) - a listing
        # can only be created directly into a store the creator owns.
        store_id = data.get("store_id")
        store: Optional[Store] = None
        if store_id:
            store = await self.db.get(Store, store_id)
            if not store:
                raise HTTPException(status_code=400, detail="Store not found")
            if store.owner_id != seller_id:
                raise HTTPException(status_code=403, detail="You do not own this store")

        # Auction terms are validated BEFORE the listing row exists, so a
        # rejected auction leaves no orphan listing behind.
        # str from the HTTP layer (ListingIn.listing_type is a str), a
        # ListingType from a direct service call in a test - accept both.
        _requested_type = data.get("listing_type", "direct")
        _requested_type = getattr(_requested_type, "value", _requested_type)
        auction_terms = None
        if _requested_type == ListingType.auction.value:
            auction_terms = resolve_auction_terms(
                data, data.get("price"), data.get("auction_date"),
            )

        # The county as officially spelt, so "nairobi" and "Nairobi County"
        # are one place to the location filter; the point it's shown at is
        # the county's, not the seller's phone (see location.py).
        county = canonical_county(data.get("location_county")) or tidy_place(data.get("location_county"))
        subcounty = tidy_place(data.get("location_subcounty"))
        lat, lng = listing_point(county, data["lat"], data["lng"])

        listing = Listing(
            seller_id=seller_id,
            store_id=store.id if store else None,
            name=data["name"],
            description=data.get("description"),
            category=category_name,
            subcategory_id=subcategory_id,
            condition=data.get("condition"),
            attributes=json.dumps(attributes) if attributes else None,
            price=data["price"],
            price_unit=data.get("price_unit"),
            quantity=data.get("quantity"),
            price_negotiable=data.get("price_negotiable", True) is not False,
            delivery_available=data.get("delivery_available"),
            delivery_note=(data.get("delivery_note") or None) if data.get("delivery_available") else None,
            sms_alerts=data.get("sms_alerts", True) is not False,
            lat=lat,
            lng=lng,
            location_name=_derive_location_name(county, subcounty, data.get("location_name")),
            location_county=county,
            location_subcounty=subcounty,
            listing_type=data.get("listing_type", "direct"),
            verified_photos=data.get("verified_photos"),
            verified_video=data.get("verified_video"),
            advert_video=data.get("advert_video"),
            target_bidders=data.get("target_bidders"),
            # For an auction this is the resolved, parsed end time rather
            # than the raw request value - ListingIn types auction_date as
            # a str, which would otherwise reach a DateTime column as one.
            auction_date=(
                auction_terms["ends_at"] if auction_terms
                else data.get("auction_date")
            ),
            reserve_price=(
                auction_terms["reserve_price"] if auction_terms
                else data.get("reserve_price")
            ),
            showcase_image_url=showcase_url,
            showcase_image_source=showcase_source,
            photo_ids=photo_ids_json,
            showcase_id=showcase_id,
            client_ref=client_ref or None,
        )
        # With listing fees on, a new listing waits, hidden, for its first
        # payment (pricing/payments.py): paid_until == created_at is how
        # "never paid" reads (listings/paid.py). Created while fees are off,
        # it stays free - paid_until NULL - even after they are switched on.
        awaiting_fee = settings.listing_fees_enabled and fee_applies(listing)
        if awaiting_fee:
            listing.created_at = listing.paid_until = datetime.utcnow()
        # Hosting an auction is premium (PRICING.md): one of the seller's
        # plan's auctions, spent last - every check that could refuse the
        # listing has already run - and given back below if this turns out
        # to be a retry of a create that already happened.
        if auction_terms is not None:
            from api.domains.premium import entitlements
            await entitlements.consume(self.db, seller_id, entitlements.Feature.AUCTION)
        self.db.add(listing)
        try:
            # Flushed for its id, then committed together with its auction
            # record. They used to be two commits, so a failure between
            # them left an auction with no window to open or close by.
            await self.db.flush()
            # An auction listing gets its lifecycle record here, at
            # creation, rather than being conjured by whatever places the
            # first bid. Creating it lazily was how auctions ended up with
            # no window at all: the row was invented with status="live" and
            # nothing else, so there was no start to enforce and no end to
            # close at. See domains/auctions/lifecycle.py.
            if auction_terms is not None:
                self._add_auction_meta(listing, auction_terms)
            await self.db.commit()
        except IntegrityError:
            # Two sends of the same create at once (a double tap on a slow
            # connection): both missed the check above, the unique index on
            # (seller_id, client_ref) let one in. The other returns it.
            await self.db.rollback()
            if auction_terms is not None:
                from api.domains.premium import entitlements
                await entitlements.release(self.db, seller_id, entitlements.Feature.AUCTION)
            if client_ref:
                replay = await self._created_with_ref(seller_id, client_ref)
                if replay is not None:
                    return replay
            raise
        await self.db.refresh(listing)

        # Only a listing buyers can see is announced: ListingCreated is what
        # sends the Buying Agent to tell buyers about it. An unpaid one is
        # announced when its fee is paid (pricing/payments.py).
        if not awaiting_fee:
            await publish(ListingCreated(
                listing_id=listing.id,
                seller_id=seller_id,
                price=data["price"],
                category=category_name,
            ))

        # The authenticated creator, reading back what they just created -
        # so the owner view, reserve included.
        assets = await load_listing_media(self.db, [listing], [seller])
        return self._owner_listing_dict(listing, seller=seller, store=store, assets=assets)

    async def _created_with_ref(self, seller_id: str, client_ref: str) -> Optional[dict]:
        """The owner view of the listing `seller_id` created with this
        X-Idempotency-Key, or None. Read fresh - it's also called after a
        rollback, when nothing loaded earlier may be touched."""
        listing = (await self.db.execute(
            select(Listing)
            .where(Listing.seller_id == seller_id, Listing.client_ref == client_ref)
            .execution_options(populate_existing=True)
        )).scalar_one_or_none()
        if listing is None:
            return None
        seller = (await self.db.execute(
            select(User).where(User.id == seller_id).execution_options(populate_existing=True)
        )).scalar_one_or_none()
        store = await self.db.get(Store, listing.store_id) if listing.store_id else None
        assets = await load_listing_media(self.db, [listing], [seller])
        return self._owner_listing_dict(listing, seller=seller, store=store, assets=assets)

    @staticmethod
    async def _check_create_rate(seller_id: str) -> None:
        """Per-seller posting limits (api/core/rate_limit.py), in words a
        seller can act on rather than the limiter's own."""
        from api.core import rate_limit
        for limiter, span in (
            (rate_limit.listing_create_limiter, "hour"),
            (rate_limit.listing_create_daily_limiter, "day"),
        ):
            try:
                await limiter.check_and_record(seller_id)
            except HTTPException as exc:
                if exc.status_code != 429:
                    raise
                raise HTTPException(
                    status_code=429,
                    detail=f"You've posted as many listings as we allow in a {span}. "
                           f"Please try again later.",
                    headers=exc.headers,
                )

    def _add_auction_meta(self, listing: Listing, terms: dict) -> None:
        """Write the auction's authoritative window from validated terms.

        `terms` comes from resolve_auction_terms, which has already applied
        the defaults and run lifecycle.validate_terms over the result. This
        method decides nothing - it used to parse and default the window
        itself, which is how creation ended up enforcing a different set of
        rules from PATCH /auctions/{id}/terms.

        Every auction gets a closing time, always: an auction that can
        never close can never take a bid (see lifecycle.place_bid), so
        listing.auction_date is kept in step with the resolved end.

        Adds to the session only: create_listing commits the listing and
        this together.
        """
        from api.database import AuctionMeta

        now = datetime.utcnow()
        ends_at = terms["ends_at"]
        if listing.auction_date != ends_at:
            listing.auction_date = ends_at

        meta = AuctionMeta(
            listing_id=listing.id,
            status="upcoming",
            min_bid_increment=terms["min_bid_increment"],
            starting_price=listing.price,
            starts_at=terms["starts_at"],
            ends_at=ends_at,
            bid_count=0,
        )
        # Derive the cached status from the window rather than assuming -
        # an auction scheduled to open now is already live.
        from api.domains.auctions import lifecycle as _lifecycle
        meta.status = _lifecycle.effective_status(meta, now)
        self.db.add(meta)

    async def get_listing(self, listing_id: str) -> dict:
        r = await self.db.execute(select(Listing).where(Listing.id == listing_id))
        listing = r.scalar_one_or_none()
        # An unpaid or lapsed listing is not there for buyers, the same as
        # one that never existed - its seller sees it at /private.
        if not listing or not is_live(listing):
            raise HTTPException(status_code=404, detail="Listing not found")
        # Increment view count
        listing.views = (listing.views or 0) + 1
        await self.db.commit()
        seller = (await self.db.execute(select(User).where(User.id == listing.seller_id))).scalar_one_or_none()
        store = await self.db.get(Store, listing.store_id) if listing.store_id else None
        assets = await load_listing_media(self.db, [listing], [seller])
        return self._listing_dict(listing, seller=seller, store=store, assets=assets)

    async def list_listings(
        self,
        category: Optional[str] = None,
        category_id: Optional[str] = None,
        subcategory_id: Optional[str] = None,
        condition: Optional[str] = None,
        listing_type: Optional[str] = None,
        seller_id: Optional[str] = None,
        store_id: Optional[str] = None,
        viewer_lat: Optional[float] = None,
        viewer_lng: Optional[float] = None,
        max_km: Optional[float] = None,
        min_price: Optional[float] = None,
        max_price: Optional[float] = None,
        search: Optional[str] = None,
        location: Optional[str] = None,
        attributes: Optional[dict] = None,
        # None/"newest": BROKA's ranking. "recent": strictly newest first.
        sort: Optional[str] = None,  # | "recent" | "price_low" | "price_high"
        limit: int = 20,
        offset: int = 0,
        with_total: bool = False,
        # Listings filed under none of these names (any case): a store's
        # "Other" shelf (StoreService.list_store_listings).
        outside_categories: Optional[List[str]] = None,
    ):
        """Phase 3 (broka_mockup_actualization_spec.md §7): "Filters must
        affect actual backend results. Do not implement fake UI-only
        filters" + "avoid fetching a page and discarding most results
        client-side". min_price/max_price/search/sort are real columns/SQL
        now. attributes (category-specific fields: brand, RAM, make...)
        live in Listing.attributes as JSON text (added Phase 2), which
        Postgres/SQLite can't both index-match the same portable way, so
        those - and max_km, which had the exact same discard-after-
        pagination bug already - are matched in Python against a bounded,
        already-SQL-narrowed candidate window, with pagination applied
        AFTER that matching rather than before it. Returns a bare list
        exactly as before unless with_total=True, which switches the shape
        to {"items": [...], "total": N} - opt-in so the two existing
        callers (CategoryZoneScreen, TraderProfileScreen) are unaffected
        unless they ask for the new shape.
        """
        q = select(Listing).where(Listing.status == ListingStatus.active, live_clause())
        if category:
            # FIX (buying-agent bug-hunt, 2026-09-17): case-insensitive
            # equality, not `Listing.category == category`.
            #
            # Listing.category is a free-text string the seller typed
            # (api/schemas.py ListingCreate: plain `str`), while every
            # caller filtering on it passes a canonical Category.name -
            # buy_agent/actions.py's SEARCH_PRODUCTS most of all. A plain
            # `==` meant "electronics" never found a listing filed as
            # "Electronics" on PostgreSQL, which is what production runs.
            #
            # func.lower() rather than .ilike(): ILIKE would treat a '%' or
            # '_' inside the caller's value as a wildcard (the bind protects
            # against injection, not against LIKE pattern semantics), and
            # this filter is reached from a user-supplied query param on
            # GET /listings. lower() = lower() has no pattern semantics at
            # all and is portable across SQLite and Postgres.
            #
            # Trade-off, stated rather than buried: Listing.category carries
            # a plain btree index (index=True on the model) that a bare
            # column comparison could use and an expression comparison
            # cannot. init_db()'s index_patches now creates the matching
            # lower(category) expression index so this stays indexed on both
            # dialects.
            # An old app build asking for "Vehicles" means "Automobiles".
            from api.domains.categories.seed import canonical_category_name
            q = q.where(func.lower(Listing.category) == canonical_category_name(category).strip().lower())
        if outside_categories:
            # lower() on both sides, like the equality above. NOT IN is
            # never true for NULL, so a listing with no category is added
            # back explicitly: it is "Other" too.
            q = q.where(or_(
                Listing.category.is_(None),
                func.lower(Listing.category).not_in([c.lower() for c in outside_categories]),
            ))
        if subcategory_id:
            # Most specific filter wins outright.
            q = q.where(Listing.subcategory_id == subcategory_id)
        elif category_id:
            # Listing.subcategory_id holds whatever Category row the listing
            # was tagged with, which may be the top-level category itself or
            # one of its children — match either so a zone shows everything
            # filed under it, not just listings tagged at the exact
            # top-level id.
            child_ids = (
                await self.db.execute(select(Category.id).where(Category.parent_id == category_id))
            ).scalars().all()
            q = q.where(Listing.subcategory_id.in_([category_id, *child_ids]))
        if condition:
            q = q.where(Listing.condition == condition)
        if listing_type:
            q = q.where(Listing.listing_type == listing_type)
        if seller_id:
            q = q.where(Listing.seller_id == seller_id)
        if store_id:
            q = q.where(Listing.store_id == store_id)
        if min_price is not None:
            q = q.where(Listing.price >= min_price)
        if max_price is not None:
            q = q.where(Listing.price <= max_price)
        # Every typed word must appear in the title, the category or the
        # description - in any order (api/core/text_search.py). This was one
        # ILIKE of the whole phrase against the title alone, so "samsung
        # a54" never found "Galaxy A54 (Samsung)", a word only in the
        # description found nothing, and "_" or "%" matched every listing.
        terms = search_terms(search)
        if terms:
            q = q.where(matches_all_terms(
                terms, (Listing.name, Listing.category, Listing.description)))
        if location and location.strip():
            # Home's "All locations" filter (§2) - was wired to trigger a
            # refetch but never actually sent anywhere, so picking a
            # location changed nothing. Free-text match against
            # location_name, wildcards escaped like search above.
            q = q.where(term_matches(location.strip().lower(), (Listing.location_name,)))

        if sort == "recent":
            q = q.order_by(desc(Listing.created_at))
        elif sort == "price_low":
            q = q.order_by(Listing.price.asc())
        elif sort == "price_high":
            q = q.order_by(Listing.price.desc())
        else:
            # Volume 2 §3.4: rank_score = 0.35*trust + 0.30*DCR + 0.15*response
            # + 0.20*freshness. domains/trust/completion_rate.py's
            # recompute_all_dcr() pre-computes and stores the first three
            # terms (SellerMetrics.rank_score, deliberately NOT renormalised -
            # see its docstring); freshness is added here as the 4th term,
            # computed live rather than stored, since it's inherently
            # per-LISTING, not per-seller.
            #
            # freshness_score buckets Listing.created_at against plain
            # datetime comparisons (`>=` against Python-computed constants),
            # not a date-diff SQL function. An earlier version used
            # EXTRACT(EPOCH FROM ...) / GREATEST(), which are Postgres-only -
            # this app's dev default is SQLite (.env.example: sqlite+
            # aiosqlite), so that query would work in production and break
            # locally. Plain `>=` comparison against a datetime is identical
            # on both dialects, so this version is portable AND faithful to
            # the actual formula, not an approximation of it (an external
            # audit caught the tiebreaker-only approach as effectively
            # giving freshness almost no real influence, since rank_score is
            # a float and ties are rare - a tiebreaker rarely fires at all).
            #
            # LEFT JOIN, not INNER: a seller with no SellerMetrics row yet
            # must still appear in search - coalesce() to
            # DEFAULT_RANK_SCORE_FOR_NEW_SELLER (computed from the same
            # neutral assumptions recompute_all_dcr uses for a brand-new
            # seller, not a second hardcoded number) for the same cold-start
            # fairness §3.5 asks for.
            from api.domains.trust.completion_rate import W_FRESHNESS, DEFAULT_RANK_SCORE_FOR_NEW_SELLER

            q = q.outerjoin(SellerMetrics, SellerMetrics.user_id == Listing.seller_id)

            _now = datetime.utcnow()
            freshness_score = case(
                (Listing.created_at >= _now - timedelta(days=3),  1.0),
                (Listing.created_at >= _now - timedelta(days=10), 0.7),
                (Listing.created_at >= _now - timedelta(days=30), 0.4),
                else_=0.1,
            )
            combined_rank = (
                func.coalesce(SellerMetrics.rank_score, DEFAULT_RANK_SCORE_FOR_NEW_SELLER)
                + (W_FRESHNESS * freshness_score)
            )
            order = [desc(Listing.is_featured), desc(combined_rank), desc(Listing.created_at)]
            if terms:
                # A search puts listings whose TITLE has every word first -
                # "iphone 13" should lead with iPhone 13s, not with a charger
                # whose description mentions one - and the usual ranking
                # (featured, seller rank, freshness) orders within each half.
                # Only for the default order: a price sort is what the buyer
                # asked for and stays exactly that.
                title_match = case(
                    (matches_all_terms(terms, (Listing.name,)), 1), else_=0)
                order.insert(0, desc(title_match))
            q = q.order_by(*order)

        needs_post_filter = bool(attributes) or (max_km is not None and viewer_lat is not None and viewer_lng is not None)

        if not needs_post_filter:
            r = await self.db.execute(q.limit(limit).offset(offset))
            candidates = r.scalars().all()
            total = None
            if with_total:
                total = await self._count(q)
        else:
            # Bounded candidate window: every cheap/indexed filter above is
            # already applied in SQL, so this is "recent matches", not "the
            # whole table" — CANDIDATE_CAP just keeps one request bounded
            # even so. Large enough that a normal filtered browse won't
            # silently truncate; not a substitute for real pagination if
            # Broka's listing volume grows far past this.
            CANDIDATE_CAP = 500
            r = await self.db.execute(q.limit(CANDIDATE_CAP))
            pool = r.scalars().all()

            if attributes:
                pool = [c for c in pool if self._matches_attributes(c, attributes)]
            if max_km is not None and viewer_lat is not None and viewer_lng is not None:
                # One call for the whole window (Rust when loaded), not one
                # interpreted formula per candidate.
                distances = distances_km(viewer_lat, viewer_lng, [(c.lat, c.lng) for c in pool])
                pool = [c for c, km in zip(pool, distances) if km is not None and km <= max_km]
            total = len(pool) if with_total else None
            candidates = pool[offset: offset + limit]

        results = []
        now = datetime.utcnow()
        # Batch-fetch sellers for the whole page in one query - FIX
        # (redesign-guide audit): product cards need seller_name/verified/
        # rating/completed_deals to show any trust signal at all (Design v2
        # §10/§31, Home Redesign Guide §15 "only real backend data"), which
        # _listing_dict previously never returned no matter who called it.
        # One IN(...) query for the whole page, not one query per listing.
        seller_ids = {listing.seller_id for listing in candidates if listing.seller_id}
        sellers_by_id: dict[str, User] = {}
        if seller_ids:
            seller_rows = (await self.db.execute(select(User).where(User.id.in_(seller_ids)))).scalars().all()
            sellers_by_id = {u.id: u for u in seller_rows}

        # Store feature: same batch pattern as sellers above - one IN(...)
        # query for the whole page's stores, not one query per listing.
        # Most listings have no store_id at all, so this is usually empty.
        store_ids = {listing.store_id for listing in candidates if listing.store_id}
        stores_by_id: dict[str, Store] = {}
        if store_ids:
            store_rows = (await self.db.execute(select(Store).where(Store.id.in_(store_ids)))).scalars().all()
            stores_by_id = {s.id: s for s in store_rows}

        # Images: one query for the page's photos, showcases and avatars.
        assets = await load_listing_media(self.db, candidates, sellers_by_id.values())

        for listing in candidates:
            d = self._listing_dict(
                listing, seller=sellers_by_id.get(listing.seller_id),
                store=stores_by_id.get(listing.store_id),
                assets=assets, card=True,
            )
            if viewer_lat is not None and viewer_lng is not None:
                d["distance_km"] = round(haversine_km(viewer_lat, viewer_lng, listing.lat, listing.lng), 1)
            # Auto-expire featured
            if listing.is_featured and listing.featured_until and listing.featured_until < now:
                listing.is_featured = False
                d["is_featured"] = False
            results.append(d)

        await self.db.commit()
        if with_total:
            return {"items": results, "total": total if total is not None else len(results)}
        return results

    @staticmethod
    def _matches_attributes(listing: Listing, wanted: dict) -> bool:
        stored = load_attributes(listing.attributes)
        if stored is None:
            return False
        for field_name, wanted_value in wanted.items():
            if wanted_value in (None, ""):
                continue
            stored_value = stored.get(field_name)
            if stored_value is None:
                return False
            if isinstance(wanted_value, dict) and ("min" in wanted_value or "max" in wanted_value):
                # number_range-type field: compare numerically, not by
                # string equality. Non-numeric stored values can't satisfy
                # a range, so they're excluded rather than raising.
                try:
                    numeric = float(stored_value)
                except (TypeError, ValueError):
                    return False
                lo = wanted_value.get("min")
                hi = wanted_value.get("max")
                if lo is not None and numeric < float(lo):
                    return False
                if hi is not None and numeric > float(hi):
                    return False
            else:
                if str(stored_value).strip().lower() != str(wanted_value).strip().lower():
                    return False
        return True

    async def _count(self, base_query) -> int:
        count_q = select(func.count()).select_from(base_query.order_by(None).subquery())
        r = await self.db.execute(count_q)
        return r.scalar_one()

    async def express_interest(
        self,
        listing_id: str,
        buyer_id: str,
        offer_price: Optional[float] = None,
    ) -> dict:
        r = await self.db.execute(select(Listing).where(Listing.id == listing_id))
        listing = r.scalar_one_or_none()
        if not listing or not is_live(listing):
            raise HTTPException(status_code=404, detail="Listing not found")
        if listing.seller_id == buyer_id:
            raise HTTPException(status_code=400, detail="Cannot express interest in your own listing")

        interest = Interest(
            listing_id=listing_id,
            buyer_id=buyer_id,
            offer_price=offer_price,
            nudge_deadline=datetime.utcnow() + timedelta(minutes=5),
        )
        self.db.add(interest)
        await self.db.commit()

        await publish(InterestExpressed(
            listing_id=listing_id,
            buyer_id=buyer_id,
            offer_price=offer_price or 0.0,
        ))

        return {"ok": True, "listing_id": listing_id, "offer_price": offer_price}

    async def get_matches(self, listing_id: str) -> list[dict]:
        r = await self.db.execute(
            select(Interest).where(Interest.listing_id == listing_id)
            .order_by(Interest.created_at.desc())
        )
        interests = r.scalars().all()
        buyer_ids = [i.buyer_id for i in interests]
        if not buyer_ids:
            return []
        ur = await self.db.execute(select(User).where(User.id.in_(buyer_ids)))
        users = {u.id: u for u in ur.scalars().all()}
        return [
            {
                "buyer_id": i.buyer_id,
                "buyer_name": users[i.buyer_id].name if i.buyer_id in users else "Unknown",
                "offer_price": i.offer_price,
                "created_at": i.created_at.isoformat() if i.created_at else None,
                "trust_score": (users[i.buyer_id].trust_score or 100) if i.buyer_id in users else 100,
            }
            for i in interests
            if i.buyer_id in users
        ]

    async def get_stats(self) -> dict:
        total_r = await self.db.execute(select(func.count(Listing.id)))
        total = total_r.scalar() or 0
        active_r = await self.db.execute(
            select(func.count(Listing.id)).where(Listing.status == ListingStatus.active)
        )
        active = active_r.scalar() or 0
        return {"total": total, "active": active, "sold": total - active}

    async def get_seller_revenue(self, seller_id: str, period: str = "week") -> dict:
        """Real revenue-over-time for the seller dashboard, aggregated from
        actually-completed deals (status == released, i.e. the buyer
        confirmed delivery and the seller was paid out).

        This replaces what used to be a client-side chart built from
        `math.Random` noise seeded off the listing's own price - numbers
        that LOOKED like a real "highest/lowest/average day" revenue
        breakdown but had no connection to any real sale. Aggregation is
        done in Python rather than with DB-specific date-trunc SQL so this
        works the same on both SQLite (dev) and Postgres (prod).

        period="week"  -> last 7 days, one bucket per day
        period="month" -> last 6 weeks, one bucket per week
        """
        now = datetime.utcnow()
        buckets = 7 if period == "week" else 6
        span = timedelta(days=7) if period == "week" else timedelta(weeks=6)
        window_start = now - span

        result = await self.db.execute(
            select(Deal).where(
                Deal.seller_id == seller_id,
                Deal.status == DealStatus.released,
            )
        )
        deals = result.scalars().all()

        totals = [0.0] * buckets
        for d in deals:
            # released_at is when the seller was actually paid; fall back to
            # created_at for any legacy row that predates that column being
            # populated consistently.
            paid_at = d.released_at or d.created_at
            if paid_at is None or paid_at < window_start:
                continue
            net = float(d.agreed_price or 0) - float(d.commission or 0)
            if period == "week":
                bucket = (now.date() - paid_at.date()).days
                bucket = buckets - 1 - bucket  # oldest day first, like the old chart
            else:
                days_ago = (now - paid_at).days
                bucket = buckets - 1 - (days_ago // 7)
            if 0 <= bucket < buckets:
                totals[bucket] += max(0.0, net)

        return {
            "period": period,
            "values": [round(v, 2) for v in totals],
            "currency": "KES",
            "has_real_data": any(v > 0 for v in totals),
        }

    async def set_listing_store(self, listing_id: str, requester_id: str, store_id: str) -> dict:
        """Associate an EXISTING listing with a store (spec §5 - "update
        listing store association"). Same shape as showcase/router.py's
        POST .../showcase for setting one field on a listing, rather than
        a generic PATCH-listing endpoint - this codebase has no generic
        listing-update endpoint at all, and adding one is out of scope
        here; a narrow, single-purpose endpoint matches the one
        established convention for "change one thing about an existing
        listing" instead of inventing a new one.

        Ownership is checked on BOTH sides (spec §22): the listing's own
        seller_id must be the requester, AND the target store's owner_id
        must also be the requester - so a user can only move their OWN
        listings into a store they OWN, never someone else's of either.
        """
        listing = await self._get_owned_listing_or_403(listing_id, requester_id)
        store = await self.db.get(Store, store_id)
        if not store:
            raise HTTPException(status_code=404, detail="Store not found")
        if store.owner_id != requester_id:
            raise HTTPException(status_code=403, detail="You do not own this store")

        listing.store_id = store.id
        await self.db.commit()
        await self.db.refresh(listing)
        seller = (await self.db.execute(select(User).where(User.id == listing.seller_id))).scalar_one_or_none()
        # _get_owned_listing_or_403 above established ownership.
        assets = await load_listing_media(self.db, [listing], [seller])
        return self._owner_listing_dict(listing, seller=seller, store=store, assets=assets)

    async def remove_listing_store(self, listing_id: str, requester_id: str) -> dict:
        """Inverse of set_listing_store - returns the listing to a
        personal (store_id=NULL) listing. Only the listing's own seller
        may do this, same ownership check as set_listing_store."""
        listing = await self._get_owned_listing_or_403(listing_id, requester_id)
        listing.store_id = None
        await self.db.commit()
        await self.db.refresh(listing)
        seller = (await self.db.execute(select(User).where(User.id == listing.seller_id))).scalar_one_or_none()
        # Ownership established by _get_owned_listing_or_403.
        assets = await load_listing_media(self.db, [listing], [seller])
        return self._owner_listing_dict(listing, seller=seller, store=None, assets=assets)

    async def get_own_listing(self, listing_id: str, requester_id: str) -> dict:
        """The seller's own listing, including the fields buyers never see.

        GET /listings/{id} is unauthenticated and must stay that way, so it
        cannot be the route that hands a seller their reserve back. This is
        the authenticated counterpart: same listing, owner view, 403 for
        anyone else.
        """
        listing = await self._get_owned_listing_or_403(listing_id, requester_id)
        seller = (await self.db.execute(
            select(User).where(User.id == listing.seller_id)
        )).scalar_one_or_none()
        store = await self.db.get(Store, listing.store_id) if listing.store_id else None
        assets = await load_listing_media(self.db, [listing], [seller])
        return self._owner_listing_dict(listing, seller=seller, store=store, assets=assets)

    async def _get_owned_listing_or_403(self, listing_id: str, requester_id: str) -> Listing:
        r = await self.db.execute(select(Listing).where(Listing.id == listing_id))
        listing = r.scalar_one_or_none()
        if not listing:
            raise HTTPException(status_code=404, detail="Listing not found")
        if listing.seller_id != requester_id:
            raise HTTPException(status_code=403, detail="You do not own this listing")
        return listing

    @staticmethod
    def _owner_listing_dict(
        listing: Listing, seller: Optional[User] = None, store: Optional[Store] = None,
        assets: Optional[dict] = None,
    ) -> dict:
        """The seller's own view of their listing. NEVER for a public route.

        Everything the public serializer returns, plus the fields only the
        owner may see. Callers must have already established ownership -
        either the listing was just created by the authenticated seller, or
        it came through _get_owned_listing_or_403.

        This exists as a separate method rather than an `include_private=True`
        flag on _listing_dict for one reason: a flag defaults, and a default
        is what leaked the reserve in the first place. A public caller that
        forgets to think about it gets the safe serializer, because the safe
        serializer is the only one it can reach by name.
        """
        return {
            **ListingService._listing_dict(listing, seller=seller, store=store, assets=assets),
            # The seller's secret walk-away price. Public responses carry
            # has_reserve/reserve_met instead - see the note in
            # _listing_dict and lifecycle.public_state.
            "reserve_price": listing.reserve_price,
            # The seller's own notification choice; nothing a buyer needs.
            "sms_alerts": getattr(listing, "sms_alerts", True) is not False,
            # Whether buyers can see it, and whether it is waiting for its
            # fee - what the app needs to offer "Pay to publish" or "Renew".
            "listing_fee": fee_state(listing),
        }

    @staticmethod
    def _listing_dict(
        listing: Listing, seller: Optional[User] = None, store: Optional[Store] = None,
        assets: Optional[dict] = None, card: bool = False,
    ) -> dict:
        """PUBLIC listing payload. Anything added here is world-readable.

        Images. `assets` is what load_listing_media returned for the page;
        without it the listing is served as if it had no image assets.
          photos  every photo's URLs (thumb/medium/large), first one first
          cover   the image a card shows: the showcase if there is one,
                  else the first photo
          seller_avatar_url  the seller's avatar, small size
        card=True is for list endpoints (Home, categories, search, store
        catalogues). Once a listing's images are assets it drops the base64
        copies - photos, showcase, the seller's selfie - and always drops
        the videos, none of which a card shows. A listing still on legacy
        base64 sends only its first photo, which is all a card reads. The
        single-listing read (card=False) keeps everything for app builds
        that predate assets.

        Used by GET /listings/ and GET /listings/{id}, both unauthenticated.

        reserve_price is deliberately absent. A reserve is the seller's
        secret walk-away price, evaluated once at close (see
        domains/auctions/lifecycle.py); publishing it turns it into a
        minimum bid and defeats the whole mechanism. This serializer used
        to return it, so every auction's reserve was one unauthenticated
        GET away while the auction API went to some trouble to hide it.

        Buyers get `has_reserve` and `reserve_met` from the auction
        endpoints - enough to bid sensibly, not enough to reconstruct the
        number. Sellers get the real value from _owner_listing_dict, on
        authenticated owner-only paths.
        """
        from api.domains.media.service import (
            asset_urls, legacy_image_or_none, parse_id_list, split_legacy_photos,
        )

        assets = assets or {}
        photo_assets = [assets[i] for i in parse_id_list(listing.photo_ids) if i in assets]
        showcase_asset = assets.get(listing.showcase_id) if listing.showcase_id else None
        cover_asset = showcase_asset or (photo_assets[0] if photo_assets else None)
        avatar_asset = (
            assets.get(seller.profile_photo_id)
            if seller is not None and seller.profile_photo_id else None
        )

        verified_photos = listing.verified_photos
        # Rows saved before legacy image fields were checked may hold a link
        # to another site; those never leave the API.
        showcase_image_url = legacy_image_or_none(listing.showcase_image_url)
        seller_profile_photo = legacy_image_or_none(seller.profile_photo) if seller else None
        if verified_photos:
            parts = split_legacy_photos(verified_photos)
            kept = [p for p in parts if legacy_image_or_none(p)]
            if len(kept) != len(parts):
                verified_photos = ",".join(kept) or None
        verified_video = listing.verified_video
        advert_video = listing.advert_video
        if card:
            if photo_assets:
                verified_photos = None
            elif verified_photos:
                legacy = split_legacy_photos(verified_photos)
                verified_photos = legacy[0] if legacy else None
            if showcase_asset is not None:
                showcase_image_url = None
            if avatar_asset is not None:
                seller_profile_photo = None
            verified_video = None
            advert_video = None

        return {
            "id": listing.id,
            "seller_id": listing.seller_id,
            "name": listing.name,
            "description": listing.description,
            "category": listing.category,
            "subcategory_id": listing.subcategory_id,
            "condition": listing.condition,
            # load_attributes, not json.loads: one corrupt or NaN-holding
            # row used to fail every page it appeared on.
            "attributes": load_attributes(listing.attributes),
            "price": listing.price,
            # Selling terms (2026-09-25); see the Listing model. getattr for
            # rows built in memory by code that predates the columns.
            "price_unit": listing.price_unit,
            "quantity": listing.quantity,
            "price_negotiable": getattr(listing, "price_negotiable", True) is not False,
            "delivery_available": listing.delivery_available,
            "delivery_note": listing.delivery_note,
            "lat": listing.lat,
            "lng": listing.lng,
            "location_name": listing.location_name,
            "location_country": listing.location_country,
            "location_county": listing.location_county,
            "location_subcounty": listing.location_subcounty,
            "listing_type": listing.listing_type.value if hasattr(listing.listing_type, "value") else str(listing.listing_type),
            "status": listing.status.value if hasattr(listing.status, "value") else str(listing.status),
            "views": listing.views or 0,
            "target_bidders": listing.target_bidders,
            "auction_date": listing.auction_date.isoformat() if listing.auction_date else None,
            "verified_photos": verified_photos,
            "verified_video": verified_video,
            "advert_video": advert_video,
            "photos": [asset_urls(a) for a in photo_assets],
            # kind: "showcase" | "photo" - lets a card label an AI showcase.
            "cover": (
                {**asset_urls(cover_asset),
                 "kind": "showcase" if cover_asset is showcase_asset else "photo"}
                if cover_asset is not None else None
            ),
            "is_featured": bool(listing.is_featured),
            "featured_until": listing.featured_until.isoformat() if listing.featured_until else None,
            # AI Showcase/Cover Image (2026-08-29). showcase_image_url is
            # data:...;base64 (see the Listing model comment) - never
            # verified_photos, and never shown on View Deal; that screen
            # must keep reading verified_photos directly, same as today.
            "showcase_image_url": showcase_image_url,
            "showcase_image_source": listing.showcase_image_source,
            "created_at": listing.created_at.isoformat() if listing.created_at else None,
            # FIX (redesign-guide audit): these four were never returned by
            # this method under any caller, so product_card.dart's
            # verification badge / seller-name line and BrokaListing had no
            # real data to show despite the UI being built for it (see
            # product_card.dart's own comment on this). seller is optional
            # so existing callers that don't fetch one still get a valid
            # (empty-trust) dict instead of an error.
            "seller_name": (seller.business_name or seller.name) if seller else None,
            "seller_verified": bool(seller.is_verified) if seller else False,
            "seller_rating": (seller.rating or 0) if seller else 0,
            "seller_completed_deals": (seller.completed_deals or 0) if seller else 0,
            # FIX (home-redesign brief, 2026-08-16): needed for the listing
            # card's trader-avatar requirement - User.profile_photo already
            # existed (surfaced on trader cards since Round 4) but was never
            # part of a listing response, so there was no real photo for a
            # product card to show at all. Same optional-seller pattern as
            # the four fields above - no seller fetched, no photo, not an error.
            "seller_profile_photo": seller_profile_photo,
            "seller_avatar_url": asset_urls(avatar_asset)["thumb"] if avatar_asset else None,
            # Store feature. store_id is always present (None for a
            # personal listing); store_name/store_slug are only populated
            # when the caller passed the resolved Store in (matching the
            # optional-seller pattern above) - a listing card can use
            # store_id's presence to decide whether to show a
            # "[View Store]" affordance at all (spec §13), without an
            # extra request.
            "store_id": listing.store_id,
            "store_name": store.name if store else None,
            "store_slug": store.slug if store else None,
        }
