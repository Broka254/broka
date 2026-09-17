"""Stores Router V1.

Route order matters for one pair here: GET "/mine" must be registered
before GET "/{store_id}", or FastAPI would try to resolve a request to
/stores/mine as store_id="mine" first (same reasoning as GET /stats
being registered before GET /{listing_id} in listings/router.py).
GET "/slug/{slug}" has no such conflict (it's a two-segment path), but is
kept nearby for readability.

Auth is required for create/update/status (spec §6 - "Require
authentication for: create store, edit store, manage store status,
associate/disassociate listings with a store"); read endpoints (get by
id, get by slug, list a store's listings) are public and use no auth
dependency at all, matching spec §15 ("Do not put authentication
barriers in front of basic Store browsing") and the same
get_current_user-free pattern GET /listings/{listing_id} already uses.
"""
from __future__ import annotations

from typing import List, Optional
from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.security import get_current_user
from .service import StoreService

router = APIRouter()

# Maximum rows any single paginated store read may return. Chosen to be
# comfortably above a real store-management page size while keeping the
# worst-case response bounded - store rows carry inline base64 media.
_MAX_PAGE_SIZE = 100


class StoreIn(BaseModel):
    name: str
    specialization: Optional[str] = None
    description: Optional[str] = None
    county: Optional[str] = None
    subcounty: Optional[str] = None
    location_description: Optional[str] = None
    official_phone: Optional[str] = None
    official_whatsapp: Optional[str] = None
    official_email: Optional[str] = None
    logo_url: Optional[str] = None
    photos: Optional[List[str]] = None


class StorePatch(BaseModel):
    name: Optional[str] = None
    specialization: Optional[str] = None
    description: Optional[str] = None
    county: Optional[str] = None
    subcounty: Optional[str] = None
    location_description: Optional[str] = None
    official_phone: Optional[str] = None
    official_whatsapp: Optional[str] = None
    official_email: Optional[str] = None
    logo_url: Optional[str] = None
    photos: Optional[List[str]] = None


class StoreStatusIn(BaseModel):
    is_active: bool


@router.post("", status_code=201)
async def create_store(
    body: StoreIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = StoreService(db)
    return await svc.create_store(current_user["id"], body.model_dump())


@router.get("")
async def list_stores(
    search: Optional[str] = None,
    specialization: Optional[str] = None,
    county: Optional[str] = None,
    # BOUNDED (implementation audit, spec §25): `limit: int = 20` with no
    # ceiling meant ?limit=1000000 returned the entire stores table in one
    # unauthenticated request - and each row carries a base64 logo and
    # photo list, so the response is heavy per row, not just long. ge/le
    # make FastAPI reject it as a 422 before any query runs.
    limit: int = Query(20, ge=1, le=_MAX_PAGE_SIZE),
    offset: int = Query(0, ge=0),
    with_total: bool = False,
    db: AsyncSession = Depends(get_db),
):
    """Phase 4: browse/search active stores - public, no auth required,
    same as every other read endpoint in this router."""
    svc = StoreService(db)
    return await svc.list_stores(
        search=search, specialization=specialization, county=county,
        limit=limit, offset=offset, with_total=with_total,
    )


@router.get("/mine")
async def get_my_store(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Returns the current user's store, or null if they don't have one
    yet - this is the check the Flutter "Store Mode" entry point uses
    (spec §9/§10), so it deliberately returns 200+null rather than 404 for
    the very common case of a user with no store."""
    svc = StoreService(db)
    return await svc.get_my_store(current_user["id"])


@router.get("/slug/{slug}")
async def get_store_by_slug(slug: str, db: AsyncSession = Depends(get_db)):
    svc = StoreService(db)
    return await svc.get_store_by_slug(slug)


@router.get("/{store_id}")
async def get_store(store_id: str, db: AsyncSession = Depends(get_db)):
    svc = StoreService(db)
    return await svc.get_store(store_id)


@router.patch("/{store_id}")
async def update_store(
    store_id: str,
    body: StorePatch,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = StoreService(db)
    # exclude_unset, not exclude_none: a field the client omitted entirely
    # must leave that column untouched, but a field sent as null/"" is the
    # client deliberately clearing it - conflating the two would make it
    # impossible to ever blank out an optional field once set.
    return await svc.update_store(store_id, current_user["id"], body.model_dump(exclude_unset=True))


@router.post("/{store_id}/status")
async def set_store_status(
    store_id: str,
    body: StoreStatusIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = StoreService(db)
    return await svc.set_store_status(store_id, current_user["id"], body.is_active)


@router.get("/{store_id}/listings")
async def get_store_listings(
    store_id: str,
    # Same ceiling as the store directory above. This is also the endpoint
    # the owner's own store-management screen pages through, so the cap
    # has to be high enough for a real merchant catalog page while still
    # ruling out "fetch the whole inventory in one request" (spec §11/§25).
    limit: int = Query(20, ge=1, le=_MAX_PAGE_SIZE),
    offset: int = Query(0, ge=0),
    with_total: bool = False,
    db: AsyncSession = Depends(get_db),
):
    svc = StoreService(db)
    return await svc.list_store_listings(store_id, limit=limit, offset=offset, with_total=with_total)
