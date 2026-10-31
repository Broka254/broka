"""Stores service.

A Store is a business identity that sits above a seller's listings (see
api/models/store.py for the User -> Store -> Listing picture). This
service:

  - creates, reads and updates stores, checking ownership on every change
    against the authenticated requester id the router passes in - never
    against anything in a request body;
  - owns the store's link name (api/domains/stores/naming.py): chosen once
    at setup, unique, and never changed by a rename;
  - serves a store's catalogue by delegating to ListingService, so a store
    product is serialized exactly like the same listing anywhere else in
    the app - a store's catalogue IS `Listing.store_id == this store`,
    never a second product table.

Only long-term sellers - sellers who gave BROKA a business name, category
and location - can open a store. A short-term seller upgrades first
(POST /auth/upgrade-to-seller with those details).

Trust shown with a store now has two layers, and they are different
records on purpose:

  * the STORE's own rating (api/domains/stores/rating.py) - its reviews,
    its reply time on threads about its own products, and its tenure;
    this is what the directory orders by;
  * the OWNER's seller record (verified badge, seller rating, deals done,
    member since), still published on the storefront for buyers who want
    to know who is behind the shop.

Before 2026-10-19 there was only the second: one number for a person, used
for every shop they might run. A store is a business identity with its own
customers, so it now carries its own number.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import datetime
import logging
import uuid
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import and_, asc, case, delete, desc, func, not_, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.core.geo import format_distance_km, haversine_km, round_distance_km
from api.core.presence import online_status
from api.core.text_search import matches_all_terms, search_terms
from api.database import AccountType, Listing, ListingStatus, SellerTier, User
from api.domains.listings.paid import is_live, live_clause
from api.domains.categories.seed import CANONICAL_CATEGORIES, canonical_category_name
from api.models.store import DEFAULT_STORE_TYPE, STORE_TYPES, Store, StoreCategoryLink
from api.domains.listings.service import ListingService, load_listing_media
from api.security import decode_email_verify_token
from . import billing as store_billing
from . import categories as store_categories
from .area_points import area_point
from api.domains.listings.location import canonical_county
from . import naming, opening_hours
from .media import (
    normalize_photo_list, parse_photo_list, normalize_single_media, MediaTooLargeError,
)

logger = logging.getLogger(__name__)

# Text fields a caller may set at creation and patch identically. One list
# so create and update can't drift apart on which fields exist.
_TEXT_FIELDS = ("description", "county", "subcounty", "location_description")
_MAX_NAME_LEN = 60
_MAX_DESCRIPTION_LEN = 1000
_MAX_PLACE_LEN = 80
_MAX_LANDMARK_LEN = 160
_TEXT_LIMITS = {
    "description": _MAX_DESCRIPTION_LEN,
    "county": _MAX_PLACE_LEN,
    "subcounty": _MAX_PLACE_LEN,
    "location_description": _MAX_LANDMARK_LEN,
}
# Retries for the rare race where two stores created at the same moment
# are given the same derived link name (only stores from app builds that
# don't choose one). Each attempt is one SELECT and one INSERT; the unique
# index on stores.slug is what actually decides.
_MAX_SLUG_RETRIES = 8
# How many numbered variants (-2, -3, ...) of a name are considered, in
# one query, before falling back to a random suffix. See _first_free.
_MAX_SLUG_SUFFIX = 25

# Catalogue sort names the store endpoints accept -> ListingService sorts.
CATALOGUE_SORTS = {
    "featured": None,          # BROKA's ranking: featured, trust, freshness
    "newest": "recent",
    "price_low": "price_low",
    "price_high": "price_high",
}

LONG_TERM_REQUIRED = (
    "Online stores are for long-term sellers. Add your business details "
    "to upgrade, then open your store."
)


def store_link(slug: str) -> str:
    return f"{settings.store_link_base}/{slug}"


def _store_time_left(sub) -> dict:
    """paid_until + countdown keys for _store_dict (listings/time_left.py)."""
    from api.domains.listings.time_left import time_left

    paid_until = sub.paid_until if sub is not None else None
    countdown = time_left(paid_until)
    return {
        "paid_until": paid_until.isoformat() if paid_until else None,
        "time_left": countdown,
        "seconds_left": countdown["seconds_left"],
        "days_left": countdown["days_left"],
        "time_left_label": countdown["label"],
        "goes_offline_at": countdown["goes_offline_at"],
    }


class StoreService:
    def __init__(self, db: AsyncSession):
        self.db = db

    # ── Create ────────────────────────────────────────────────────────────

    async def create_store(self, owner_id: str, data: dict) -> dict:
        name = self._clean_name(data.get("name"))
        # A client that predates store types gets "physical": every store
        # that existed before the field was a shop you could walk into.
        store_type = self._store_type(data, current=DEFAULT_STORE_TYPE) or DEFAULT_STORE_TYPE
        hours_json = self._opening_hours_column(data)
        service_areas_json, delivery_note = self._coverage_columns(data)

        owner = await self._lock_owner_for_create(owner_id)

        chosen_slug = None
        if data.get("slug"):
            chosen_slug = naming.normalize(data["slug"])
            problem = naming.check_link_name(chosen_slug)
            if problem:
                raise HTTPException(status_code=400, detail=problem)
            if await self._slug_taken(chosen_slug):
                raise HTTPException(
                    status_code=409, detail="That store link is already taken. Choose another.",
                )

        categories = self._categories_from(data)
        if categories is None:
            # A client that sends none keeps the one mapped from the
            # owner's signup business category.
            mapped = store_categories.from_legacy(owner.business_category)
            categories = [mapped] if mapped else []
        # The store's primary category is the first chosen; the links
        # written below are what the directory's category filter reads.
        category = categories[0] if categories else None

        logo_url = self._safe_normalize_single_media(data.get("logo_url"))
        photos = self._safe_normalize_photo_list(data.get("photos"))
        email = self._business_email(owner, data, current=(None, False))
        text_values = {field: self._clean_text(field, data.get(field)) for field in _TEXT_FIELDS}
        coords = self._clean_coords(data)

        attempts = 1 if chosen_slug else _MAX_SLUG_RETRIES
        for attempt in range(attempts):
            if attempt:
                # The rollback released the lock and expired `owner`.
                owner = await self._lock_owner_for_create(owner_id)
            # Inside the loop: checking the images also marks them in use
            # (media.service.require_owned_assets), in this transaction - so
            # a retry after a rollback must mark them again, or the store
            # would reference uploads the clean-up later deletes.
            await self._check_legacy_media(owner_id, data)
            image_columns = await self._image_columns(owner_id, data)
            # An asset replaces the legacy base64 copy of the same image.
            if image_columns.get("logo_id"):
                logo_url = None
            if image_columns.get("photo_ids"):
                photos = None
            # A store opens with at least one real photo of the shop. A
            # logo or a cover isn't one: buyers trust a shop they can see.
            # Only clients new enough to choose a link name are held to
            # it - app builds that predate phase 2 (no slug, no image
            # assets) must still be able to open a store.
            # A physical shop opens with at least one real photo of it: a
            # logo or cover isn't one. A virtual store has no premises to
            # photograph, so the rule does not apply to it - requiring one
            # would force a seller to invent a shop that doesn't exist.
            if (store_type == "physical" and data.get("slug")
                    and not image_columns.get("photo_ids") and not photos):
                raise HTTPException(
                    status_code=400,
                    detail="Add at least one photo of your shop before opening your store. "
                           "A store with no premises can open as a virtual store.",
                )
            # A current client that explicitly chooses a physical store
            # must name a place a buyer could go. An app build that predates
            # store types sends no store_type: it opens as it always did.
            # The wizard's location step is not enough on its own - the
            # server is what the storefront later publishes.
            if store_type == "physical" and "store_type" in data:
                has_place = bool(
                    (text_values.get("county") or "").strip()
                    or (text_values.get("subcounty") or "").strip()
                    or (text_values.get("location_description") or "").strip()
                    or coords is not None
                )
                if not has_place:
                    raise HTTPException(
                        status_code=400,
                        detail="Add your county and area before opening a physical store - "
                               "buyers need somewhere to go. A store with no premises can "
                               "open as a virtual store.",
                    )
            slug = chosen_slug or await self._unique_slug(name)
            store = Store(
                owner_id=owner_id, name=name, slug=slug, category=category,
                logo_url=logo_url, photos=photos, store_type=store_type,
                opening_hours=hours_json, service_areas=service_areas_json,
                delivery_note=delivery_note,
            )
            if coords is not None:
                store.lat, store.lng = coords
            if email is not None:
                store.official_email, store.business_email_verified = email
            for field, value in text_values.items():
                setattr(store, field, value)
            for column, value in image_columns.items():
                setattr(store, column, value)

            self.db.add(store)
            try:
                # Flush before the billing row so a slug collision (the only
                # unique index on stores) fails on the store alone; and so
                # the store has its id. Billing on: the store opens with
                # its own unpaid subscription row in the same commit, so
                # nothing later has to guess whether it predates billing.
                await self.db.flush()
                for name in categories:
                    self.db.add(StoreCategoryLink(store_id=store.id, category=name))
                # Launch offer: the first FREE_STORE_OFFER_LIMIT stores
                # set up free, one per user (pricing/launch_offers.py) -
                # claimed in this transaction, so a rolled-back create
                # (the slug retry below) consumes no slot. A claimed
                # store opens live on a free period. Claiming is not gated
                # on billing: while billing is off the claim stamps the
                # 60-day live window (countdown + 2-day SMS) instead of a
                # fee waiver; an unclaimed store opens with no row, as
                # before. With billing on, an unclaimed store opens with
                # its own unpaid subscription row instead.
                from api.domains.pricing import launch_offers

                claim = await launch_offers.claim_store_offer(
                    self.db, owner_id, store.id)
                if claim is not None:
                    store_billing.grant_free_store_period(self.db, store, claim)
                elif store_billing.enabled():
                    store_billing.create_unpaid_subscription(self.db, store.id)
                await self.db.commit()
            except IntegrityError:
                # The only unique constraint on this table is slug: someone
                # else took it between our check and this insert.
                await self.db.rollback()
                continue
            await self.db.refresh(store)
            # Give the new shop its stored rating straight away, so the
            # directory can order it from its first second instead of
            # sorting a NULL last until the nightly pass. A brand-new store
            # lands on the neutral 6.5 (rating.py); failure here must not
            # undo a successfully created store, so it is best-effort.
            try:
                from .rating import refresh_store_rating
                await refresh_store_rating(self.db, store.id)
                await self.db.refresh(store)
            except Exception as exc:  # noqa: BLE001 - never lose the shop
                logger.warning("[stores] initial rating failed for %s: %s", store.id, exc)
            return await self._store_dict(store, owner=owner, owner_view=True)

        if chosen_slug:
            raise HTTPException(
                status_code=409, detail="That store link was just taken. Choose another.",
            )
        raise HTTPException(
            status_code=409,
            detail="Could not allocate a unique store link right now - please try again.",
        )

    async def _lock_owner_for_create(self, owner_id: str) -> User:
        """The owner, row-locked, after checking they may open a store.

        The lock serializes two concurrent creates from the same account,
        so the one-store check can't be raced (there is deliberately no
        unique index on owner_id: the schema stays able to hold several
        stores per owner if that's ever wanted). On SQLite FOR UPDATE is
        dropped silently; production is Postgres."""
        owner = (await self.db.execute(
            select(User).where(User.id == owner_id).with_for_update()
            .execution_options(populate_existing=True)
        )).scalar_one_or_none()
        if owner is None:
            raise HTTPException(status_code=404, detail="User not found")
        if not self._is_long_term_seller(owner):
            raise HTTPException(status_code=403, detail=LONG_TERM_REQUIRED)
        existing = (await self.db.execute(
            select(Store.id).where(
                Store.owner_id == owner_id, Store.deleted_at.is_(None),
            ).limit(1)
        )).scalar_one_or_none()
        if existing:
            raise HTTPException(
                status_code=409,
                detail="You already have a store. BROKA currently supports one store per account.",
            )
        return owner

    # ── Link names ────────────────────────────────────────────────────────

    async def check_name(self, raw: Optional[str]) -> dict:
        """The setup wizard's live check. `suggestion` is a free name close
        to what was asked for, whenever the asked-for one can't be used."""
        name = naming.normalize(raw)
        problem = naming.check_link_name(name)
        if problem is None and await self._slug_taken(name):
            problem = "That link is already taken."
        if problem is None:
            return {"name": name, "available": True, "reason": None, "suggestion": None,
                    "url": store_link(name)}
        base = name if naming.check_link_name(name) is None else naming.suggest_base(name)
        suggestion = await self._first_free(base)
        return {"name": name, "available": False, "reason": problem, "suggestion": suggestion,
                "url": None}

    async def _slug_taken(self, slug: str) -> bool:
        return (await self.db.execute(
            select(Store.id).where(Store.slug == slug).limit(1)
        )).scalar_one_or_none() is not None

    async def _first_free(self, base: str) -> str:
        """`base` itself or its first free numbered variant, found with one
        query. Falls back to a random suffix when all of them are taken."""
        candidates = [base] + [naming.numbered(base, n) for n in range(2, _MAX_SLUG_SUFFIX + 2)]
        taken = set((await self.db.execute(
            select(Store.slug).where(Store.slug.in_(candidates))
        )).scalars().all())
        for candidate in candidates:
            if candidate not in taken and candidate not in naming.RESERVED:
                return candidate
        return f"{base[: naming.MAX_LENGTH - 7].rstrip('-')}-{uuid.uuid4().hex[:6]}"

    async def _unique_slug(self, name: str) -> str:
        """A free link name derived from a store name, for stores created
        without one. Duplicate names get -2, -3, ... so one store never
        takes over another's link."""
        return await self._first_free(naming.suggest_base(name))

    # ── Read ──────────────────────────────────────────────────────────────

    async def list_stores(
        self,
        search: Optional[str] = None,
        category: Optional[str] = None,
        county: Optional[str] = None,
        subcounty: Optional[str] = None,
        limit: int = 20,
        offset: int = 0,
        with_total: bool = False,
        viewer_lat: Optional[float] = None,
        viewer_lng: Optional[float] = None,
        max_distance_km: Optional[float] = None,
        nearest_first: bool = False,
        store_type: Optional[str] = None,
    ):
        """Browse active stores. A paused store is left out of the
        directory, though its own link still resolves; with store billing
        on, a store whose plan is unpaid is left out the same way.

        With viewer_lat/lng every item also carries distance_km (one
        decimal - see _store_distance for which point it measures to)
        and distance_label ('6 km from you', '≈ …' when approximate).
        With max_distance_km only stores within that range are returned;
        with nearest_first they come nearest first for the 'Stores near
        you' rail. A store with no pin, no declared county and no visible
        owner point has no distance and is left out of a max-distance
        filter. Distance is physical proximity only: coverage never
        invents one, and a virtual store never has a distance at all.

        county/subcounty filter by the area a buyer wants to buy in, not
        by the shop's address alone (see _area_clause): a physical shop is
        found where it is or where it delivers, a virtual shop is found
        through its declared service areas, and a Nationwide shop is found
        everywhere it promises. A virtual store's kept-over address is
        never treated as premises; its coverage is the only geography it
        publishes.

        A deleted store (Store.deleted_at) never appears: deleting is a
        soft delete, so the row survives for its listings and payments
        while the shop itself is gone.

        A store with no photo of the shop should not exist at all: the
        setup wizard refuses one, update_store refuses to let the last
        photo go, and shops opened before that rule were removed by
        backend/cleanup_photoless_stores.py."""
        q = select(Store).where(
            Store.is_active == True,  # noqa: E712
            Store.deleted_at.is_(None),
        )
        if store_billing.enabled():
            q = q.where(store_billing.live_subscription_clause(Store.id))
        if store_type:
            # A filter, never a way to hide virtual stores: leaving it out
            # returns both kinds, and `store_type` never enters distance
            # filtering (a virtual store has no pin but still serves buyers).
            normalised = self._store_type({"store_type": store_type})
            q = q.where(Store.store_type == normalised)
        search_terms_ = search_terms(search)
        if search_terms_:
            # Every typed word has to appear somewhere a buyer would look
            # for it: the shop's own name, the trade it is listed under,
            # where it is, or one of its live products. Searching only
            # Store.name meant "router" - a word in a product's title -
            # returned nothing at all, which read as a dead search box.
            # Matching stays LIKE-based and portable (api/core/text_search.py).
            q = q.where(or_(
                matches_all_terms(search_terms_, (
                    Store.name, Store.category, Store.county, Store.subcounty,
                )),
                Store.id.in_(self._stores_selling_matching(search_terms_)),
            ))
        if category:
            if store_categories.is_wholesale_facet(category):
                # "Wholesale and General": stores selling across more than
                # one category, wherever they are otherwise listed.
                q = q.where(Store.id.in_(self._wholesale_stores()))
            else:
                # Old stores' categories are filled in at startup
                # (categories.backfill_store_categories).
                wanted = store_categories.canonical(category) or store_categories.from_legacy(category)
                # A store's `category` is only where it is listed - the setup
                # screen has always said products from any category can go in
                # it. Matching the column alone hid every wholesaler from
                # every category they stock but aren't listed under, so a
                # store also matches through its chosen categories
                # (StoreCategoryLink) and through a live listing in the
                # category.
                q = q.where(or_(
                    Store.category == wanted,
                    Store.id.in_(
                        select(StoreCategoryLink.store_id)
                        .where(StoreCategoryLink.category == wanted)
                    ),
                    Store.id.in_(self._stores_stocking(wanted)),
                ))
        if county or subcounty:
            area_clause = self._area_clause(county, subcounty)
            if area_clause is not None:
                q = q.where(area_clause)

        total = None
        if with_total:
            count_q = select(func.count()).select_from(q.order_by(None).subquery())
            total = (await self.db.execute(count_q)).scalar_one()

        # Nearest-first needs the whole filtered set to sort before the
        # page is cut: fetch a bounded window, sort by distance, then cut.
        # Newest keeps the SQL order and pages normally.
        want_near = nearest_first and viewer_lat is not None and viewer_lng is not None
        fetch_limit, fetch_offset = (500, 0) if want_near else (limit, offset)

        q = q.order_by(
            # Highest-rated shops first - the position the store rating
            # exists to earn. created_at and then id break ties: without a
            # deterministic order, stores created in the same second can
            # swap places between two OFFSET pages, so a shop appears twice
            # (or not at all) while paging. id is unique, so the last key
            # always decides.
            Store.rating.desc().nulls_last(),
            Store.created_at.desc(),
            Store.id.asc(),
        ).limit(fetch_limit).offset(fetch_offset)
        stores = (await self.db.execute(q)).scalars().all()

        # One row per shop, even if a future join ever fans one out: the
        # directory is a list of shops, and a duplicate here reads as a
        # second branch of the same business.
        seen_ids: set[str] = set()
        stores = [s for s in stores if not (s.id in seen_ids or seen_ids.add(s.id))]

        # One grouped count, one owners query, one assets query, one
        # subscriptions query and one category-links query for the whole
        # page - never one per store.
        counts = await self._listing_counts_for([s.id for s in stores])
        assets = await self._assets_for(stores)
        owners = await self._owners_for(stores)
        links = await self._categories_for([s.id for s in stores])
        # The owners' real buyer-review figures, one query for the page -
        # User.rating is a legacy cache whose 5.0 starting value would show
        # every new seller as perfect.
        from api.domains.reviews.stats import seller_review_figures
        owner_reviews = await seller_review_figures(self.db, owners.keys())
        subs = (await store_billing.subscriptions_for(self.db, [s.id for s in stores])
                if store_billing.enabled() else {})
        items = [
            await self._store_dict(
                s, listing_count=counts.get(s.id, 0), assets=assets, owner=owners.get(s.owner_id),
                billing_subs=subs, category_names=links.get(s.id, []),
                viewer_lat=viewer_lat, viewer_lng=viewer_lng,
                owner_reviews=owner_reviews,
            )
            for s in stores
        ]
        # Belt and braces on the payload side too: the client draws whatever
        # it is given, so one shop in two rows is one shop drawn twice.
        unique_items: list[dict] = []
        seen_payload: set[str] = set()
        for item in items:
            if item.get("id") in seen_payload:
                continue
            seen_payload.add(item.get("id"))
            unique_items.append(item)
        items = unique_items
        if viewer_lat is not None and viewer_lng is not None and max_distance_km is not None:
            items = [d for d in items
                     if d.get("distance_km") is not None and d["distance_km"] <= max_distance_km]
        if want_near:
            items.sort(key=lambda d: (d.get("distance_km") is None, d.get("distance_km") or 0))
            total = len(items) if with_total else None
            items = items[offset: offset + limit]
            return {"items": items, "total": total} if with_total else items
        return {"items": items, "total": total} if with_total else items

    @classmethod
    def _area_clause(cls, county: Optional[str], subcounty: Optional[str]):
        """The directory's county/subcounty filter, in terms of the buyer's
        question: which shops can serve me here?

        Three true answers, because a shop's address and its coverage are
        different facts (models/store.py):

          * a physical store whose premises are in the selected area;
          * any store - physical or virtual - that declares the area in
            its service areas;
          * a store declaring Nationwide, which covers every county.

        A virtual store's stored county/subcounty never counts: it has no
        shopfront there, so treating a leftover address as a place a buyer
        can find it would invent premises. With only a subcounty selected,
        coverage is matched on Nationwide alone - service areas are
        counties, and nothing maps every constituency to its county here.

        This is deliberately separate from distance: serving an area does
        not make a far shop near, and max_distance_km is applied later to
        physical points only.
        """
        located: list = []
        if county and county.strip():
            located.append(cls._place_clause(Store.county, county, canonical_county(county)))
        if subcounty and subcounty.strip():
            located.append(cls._place_clause(Store.subcounty, subcounty, None))

        covered: list = []
        known_county = canonical_county(county) if county else None
        if known_county:
            covered.append(cls._service_area_clause(known_county))
        elif subcounty and subcounty.strip():
            covered.append(Store.service_areas.like('%"Nationwide"%'))

        clauses: list = []
        if located:
            # Only premises can be "located in" an area. A virtual store
            # cannot satisfy this arm even if it kept an old address.
            clauses.append(and_(Store.store_type != "virtual", *located))
        clauses.extend(covered)
        return or_(*clauses) if clauses else None

    @staticmethod
    def _place_key_sql(column):
        """A county/area name as SQL, compared the way buyers spell it:
        case, surrounding space, hyphens and apostrophes don't matter
        ("Tharaka-Nithi", "tharaka nithi", "Muranga", "Murang'a")."""
        text = func.replace(func.lower(func.trim(column)), "-", " ")
        return func.replace(text, "'", "")

    @classmethod
    def _place_keys(cls, value: str, canonical: Optional[str]) -> list[str]:
        """The stored spellings that mean `value`, including the official
        one and the common "… County" suffix older clients typed."""
        keys: set[str] = set()
        for candidate in (value, canonical):
            if not candidate:
                continue
            text = " ".join(candidate.split()).casefold()
            text = text.replace("-", " ").replace("'", "")
            text = " ".join(text.split())
            if not text:
                continue
            keys.update({text, f"{text} county", f"{text} city county"})
        return sorted(keys)

    @classmethod
    def _place_clause(cls, column, value: str, canonical: Optional[str]):
        return cls._place_key_sql(column).in_(cls._place_keys(value, canonical))

    @staticmethod
    def _service_area_clause(county: str):
        """Stored service areas that cover `county`: the county itself, or
        Nationwide. Values are JSON text written by _coverage_columns, so
        a quoted token matches a whole entry and never part of one."""
        return or_(
            Store.service_areas.like(f'%"{county}"%'),
            Store.service_areas.like('%"Nationwide"%'),
        )

    @staticmethod
    def _clean_coords(data: dict) -> Optional[tuple]:
        """The shop pin a request sets: (lat, lng), (None, None) to clear
        it, or None when the request doesn't mention it. A half-pin or an
        off-globe point is refused, never guessed at."""
        if "lat" not in data and "lng" not in data:
            return None
        lat, lng = data.get("lat"), data.get("lng")
        if lat is None and lng is None:
            return (None, None)
        try:
            lat, lng = float(lat), float(lng)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="That shop location looks wrong. Try again.")
        if not (-90 <= lat <= 90 and -180 <= lng <= 180):
            raise HTTPException(status_code=400, detail="That shop location looks wrong. Try again.")
        return (lat, lng)

    @staticmethod
    def _approx_point(lat, lng):
        """A mappable point at the same ±1 km rounding distances use, so
        the map can never show a shop (or home) more precisely than the
        distance beside it already does."""
        if lat is None or lng is None:
            return (None, None)
        try:
            return (round(float(lat), 2), round(float(lng), 2))
        except (TypeError, ValueError):
            return (None, None)

    @staticmethod
    def _valid_point(lat, lng) -> Optional[tuple[float, float]]:
        """(lat, lng) as floats when they are a real place on the globe,
        else None. (0, 0) is the Gulf of Guinea, not a shop: coordinates
        that were never set arrive as 0 often enough that the pair reads
        as missing, never as next door."""
        if lat is None or lng is None:
            return None
        try:
            point = (float(lat), float(lng))
        except (TypeError, ValueError):
            return None
        if point == (0.0, 0.0):
            return None
        if not (-90 <= point[0] <= 90 and -180 <= point[1] <= 180):
            return None
        return point

    @classmethod
    def _store_point(cls, store, owner) -> tuple[Optional[tuple[float, float]], bool]:
        """Where a store is, best first, and whether that is approximate.

        1. The shop's own pin - where the owner stood at the shop. Exact.
        2. The shop's declared county/subcounty, at that area's point
           (area_points). Approximate - flagged, never exact - and the
           repair for shops opened before pins existed: their owners
           registered wherever they happened to be, but the shop's
           county was typed for the shop.
        3. The owner's account point, while their location is visible -
           for shops that declared no county at all.

        The distance itself is computed from the raw point: rounding the
        point to two decimals first (~1 km) pushed shops at 24.9 km past
        a 25 km filter. Rounding survives only in the mappable point the
        payload hands out, so no read can triangulate an exact spot."""
        if store is not None:
            # A virtual store has no premises. A county it kept from before
            # the switch (or a pin its owner entered for deliveries) is not
            # a place a buyer can go, so it never becomes a distance, a map
            # point or a "nearest" ranking.
            if (getattr(store, "store_type", None) or DEFAULT_STORE_TYPE) == "virtual":
                return None, False
            pin = cls._valid_point(getattr(store, "lat", None), getattr(store, "lng", None))
            if pin is not None:
                return pin, False
            area = area_point(getattr(store, "county", None), getattr(store, "subcounty", None))
            if area is not None:
                return area, True
        if owner is not None and getattr(owner, "location_visible", True):
            point = cls._valid_point(getattr(owner, "lat", None), getattr(owner, "lng", None))
            if point is not None:
                return point, False
        return None, False

    @classmethod
    def _store_distance(cls, store, owner, viewer_lat: Optional[float], viewer_lng: Optional[float]):
        """(distance_km, approximate) from the viewer to _store_point's
        point. Distance is None when either side has no real point - a
        missing distance is unknown, never 0 km, so a max-distance
        filter leaves the store out rather than guessing."""
        if viewer_lat is None or viewer_lng is None:
            return None, False
        viewer = cls._valid_point(viewer_lat, viewer_lng)
        point, approximate = cls._store_point(store, owner)
        if viewer is None or point is None:
            return None, approximate
        return round_distance_km(haversine_km(viewer[0], viewer[1], point[0], point[1])), approximate

    @staticmethod
    def _has_shop_photo(store: Store) -> bool:
        """Whether a store still has a real photo of the shop (not only a
        logo or cover): the same rule create_store applies to a new one."""
        from api.domains.media.service import parse_id_list
        if parse_id_list(store.photo_ids):
            return True
        return bool(parse_photo_list(store.photos))

    @staticmethod
    def _stores_selling_matching(terms: list[str]):
        """Store ids with a live product matching every typed word.

        The directory's search reaches a shop through its goods as well
        as its name: someone typing "router" means the thing, and the
        word only appears in a listing title. Same words, same escaping,
        same live-listing rule as the category filter (_stores_stocking).
        """
        return (
            select(Listing.store_id)
            .where(
                Listing.store_id.is_not(None),
                Listing.status == ListingStatus.active,
                live_clause(),
                matches_all_terms(terms, (
                    Listing.name, Listing.category, Listing.description,
                )),
            )
        )

    @staticmethod
    def _stores_stocking(category: str):
        """The subquery of store ids with a live listing filed under
        `category` - the wholesaler's second way into the directory.

        Matching mirrors ListingService.list_listings: the lower-cased
        canonical name (so an old name of a renamed category still finds
        its listings), and "Other" is every listing outside BROKA's named
        ones, NULL included - the same rule the storefront's category
        rail counts by. Only live listings count: a hidden or sold one is
        not something a buyer browsing the category can find.
        """
        if category == store_categories.OTHER:
            outside = store_categories.named_listing_categories()
            conditions = (
                Listing.category.is_(None),
                func.lower(Listing.category).not_in([c.lower() for c in outside]),
            )
        else:
            conditions = (
                func.lower(Listing.category) ==
                canonical_category_name(category).strip().lower(),
            )
        return (
            select(Listing.store_id)
            .where(Listing.store_id.is_not(None),
                   Listing.status == ListingStatus.active, live_clause(),
                   or_(*conditions))
        )

    @staticmethod
    def _wholesale_stores():
        """Store ids holding two or more category links - what the
        "Wholesale and General" rail entry lists."""
        return (
            select(StoreCategoryLink.store_id)
            .group_by(StoreCategoryLink.store_id)
            .having(func.count(StoreCategoryLink.id) >= 2)
        )

    async def _categories_for(self, store_ids: list[str]) -> dict[str, list[str]]:
        """Store id -> its category links, in one query for the whole page
        (single reads pass one id). Primary first, the rest alphabetical."""
        if not store_ids:
            return {}
        rows = (await self.db.execute(
            select(StoreCategoryLink.store_id, StoreCategoryLink.category)
            .where(StoreCategoryLink.store_id.in_(store_ids))
        )).all()
        links: dict[str, list[str]] = defaultdict(list)
        for store_id, name in rows:
            links[store_id].append(name)
        return {store_id: sorted(names) for store_id, names in links.items()}

    async def _listing_counts_for(self, store_ids: list[str]) -> dict[str, int]:
        """Active-listing counts for many stores in one grouped query. A
        store with no active listings has no row, so read with .get(id, 0)."""
        if not store_ids:
            return {}
        rows = (await self.db.execute(
            select(Listing.store_id, func.count())
            .where(Listing.store_id.in_(store_ids),
                   Listing.status == ListingStatus.active, live_clause())
            .group_by(Listing.store_id)
        )).all()
        return {row[0]: row[1] for row in rows}

    async def get_store(self, store_id: str, viewer_id: Optional[str] = None) -> dict:
        store = await self._get_or_404(store_id)
        return await self._public_or_owner(store, viewer_id)

    async def get_store_by_slug(self, slug: str, viewer_id: Optional[str] = None) -> dict:
        store = await self.find_by_slug(slug)
        if not store or store.deleted_at is not None:
            raise HTTPException(status_code=404, detail="Store not found")
        return await self._public_or_owner(store, viewer_id)

    async def _public_or_owner(self, store: Store, viewer_id: Optional[str]) -> dict:
        """A store's payload for a public read - which, while billing is
        on and the plan is unpaid or has lapsed, is no store at all: the
        link, the catalogue and the storefront go dark until it pays.
        The owner still sees their own store, with the billing object, so
        the app can send them to the plan screen instead of a 404."""
        if store.deleted_at is not None:
            raise HTTPException(status_code=404, detail="Store not found")
        if viewer_id and store.owner_id == viewer_id:
            return await self._store_dict(store, owner_view=True)
        if store_billing.enabled() and not await store_billing.store_live(self.db, store):
            raise HTTPException(status_code=404, detail="Store not found")
        return await self._store_dict(store)

    async def find_by_slug(self, slug: str) -> Optional[Store]:
        # Links are case-insensitive: someone typing BROKA.co.ke/store/Clanix
        # from a flyer still arrives. A deleted store is not found - its
        # slug stays reserved, but the link is dead for good.
        return (await self.db.execute(
            select(Store).where(
                Store.slug == naming.normalize(slug), Store.deleted_at.is_(None),
            )
        )).scalar_one_or_none()

    async def get_my_store(self, owner_id: str) -> Optional[dict]:
        """The owner's store, or None when they haven't opened one - a
        normal state for most users, not an error. The schema allows more
        than one per owner, so this takes the newest; a deleted one never
        counts, so an owner who deleted their store can open another."""
        store = await self._my_store(owner_id)
        return await self._store_dict(store, owner_view=True) if store else None

    async def _my_store(self, owner_id: str) -> Optional[Store]:
        return (await self.db.execute(
            select(Store).where(Store.owner_id == owner_id, Store.deleted_at.is_(None))
            .order_by(Store.created_at.desc()).limit(1)
        )).scalar_one_or_none()

    async def list_store_listings(
        self,
        store_id: str,
        limit: int = 20,
        offset: int = 0,
        with_total: bool = False,
        search: Optional[str] = None,
        category: Optional[str] = None,
        sort: Optional[str] = None,
        condition: Optional[str] = None,
        min_price: Optional[float] = None,
        max_price: Optional[float] = None,
    ):
        store = await self._get_or_404(store_id)
        if not await store_billing.store_live(self.db, store):
            # A paused store - or, with billing on, one whose plan is unpaid
            # - keeps its profile but shows an empty catalogue: a shared
            # link should say "nothing listed right now", not 404.
            return {"items": [], "total": 0} if with_total else []

        listing_category = None
        outside_categories = None
        if category:
            listing_category = store_categories.canonical(category)
            if listing_category is None:
                raise HTTPException(status_code=400, detail="Unknown category")
            if listing_category == store_categories.OTHER:
                # The rail (list_categories) counts every listing whose
                # category isn't one of BROKA's named ones as "Other" - free
                # text from older app builds and API clients. Filtering on
                # the word itself found only listings literally filed as
                # "Other", so tapping "Other · 3" showed "No products".
                listing_category = None
                outside_categories = store_categories.named_listing_categories()
        return await ListingService(self.db).list_listings(
            store_id=store_id, category=listing_category,
            outside_categories=outside_categories, search=(search or "").strip() or None,
            sort=CATALOGUE_SORTS.get(sort or "featured"),
            condition=condition, min_price=min_price, max_price=max_price,
            limit=limit, offset=offset, with_total=with_total,
        )

    async def list_owner_listings(
        self,
        store_id: str,
        requester_id: str,
        state: str = "all",
        search: Optional[str] = None,
        category: Optional[str] = None,
        sort: str = "newest",
        limit: int = 20,
        offset: int = 0,
    ) -> dict:
        """Every product in the store, as its owner manages them.

        The public catalogue shows only what buyers can see: active and paid
        up. My Store listed products through it, so a product vanished from
        its owner's screen the moment it went into a deal, sold, or waited
        for its listing fee - the products that most need the owner. This
        lists them all, newest first, each with the state My Store shows:

          live      buyers can see it
          hidden    active, but its listing fee is unpaid or ran out
          in_deal   a buyer agreed a deal (status pending)
          sold      the deal completed
          archived  the seller took it off sale (status cancelled)

        Archived listings are a state, not a deletion: the row survives so
        deals, reviews and history keep pointing at it, and the owner can
        still find it under the Archived filter. `counts` has how many are
        in each state (and "all"), for the search when there is one, so the
        filter chips say what tapping them will show.
        """
        store = await self.get_owned(store_id, requester_id)
        now = datetime.utcnow()
        live = live_clause(now)
        # With billing on, every active listing of an unpaid store reads
        # "hidden" here too - the SQL counts below say the same thing.
        store_live = await store_billing.store_live(self.db, store, now)
        archived = and_(
            Listing.status == ListingStatus.cancelled,
            Listing.archived_at.is_not(None),
        )
        in_state = {
            "live": and_(Listing.status == ListingStatus.active, live),
            "hidden": and_(Listing.status == ListingStatus.active, not_(live)),
            "in_deal": Listing.status == ListingStatus.pending,
            "sold": Listing.status == ListingStatus.completed,
            "archived": archived,
        }
        where = [
            Listing.store_id == store.id,
            # A deleted listing is also status "cancelled"; only one the
            # seller archived stays visible here.
            or_(
                Listing.status.in_([
                    ListingStatus.active, ListingStatus.pending, ListingStatus.completed,
                ]),
                archived,
            ),
        ]
        terms = search_terms(search)
        if terms:
            where.append(matches_all_terms(
                terms, (Listing.name, Listing.category, Listing.description)))
        if category:
            # The same category string Home's chips use, so a seller filtering
            # "Phones" here sees what a buyer filtering it there would.
            where.append(Listing.category == category)

        # sum(case) rather than count() FILTER, which older SQLite lacks.
        row = (await self.db.execute(select(*(
            func.coalesce(func.sum(case((cond, 1), else_=0)), 0)
            for cond in in_state.values()
        )).where(*where))).one()
        counts = {name: int(n) for name, n in zip(in_state, row)}
        counts["all"] = sum(counts.values())

        q = select(Listing).where(*where)
        if state != "all":
            q = q.where(in_state[state])
        order = {
            "newest": (desc(Listing.created_at), Listing.id),
            "oldest": (asc(Listing.created_at), Listing.id),
            "name": (func.lower(Listing.name), Listing.id),
            "price_low": (asc(Listing.price), Listing.id),
            "price_high": (desc(Listing.price), Listing.id),
        }.get(sort, (desc(Listing.created_at), Listing.id))
        listings = (await self.db.execute(
            q.order_by(*order).limit(limit).offset(offset)
        )).scalars().all()

        seller_ids = {l.seller_id for l in listings}
        sellers = {
            u.id: u for u in (await self.db.execute(
                select(User).where(User.id.in_(seller_ids)))).scalars()
        } if seller_ids else {}
        assets = await load_listing_media(self.db, listings, list(sellers.values()))
        items = []
        for listing in listings:
            item = ListingService._owner_listing_dict(
                listing, seller=sellers.get(listing.seller_id), store=store, assets=assets)
            item["store_state"] = self._owner_state(listing, now, store_live)
            # Why this product isn't showing, or what would make it sell -
            # answered by the server so the app doesn't re-derive BROKA's
            # rules and drift from them.
            item["health"] = self._product_health(listing, assets)
            items.append(item)
        return {"items": items, "counts": counts}

    @staticmethod
    def _product_health(listing: Listing, assets: Optional[dict] = None) -> dict:
        """The issues a seller can fix on a product, and nothing invented.

        Each issue names the screen that fixes it (`fix`), so the app can
        link straight there instead of leaving the seller to guess. Empty
        issues means the product passes the checks BROKA actually applies.
        """
        from api.domains.media.service import parse_id_list

        # A product that is no longer for sale has exactly one issue worth
        # stating. "Listing fee unpaid - buyers cannot see it" on an
        # archived row would name the wrong reason and send the seller to
        # pay for a listing they deliberately took down.
        if getattr(listing.status, "value", listing.status) == ListingStatus.cancelled.value:
            return {"issues": [{"code": "archived", "label": "Archived", "fix": "details"}],
                    "ok": False}

        issues: list[dict] = []
        photo_ids = parse_id_list(getattr(listing, "photo_ids", None))
        has_photo = bool(photo_ids) or bool(getattr(listing, "verified_photos", None)) or bool(
            getattr(listing, "showcase_image_url", None))
        if not has_photo:
            issues.append({"code": "no_image", "label": "No product photo",
                           "fix": "photos"})
        description = (getattr(listing, "description", None) or "").strip()
        if len(description) < 25:
            issues.append({"code": "short_description",
                           "label": "Description is too short to answer questions",
                           "fix": "details"})
        if not (getattr(listing, "category", None) or "").strip():
            issues.append({"code": "no_category", "label": "No category",
                           "fix": "category"})
        quantity = getattr(listing, "quantity", None)
        if quantity is not None and int(quantity) <= 0:
            issues.append({"code": "out_of_stock", "label": "Out of stock",
                           "fix": "stock"})
        fee = getattr(listing, "paid_until", None)
        from api.domains.listings.paid import fee_state
        if fee_state(listing).get("needs_payment"):
            issues.append({"code": "unpaid_listing_fee",
                           "label": "Listing fee unpaid - buyers cannot see it",
                           "fix": "fee"})
        return {"issues": issues, "ok": not issues}

    async def bulk_archive_listings(
        self, store_id: str, requester_id: str, listing_ids: list[str],
    ) -> dict:
        """Archive several of the store's products in one call.

        Every id is checked against this store AND this seller before any
        row changes: an id from another shop, another seller's listing, or
        one that has a buyer's deal on it is refused for the whole request,
        not silently skipped. Archiving is a status change on the existing
        listing row - never a delete - so deals, payments, reviews and
        history keep pointing at something real.
        """
        from api.domains.media.service import parse_id_list  # noqa: F401 - keep import light
        ids = list(dict.fromkeys(listing_ids or []))
        if not ids:
            raise HTTPException(status_code=400, detail="Choose at least one product.")
        if len(ids) > 50:
            raise HTTPException(status_code=400, detail="Archive at most 50 products at a time.")
        store = await self.get_owned(store_id, requester_id)
        rows = (await self.db.execute(
            select(Listing).where(
                Listing.id.in_(ids), Listing.store_id == store.id,
                Listing.seller_id == requester_id,
            )
        )).scalars().all()
        found = {row.id: row for row in rows}
        missing = [i for i in ids if i not in found]
        if missing:
            raise HTTPException(
                status_code=400,
                detail="Some of those products aren't in this store. Select them again.",
            )
        blocked = [
            row.name for row in rows
            if getattr(row.status, "value", row.status) in (
                ListingStatus.pending.value, ListingStatus.completed.value)
        ]
        if blocked:
            raise HTTPException(
                status_code=409,
                detail="These products are in a deal or sold, so they can't be archived: "
                       + ", ".join(blocked[:5]) + ("…" if len(blocked) > 5 else ""),
            )
        archived: list[str] = []
        for row in rows:
            if getattr(row.status, "value", row.status) == ListingStatus.cancelled.value:
                continue
            row.status = ListingStatus.cancelled
            row.archived_at = datetime.utcnow()
            row.is_featured = False
            archived.append(row.id)
        if archived:
            await self.db.commit()
        return {"archived": archived, "already_archived": [i for i in ids if i not in archived]}

    @staticmethod
    def _owner_state(listing: Listing, now: datetime, store_live: bool = True) -> str:
        status = getattr(listing.status, "value", listing.status)
        if status == ListingStatus.cancelled.value:
            return "archived" if getattr(listing, "archived_at", None) else "deleted"
        if status == ListingStatus.pending.value:
            return "in_deal"
        if status == ListingStatus.completed.value:
            return "sold"
        if not store_live:
            return "hidden"
        return "live" if is_live(listing, now) else "hidden"

    async def list_categories(self, store_id: str) -> list[dict]:
        """The categories this store has active products in, with counts,
        biggest first - the storefront's category rail. Listings whose
        category isn't one of BROKA's own count under "Other".

        Online (goods) stores never browse by Property, Automobiles, Land,
        Services or Other: those rows stay stored, they are just left out
        of the rail so the shop reads as a goods shop. Dealer/agent cards
        keep their own trades."""
        store = await self._get_or_404(store_id)
        if not await store_billing.store_live(self.db, store):
            return []
        rows = (await self.db.execute(
            select(Listing.category, func.count())
            .where(Listing.store_id == store_id, Listing.status == ListingStatus.active,
                   live_clause())
            .group_by(Listing.category)
        )).all()
        counts: dict[str, int] = defaultdict(int)
        for category, n in rows:
            counts[store_categories.for_listing(category)] += n
        card = store_billing.rate_card_for(store.category)
        if card.id == "goods":
            for excluded in store_categories.ONLINE_STORE_EXCLUDED:
                counts.pop(excluded, None)
        order = {c: i for i, c in enumerate(CANONICAL_CATEGORIES)}
        return [
            {"name": name, "count": n}
            for name, n in sorted(counts.items(), key=lambda kv: (-kv[1], order.get(kv[0], 99)))
        ]

    async def store_reviews(
        self, store_id: str, limit: int = 20, offset: int = 0,
        *, viewer_id: Optional[str] = None,
    ) -> dict:
        """A store's buyer reviews plus the owner's published standing.

        Store-scoped since 2026-10-19: these are the reviews of deals whose
        product was sold THROUGH this store, which is what its rating is
        built from. A seller with two shops would otherwise have one shop's
        reviews shown - and counted - on the other.

        Chat-only reviews - legacy rows from before reviews became
        deal-only (2026-10-22) - have no listing to name. They stay on the
        seller's profile; the shop shows them only when its owner has exactly
        one live store, where attribution is unambiguous (review_scope.py).
        A paused or unpaid store still reports its reviews: the shop's
        visibility governs the shop, not what buyers already said about it.

        A signed-in viewer also gets `viewer`: whether they have a sale on
        this shop they can still review, and the deals to choose from. It
        is computed from their own deals, so a buyer's other shops' deals
        can never appear here.
        """
        from api.domains.reviews.service import ReviewService
        from api.domains.trust.public_standing import public_seller_standing

        store = await self._get_or_404(store_id)
        from .review_scope import sole_store_ids
        sole = bool(await sole_store_ids(self.db, [store.id]))
        reviews_service = ReviewService(self.db)
        rows = await reviews_service.get_store_reviews(
            store.id, limit=limit, offset=offset,
            owner_id=store.owner_id, include_seller_chat=sole)
        payload = {
            "summary": await reviews_service.get_store_summary(
                store.id, owner_id=store.owner_id, include_seller_chat=sole),
            # Only what a review card shows: no reviewer, seller or deal id.
            "reviews": [
                {
                    "id": row["id"],
                    "rating": row["rating"],
                    "comment": row["comment"],
                    "created_at": row["created_at"],
                    "reviewer_name": row["reviewer_name"],
                }
                for row in rows
            ],
            # The owner as a seller, unchanged - the person's record is
            # still worth knowing, it is just no longer the shop's number.
            "seller_standing": await public_seller_standing(self.db, store.owner_id),
        }
        if viewer_id:
            deals = await reviews_service.my_reviewable_deals(
                viewer_id, store_id=store.id)
            unreviewed = [d for d in deals if not d["already_reviewed"]]
            payload["viewer"] = {
                "can_review": bool(unreviewed),
                # True only when every sale they had here is already
                # reviewed; a shopper with no deal at all is neither.
                "already_reviewed": bool(deals) and not unreviewed,
                "reviewable_deals": deals,
            }
        return payload

    # ── Update ────────────────────────────────────────────────────────────

    async def update_store(self, store_id: str, requester_id: str, data: dict) -> dict:
        store = await self._get_or_404(store_id)
        self._require_owner(store, requester_id)

        requested_type = self._store_type(data, current=store.store_type)
        hours_json = self._opening_hours_column(data)
        service_areas_json, delivery_note = self._coverage_columns(data)

        if "slug" in data and data["slug"] and naming.normalize(data["slug"]) != store.slug:
            raise HTTPException(
                status_code=400,
                detail="A store's link can't be changed once the store is open.",
            )
        if "name" in data:
            store.name = self._clean_name(data["name"])

        keep = frozenset()
        if "categories" in data:
            # Excluded trades the store already holds may stay (a dealer
            # store predating the online-store rail); adding one may not.
            held = (await self.db.execute(
                select(StoreCategoryLink.category)
                .where(StoreCategoryLink.store_id == store.id)
            )).scalars().all()
            keep = frozenset(n for n in [store.category, *held] if n)
        categories = self._categories_from(data, keep=keep)
        if categories is not None:
            # The set the request chose replaces the previous set: the
            # first category is the store's primary (what old clients
            # read), and the links are what the directory searches.
            store.category = categories[0]
            await self.db.execute(
                delete(StoreCategoryLink).where(StoreCategoryLink.store_id == store.id)
            )
            for name in categories:
                self.db.add(StoreCategoryLink(store_id=store.id, category=name))
        for field in _TEXT_FIELDS:
            if field in data:
                setattr(store, field, self._clean_text(field, data[field]))
        coords = self._clean_coords(data)
        if coords is not None:
            store.lat, store.lng = coords

        await self._check_legacy_media(requester_id, data)
        image_columns = await self._image_columns(requester_id, data)
        if "logo_id" in data:
            store.logo_id = image_columns["logo_id"]
            store.logo_url = None
        elif "logo_url" in data:
            # A blank legacy value clears only the legacy column. An older
            # build that sends "" is not asking to lose the logo that is
            # stored as an asset; logo_id is the field that removes one.
            store.logo_url = self._safe_normalize_single_media(data["logo_url"])
            if store.logo_url:
                store.logo_id = None      # the media backfill converts it
        if "cover_id" in data:
            store.cover_id = image_columns["cover_id"]
        if "photo_ids" in data:
            store.photo_ids = image_columns["photo_ids"]
            store.photos = None
        elif "photos" in data:
            store.photos = self._safe_normalize_photo_list(data["photos"])
            store.photo_ids = None    # the media backfill converts them
        # A shop is only a shop with a photo of itself. The wizard has
        # required one at setup since phase 2, but the Settings page could
        # take them all away afterwards, which left a storefront with
        # nothing to show. A removal that would take the last photo is
        # refused; adding, replacing or reordering still goes through.
        effective_type = requested_type or store.store_type
        if (("photo_ids" in data or "photos" in data) and not self._has_shop_photo(store)
                and effective_type == "physical"):
            raise HTTPException(
                status_code=400,
                detail="Keep at least one photo of your shop - buyers need to see it. "
                       "A store with no premises can become a virtual store instead.",
            )

        if requested_type and requested_type != store.store_type:
            # Switching changes what the storefront may claim, not what the
            # owner already told us: a move to virtual keeps the address and
            # pin stored (they are not destroyed), it just stops publishing
            # them as premises. A move to physical needs both a real shop
            # photo and a location buyers could find, because a physical
            # storefront with neither is exactly the state the rules exist
            # to prevent. Checked here, not only in the app: any client can
            # PATCH store_type, and the server is what the storefront reads.
            if requested_type == "physical" and not self._has_shop_photo(store):
                raise HTTPException(
                    status_code=400,
                    detail="Add at least one photo of your shop before switching to a physical store.",
                )
            if requested_type == "physical" and not self._has_premises_location(store):
                raise HTTPException(
                    status_code=400,
                    detail="Add your county and area under Where to find you before "
                           "switching to a physical store - buyers need somewhere to go.",
                )
            store.store_type = requested_type
        if "opening_hours" in data:
            store.opening_hours = hours_json
        if "service_areas" in data:
            store.service_areas = service_areas_json
        if "delivery_note" in data:
            store.delivery_note = delivery_note

        if "business_email" in data or "official_email" in data:
            owner = await self.db.get(User, requester_id)
            email = self._business_email(
                owner, data, current=(store.official_email, bool(store.business_email_verified)),
            )
            if email is not None:
                store.official_email, store.business_email_verified = email

        store.updated_at = datetime.utcnow()
        await self.db.commit()
        await self.db.refresh(store)
        return await self._store_dict(store, owner_view=True)

    async def set_store_status(self, store_id: str, requester_id: str, is_active: bool) -> dict:
        store = await self._get_or_404(store_id)
        self._require_owner(store, requester_id)
        if is_active and store_billing.enabled():
            # Opening is what buyers see, and with billing on that is what
            # a paid plan buys. Pausing needs no plan.
            sub = await store_billing.subscription_for(self.db, store.id)
            if not store_billing.is_live(sub):
                raise HTTPException(status_code=409, detail=(
                    "Your store's plan isn't paid, so buyers can't see it. "
                    "Pay for the plan first, then open the store."
                ))
        store.is_active = is_active
        store.updated_at = datetime.utcnow()
        await self.db.commit()
        await self.db.refresh(store)
        return await self._store_dict(store, owner_view=True)

    async def delete_store(self, store_id: str, requester_id: str) -> dict:
        """Delete the owner's store, and archive what it held.

        A soft delete, exactly like a listing's (ListingService.delete_listing):
        the row stays under Store.deleted_at so its payments, audit trail
        and product history keep pointing at something real, while the
        shop is gone from every buyer-facing read - directory, storefront,
        catalogue, categories - and its link is dead for good. The slug
        stays reserved too: a link printed on a flyer must never start
        showing a different shop's goods.

        The store's products are archived, not deleted: every listing
        under it becomes `cancelled` (the status every buyer-facing query
        already excludes), the same state delete_listing uses. A deal on
        one of them keeps its row, so a conversation or money in escrow
        carries on; nothing new can start.

        After this the owner has no store (get_my_store returns null), so
        they are free to open another.
        """
        from api.core.audit import record_audit

        store = (await self.db.execute(
            select(Store).where(Store.id == store_id, Store.deleted_at.is_(None))
            .with_for_update().execution_options(populate_existing=True)
        )).scalar_one_or_none()
        if store is None:
            raise HTTPException(status_code=404, detail="Store not found")
        self._require_owner(store, requester_id)

        now = datetime.utcnow()
        # Only what buyers could still see is archived: an active listing
        # becomes cancelled. A sold listing keeps "completed" and a deal's
        # "pending" keeps its state, so a buyer's history and an open deal
        # are not rewritten by the shop closing.
        listings = (await self.db.execute(
            select(Listing).where(
                Listing.store_id == store.id,
                Listing.status == ListingStatus.active,
            )
        )).scalars().all()
        for listing in listings:
            listing.status = ListingStatus.cancelled
            listing.is_featured = False

        store.deleted_at = now
        store.is_active = False
        store.updated_at = now
        await record_audit(
            self.db, requester_id, "store_deleted", "store", store.id,
            detail=f"slug={store.slug!r} name={store.name!r} archived_listings={len(listings)}",
        )
        await self.db.commit()
        return {"deleted": True, "store_id": store.id, "archived_listings": len(listings)}

    async def get_row(self, store_id: str) -> Store:
        return await self._get_or_404(store_id)

    async def get_owned(self, store_id: str, requester_id: str) -> Store:
        store = await self._get_or_404(store_id)
        self._require_owner(store, requester_id)
        return store

    # ── Internals ─────────────────────────────────────────────────────────

    async def _get_or_404(self, store_id: str) -> Store:
        store = await self.db.get(Store, store_id)
        if not store or store.deleted_at is not None:
            # A deleted store is gone from every read, owner included: the
            # link is dead, and nothing can be managed through an id that
            # no longer names a shop.
            raise HTTPException(status_code=404, detail="Store not found")
        return store

    @staticmethod
    def _require_owner(store: Store, requester_id: str) -> None:
        if store.owner_id != requester_id:
            raise HTTPException(status_code=403, detail="You do not have permission to manage this store")

    @staticmethod
    def _is_long_term_seller(user: User) -> bool:
        return (
            user.account_type == AccountType.buyer_seller
            and user.seller_tier == SellerTier.long_term
        )

    # ── Store type, hours and delivery coverage ──────────────────────────

    @staticmethod
    def _store_type(data: dict, current: Optional[str] = None) -> Optional[str]:
        """The validated type a request sets, or `current` when it sets
        none. `store_type` is never guessed from location or photos: a shop
        without a pin is not automatically virtual, and a virtual shop may
        still have an address on file."""
        if "store_type" not in data or data.get("store_type") is None:
            return current
        value = data.get("store_type")
        if not isinstance(value, str) or value.strip().lower() not in STORE_TYPES:
            raise HTTPException(
                status_code=400,
                detail="Choose a physical or virtual store.",
            )
        return value.strip().lower()

    @staticmethod
    def _has_premises_location(store: Store) -> bool:
        """Whether the store has enough location information to be published
        as a place a buyer can visit: a county, a written location, or a pin
        the owner set at their shop. A virtual store that was given an
        address already satisfies this, so switching it back loses nothing.
        """
        if (store.county or "").strip():
            return True
        if (store.location_description or "").strip():
            return True
        return store.lat is not None and store.lng is not None

    @staticmethod
    def _opening_hours_column(data: dict) -> Optional[str]:
        """The JSON to store for a request's `opening_hours`; None clears it.
        Only called when the key is present (create passes the result even
        when absent, which is None and means no schedule)."""
        if "opening_hours" not in data:
            return None
        try:
            return opening_hours.dumps(opening_hours.normalize(data.get("opening_hours")))
        except opening_hours.OpeningHoursError as exc:
            raise HTTPException(status_code=400, detail=str(exc))

    @staticmethod
    def _coverage_columns(data: dict) -> tuple[Optional[str], Optional[str]]:
        """(service_areas JSON, delivery_note) from a request. Keys that
        aren't present become None, which callers only assign when the key
        is in the payload - so an unrelated edit never clears coverage."""
        areas_json = None
        if "service_areas" in data:
            raw = data.get("service_areas")
            if raw is None or raw == []:
                areas_json = None
            else:
                if not isinstance(raw, list) or not all(isinstance(v, str) for v in raw):
                    raise HTTPException(
                        status_code=400,
                        detail="Choose the counties you deliver to, or Nationwide.",
                    )
                cleaned: list[str] = []
                for value in raw:
                    text = " ".join(value.split())
                    if text.lower() == "nationwide":
                        cleaned = ["Nationwide"]
                        break
                    county = canonical_county(text)
                    if county is None:
                        raise HTTPException(
                            status_code=400,
                            detail=f"\"{text}\" isn't a Kenyan county. Choose from the list, or Nationwide.",
                        )
                    if county not in cleaned:
                        cleaned.append(county)
                areas_json = __import__("json").dumps(cleaned) if cleaned else None
        note = None
        if "delivery_note" in data:
            raw = data.get("delivery_note")
            if isinstance(raw, str) and raw.strip():
                note = raw.strip()
                if len(note) > 200:
                    raise HTTPException(
                        status_code=400,
                        detail="Keep the delivery note under 200 characters.",
                    )
        return areas_json, note

    @staticmethod
    def _service_area_list(raw: Optional[str]) -> list[str]:
        if not raw:
            return []
        try:
            value = __import__("json").loads(raw)
        except (TypeError, ValueError):
            return []
        return [v for v in value if isinstance(v, str)] if isinstance(value, list) else []

    @staticmethod
    def _clean_name(raw) -> str:
        name = " ".join((raw or "").split()) if isinstance(raw, str) else ""
        if not name:
            raise HTTPException(status_code=400, detail="Store name is required")
        if len(name) > _MAX_NAME_LEN:
            raise HTTPException(
                status_code=400, detail=f"Keep the store name under {_MAX_NAME_LEN} characters",
            )
        return name

    @staticmethod
    def _clean_text(field: str, raw) -> Optional[str]:
        if not isinstance(raw, str) or not raw.strip():
            return None
        value = raw.strip()
        limit = _TEXT_LIMITS[field]
        if len(value) > limit:
            label = "Description" if field == "description" else "Location"
            raise HTTPException(status_code=400, detail=f"{label} is too long (max {limit} characters)")
        return value

    @staticmethod
    def _category_from(data: dict) -> Optional[str]:
        """The canonical category a request sets, or None when it sets
        none. `specialization` is what app builds before phase 2 send."""
        if data.get("category"):
            category = store_categories.canonical(data["category"])
            if category is None:
                raise HTTPException(status_code=400, detail="Choose one of BROKA's categories")
            return category
        if data.get("specialization"):
            return store_categories.from_legacy(data["specialization"])
        return None

    @staticmethod
    def _categories_from(data: dict, keep: frozenset = frozenset()) -> Optional[list[str]]:
        """The canonical categories a request sets, primary first, or None
        when it sets none.

        Phase 3 sends `categories` - one or more, because a store may sell
        across several and the "Wholesale and General" rail entry is the
        view of stores with two or more. The singular `category`/
        `specialization` older clients send becomes a one-element list. A
        name that isn't one of BROKA's is refused, not mapped: this is a
        choice from a list the app shows, and quietly filing a typo under
        "Other" is how a seller ends up invisible in the category they
        meant.

        A phase-3 choice also refuses the trades an online store doesn't
        sell (categories.ONLINE_STORE_EXCLUDED: Property, Automobiles,
        Land, Services, Other) - the setup screen no longer offers them,
        so a client still sending one is out of date or hand-built.
        `keep` grandfathers excluded names a store already holds (a
        dealer store opened through the legacy singular fields): keeping
        one is fine, adding a new one is not. The singular legacy path
        below is untouched for the same reason."""
        if "categories" in data:
            raw = data.get("categories")
            if not isinstance(raw, list) or not raw:
                raise HTTPException(
                    status_code=400, detail="Choose at least one of BROKA's categories")
            names: list[str] = []
            for value in raw:
                category = store_categories.canonical(value)
                if category is None:
                    raise HTTPException(
                        status_code=400, detail="Choose one of BROKA's categories")
                if category in store_categories.ONLINE_STORE_EXCLUDED and category not in keep:
                    raise HTTPException(
                        status_code=400,
                        detail=f"{category} isn't sold through an online store. "
                               "Choose from the online store categories.")
                if category not in names:
                    names.append(category)
            return names
        single = StoreService._category_from(data)
        return [single] if single is not None else None

    @staticmethod
    def _ordered_categories(primary: Optional[str], names: list[str]) -> list[str]:
        """A store's categories, primary first, the rest alphabetical -
        the payload's `categories`, so index 0 always equals `category`
        for clients that read one."""
        rest = sorted(n for n in names if n != primary)
        return ([primary] if primary else []) + rest

    @staticmethod
    def _business_email(owner, data: dict, current: tuple) -> Optional[tuple]:
        """(address, verified) to save, or None when the request doesn't
        touch the business email.

        A new address must be proven: an `business_email_token` from the
        email-code step for that exact address, unless it is the owner's
        own already-verified account email. An unproven address is
        refused rather than saved unverified - orders and receipts will be
        sent there, and mail to a mistyped or someone else's address is a
        leak. Re-sending the address already saved keeps its status.
        App builds before phase 2 send `official_email` with no way to
        verify it; that is saved as unverified, and nothing is sent to an
        unverified address.
        """
        from api.domains.auth.service import _normalize_email

        if "business_email" in data:
            raw = data.get("business_email")
            if not raw or not str(raw).strip():
                return (None, False)
            email = _normalize_email(str(raw))
            if not email:
                raise HTTPException(status_code=400, detail="Enter a valid email address")
            current_email, current_verified = current
            if current_email and current_email.lower() == email and current_verified:
                return (email, True)
            if owner is not None and owner.email and owner.email.lower() == email and owner.email_verified:
                return (email, True)
            token = data.get("business_email_token")
            proven = decode_email_verify_token(token) if token else None
            if proven and proven.lower() == email:
                return (email, True)
            raise HTTPException(
                status_code=400,
                detail="Verify this email first: enter the code we sent to it.",
            )
        if "official_email" in data:
            raw = data.get("official_email")
            if not raw or not str(raw).strip():
                return (None, False)
            email = _normalize_email(str(raw))
            if not email:
                raise HTTPException(status_code=400, detail="Enter a valid email address")
            current_email, current_verified = current
            if current_email and current_email.lower() == email:
                return (email, current_verified)
            return (email, False)
        return None

    @staticmethod
    def _safe_normalize_single_media(raw: Optional[str]) -> Optional[str]:
        try:
            return normalize_single_media(raw)
        except MediaTooLargeError as e:
            raise HTTPException(status_code=413, detail=str(e))

    @staticmethod
    def _safe_normalize_photo_list(raw) -> Optional[str]:
        try:
            return normalize_photo_list(raw)
        except MediaTooLargeError as e:
            raise HTTPException(status_code=413, detail=str(e))

    async def _check_legacy_media(self, owner_id: str, data: dict) -> None:
        """logo_url / photos from app builds that predate image assets may
        only be inline images or the owner's own BROKA image URLs."""
        from api.domains.media.service import check_legacy_images
        from api.models.media import MediaPurpose as P

        if "logo_url" in data:
            await check_legacy_images(self.db, owner_id, [data.get("logo_url")], P.STORE_LOGO)
        if "photos" in data:
            photos = data.get("photos") or []
            await check_legacy_images(
                self.db, owner_id, [p for p in photos if isinstance(p, str)], P.STORE_PHOTO,
            )

    async def _image_columns(self, owner_id: str, data: dict) -> dict:
        """Validated image-asset columns for the keys present in `data`:
        each id must be the owner's own upload, for a store purpose."""
        from api.domains.media.service import (
            MAX_STORE_PHOTOS, dump_id_list, require_owned_assets,
        )
        from api.models.media import MediaPurpose as P

        out: dict = {}
        if "logo_id" in data:
            logo_id = data.get("logo_id") or None
            if logo_id:
                await require_owned_assets(self.db, owner_id, [logo_id], {P.STORE_LOGO})
            out["logo_id"] = logo_id
        if "cover_id" in data:
            cover_id = data.get("cover_id") or None
            if cover_id:
                await require_owned_assets(
                    self.db, owner_id, [cover_id], {P.STORE_COVER, P.STORE_PHOTO},
                )
            out["cover_id"] = cover_id
        if "photo_ids" in data:
            ids = data.get("photo_ids") or []
            ids = await require_owned_assets(
                self.db, owner_id, ids, {P.STORE_PHOTO, P.STORE_COVER},
            ) if ids else []
            out["photo_ids"] = dump_id_list(ids[:MAX_STORE_PHOTOS]) if ids else None
        return out

    async def _assets_for(self, stores) -> dict:
        from api.domains.media.service import load_assets, parse_id_list
        ids: set[str] = set()
        for store in stores:
            ids.update(i for i in (store.logo_id, store.cover_id) if i)
            ids.update(parse_id_list(store.photo_ids))
        return await load_assets(self.db, ids)

    async def _owners_for(self, stores) -> dict[str, User]:
        ids = {s.owner_id for s in stores}
        if not ids:
            return {}
        rows = (await self.db.execute(select(User).where(User.id.in_(ids)))).scalars().all()
        return {u.id: u for u in rows}

    @staticmethod
    def _owner_facts(
        owner: Optional[User],
        review: tuple[int, Optional[float]] = (0, None),
    ) -> Optional[dict]:
        if owner is None:
            return None
        # The name is what a buyer needs to know who runs the store (the
        # store page's "Store details"). Still no id or phone: a store
        # page is public and indexed, and nothing on it needs either.
        # Online is the chat header's rule (api/core/presence.py): a
        # heartbeat in the last five minutes. An owner who has never sent
        # one has no "last active" - "Recently active" would be a guess.
        #
        # `rating` is the owner's BUYER-REVIEW average, from the reviews
        # themselves: null when nobody has reviewed them. User.rating's
        # 5.0 starting value is not a score anyone gave, and the shop's
        # own 0-10 composite is published separately as `rating` above.
        online, last_active = online_status(owner.last_seen)
        review_count, review_avg = review
        return {
            "name": (owner.name or "").strip() or None,
            "verified": bool(owner.is_verified),
            "rating": round(review_avg, 1) if review_avg is not None else None,
            "review_count": review_count,
            "completed_deals": int(owner.completed_deals or 0),
            "member_since": owner.created_at.isoformat() if owner.created_at else None,
            "online": online,
            "last_active": last_active if owner.last_seen else None,
        }

    async def _store_dict(
        self,
        store: Store,
        listing_count: Optional[int] = None,
        assets: Optional[dict] = None,
        owner: Optional[User] = None,
        owner_view: bool = False,
        billing_subs: Optional[dict] = None,
        category_names: Optional[list[str]] = None,
        viewer_lat: Optional[float] = None,
        viewer_lng: Optional[float] = None,
        owner_reviews: Optional[dict[str, tuple[int, Optional[float]]]] = None,
    ) -> dict:
        """The store payload. owner_view=True only for responses to the
        owner themselves (create, update, status, /stores/mine); every other
        read is public.

        With store billing on, public reads report an unpaid store as
        is_active=False - the storefront and app builds that predate
        billing show the same "nothing listed right now" a paused store
        shows - while the owner's own payload carries their real
        is_active and a `billing` object with what is owed. `billing` is
        null when the setting is off, and the app only shows billing
        screens when it is not."""
        # listing_count and assets may come from a caller that loaded them
        # for a whole page at once (list_stores); single-store reads load
        # them here.
        if listing_count is None:
            listing_count = (await self.db.execute(
                select(func.count()).select_from(Listing).where(
                    Listing.store_id == store.id, Listing.status == ListingStatus.active,
                    live_clause(),
                )
            )).scalar_one()
        from api.domains.media.service import asset_urls, legacy_image_or_none, parse_id_list
        if assets is None:
            assets = await self._assets_for([store])
        if owner is None:
            owner = await self.db.get(User, store.owner_id)
        if owner_reviews is not None:
            owner_review = owner_reviews.get(owner.id, (0, None)) if owner else (0, None)
        elif owner is not None:
            # One grouped read for a single store; list_stores passes the
            # whole page's figures in rather than doing this per shop.
            from api.domains.reviews.stats import seller_review_figures
            owner_review = (await seller_review_figures(self.db, [owner.id])).get(
                owner.id, (0, None))
        else:
            owner_review = (0, None)
        logo = asset_urls(assets.get(store.logo_id)) if store.logo_id else None
        cover = asset_urls(assets.get(store.cover_id)) if store.cover_id else None
        photo_images = [
            asset_urls(assets[i]) for i in parse_id_list(store.photo_ids) if i in assets
        ]
        category = store.category or store_categories.from_legacy(store.specialization)
        if category_names is None:
            category_names = (await self._categories_for([store.id])).get(store.id, [])
        active = bool(store.is_active)
        billing_state = None
        billing_sub = None
        if store_billing.enabled():
            billing_sub = (billing_subs.get(store.id) if billing_subs is not None
                           else await store_billing.subscription_for(self.db, store.id))
            if owner_view:
                billing_state = store_billing.state_for(billing_sub)
            elif not store_billing.is_live(billing_sub):
                active = False
        elif owner_view:
            # A launch-offer store carries a free-period subscription row
            # even while billing is off (service.create_store claims
            # regardless of the switch). The owner's own payload must show
            # that row's real countdown, not "No expiry". `billing` itself
            # stays null - the billing screens are hidden while off.
            billing_sub = (billing_subs.get(store.id) if billing_subs is not None
                           else await store_billing.subscription_for(self.db, store.id))

        store_type_public = store.store_type or DEFAULT_STORE_TYPE
        distance_km, distance_approximate = self._store_distance(
            store, owner, viewer_lat, viewer_lng)
        # The mappable point is _store_point's point at ±1 km rounding:
        # pin, declared area, or owner's point - never more precise.
        point, _ = self._store_point(store, owner)
        approx_lat, approx_lng = self._approx_point(*(point or (None, None)))
        distance_label = format_distance_km(distance_km)
        if distance_label is not None and distance_approximate:
            distance_label = f"≈ {distance_label}"

        # The store's own rating (stores/rating.py). Stored values, so a
        # directory page costs one row read per shop, not an aggregate.
        from .rating import rating_payload
        rating_block = await rating_payload(self.db, store, owner_view=owner_view)

        return {
            "id": store.id,
            "name": store.name,
            "slug": store.slug,
            "url": store_link(store.slug),
            # logo_url/photos stay plain strings for app builds before phase
            # 1: image URLs once the store's images are assets, the legacy
            # data URIs until the media backfill has converted them.
            # Legacy values are filtered on the way out too: rows saved
            # before these fields were checked may hold links elsewhere.
            "logo_url": logo["medium"] if logo else legacy_image_or_none(store.logo_url),
            "photos": (
                [p["large"] for p in photo_images] if photo_images
                else [p for p in parse_photo_list(store.photos) if legacy_image_or_none(p)]
            ),
            "logo": logo,
            "cover": cover,
            "photo_images": photo_images,
            "category": category,
            # Every category the store chose, primary first; `category`
            # above stays the first element for app builds that read one.
            "categories": self._ordered_categories(category, category_names),
            # What app builds before phase 2 display.
            "specialization": category,
            "description": store.description,
            # Physical or virtual. The rest of the type-specific fields
            # below are always present so an older client can ignore them;
            # the app and the web decide what to draw from this one value.
            "store_type": store.store_type or DEFAULT_STORE_TYPE,
            # Weekly hours, the rows a storefront draws, and "open now" -
            # computed here, in Africa/Nairobi, so neither client has to
            # and neither can disagree with the other. A virtual store has
            # no opening times: stored hours from before a type switch stay
            # editable for the owner but are never published as if there
            # were a door to open.
            **opening_hours.public_payload(
                store.opening_hours
                if owner_view or store_type_public != "virtual" else None
            ),
            "service_areas": self._service_area_list(store.service_areas),
            "delivery_note": store.delivery_note,
            # A virtual store keeps its stored address for the owner (so the
            # switch can be reversed and the owner can still edit it), but a
            # public read never publishes premises it does not have. Clients
            # that drew county/subcounty unconditionally would otherwise put
            # an invented shopfront on the page.
            **(
                {
                    "country": store.country,
                    "county": store.county,
                    "subcounty": store.subcounty,
                    "location_description": store.location_description,
                }
                if owner_view or store_type_public != "virtual"
                else {
                    "country": None,
                    "county": None,
                    "subcounty": None,
                    "location_description": None,
                }
            ),
            # Public reads show only a verified address: an unverified one
            # (saved by app builds that couldn't verify) may be a typo or
            # someone else's. The owner always sees what they saved.
            "business_email": (
                store.official_email
                if owner_view or store.business_email_verified else None
            ),
            "business_email_verified": bool(store.business_email_verified),
            "owner": self._owner_facts(owner, owner_review),
            "rating": rating_block["rating"],
            "review_count": rating_block["review_count"],
            "response_minutes": rating_block["response_minutes"],
            "rating_as_of": rating_block["as_of"],
            # Owner only: the working behind the number, and one line
            # saying what moves it. Never shown to a buyer.
            **({"rating_breakdown": rating_block["breakdown"],
                "rating_explanation": rating_block["explanation"]}
               if owner_view and "breakdown" in rating_block else {}),
            "is_active": active,
            # Owner's view only, and only while billing is on: the app
            # routes a fresh store to the billing screen on this being
            # non-null and not active.
            "billing": billing_state,
            # Time before this store goes offline, for every reader (the
            # billing object above is owner-only). Billing off, or a store
            # with no deadline, reads "No expiry" (listings/time_left.py).
            **_store_time_left(billing_sub),
            "listing_count": listing_count,
            "distance_km": distance_km,
            "distance_label": distance_label,
            # True when the distance is measured to the shop's declared
            # area (county/subcounty point), not to a real pin - clients
            # show those as approximate ("≈ 6 km from you").
            "distance_approximate": bool(distance_approximate and distance_km is not None),
            # Where the map may put the shop (±1 km, never exact), and -
            # for the owner only - the pin exactly as they set it. A virtual
            # store publishes no map point: it has no premises, and showing
            # one (even an approximate area) would invent a shopfront. The
            # owner still receives their own stored pin below.
            "approx_lat": approx_lat if (store_type_public == "physical") else None,
            "approx_lng": approx_lng if (store_type_public == "physical") else None,
            "has_location": approx_lat is not None and store_type_public == "physical",
            **({"lat": store.lat, "lng": store.lng} if owner_view else {}),
            "created_at": store.created_at.isoformat() if store.created_at else None,
            "updated_at": store.updated_at.isoformat() if store.updated_at else None,
        }
