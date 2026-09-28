"""Stores router.

Route order matters: the fixed paths ("/mine", "/name-available",
"/email/...") must be registered before GET "/{store_id}", or FastAPI
would read /stores/mine as store_id="mine".

Creating and managing a store needs a signed-in owner; reading a store and
its catalogue is public - browsing a store someone shared must never hit
a sign-in wall.
"""
from __future__ import annotations

from typing import List, Literal, Optional
from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.client_ip import client_ip
from api.core.rate_limit import (
    otp_request_limiter, otp_verify_limiter, store_counter_limiter, store_name_check_limiter,
)
from api.database import OtpPurpose, get_db
from api.security import get_current_user, get_current_user_optional
from . import stats as store_stats
from .service import StoreService

router = APIRouter()

_MAX_PAGE_SIZE = 100


class StoreIn(BaseModel):
    name: str = Field(max_length=200)
    # The link name (broka.co.ke/store/<slug>), chosen in the setup
    # wizard. Optional only for app builds that predate it; those get one
    # derived from the name.
    slug: Optional[str] = Field(default=None, max_length=64)
    category: Optional[str] = None
    description: Optional[str] = None
    county: Optional[str] = None
    subcounty: Optional[str] = None
    location_description: Optional[str] = None
    # Optional. A new address needs business_email_token from
    # POST /stores/email/verify, unless it's the owner's verified account
    # email.
    business_email: Optional[str] = None
    business_email_token: Optional[str] = None
    # Image assets from POST /media/images: purposes store_logo,
    # store_cover and store_photo.
    logo_id: Optional[str] = None
    cover_id: Optional[str] = None
    photo_ids: Optional[List[str]] = Field(default=None, max_length=6)
    # Sent by app builds before phase 2: specialization -> category,
    # official_email -> an unverified business email, logo_url/photos are
    # base64 converted by the media backfill.
    specialization: Optional[str] = None
    official_email: Optional[str] = None
    logo_url: Optional[str] = None
    photos: Optional[List[str]] = None


class StorePatch(BaseModel):
    name: Optional[str] = Field(default=None, max_length=200)
    # Accepted only when unchanged: a store's link is fixed once it opens.
    slug: Optional[str] = Field(default=None, max_length=64)
    category: Optional[str] = None
    description: Optional[str] = None
    county: Optional[str] = None
    subcounty: Optional[str] = None
    location_description: Optional[str] = None
    business_email: Optional[str] = None
    business_email_token: Optional[str] = None
    logo_id: Optional[str] = None
    cover_id: Optional[str] = None
    photo_ids: Optional[List[str]] = Field(default=None, max_length=6)
    specialization: Optional[str] = None
    official_email: Optional[str] = None
    logo_url: Optional[str] = None
    photos: Optional[List[str]] = None


class StoreStatusIn(BaseModel):
    is_active: bool


class EmailCodeIn(BaseModel):
    email: str = Field(max_length=254)


class EmailVerifyIn(BaseModel):
    email: str = Field(max_length=254)
    code: str = Field(max_length=12)


class VisitIn(BaseModel):
    # The ?via= tag of the link that opened the store, if any. Shortened,
    # not refused: the app passes on the tag of whatever link opened it,
    # and a longer one made the whole visit a 422 that was never counted.
    # An unknown tag counts as "other" either way (stats.visit_source).
    via: Optional[str] = Field(default=None, max_length=512)
    # "web": the web storefront, reporting from the visitor's browser.
    surface: Literal["app", "web"] = "app"
    # The web page's document.referrer, where visitors came from when the
    # link had no ?via= tag.
    referrer: Optional[str] = Field(default=None, max_length=512)
    # A random id the web storefront keeps in the browser, so a returning
    # visitor is recognised without relying on IP addresses (behind the
    # hosting proxy, many visitors can share one).
    visitor: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9_-]{8,64}$")

    @field_validator("via")
    @classmethod
    def _short_via(cls, v: Optional[str]) -> Optional[str]:
        return store_stats.short_via(v)


class ShareIn(BaseModel):
    channel: str = Field(max_length=32)
    surface: Literal["app", "web"] = "app"


def _client_key(request: Request, current_user: Optional[dict]) -> str:
    """Who is really calling, for limits: the signed-in user, else the
    caller's IP address (api/core/client_ip.py). Never anything taken from
    the request body - a value the caller picks is no limit at all."""
    if current_user:
        return f"user:{current_user['id']}"
    return f"ip:{client_ip(request)}"


