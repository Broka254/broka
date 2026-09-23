"""Where image bytes live: Cloudflare R2, or the database as a fallback.

Two drivers with one interface, so nothing above this file knows which is
in use:

  R2Storage        Objects in the R2 bucket, served straight from its
                   public domain (MEDIA_PUBLIC_BASE_URL). The production
                   setup: images never touch the API process once uploaded,
                   and the web storefront and link previews get real image
                   URLs.
  DatabaseStorage  Bytes in the media_blobs table, served by
                   GET /media/i/{key}. Used whenever R2 isn't fully
                   configured - dev, tests, and a deployment that hasn't
                   set the R2 variables yet - so no feature waits on
                   infrastructure.

Keys are immutable ("img/<asset id>/<size>.webp"): a new upload is a new
asset with new keys, never an overwrite. That is what lets every response
be cached forever.

Each MediaAsset records the driver it was written with (`storage`), and
URLs are built with that driver, so turning R2 on doesn't strand images
already in the database.
"""
from __future__ import annotations

import asyncio
import logging
from abc import ABC, abstractmethod
from typing import Optional

from api.core.config import settings

logger = logging.getLogger(__name__)

CACHE_FOREVER = "public, max-age=31536000, immutable"


class StorageError(Exception):
    """A storage operation failed. The upload that caused it fails cleanly
    rather than leaving an asset row that points at nothing."""


class ImageStorage(ABC):
    name: str

    @abstractmethod
    async def put(self, key: str, data: bytes, content_type: str) -> None: ...

    @abstractmethod
    async def get(self, key: str) -> Optional[tuple[bytes, str]]:
        """(bytes, content type), or None if there is no such object."""

    @abstractmethod
    def public_url(self, key: str) -> str: ...


class DatabaseStorage(ImageStorage):
    name = "db"

    async def put(self, key: str, data: bytes, content_type: str) -> None:
        # Its own short session: the blob must exist before the asset row
        # that points at it is committed by the caller, and a failure here
        # must not roll back the caller's unrelated work.
        from api.database import AsyncSessionLocal
        from api.models.media import MediaBlob
        try:
            async with AsyncSessionLocal() as db:
                await db.merge(MediaBlob(key=key, content_type=content_type, data=data))
                await db.commit()
        except Exception as exc:
            raise StorageError(f"database put failed: {type(exc).__name__}") from exc

    async def get(self, key: str) -> Optional[tuple[bytes, str]]:
        from api.database import AsyncSessionLocal
        from api.models.media import MediaBlob
        async with AsyncSessionLocal() as db:
            blob = await db.get(MediaBlob, key)
            return (blob.data, blob.content_type) if blob else None

    def public_url(self, key: str) -> str:
        return f"{settings.public_api_base_url}/media/i/{key}"


class R2Storage(ImageStorage):
    """Cloudflare R2 through its S3-compatible API.

    boto3 is synchronous, so every call runs in a worker thread. The client
    is created on first use and reused; boto3 clients are thread-safe.
    """
    name = "r2"

    def __init__(self, client=None, bucket: Optional[str] = None,
                 public_base_url: Optional[str] = None):
        self._client = client
        self._bucket = bucket or settings.r2_bucket
        self._public_base_url = (public_base_url or settings.media_public_base_url).rstrip("/")

    def _get_client(self):
        if self._client is None:
            import boto3
            from botocore.config import Config
            self._client = boto3.client(
                "s3",
                endpoint_url=f"https://{settings.r2_account_id}.r2.cloudflarestorage.com",
                aws_access_key_id=settings.r2_access_key_id,
                aws_secret_access_key=settings.r2_secret_access_key,
                region_name="auto",
                config=Config(
                    signature_version="s3v4",
                    retries={"max_attempts": 3, "mode": "standard"},
                    connect_timeout=5,
                    read_timeout=20,
                ),
            )
        return self._client

    async def put(self, key: str, data: bytes, content_type: str) -> None:
        client = self._get_client()
        try:
            await asyncio.to_thread(
                client.put_object,
                Bucket=self._bucket,
                Key=key,
                Body=data,
                ContentType=content_type,
                CacheControl=CACHE_FOREVER,
            )
        except Exception as exc:
            # The exception text can include the endpoint; the log line says
            # what failed without repeating credentials-adjacent detail.
            logger.error("[media] R2 put failed key=%s: %s", key, type(exc).__name__)
            raise StorageError(f"R2 put failed: {type(exc).__name__}") from exc

    async def get(self, key: str) -> Optional[tuple[bytes, str]]:
        client = self._get_client()

        def _fetch():
            try:
                obj = client.get_object(Bucket=self._bucket, Key=key)
            except Exception as exc:
                code = getattr(exc, "response", {}).get("Error", {}).get("Code")
                if code in ("NoSuchKey", "404"):
                    return None
                raise
            return obj["Body"].read(), obj.get("ContentType") or "application/octet-stream"

        try:
            return await asyncio.to_thread(_fetch)
        except Exception as exc:
            raise StorageError(f"R2 get failed: {type(exc).__name__}") from exc

    def public_url(self, key: str) -> str:
        return f"{self._public_base_url}/{key}"


# ── Selection ─────────────────────────────────────────────────────────────────

_drivers: dict[str, ImageStorage] = {}
_override: Optional[ImageStorage] = None


def use_storage(storage: Optional[ImageStorage]) -> None:
    """Tests: make `storage` the driver for new writes and for its own name.
    Pass None to go back to configuration-driven selection."""
    global _override
    _override = storage
    _drivers.clear()


def current_storage() -> ImageStorage:
    """The driver new uploads are written with."""
    if _override is not None:
        return _override
    return storage_named("r2" if settings.r2_configured else "db")


def storage_named(name: str) -> ImageStorage:
    """The driver an existing asset was written with (MediaAsset.storage)."""
    if _override is not None and _override.name == name:
        return _override
    if name not in _drivers:
        _drivers[name] = R2Storage() if name == "r2" else DatabaseStorage()
    return _drivers[name]
