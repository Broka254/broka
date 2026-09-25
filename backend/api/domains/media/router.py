"""Image upload and serving.

POST /media/images      Upload one image for a stated purpose. Returns the
                        asset id to send with the listing or store, and the
                        URL of each size.
GET  /media/i/{key}     Serve an image stored by the database driver. Images
                        on R2 are served by R2's own domain and never come
                        through here.
GET  /media/og/{id}.jpg An image's 1200x630 JPEG link preview (og:image) for
                        the web storefront, made the first time it's asked
                        for and stored with the image's other sizes.

Mounted at /media alongside the older negotiation-media router
(api/routers/media.py), whose paths (/upload, /ws/...) don't overlap.
"""
from __future__ import annotations

import re

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import RedirectResponse, Response
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.image_processing import MAX_UPLOAD_BYTES, ImageRejected
from api.core.media_storage import CACHE_FOREVER, StorageError, storage_named
from api.database import get_db
from api.models.media import MediaPurpose
from api.security import get_current_user
from .service import PREVIEWABLE, asset_urls, create_image_asset, link_preview, load_assets

router = APIRouter()

# Exactly the keys create_image_asset writes. Anything else is a 404
# without a database lookup.
_KEY_RE = re.compile(r"^img/[0-9a-f-]{36}/((thumb|medium|large)\.webp|og\.jpg)$")
_ASSET_ID_RE = re.compile(r"^[0-9a-f-]{36}$")


@router.post("/images", status_code=201)
async def upload_image(
    file: UploadFile = File(...),
    purpose: str = Form(...),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if purpose not in MediaPurpose.UPLOADABLE:
        raise HTTPException(
            status_code=422,
            detail=f"purpose must be one of: {', '.join(sorted(MediaPurpose.UPLOADABLE))}",
        )
    from api.core.rate_limit import image_upload_daily_limiter, image_upload_limiter
    await image_upload_limiter.check_and_record(current_user["id"])
    await image_upload_daily_limiter.check_and_record(current_user["id"])

    # Bounded read: one byte past the limit is enough to know it's too big,
    # without buffering whatever size the client chose to send.
    raw = await file.read(MAX_UPLOAD_BYTES + 1)
    if len(raw) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Images must be 10 MB or smaller.")

    try:
        asset = await create_image_asset(db, current_user["id"], purpose, raw)
    except ImageRejected as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except StorageError:
        await db.rollback()
        raise HTTPException(status_code=503, detail="Couldn't save the image right now. Please try again.")
    await db.commit()
    return {**asset_urls(asset), "purpose": asset.purpose}


@router.get("/i/{key:path}")
async def serve_image(key: str):
    if not _KEY_RE.match(key):
        raise HTTPException(status_code=404, detail="Not found")
    found = await storage_named("db").get(key)
    if found is None:
        raise HTTPException(status_code=404, detail="Not found")
    data, content_type = found
    return Response(
        content=data,
        media_type=content_type,
        headers={"Cache-Control": CACHE_FOREVER},
    )


@router.get("/og/{asset_id}.jpg")
async def link_preview_image(asset_id: str, db: AsyncSession = Depends(get_db)):
    """og:image for store and product pages: a JPEG, because WhatsApp
    doesn't show WebP previews. Public, like the image itself."""
    if not _ASSET_ID_RE.match(asset_id):
        raise HTTPException(status_code=404, detail="Not found")
    asset = (await load_assets(db, [asset_id])).get(asset_id)
    if asset is None or asset.purpose not in PREVIEWABLE:
        raise HTTPException(status_code=404, detail="Not found")
    try:
        made = await link_preview(db, asset)
    except StorageError:
        await db.rollback()
        raise HTTPException(status_code=503, detail="Preview unavailable right now")
    if made is None:
        raise HTTPException(status_code=404, detail="Not found")
    key, fresh = made
    storage = storage_named(asset.storage)
    url = storage.public_url(key)
    # R2 serves its own files; everything else is served from here.
    if fresh is None and url.startswith("https://") and asset.storage == "r2":
        return RedirectResponse(url, status_code=302, headers={"Cache-Control": "public, max-age=86400"})
    data = fresh
    if data is None:
        found = await storage.get(key)
        if found is None:
            raise HTTPException(status_code=404, detail="Not found")
        data = found[0]
    return Response(content=data, media_type="image/jpeg", headers={"Cache-Control": CACHE_FOREVER})
