"""
BROKA - Store Model
====================
A Store is a first-class, ownable business identity that sits ABOVE a
User's personal Listings — not a replacement for them:

    User
     ├── personal Listings   (Listing.store_id IS NULL)
     └── Store
          └── Listings       (Listing.store_id == Store.id)

This is deliberately a different concept from Trader
(api/domains/traders/) — Trader stays exactly as it was designed
(Design Journal Volume 6, Ch.5: "Trader == User", a read-only view
derived from User + UserSpecialization + a Listing count). A Store is
the opposite: a genuinely new, editable row with its own id, its own
branding/location/contact fields, and a unique public slug. Listings
opt into a Store explicitly via Listing.store_id (see that column's
comment in api/database.py) — a Store's catalog is always
`SELECT * FROM listings WHERE store_id = :this_store_id`, never a
second product table.

A user can have personal listings and a Store at the same time; owning
a Store never removes seller_id from a Listing (seller_id = who is
legally/operationally responsible for it; store_id = which business it
is merchandised under, if any).

New table -> picked up automatically by Base.metadata.create_all() in
api/database.py's init_db(), same mechanism as api/models/dispute.py's
DisputeCase/etc and api/models/escrow_ledger.py's LedgerEntry before it.
No Alembic migration file for this — this repo's own
api/core/migrations_guide.py and api/database.py's init_db() both
establish the actual convention: brand-new TABLES arrive via
create_all() picking up a newly-imported model class; new COLUMNS on
an EXISTING table (Listing.store_id, added in api/database.py) go
through that same function's manual `migrations` ALTER-TABLE list
instead, since create_all() never alters a table that already exists.
"""
from __future__ import annotations

import re
import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean, Column, Date, DateTime, Float, ForeignKey, Index, Integer, String, Text,
    UniqueConstraint,
)
from api.database import Base

# The two ways a business trades on BROKA. A physical store has premises a
# customer can visit; a virtual store sells online only. The type is stored,
# validated and used - it decides which setup fields are required, whether a
# map point is published, and how the storefront describes the business. It
# is deliberately a plain String + an application-side check rather than a
# native PostgreSQL ENUM: adding a value to an enum needs ALTER TYPE, which
# init_db's migrations cannot run (see api/database.py).
STORE_TYPES = ("physical", "virtual")
DEFAULT_STORE_TYPE = "physical"


def slugify(value: str) -> str:
    """Deterministic, URL-safe normalization: lowercase, alphanumerics and
    hyphens only, collapsed and trimmed. 'Clanix Electronics' ->
    'clanix-electronics'. This only normalizes text — it does NOT guarantee
    uniqueness; duplicate-name collision handling (append -2, -3, ...) is
    the caller's job, see StoreService._unique_slug, so a store name never
    silently overwrites another store's slug."""
    value = (value or "").strip().lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = value.strip("-")
    return value or "store"


