"""Stores Service V1.

Store is a first-class business identity (see api/models/store.py's module
docstring for the full User -> Store -> Listing picture). This service:
  - creates/reads/updates a Store, with slug uniqueness and server-side
    ownership checks on every mutation (spec §22 - ownership is never
    trusted from the client, only from the authenticated requester_id the
    router passes in)
  - exposes a store's public catalog by delegating to ListingService
    rather than re-implementing listing serialization (spec §26 - "Do not:
    ... create a second Listing system"). A store's catalog IS
    `Listing.store_id == this store`, filtered/serialized exactly the same
    way Home/search/category results already are.

No fake reputation numbers here (spec §7/§19): this V1 response only
includes listing_count, which is a real live COUNT(*) - not a rating, DCR,
or completed-deals figure, since nothing in this codebase yet computes a
STORE-level (as opposed to seller-level) trust signal. SellerMetrics
(api/domains/trust/completion_rate.py) is seller-scoped, not store-scoped,
and deliberately not reused here as if it were the same thing - a future
pass can decide how store-level reputation should actually be derived from
real Deal/Review data, once that's asked for.
"""
from __future__ import annotations

from datetime import datetime
import uuid
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import select, func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, ListingStatus, User
from api.models.store import Store, slugify
from api.domains.listings.service import ListingService
from .media import (
    normalize_photo_list, parse_photo_list, normalize_single_media, MediaTooLargeError,
)

# Fields a caller may set at creation and patch identically (name is
# handled separately in both places since it also drives slug
# regeneration). Kept as one list so create/update can't silently drift
# apart on which fields exist - a real risk once this grows past a
# handful of columns.
_TEXT_FIELDS = (
    "specialization", "description", "county", "subcounty",
    "location_description",
)
_MAX_NAME_LEN = 120
# Phase 4 hardening: bounded retries for the rare slug-uniqueness race
# (see create_store/update_store) - not a distributed lock, just enough
# attempts that an actual failure after this many is worth surfacing
# rather than silently retrying forever.
#
# 3 was too tight in practice: under N truly concurrent requests for the
# identical name, several can be mid-flight against the SAME sequence of
# candidate suffixes (-2, -3, -4...) at once, so the "loser" of that
# particular race needs more than a couple of retries to reach a slug
# nobody else grabbed first - a live CI run with 5 concurrent identical-
# name creations reproduced exactly this (one request got a real 409
# after exhausting 3 attempts, not a bug in the retry mechanism itself,
# just too small a budget for that much simultaneous contention). 8 gives
# real margin for that scale without pretending to solve unbounded
# contention - each attempt is cheap (one SELECT, one failed INSERT to
# roll back), so a wider budget costs little even in the worst case.
_MAX_SLUG_RETRIES = 8
# How far the -2/-3/... suffix search probes before falling back to a
# random suffix. See _unique_slug.
_MAX_SLUG_SUFFIX = 25


