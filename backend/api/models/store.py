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

from sqlalchemy import Boolean, Column, DateTime, ForeignKey, String, Text
from api.database import Base


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
    # Unique, URL-safe, never a raw display name (see slugify above and
    # StoreService._unique_slug for the collision-handling that keeps this
    # deterministic AND unique together). Powers GET /stores/slug/{slug}
    # and the future public broka.co.ke/store/{slug} page.
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

    specialization = Column(String, nullable=True)   # e.g. "Electronics"
    description    = Column(Text, nullable=True)

    country              = Column(String, nullable=False, default="Kenya")
    county               = Column(String, nullable=True)
    subcounty            = Column(String, nullable=True)
    location_description = Column(String, nullable=True)

    official_phone    = Column(String, nullable=True)
    official_whatsapp = Column(String, nullable=True)
    official_email     = Column(String, nullable=True)

    is_active  = Column(Boolean, default=True, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, index=True)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    # No relationship()/back_populates here on purpose: every existing
    # service in this codebase (ListingService, TradersService...) fetches
    # related rows via an explicit select(...) batch query rather than ORM
    # relationship traversal — see StoreService/ListingService for the
    # store<->listing lookups. Matching that keeps this model consistent
    # with how the rest of the codebase actually queries, and avoids any
    # async lazy-load surprise from an unused relationship attribute.