class Store(Base):
    """A business/store identity, owned by exactly one User (owner_id).
    V1 UI only lets a user manage one active store, but the schema itself
    does not enforce a one-user-one-store constraint (no unique index on
    owner_id alone) — deliberately, per the spec, so a real multi-store
    owner isn't an architectural rewrite later, just a UI change."""
    __tablename__ = "stores"

    id       = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    owner_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)

    name = Column(String, nullable=False)
    # The store's link name: broka.co.ke/store/{slug}. Chosen by the owner
    # when the store is set up (rules in api/domains/stores/naming.py) and
    # fixed from then on - the link is printed on flyers and shared in
    # WhatsApp groups, so renaming the store never changes it. Stores made
    # by app builds that don't send one get a name derived from the store
    # name (StoreService._unique_slug).
    slug = Column(String, nullable=False, unique=True, index=True)

    # Branding/media. Same "JSON-as-Text" convention this codebase already
    # uses for Listing.attributes/verified_photos — see
    # api/domains/stores/media.py for the small abstraction that reads/
    # writes this field, isolating the inline-base64-today reality from
    # callers so a future object-storage swap (Cloudflare R2) touches one
    # file, not every place a store photo is read.
    logo_url = Column(Text, nullable=True)
    photos   = Column(Text, nullable=True)   # JSON list of media-item dicts
    # Image assets (api/models/media.py) - what the store's images really
    # are from Online Stores phase 1 on. logo_url/photos above only hold
    # base64 sent by app builds that predate assets, until the media
    # backfill converts it and clears them. NULL = unset or not converted
    # yet; "" / "[]" = legacy data that couldn't be converted.
    logo_id   = Column(String, nullable=True)
    cover_id  = Column(String, nullable=True)
    photo_ids = Column(Text, nullable=True)   # ordered JSON list of asset ids

    # One of BROKA's top-level categories (api/domains/categories/seed.py).
    # Replaces `specialization`, a free-text value from an older 11-item
    # list; stores that only have that are mapped on read
    # (api/domains/stores/categories.py).
    category       = Column(String, nullable=True)
    specialization = Column(String, nullable=True)   # legacy, see category
    description    = Column(Text, nullable=True)

    # "physical" | "virtual" (STORE_TYPES). Existing rows were all shops you
    # could walk into, so the migration gives them "physical" - the migration
    # must never invent a type from missing data.
    store_type           = Column(
        String(16), nullable=False, default=DEFAULT_STORE_TYPE,
        server_default=DEFAULT_STORE_TYPE,
    )

    # Structured weekly opening hours, JSON text:
    #   {"mon": {"open": "08:00", "close": "18:00"}, ..., "sun": null}
    # A day is null/absent when closed, {"all_day": true} for 24 hours, or an
    # open/close pair. close <= open is a window that crosses midnight (a
    # kiosk open 20:00-02:00); api/domains/stores/opening_hours.py validates
    # it and computes "Open now" in Africa/Nairobi. NULL = not provided -
    # an unset schedule is unknown, never "closed".
    opening_hours        = Column(Text, nullable=True)

    # Where the store delivers or serves customers, JSON list. Either a list
    # of Kenya's counties or the single entry ["Nationwide"]. This is
    # delivery coverage, NOT the shop's address: a shop in Kisumu can serve
    # the whole country, and a virtual store can serve one county. NULL = not
    # stated, which is not the same as "nowhere".
    service_areas        = Column(Text, nullable=True)
    # Free text on how delivery/collection works ("Same-day in Kisumu,
    # courier elsewhere"). Optional; never a promise BROKA makes.
    delivery_note        = Column(String(200), nullable=True)

    country              = Column(String, nullable=False, default="Kenya")
    county               = Column(String, nullable=True)
    subcounty            = Column(String, nullable=True)
    location_description = Column(String, nullable=True)
    # The shop's own pin, captured in the setup wizard. Stores used to
    # borrow their owner's account point for "near you", so a shop read
    # as wherever its owner happened to sign up. NULL = no pin set; reads
    # fall back to the owner's point (see stores/service.py).
    lat = Column(Float, nullable=True)
    lng = Column(Float, nullable=True)

    # No longer read or written: buyers reach a store through BROKA's own
    # chat and checkout. Kept so existing rows aren't disturbed.
    official_phone    = Column(String, nullable=True)
    official_whatsapp = Column(String, nullable=True)
    # The store's business email (API name: business_email). Optional.
    # business_email_verified says the owner proved they receive mail
    # there; only a verified address is used to send anything.
    official_email          = Column(String, nullable=True)
    business_email_verified = Column(Boolean, default=False, nullable=False)

    is_active  = Column(Boolean, default=True, nullable=False)
    # The store's own rating, 0-10, computed from its reviews, its own
    # reply time and how long it has traded (api/domains/stores/rating.py).
    # Deliberately a STORE number, not User.rating: a seller with two shops
    # must not have one shop's record lift the other. Null only on rows
    # created before the rating shipped; the startup backfill fills them.
    rating                  = Column(Float, nullable=True, index=True)
    rating_reviews          = Column(Integer, nullable=False, default=0)
    rating_response_minutes = Column(Float, nullable=True)
    # The components the number is built from, stored beside it so a store
    # payload needs no extra query and the owner's breakdown cannot drift
    # from the rating it explains.
    rating_review_component   = Column(Float, nullable=True)
    rating_response_component = Column(Float, nullable=True)
    rating_tenure_component   = Column(Float, nullable=True)
    rating_updated_at       = Column(DateTime, nullable=True)
    # Deleting a store is a soft delete, exactly like a listing's
    # (ListingService.delete_listing): the row stays so its listings,
    # payments and audit trail keep pointing at something real, while the
    # store itself is gone from every buyer-facing read. The slug stays
    # reserved too - a dead link must never start showing a different
    # shop's goods.
    deleted_at = Column(DateTime, nullable=True, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, index=True)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    # No relationship()/back_populates here on purpose: every existing
    # service in this codebase (ListingService, TradersService...) fetches
    # related rows via an explicit select(...) batch query rather than ORM
    # relationship traversal — see StoreService/ListingService for the
    # store<->listing lookups. Matching that keeps this model consistent
    # with how the rest of the codebase actually queries, and avoids any
    # async lazy-load surprise from an unused relationship attribute.


