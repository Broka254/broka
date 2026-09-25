"""Image assets - one uploaded image, stored as a few resized WebP files.

A `MediaAsset` is what listings, stores and avatars point at (by id) instead
of carrying image bytes as base64 text in their own rows. Each asset holds
the storage keys of its sizes (see api/core/image_processing.VARIANTS); the
bytes live in Cloudflare R2, or in `media_blobs` when R2 isn't configured.

`storage` records which of those two an asset was written to, so its URLs
keep resolving correctly if R2 is configured later - an asset written to the
database stays served from the database until something moves it.

New tables, so init_db()'s create_all() creates them; see
api/core/migrations_guide.py.
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime

from sqlalchemy import Column, DateTime, ForeignKey, Index, Integer, LargeBinary, String, Text

from api.database import Base


class MediaPurpose:
    """What an image is for. Checked when a listing or store references an
    asset, so a store logo can't be passed off as a listing photo, and an
    asset can't be attached somewhere it wasn't uploaded for."""
    LISTING_PHOTO    = "listing_photo"
    LISTING_SHOWCASE = "listing_showcase"
    STORE_LOGO       = "store_logo"
    STORE_COVER      = "store_cover"
    STORE_PHOTO      = "store_photo"
    AVATAR           = "avatar"

    ALL = frozenset({
        LISTING_PHOTO, LISTING_SHOWCASE, STORE_LOGO, STORE_COVER, STORE_PHOTO, AVATAR,
    })
    # What a client may upload directly. Avatars are converted server-side
    # from the profile photo the signup and profile flows already send.
    UPLOADABLE = ALL - {AVATAR}


class AttachState:
    """Whether anything has ever used an asset - what decides if an
    unused upload may be cleaned up (api/domains/media/cleanup.py).

    pending   uploaded, not yet part of a listing, store or profile. An
              abandoned sell or store-setup wizard leaves these behind;
              after ABANDONED_AFTER they are deleted.
    attached  used at least once. Kept for good, even if later replaced:
              a listing's old photos can matter to a dispute.
    legacy    written before this was tracked. Never cleaned up - nothing
              says whether it was used.
    deleting  being cleaned up; its files are removed, then -> purged.
    purged    cleaned up. The row stays as a record; it serves nothing.
    """
    PENDING = "pending"
    ATTACHED = "attached"
    LEGACY = "legacy"
    DELETING = "deleting"
    PURGED = "purged"


class MediaAsset(Base):
    __tablename__ = "media_assets"
    __table_args__ = (
        Index("ix_media_assets_attach_state_created", "attach_state", "created_at"),
    )

    id         = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    owner_id   = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    purpose    = Column(String(32), nullable=False)
    # "r2" | "db" - see the module docstring.
    storage    = Column(String(8), nullable=False)
    width      = Column(Integer, nullable=False)
    height     = Column(Integer, nullable=False)
    # Of the uploaded bytes. Lets a re-upload of the same file be spotted
    # later; not unique, since two owners may upload the same image.
    sha256     = Column(String(64), nullable=False, index=True)
    # JSON: {"thumb": {"key": ..., "w": ..., "h": ..., "bytes": ...}, ...}
    variants   = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    deleted_at = Column(DateTime, nullable=True)
    # See AttachState. New rows start "pending"; rows that existed before
    # the column did get the server default, "legacy".
    attach_state = Column(
        String(12), nullable=False, default=AttachState.PENDING, server_default=AttachState.LEGACY,
    )

    def variant_map(self) -> dict:
        try:
            value = json.loads(self.variants or "{}")
        except (TypeError, ValueError):
            return {}
        return value if isinstance(value, dict) else {}


class MediaBlob(Base):
    """Image bytes for the database storage driver. Keyed by the same
    storage key an R2 object would have, so the two drivers are
    interchangeable to everything above them."""
    __tablename__ = "media_blobs"

    key          = Column(String, primary_key=True)
    content_type = Column(String(64), nullable=False)
    data         = Column(LargeBinary, nullable=False)
    created_at   = Column(DateTime, default=datetime.utcnow, nullable=False)