class StoreService:
    def __init__(self, db: AsyncSession):
        self.db = db

    # ── Create ────────────────────────────────────────────────────────────

    async def create_store(self, owner_id: str, data: dict) -> dict:
        name = (data.get("name") or "").strip()
        if not name:
            raise HTTPException(status_code=400, detail="Store name is required")
        if len(name) > _MAX_NAME_LEN:
            raise HTTPException(status_code=400, detail="Store name is too long")

        # Phase 8 decision: this product currently intends ONE store per
        # user. Every existing Flutter surface already behaves this way
        # (getMyStore, a singular "My Store" entry, an empty-state
        # "Create Store" button that only appears when you have none) -
        # but until now nothing stopped a direct API call from creating a
        # second one. Enforced here at the service level, WITHOUT a
        # database constraint: the schema still architecturally allows
        # multiple stores per owner (api/models/store.py's own comment),
        # kept open for a real future multi-store decision rather than
        # closed off by a migration-requiring unique index.
        # RACE FIX (implementation audit, spec §4): the one-store rule was
        # a plain check-then-act - SELECT, then INSERT in a separate
        # statement - which is precisely the pattern §6 identifies for
        # slugs and which create_store already handles correctly THERE via
        # the unique index. The one-store rule has no index behind it (by
        # design: no migration, schema stays multi-store-capable), so
        # nothing caught it: two concurrent POST /stores from the same
        # account both passed the check, got different slugs from the
        # collision handler, and both committed. The user ends up with two
        # stores, and every Flutter surface assumes exactly one.
        #
        # Locking the owner's User row serializes concurrent creates for
        # that account without adding a constraint. Same mechanism and the
        # same caveat as escrow's lock_deal_if_status: on Postgres this is
        # a real row lock; on SQLite SQLAlchemy drops FOR UPDATE silently,
        # so dev/test keeps the plain re-check and production gets the
        # serialization.
        await self.db.execute(
            select(User.id).where(User.id == owner_id).with_for_update()
        )
        existing = (await self.db.execute(
            select(Store.id).where(Store.owner_id == owner_id).limit(1)
        )).scalar_one_or_none()
        if existing:
            raise HTTPException(
                status_code=409,
                detail="You already have a store. BROKA currently supports one store per account.",
            )

        logo_url = self._safe_normalize_single_media(data.get("logo_url"))
        photos = self._safe_normalize_photo_list(data.get("photos"))
        image_columns = await self._image_columns(owner_id, data)
        # An asset replaces the legacy base64 copy of the same image.
        if image_columns.get("logo_id"):
            logo_url = None
        if image_columns.get("photo_ids"):
            photos = None
        official_phone = self._normalize_contact(data.get("official_phone"))
        official_whatsapp = self._normalize_contact(data.get("official_whatsapp"))
        official_email = self._normalize_email(data.get("official_email"))
        text_values = {
            field: (data.get(field).strip() if isinstance(data.get(field), str) and data.get(field).strip() else None)
            for field in _TEXT_FIELDS
        }

        # Race-safe slug allocation. _unique_slug's existence check and
        # this insert are two separate statements, so two concurrent
        # requests for the same store name can both pass the check before
        # either commits - the DB's unique constraint on Store.slug is
        # still the actual source of truth, this loop just turns its
        # (rare) rejection into a fresh retry instead of an unhandled 500.
        # Not a distributed slug service - a bounded retry against a
        # single-node Postgres unique index is the appropriately-sized
        # fix for this scale.
        for _attempt in range(_MAX_SLUG_RETRIES):
            slug = await self._unique_slug(name)
            store = Store(
                owner_id=owner_id, name=name, slug=slug,
                logo_url=logo_url, photos=photos,
                official_phone=official_phone, official_whatsapp=official_whatsapp,
                official_email=official_email,
            )
            for field, value in text_values.items():
                setattr(store, field, value)
            for column, value in image_columns.items():
                setattr(store, column, value)

            self.db.add(store)
            try:
                await self.db.commit()
            except IntegrityError:
                # The only unique constraint on this table is slug, so
                # this can only mean someone else just took the slug we
                # checked was free a moment ago.
                await self.db.rollback()
                continue
            await self.db.refresh(store)
            return await self._store_dict(store)

        raise HTTPException(
            status_code=409,
            detail="Could not allocate a unique store name right now — please try again.",
        )

    # ── Read ──────────────────────────────────────────────────────────────

    async def list_stores(
        self,
        search: Optional[str] = None,
        specialization: Optional[str] = None,
        county: Optional[str] = None,
        limit: int = 20,
        offset: int = 0,
        with_total: bool = False,
    ):
        """Phase 4 (discovery): browse active stores. Inactive/paused
        stores are excluded here the same way an inactive store's own
        catalog is empty (see list_store_listings) - a paused business
        shouldn't surface in a directory, even though its direct link
        still resolves for someone who already has it."""
        q = select(Store).where(Store.is_active == True)  # noqa: E712
        if search:
            like = f"%{search.strip()}%"
            q = q.where(Store.name.ilike(like))
        if specialization:
            q = q.where(Store.specialization == specialization)
        if county:
            q = q.where(Store.county == county)

        total = None
        if with_total:
            count_q = select(func.count()).select_from(q.order_by(None).subquery())
            total = (await self.db.execute(count_q)).scalar_one()

        q = q.order_by(Store.created_at.desc()).limit(limit).offset(offset)
        stores = (await self.db.execute(q)).scalars().all()

        # N+1 FIX (implementation audit, spec §7/§25): this was
        # `[await self._store_dict(s) for s in stores]`, and _store_dict
        # issues its own COUNT(*) per store - so a 20-store directory page
        # cost 21 round trips, and the count query is the expensive one
        # (it scans listings, not stores). One grouped COUNT for the whole
        # page instead, passed down so _store_dict doesn't re-query.
        counts = await self._listing_counts_for([s.id for s in stores])
        assets = await self._assets_for(stores)
        items = [await self._store_dict(s, listing_count=counts.get(s.id, 0), assets=assets)
                 for s in stores]
        return {"items": items, "total": total} if with_total else items

    async def _listing_counts_for(self, store_ids: list[str]) -> dict[str, int]:
        """Active-listing counts for many stores in a single grouped query.

        Returns a plain dict so callers can .get(id, 0) - a store with no
        active listings produces no row in a GROUP BY and must still
        report 0 rather than going missing.
        """
        if not store_ids:
            return {}
        rows = (await self.db.execute(
            select(Listing.store_id, func.count())
            .where(Listing.store_id.in_(store_ids),
                   Listing.status == ListingStatus.active)
            .group_by(Listing.store_id)
        )).all()
        return {row[0]: row[1] for row in rows}

    async def get_store(self, store_id: str) -> dict:
        store = await self._get_or_404(store_id)
        return await self._store_dict(store)

    async def get_store_by_slug(self, slug: str) -> dict:
        r = await self.db.execute(select(Store).where(Store.slug == slug))
        store = r.scalar_one_or_none()
        if not store:
            raise HTTPException(status_code=404, detail="Store not found")
        return await self._store_dict(store)

    async def get_my_store(self, owner_id: str) -> Optional[dict]:
        """V1 UI only ever creates one store per user, but the schema
        doesn't enforce that (spec §4), so this resolves to the most
        recently created one rather than assuming there's exactly one.
        Returns None (not 404) when the user has no store yet - this is a
        normal, expected state for most users, not an error."""
        r = await self.db.execute(
            select(Store).where(Store.owner_id == owner_id)
            .order_by(Store.created_at.desc()).limit(1)
        )
        store = r.scalar_one_or_none()
        return await self._store_dict(store) if store else None

    async def list_store_listings(
        self, store_id: str, limit: int = 20, offset: int = 0, with_total: bool = False,
    ):
        store = await self._get_or_404(store_id)
        if not store.is_active:
            # A paused store keeps a visible profile (get_store above) but
            # shows an empty public catalog rather than erroring - a
            # shared store link should say "nothing listed right now", not
            # 404, since the business itself still exists.
            return {"items": [], "total": 0} if with_total else []

        return await ListingService(self.db).list_listings(
            store_id=store_id, limit=limit, offset=offset, with_total=with_total,
        )

    # ── Update ────────────────────────────────────────────────────────────

    async def update_store(self, store_id: str, requester_id: str, data: dict) -> dict:
        store = await self._get_or_404(store_id)
        self._require_owner(store, requester_id)

        new_name: Optional[str] = None
        if "name" in data:
            new_name = (data["name"] or "").strip()
            if not new_name:
                raise HTTPException(status_code=400, detail="Store name cannot be empty")
            if len(new_name) > _MAX_NAME_LEN:
                raise HTTPException(status_code=400, detail="Store name is too long")

        # Race-safe rename. A rollback (only reached on the rare slug
        # conflict below) expires every attribute this transaction set on
        # `store`, so every field assignment lives inside this loop and
        # gets re-applied on each attempt - only the slug itself actually
        # needs a fresh candidate each time.
        #
        # Hardening-pass note (spec §9 "canonical Store URL is stable"):
        # a rename DOES still change the slug below, so a previously-
        # shared public link (broka.co.ke/store/{old-slug}) 404s after a
        # rename. Real, known tradeoff, not an oversight - a slug-history
        # table with redirect-on-miss is a genuine feature, not something
        # this incremental hardening pass should invent unprompted. If
        # broken share links after a rename turn out to matter, that's
        # the shape of the fix: a small table of retired slugs per store,
        # checked in get_store_by_slug/the web page's lookup when the
        # primary slug misses, before falling through to 404.
        image_columns = await self._image_columns(requester_id, data)

        for _attempt in range(_MAX_SLUG_RETRIES):
            if new_name is not None and new_name != store.name:
                store.name = new_name
                store.slug = await self._unique_slug(new_name, exclude_store_id=store.id)

            for field in _TEXT_FIELDS:
                if field in data:
                    value = data[field]
                    setattr(store, field, value.strip() if isinstance(value, str) and value.strip() else None)
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
            if "official_phone" in data:
                store.official_phone = self._normalize_contact(data["official_phone"])
            if "official_whatsapp" in data:
                store.official_whatsapp = self._normalize_contact(data["official_whatsapp"])
            if "official_email" in data:
                store.official_email = self._normalize_email(data["official_email"])
            store.updated_at = datetime.utcnow()

            try:
                await self.db.commit()
            except IntegrityError:
                await self.db.rollback()
                await self.db.refresh(store)  # explicit reload before the next attempt reuses `store`
                continue
            await self.db.refresh(store)
            return await self._store_dict(store)

        raise HTTPException(
            status_code=409,
            detail="Could not save that name right now due to a naming conflict — please try again.",
        )

    async def set_store_status(self, store_id: str, requester_id: str, is_active: bool) -> dict:
        store = await self._get_or_404(store_id)
        self._require_owner(store, requester_id)
        store.is_active = is_active
        store.updated_at = datetime.utcnow()
        await self.db.commit()
        await self.db.refresh(store)
        return await self._store_dict(store)

    # ── Internals ─────────────────────────────────────────────────────────

    async def _get_or_404(self, store_id: str) -> Store:
        store = await self.db.get(Store, store_id)
        if not store:
            raise HTTPException(status_code=404, detail="Store not found")
        return store

    @staticmethod
    def _require_owner(store: Store, requester_id: str) -> None:
        # Ownership is checked against the authenticated requester_id the
        # router derived from the JWT (get_current_user) - never against
        # anything the client could put in a request body, per spec §22.
        if store.owner_id != requester_id:
            raise HTTPException(status_code=403, detail="You do not have permission to manage this store")

    async def _unique_slug(self, name: str, exclude_store_id: Optional[str] = None) -> str:
        """Deterministic base slug, then append -2/-3/... on collision so a
        duplicate business name never silently overwrites another store's
        slug (spec §23)."""
        base = slugify(name)
        candidate = base
        # BOUNDED (implementation audit, spec §6): this was `while True`,
        # one DB round trip per iteration, walking -2, -3, -4... with no
        # ceiling. Benign for two or three same-named shops; a pathological
        # case (many stores sharing a popular name, or a name that slugifies
        # to something generic like "store" - which slugify() returns for
        # any name with no alphanumerics at all, so every emoji-only store
        # name lands on it) turns store creation into an unbounded query
        # loop inside a request. After _MAX_SLUG_SUFFIX tries we stop
        # probing and take a short random suffix: still deterministic in
        # shape, still URL-safe, and the DB unique index remains the final
        # authority either way (see create_store's IntegrityError retry).
        for suffix in range(2, _MAX_SLUG_SUFFIX + 2):
            q = select(Store.id).where(Store.slug == candidate)
            if exclude_store_id:
                q = q.where(Store.id != exclude_store_id)
            existing = (await self.db.execute(q)).scalar_one_or_none()
            if not existing:
                return candidate
            candidate = f"{base}-{suffix}"
        return f"{base}-{uuid.uuid4().hex[:6]}"

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

    @staticmethod
    def _normalize_contact(raw: Optional[str]) -> Optional[str]:
        if not raw or not isinstance(raw, str):
            return None
        value = raw.strip()
        return value or None

    @staticmethod
    def _normalize_email(raw: Optional[str]) -> Optional[str]:
        if not raw or not isinstance(raw, str):
            return None
        value = raw.strip()
        if not value:
            return None
        # Light sanity check only, matching this codebase's existing
        # light-touch validation elsewhere - not a full RFC 5322 validator.
        if "@" not in value or " " in value:
            raise HTTPException(status_code=400, detail="official_email is not a valid email address")
        return value

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

    async def _store_dict(
        self, store: Store, listing_count: Optional[int] = None, assets: Optional[dict] = None,
    ) -> dict:
        # Was: SELECT every matching Listing.id, transfer all of them to
        # Python, then len(...) - correct but doesn't scale (a store with
        # thousands of active listings shipped thousands of id strings
        # over the wire just to count them). Now a real SQL COUNT(*),
        # never touching listing rows/ids at all.
        #
        # listing_count may be supplied by a caller that already counted
        # in bulk (see _listing_counts_for) - that is what keeps the store
        # directory at one count query for the whole page instead of one
        # per store. Single-store reads still fall through and count here.
        if listing_count is None:
            listing_count = (await self.db.execute(
                select(func.count()).select_from(Listing).where(
                    Listing.store_id == store.id, Listing.status == ListingStatus.active,
                )
            )).scalar_one()
        from api.domains.media.service import asset_urls, parse_id_list
        if assets is None:
            assets = await self._assets_for([store])
        logo = asset_urls(assets.get(store.logo_id)) if store.logo_id else None
        cover = asset_urls(assets.get(store.cover_id)) if store.cover_id else None
        photo_images = [
            asset_urls(assets[i]) for i in parse_id_list(store.photo_ids) if i in assets
        ]

        return {
            # Hardening-pass: owner_id was previously included here for
            # every caller, public or not - checked and confirmed nothing
            # in the Flutter app actually reads it (the "is this my
            # store" check compares store ids from GET /stores/mine, not
            # owner_id), so this was unnecessary internal-id exposure on
            # every public read with zero functional consumer. Removed
            # rather than made conditional-on-requester, since there's no
            # current use for it even to the owner.
            "id": store.id,
            "name": store.name,
            "slug": store.slug,
            # logo_url/photos stay plain strings for the current app: image
            # URLs once the store's images are assets, the legacy data URIs
            # until the media backfill has converted them.
            "logo_url": logo["medium"] if logo else store.logo_url,
            "photos": (
                [p["large"] for p in photo_images] if photo_images
                else parse_photo_list(store.photos)
            ),
            "logo": logo,
            "cover": cover,
            "photo_images": photo_images,
            "specialization": store.specialization,
            "description": store.description,
            "country": store.country,
            "county": store.county,
            "subcounty": store.subcounty,
            "location_description": store.location_description,
            "official_phone": store.official_phone,
            "official_whatsapp": store.official_whatsapp,
            "official_email": store.official_email,
            "is_active": bool(store.is_active),
            "listing_count": listing_count,
            "created_at": store.created_at.isoformat() if store.created_at else None,
            "updated_at": store.updated_at.isoformat() if store.updated_at else None,
        }