class StoreCategoryLink(Base):
    """One category a store sells in; a store has one row per category it
    chose. `Store.category` stays the primary (the first chosen) for app
    builds and payloads that predate this table; these links are what the
    directory's category filter reads, so a shop that sells across several
    categories is found in each of them. Two or more links is also what
    the "Wholesale and General" rail entry lists - a storefront facet,
    not a taxonomy category: the canonical list in
    api/domains/categories/seed.py is untouched."""
    __tablename__ = "store_category_links"
    __table_args__ = (
        UniqueConstraint("store_id", "category", name="uq_store_category_link"),
    )

    id       = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    store_id = Column(String, ForeignKey("stores.id"), nullable=False, index=True)
    category = Column(String, nullable=False, index=True)


class StoreDailyCount(Base):
    """Per-day counters behind a store owner's stats: storefront visits
    and share-button taps.

    One row per (store, day, kind, surface, source), incremented in place -
    never one row per visit - so the table grows by at most a handful of
    rows per store per day however busy the store is, and a 7-day chart is
    a small indexed read.

      kind    "visit" or "share"
      surface where it happened: "app" or "web"
      source  visits: where the visitor came from (whatsapp, tiktok,
              instagram, facebook, x, qr, direct, other); shares: the
              channel the owner or a buyer shared to (whatsapp, ..., copy,
              qr, other)

    Counting rules (de-duplication, the owner's own visits) live in
    api/domains/stores/stats.py.
    """
    __tablename__ = "store_daily_counts"
    __table_args__ = (
        UniqueConstraint("store_id", "day", "kind", "surface", "source",
                         name="uq_store_daily_count"),
    )

    id       = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    store_id = Column(String, ForeignKey("stores.id"), nullable=False, index=True)
    day      = Column(Date, nullable=False)
    kind     = Column(String(16), nullable=False)
    surface  = Column(String(8), nullable=False)
    source   = Column(String(16), nullable=False)
    count    = Column(Integer, nullable=False, default=0)


class StoreRatingSnapshot(Base):
    """One row per store per day: the rating and the components behind it.

    Same argument as SellerMetricSnapshot. The rating is computable today,
    but not reconstructible tomorrow: response time is a rolling 30-day
    window and review averages move with every new review, so yesterday's
    line cannot be redrawn from today's tables. Written by the daily
    refresh in api/domains/stores/rating.py.
    """
    __tablename__ = "store_rating_snapshots"
    __table_args__ = (
        UniqueConstraint("store_id", "snapshot_date", name="uq_store_rating_day"),
        Index("ix_store_rating_snapshot", "store_id", "snapshot_date"),
    )

    id                  = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    store_id            = Column(String, ForeignKey("stores.id"), nullable=False, index=True)
    snapshot_date       = Column(Date, nullable=False, index=True)

    rating              = Column(Float, nullable=True)   # 0-10
    review_component    = Column(Float, nullable=True)   # 0-1
    response_component  = Column(Float, nullable=True)   # 0-1
    tenure_component    = Column(Float, nullable=True)   # 0-1
    review_count        = Column(Integer, nullable=True)
    response_minutes    = Column(Float, nullable=True)
    created_at          = Column(DateTime, default=datetime.utcnow)
