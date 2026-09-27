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

Trust shown with a store is its owner's real, seller-level record
(verified badge, rating, completed deals, member since). There is no
separate store-level rating: nothing computes one, and inventing one
would be a number with nothing behind it.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import datetime
import uuid
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import select, func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.database import AccountType, Listing, ListingStatus, SellerTier, User
from api.domains.listings.paid import live_clause
from api.domains.categories.seed import CANONICAL_CATEGORIES
from api.models.store import Store
from api.domains.listings.service import ListingService
from api.security import decode_email_verify_token
from . import categories as store_categories
from . import naming
from .media import (
    normalize_photo_list, parse_photo_list, normalize_single_media, MediaTooLargeError,
)

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


class StoreService:
    def __init__(self, db: AsyncSession):
        self.db = db

    # ── Create ────────────────────────────────────────────────────────────

    async def create_store(self, owner_id: str, data: dict) -> dict:
        name = self._clean_name(data.get("name"))

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

        category = self._category_from(data)
        if category is None:
            category = store_categories.from_legacy(owner.business_category)

        logo_url = self._safe_normalize_single_media(data.get("logo_url"))
        photos = self._safe_normalize_photo_list(data.get("photos"))
        email = self._business_email(owner, data, current=(None, False))
        text_values = {field: self._clean_text(field, data.get(field)) for field in _TEXT_FIELDS}

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
            slug = chosen_slug or await self._unique_slug(name)
            store = Store(
                owner_id=owner_id, name=name, slug=slug, category=category,
                logo_url=logo_url, photos=photos,
            )
            if email is not None:
                store.official_email, store.business_email_verified = email
            for field, value in text_values.items():
                setattr(store, field, value)
            for column, value in image_columns.items():
                setattr(store, column, value)

            self.db.add(store)
            try:
                await self.db.commit()
            except IntegrityError:
                # The only unique constraint on this table is slug: someone
                # else took it between our check and this insert.
                await self.db.rollback()
                continue
            await self.db.refresh(store)
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
            select(Store.id).where(Store.owner_id == owner_id).limit(1)
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
        limit: int = 20,
        offset: int = 0,
        with_total: bool = False,
    ):
        """Browse active stores. A paused store is left out of the
        directory, though its own link still resolves."""
        q = select(Store).where(Store.is_active == True)  # noqa: E712
        if search:
            q = q.where(Store.name.ilike(f"%{search.strip()}%"))
        if category:
            # Old stores' categories are filled in at startup
            # (categories.backfill_store_categories).
            wanted = store_categories.canonical(category) or store_categories.from_legacy(category)
            q = q.where(Store.category == wanted)
        if county:
            q = q.where(Store.county == county)

        total = None
        if with_total:
            count_q = select(func.count()).select_from(q.order_by(None).subquery())
            total = (await self.db.execute(count_q)).scalar_one()

        q = q.order_by(Store.created_at.desc()).limit(limit).offset(offset)
        stores = (await self.db.execute(q)).scalars().all()

        # One grouped count, one owners query and one assets query for the
        # whole page - never one per store.
        counts = await self._listing_counts_for([s.id for s in stores])
        assets = await self._assets_for(stores)
        owners = await self._owners_for(stores)
        items = [
            await self._store_dict(
                s, listing_count=counts.get(s.id, 0), assets=assets, owner=owners.get(s.owner_id),
            )
            for s in stores
        ]
        return {"items": items, "total": total} if with_total else items

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

    async def get_store(self, store_id: str) -> dict:
        store = await self._get_or_404(store_id)
        return await self._store_dict(store)

    async def get_store_by_slug(self, slug: str) -> dict:
        store = await self.find_by_slug(slug)
        if not store:
            raise HTTPException(status_code=404, detail="Store not found")
        return await self._store_dict(store)

    async def find_by_slug(self, slug: str) -> Optional[Store]:
        # Links are case-insensitive: someone typing BROKA.co.ke/store/Clanix
        # from a flyer still arrives.
        return (await self.db.execute(
            select(Store).where(Store.slug == naming.normalize(slug))
        )).scalar_one_or_none()

    async def get_my_store(self, owner_id: str) -> Optional[dict]:
        """The owner's store, or None when they haven't opened one - a
        normal state for most users, not an error. The schema allows more
        than one per owner, so this takes the newest."""
        store = await self._my_store(owner_id)
        return await self._store_dict(store, owner_view=True) if store else None

    async def _my_store(self, owner_id: str) -> Optional[Store]:
        return (await self.db.execute(
            select(Store).where(Store.owner_id == owner_id)
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
    ):
        store = await self._get_or_404(store_id)
        if not store.is_active:
            # A paused store keeps its profile but shows an empty catalogue:
            # a shared link should say "nothing listed right now", not 404.
            return {"items": [], "total": 0} if with_total else []

        listing_category = None
        if category:
            listing_category = store_categories.canonical(category)
            if listing_category is None:
                raise HTTPException(status_code=400, detail="Unknown category")
        return await ListingService(self.db).list_listings(
            store_id=store_id, category=listing_category, search=(search or "").strip() or None,
            sort=CATALOGUE_SORTS.get(sort or "featured"),
            limit=limit, offset=offset, with_total=with_total,
        )

    async def list_categories(self, store_id: str) -> list[dict]:
        """The categories this store has active products in, with counts,
        biggest first - the storefront's category rail. Listings whose
        category isn't one of BROKA's own count under "Other"."""
        store = await self._get_or_404(store_id)
        if not store.is_active:
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
        order = {c: i for i, c in enumerate(CANONICAL_CATEGORIES)}
        return [
            {"name": name, "count": n}
            for name, n in sorted(counts.items(), key=lambda kv: (-kv[1], order.get(kv[0], 99)))
        ]

    # ── Update ────────────────────────────────────────────────────────────

    async def update_store(self, store_id: str, requester_id: str, data: dict) -> dict:
        store = await self._get_or_404(store_id)
        self._require_owner(store, requester_id)

        if "slug" in data and data["slug"] and naming.normalize(data["slug"]) != store.slug:
            raise HTTPException(
                status_code=400,
                detail="A store's link can't be changed once the store is open.",
            )
        if "name" in data:
            store.name = self._clean_name(data["name"])

        category = self._category_from(data)
        if category is not None:
            store.category = category
        for field in _TEXT_FIELDS:
            if field in data:
                setattr(store, field, self._clean_text(field, data[field]))

        await self._check_legacy_media(requester_id, data)
        image_columns = await self._image_columns(requester_id, data)
        if "logo_id" in data:
            store.logo_id = image_columns["logo_id"]
            store.logo_url = None
        elif "logo_url" in data:
            store.logo_url = self._safe_normalize_single_media(data["logo_url"])
            store.logo_id = None      # the media backfill converts it
        if "cover_id" in data:
            store.cover_id = image_columns["cover_id"]
        if "photo_ids" in data:
            store.photo_ids = image_columns["photo_ids"]
            store.photos = None
        elif "photos" in data:
            store.photos = self._safe_normalize_photo_list(data["photos"])
            store.photo_ids = None    # the media backfill converts them

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
        store.is_active = is_active
        store.updated_at = datetime.utcnow()
        await self.db.commit()
        await self.db.refresh(store)
        return await self._store_dict(store, owner_view=True)

    async def get_row(self, store_id: str) -> Store:
        return await self._get_or_404(store_id)

    async def get_owned(self, store_id: str, requester_id: str) -> Store:
        store = await self._get_or_404(store_id)
        self._require_owner(store, requester_id)
        return store

    # ── Internals ─────────────────────────────────────────────────────────

    async def _get_or_404(self, store_id: str) -> Store:
        store = await self.db.get(Store, store_id)
        if not store:
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
    def _owner_facts(owner: Optional[User]) -> Optional[dict]:
        if owner is None:
            return None
        return {
            "verified": bool(owner.is_verified),
            "rating": round(float(owner.rating), 1) if owner.rating is not None else None,
            "completed_deals": int(owner.completed_deals or 0),
            "member_since": owner.created_at.isoformat() if owner.created_at else None,
        }

    async def _store_dict(
        self,
        store: Store,
        listing_count: Optional[int] = None,
        assets: Optional[dict] = None,
        owner: Optional[User] = None,
        owner_view: bool = False,
    ) -> dict:
        """The store payload. owner_view=True only for responses to the
        owner themselves (create, update, status, /stores/mine); every other
        read is public."""
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
        logo = asset_urls(assets.get(store.logo_id)) if store.logo_id else None
        cover = asset_urls(assets.get(store.cover_id)) if store.cover_id else None
        photo_images = [
            asset_urls(assets[i]) for i in parse_id_list(store.photo_ids) if i in assets
        ]
        category = store.category or store_categories.from_legacy(store.specialization)

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
            # What app builds before phase 2 display.
            "specialization": category,
            "description": store.description,
            "country": store.country,
            "county": store.county,
            "subcounty": store.subcounty,
            "location_description": store.location_description,
            # Public reads show only a verified address: an unverified one
            # (saved by app builds that couldn't verify) may be a typo or
            # someone else's. The owner always sees what they saved.
            "business_email": (
                store.official_email
                if owner_view or store.business_email_verified else None
            ),
            "business_email_verified": bool(store.business_email_verified),
            "owner": self._owner_facts(owner),
            "is_active": bool(store.is_active),
            "listing_count": listing_count,
            "created_at": store.created_at.isoformat() if store.created_at else None,
            "updated_at": store.updated_at.isoformat() if store.updated_at else None,
        }