@router.post("", status_code=201)
async def create_store(
    body: StoreIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # exclude_unset: a field the client didn't send is "not given", which
    # matters where an old field and its replacement are both accepted.
    return await StoreService(db).create_store(
        current_user["id"], body.model_dump(exclude_unset=True),
    )


@router.get("")
async def list_stores(
    search: Optional[str] = Query(None, max_length=100),
    category: Optional[str] = None,
    # Old name of `category`, still sent by app builds before phase 2.
    specialization: Optional[str] = None,
    county: Optional[str] = None,
    limit: int = Query(20, ge=1, le=_MAX_PAGE_SIZE),
    offset: int = Query(0, ge=0),
    with_total: bool = False,
    db: AsyncSession = Depends(get_db),
):
    """Browse active stores. Public."""
    return await StoreService(db).list_stores(
        search=search, category=category or specialization, county=county,
        limit=limit, offset=offset, with_total=with_total,
    )


@router.get("/mine")
async def get_my_store(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The signed-in user's store, or null when they haven't opened one."""
    return await StoreService(db).get_my_store(current_user["id"])


@router.get("/name-available")
async def name_available(
    name: str = Query(..., max_length=64),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Live check for the setup wizard's link step:
    {name, available, reason, suggestion, url}."""
    await store_name_check_limiter.check_and_record(current_user["id"])
    return await StoreService(db).check_name(name)


@router.post("/email/request-code")
async def request_business_email_code(
    body: EmailCodeIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Email a code to prove the store's business email. Same codes and
    limits as signup's email step; unlike signup, the address may already
    belong to a BROKA account."""
    from api.domains.auth.router import _email_key
    from api.domains.auth.service import AuthService

    await otp_request_limiter.check_and_record(_email_key(body.email))
    await otp_request_limiter.check_and_record(f"user:{current_user['id']}")
    return await AuthService(db).request_email_otp(
        body.email, purpose=OtpPurpose.registration, allow_registered=True,
    )


@router.post("/email/verify")
async def verify_business_email_code(
    body: EmailVerifyIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Returns email_verify_token, sent as business_email_token when the
    store is saved."""
    from api.domains.auth.router import _email_key
    from api.domains.auth.service import AuthService

    await otp_verify_limiter.check_and_record(_email_key(body.email))
    return await AuthService(db).verify_email_otp(
        body.email, body.code, purpose=OtpPurpose.registration,
    )


@router.get("/slug/{slug}")
async def get_store_by_slug(slug: str, db: AsyncSession = Depends(get_db)):
    return await StoreService(db).get_store_by_slug(slug)


@router.get("/{store_id}")
async def get_store(store_id: str, db: AsyncSession = Depends(get_db)):
    return await StoreService(db).get_store(store_id)


@router.patch("/{store_id}")
async def update_store(
    store_id: str,
    body: StorePatch,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # exclude_unset, not exclude_none: an omitted field leaves the column
    # alone, while one sent as null/"" clears it.
    return await StoreService(db).update_store(
        store_id, current_user["id"], body.model_dump(exclude_unset=True),
    )


@router.post("/{store_id}/status")
async def set_store_status(
    store_id: str,
    body: StoreStatusIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await StoreService(db).set_store_status(store_id, current_user["id"], body.is_active)


@router.get("/{store_id}/listings")
async def get_store_listings(
    store_id: str,
    search: Optional[str] = Query(None, max_length=100),
    category: Optional[str] = None,
    sort: Literal["featured", "newest", "price_low", "price_high"] = "featured",
    limit: int = Query(20, ge=1, le=_MAX_PAGE_SIZE),
    offset: int = Query(0, ge=0),
    with_total: bool = False,
    db: AsyncSession = Depends(get_db),
):
    """The store's catalogue, in the same card format as Home. Public."""
    return await StoreService(db).list_store_listings(
        store_id, limit=limit, offset=offset, with_total=with_total,
        search=search, category=category, sort=sort,
    )


@router.get("/{store_id}/categories")
async def get_store_categories(store_id: str, db: AsyncSession = Depends(get_db)):
    """[{name, count}] - the categories this store has products in."""
    return await StoreService(db).list_categories(store_id)


@router.post("/{store_id}/visit", status_code=202)
async def record_visit(
    store_id: str,
    body: VisitIn,
    request: Request,
    current_user: Optional[dict] = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db),
):
    """The app or the web storefront opened this store. Counted once per
    visitor per half hour, and at most stats.MAX_VISITORS_PER_CLIENT new
    visitors per caller per store in that time; the owner's own visits,
    and crawlers, aren't counted."""
    # Limited by who is really calling. This used to be keyed on
    # body.visitor for anonymous callers - a random string the caller
    # chooses, so a new one per request was never limited, and every
    # request was counted as a new visitor.
    client = _client_key(request, current_user)
    await store_counter_limiter.check_and_record(client)
    store = await StoreService(db).get_row(store_id)
    if current_user and current_user["id"] == store.owner_id:
        return {"counted": False}
    user_agent = request.headers.get("user-agent")
    if body.surface == "web" and store_stats.is_bot(user_agent):
        return {"counted": False}
    if current_user:
        visitor = f"u:{current_user['id']}"
    elif body.visitor:
        visitor = f"v:{body.visitor}"
    else:
        visitor = store_stats.anonymous_visitor_key(client_ip(request), user_agent)
    source = store_stats.visit_source(
        body.via, body.referrer if body.surface == "web" else None,
    )
    counted = await store_stats.record_visit(
        db, store_id, body.surface, source, visitor, client=client,
    )
    return {"counted": counted}


@router.post("/{store_id}/share", status_code=202)
async def record_share(
    store_id: str,
    body: ShareIn,
    request: Request,
    current_user: Optional[dict] = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db),
):
    """A share button was tapped. Counted for the owner's stats, up to
    stats.MAX_SHARES_PER_CLIENT per caller per store per half hour."""
    client = _client_key(request, current_user)
    await store_counter_limiter.check_and_record(client)
    await StoreService(db).get_row(store_id)
    counted = await store_stats.record_share(
        db, store_id, body.surface, store_stats.share_channel(body.channel), client=client,
    )
    return {"counted": counted}


@router.get("/{store_id}/stats")
async def get_store_stats(
    store_id: str,
    days: int = Query(7, ge=1, le=store_stats.MAX_STATS_DAYS),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Visits and shares for the owner. Owner only."""
    await StoreService(db).get_owned(store_id, current_user["id"])
    return await store_stats.stats_for(db, store_id, days)
