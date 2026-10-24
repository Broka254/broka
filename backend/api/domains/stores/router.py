"""Stores router.

Route order matters: the fixed paths ("/mine", "/name-available",
"/email/...") must be registered before GET "/{store_id}", or FastAPI
would read /stores/mine as store_id="mine".

Creating and managing a store needs a signed-in owner; reading a store and
its catalogue is public - browsing a store someone shared must never hit
a sign-in wall.
"""
from __future__ import annotations

import logging
from typing import List, Literal, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.client_ip import client_ip
from api.core.config import settings
from api.core.idempotency import IdempotencyResult, idempotency_guard
from api.core.rate_limit import (
    marketing_event_limiter, marketing_generation_limiter, otp_request_limiter,
    otp_verify_limiter, store_counter_limiter, store_name_check_limiter, stk_limiter,
)
from api.database import OtpPurpose, get_db
from api.domains.reviews.router import PublicReviewOut, ReviewSummaryOut
from api.security import get_current_user, get_current_user_optional
from . import billing as store_billing
from . import stats as store_stats
from .marketing import MarketingService
from .service import StoreService

logger = logging.getLogger(__name__)
router = APIRouter()

_MAX_PAGE_SIZE = 100


class ReviewableDealOut(BaseModel):
    """One of the caller's own deals, returned only to that caller.

    It carries the ids the review form needs to submit the chosen deal.
    Keeping an explicit model means a future change to the service cannot
    accidentally publish the rest of a Deal row through this route.
    """
    deal_id: str
    seller_id: str
    seller_name: str
    listing_name: str
    store_id: Optional[str] = None
    store_name: Optional[str] = None
    agreed_price: Optional[float] = None
    status: str
    created_at: Optional[str] = None
    completed_at: Optional[str] = None
    already_reviewed: bool


class StoreReviewsViewerOut(BaseModel):
    """The signed-in buyer's own eligibility for this shop."""
    can_review: bool
    already_reviewed: bool
    reviewable_deals: List[ReviewableDealOut]


class SellerStandingOut(BaseModel):
    """The public figures from the owner's latest seller snapshot.

    This is the person's 0-10 standing, not the shop's buyer-review average.
    An explicit model keeps any future internal field added to the snapshot
    from being published by this storefront route.
    """
    overall_rating: Optional[float] = None
    dcr: Optional[float] = None
    dcr_provisional: bool
    median_response_minutes: Optional[float] = None
    completed_deals: int
    as_of: str


class StoreReviewsOut(BaseModel):
    """The public storefront review payload.

    Reviews are public cards. The only identifiers allowed are the review's
    own id and the reviewer's display name; deal, reviewer and seller ids
    stay inside authorized endpoints such as `reviewable_deals`.
    """
    summary: ReviewSummaryOut
    reviews: List[PublicReviewOut]
    seller_standing: Optional[SellerStandingOut] = None
    viewer: Optional[StoreReviewsViewerOut] = None


class StoreIn(BaseModel):
    name: str = Field(max_length=200)
    # "physical" | "virtual". Optional for app builds that predate store
    # types; the server then treats the store as physical, which is what
    # every store that existed before this field was.
    store_type: Optional[Literal["physical", "virtual"]] = None
    # Structured weekly hours (see stores/opening_hours.py). Refused if a
    # time is invalid, rather than silently dropped.
    opening_hours: Optional[dict] = None
    # Delivery coverage: Kenyan counties, or ["Nationwide"]. Not the shop's
    # address - a physical shop may deliver countrywide and a virtual store
    # may serve one county.
    service_areas: Optional[List[str]] = Field(default=None, max_length=47)
    delivery_note: Optional[str] = Field(default=None, max_length=200)
    # The link name (broka.co.ke/store/<slug>), chosen in the setup
    # wizard. Optional only for app builds that predate it; those get one
    # derived from the name.
    slug: Optional[str] = Field(default=None, max_length=64)
    category: Optional[str] = None
    # Phase 3: every category the store sells in, primary first. A store
    # with two or more is the "Wholesale and General" directory entry;
    # `category` stays accepted for older app builds and means the same
    # as a one-element list.
    categories: Optional[List[str]] = None
    description: Optional[str] = None
    county: Optional[str] = None
    subcounty: Optional[str] = None
    location_description: Optional[str] = None
    # The shop's own pin for "near you". Both or neither; the service
    # refuses a half-pin.
    lat: Optional[float] = Field(default=None, ge=-90, le=90)
    lng: Optional[float] = Field(default=None, ge=-180, le=180)
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
    store_type: Optional[Literal["physical", "virtual"]] = None
    opening_hours: Optional[dict] = None
    service_areas: Optional[List[str]] = Field(default=None, max_length=47)
    delivery_note: Optional[str] = Field(default=None, max_length=200)
    # Accepted only when unchanged: a store's link is fixed once it opens.
    slug: Optional[str] = Field(default=None, max_length=64)
    category: Optional[str] = None
    # The full set that replaces the store's categories; see StoreIn.
    categories: Optional[List[str]] = None
    description: Optional[str] = None
    county: Optional[str] = None
    subcounty: Optional[str] = None
    location_description: Optional[str] = None
    lat: Optional[float] = Field(default=None, ge=-90, le=90)
    lng: Optional[float] = Field(default=None, ge=-180, le=180)
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
    # A Marketing Studio campaign link's `c=` token. Only a token that
    # belongs to this store counts; anything else is ignored, and the
    # campaign is credited only when the visit itself was counted.
    campaign: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9_-]{8,32}$")
    # The page was opened on a product, not just the store's home: the same
    # counted visit also credits the campaign with a product view, with no
    # second call and no separate visitor identity.
    product_view: bool = False

    @field_validator("via")
    @classmethod
    def _short_via(cls, v: Optional[str]) -> Optional[str]:
        return store_stats.short_via(v)


class ShareIn(BaseModel):
    channel: str = Field(max_length=32)
    surface: Literal["app", "web"] = "app"


class BulkListingActionIn(BaseModel):
    """A bulk change to the store's own products.

    Only archiving is offered in bulk. Publishing a hidden listing needs its
    own listing-fee payment (an M-Pesa prompt per product), and BROKA has no
    per-listing paused state, so a "Pause" here would have to invent one -
    neither belongs behind a single tap on a multi-select.
    """
    action: Literal["archive"]
    listing_ids: List[str] = Field(min_length=1, max_length=50)


class CampaignIn(BaseModel):
    title: Optional[str] = Field(default=None, max_length=120)
    objective: Literal[
        "new_store", "product", "new_stock", "discount", "awareness",
        "seasonal", "storefront", "enquiries",
    ] = "product"
    product_ids: List[str] = Field(default_factory=list, max_length=10)
    platforms: List[Literal["whatsapp", "instagram", "tiktok", "facebook", "x"]] = Field(
        min_length=1, max_length=5,
    )
    audience: Optional[str] = Field(default=None, max_length=120)
    tone: Literal["friendly", "professional", "bold", "playful", "premium"] = "friendly"
    language: Literal["en", "sw"] = "en"
    instructions: Optional[str] = Field(default=None, max_length=600)
    # The seller's chosen call to action and preferred shape. The service
    # checks the format against the selected platforms - formats differ by
    # platform, and a "story" for X would be a promise BROKA can't keep.
    cta: Optional[str] = Field(default=None, max_length=160)
    creative_format: Optional[str] = Field(default=None, max_length=24)
    # False saves the configuration as a draft; the seller can generate
    # later. True (the default) creates it and generates in one step.
    generate: bool = True


class CampaignPatchIn(BaseModel):
    title: Optional[str] = Field(default=None, max_length=120)
    audience: Optional[str] = Field(default=None, max_length=120)
    instructions: Optional[str] = Field(default=None, max_length=600)
    cta: Optional[str] = Field(default=None, max_length=160)
    creative_format: Optional[str] = Field(default=None, max_length=24)


class CreativePatchIn(BaseModel):
    headline: Optional[str] = Field(default=None, max_length=160)
    body: Optional[str] = Field(default=None, max_length=2200)
    cta: Optional[str] = Field(default=None, max_length=160)
    hashtags: Optional[List[str]] = Field(default=None, max_length=12)


class CampaignEventIn(BaseModel):
    kind: Literal["downloaded", "shared"]
    platform: Optional[str] = Field(default=None, max_length=16)


class AttributionIn(BaseModel):
    kind: Literal["visit", "product_view"] = "visit"


class CopywriterIn(BaseModel):
    field: Literal["title", "description", "caption", "store_description"] = "description"
    listing_id: Optional[str] = None
    text: Optional[str] = Field(default=None, max_length=2200)
    language: Literal["en", "sw"] = "en"
    tone: Literal["friendly", "professional", "bold", "playful", "premium"] = "friendly"


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
    subcounty: Optional[str] = None,
    limit: int = Query(20, ge=1, le=_MAX_PAGE_SIZE),
    offset: int = Query(0, ge=0),
    with_total: bool = False,
    lat: Optional[float] = Query(None, description="Viewer's latitude for distance_km"),
    lng: Optional[float] = Query(None, description="Viewer's longitude for distance_km"),
    max_distance_km: Optional[float] = Query(None, gt=0, le=2000),
    nearest_first: bool = Query(False, description="Nearest stores first for 'Stores near you'"),
    store_type: Optional[Literal["physical", "virtual"]] = Query(
        None, description="Both kinds when omitted; never hides virtual stores by default"),
    db: AsyncSession = Depends(get_db),
):
    """Browse active stores. Public. With lat/lng every store carries
    distance_km and distance_label ('6 km from you'); with max_distance_km
    only nearby stores; with nearest_first nearest first."""
    return await StoreService(db).list_stores(
        search=search, category=category or specialization, county=county, subcounty=subcounty,
        limit=limit, offset=offset, with_total=with_total,
        viewer_lat=lat, viewer_lng=lng,
        max_distance_km=max_distance_km, nearest_first=nearest_first,
        store_type=store_type,
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
async def get_store_by_slug(
    slug: str,
    current_user: Optional[dict] = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db),
):
    """A store by its link name. Public; the owner (signed in) also gets
    their own unpaid store back rather than a 404."""
    return await StoreService(db).get_store_by_slug(
        slug, viewer_id=current_user["id"] if current_user else None,
    )


# Registered before the dynamic "/{store_id}" routes, per this module's
# rule: a fixed path first, or FastAPI reads it as a store id.
class StorePayIn(BaseModel):
    listings: int = Field(..., ge=1, le=10_000, description="Listings the plan should cover")
    months: int = Field(..., ge=2, le=12, description="2, 4, 6 or 12 months")
    phone_number: str = Field(..., max_length=20)


async def _store_billing_callback(request: Request, db: AsyncSession) -> dict:
    try:
        await store_billing.process_callback(db, await request.json())
    except Exception as exc:
        # Still a 200: a non-200 makes Safaricom redeliver forever, and the
        # status poll's own query settles the payment.
        logger.error("[stores] billing callback error: %s", exc, exc_info=True)
    return {"ResultCode": 0, "ResultDesc": "Accepted"}


@router.post("/billing/callback")
async def store_billing_callback(request: Request, db: AsyncSession = Depends(get_db)):
    """Only while MPESA_CALLBACK_SECRET is unset (local and sandbox)."""
    if settings.mpesa_callback_secret:
        raise HTTPException(status_code=404, detail="Not found")
    return await _store_billing_callback(request, db)


@router.post("/billing/callback/{secret}")
async def store_billing_callback_secured(
    secret: str, request: Request, db: AsyncSession = Depends(get_db),
):
    if not settings.mpesa_callback_secret or secret != settings.mpesa_callback_secret:
        raise HTTPException(status_code=404, detail="Not found")
    return await _store_billing_callback(request, db)


@router.get("/{store_id}")
async def get_store(
    store_id: str,
    current_user: Optional[dict] = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db),
):
    """A store by id. Public; the owner (signed in) sees their own unpaid
    store, which everyone else gets as a 404 - the link is dead until the
    plan is paid (stores/billing.py)."""
    return await StoreService(db).get_store(
        store_id, viewer_id=current_user["id"] if current_user else None,
    )


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


@router.delete("/{store_id}")
async def delete_store(
    store_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Delete your own store. The shop and its link go dark; its products
    are archived (cancelled), never deleted - see StoreService.delete_store."""
    return await StoreService(db).delete_store(store_id, current_user["id"])


@router.get("/{store_id}/billing")
async def get_store_billing(
    store_id: str,
    listings: Optional[int] = Query(None, ge=1, le=10_000,
                                    description="Price this size; without it, just the card and state"),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The owner's billing screen: their store's rate card, what is owed
    now, and - with ?listings= - that plan's priced periods. Owner only."""
    store = await StoreService(db).get_owned(store_id, current_user["id"])
    return await store_billing.summary(db, store, listings)


@router.post("/{store_id}/billing/pay")
async def pay_store_billing(
    store_id: str,
    body: StorePayIn,
    current_user: dict = Depends(get_current_user),
    idempotency: IdempotencyResult = Depends(idempotency_guard),
    db: AsyncSession = Depends(get_db),
):
    """Send the M-Pesa prompt for a store plan. The amount is the rate
    card's price for that size and those months plus any opening fee,
    never the request's."""
    if idempotency.cached:
        return idempotency.response
    # Per user: every call prompts a phone for money, and the number is the
    # caller's to type.
    await stk_limiter.check_and_record(current_user["id"])
    store = await StoreService(db).get_owned(store_id, current_user["id"])
    result = await store_billing.start_payment(
        db, current_user["id"], store, body.listings, body.months, body.phone_number,
    )
    await idempotency.store(result)
    return result


@router.get("/{store_id}/billing/payments/{payment_id}")
async def store_billing_payment_status(
    store_id: str,
    payment_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await store_billing.payment_status(db, current_user["id"], store_id, payment_id)


@router.get("/{store_id}/listings")
async def get_store_listings(
    store_id: str,
    search: Optional[str] = Query(None, max_length=100),
    category: Optional[str] = None,
    sort: Literal["featured", "newest", "price_low", "price_high"] = "featured",
    condition: Optional[Literal["new", "used", "refurbished"]] = None,
    min_price: Optional[float] = Query(None, ge=0),
    max_price: Optional[float] = Query(None, ge=0),
    limit: int = Query(20, ge=1, le=_MAX_PAGE_SIZE),
    offset: int = Query(0, ge=0),
    with_total: bool = False,
    db: AsyncSession = Depends(get_db),
):
    """The store's catalogue, in the same card format as Home. Public.
    condition and the price range are the storefront's filter panel - the
    same filters Home's panel sends to /listings."""
    return await StoreService(db).list_store_listings(
        store_id, limit=limit, offset=offset, with_total=with_total,
        search=search, category=category, sort=sort,
        condition=condition, min_price=min_price, max_price=max_price,
    )


@router.get("/{store_id}/manage/listings")
async def get_owner_listings(
    store_id: str,
    state: Literal["all", "live", "hidden", "in_deal", "sold", "archived"] = "all",
    search: Optional[str] = Query(None, max_length=100),
    category: Optional[str] = Query(None, max_length=120),
    sort: Literal["newest", "oldest", "name", "price_low", "price_high"] = "newest",
    limit: int = Query(20, ge=1, le=_MAX_PAGE_SIZE),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Every product in the store with its state and listing fee, for My
    Store: {items, counts}. Owner only. `category` filters the catalogue the
    way the public storefront's chips do; `sort` is a fixed list, never a
    client-supplied SQL expression."""
    return await StoreService(db).list_owner_listings(
        store_id, current_user["id"], state=state, search=search,
        category=category, sort=sort, limit=limit, offset=offset,
    )


@router.post("/{store_id}/manage/listings/bulk")
async def bulk_listing_action(
    store_id: str,
    body: BulkListingActionIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Archive several of the store's products at once. Owner only; every
    selected id is validated against this store before anything changes."""
    return await StoreService(db).bulk_archive_listings(
        store_id, current_user["id"], body.listing_ids,
    )


@router.get("/{store_id}/categories")
async def get_store_categories(store_id: str, db: AsyncSession = Depends(get_db)):
    """[{name, count}] - the categories this store has products in."""
    return await StoreService(db).list_categories(store_id)


@router.get("/{store_id}/reviews", response_model=StoreReviewsOut)
async def get_store_reviews(
    store_id: str,
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    current_user: Optional[dict] = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db),
):
    """{summary, reviews, seller_standing}, plus `viewer` for a signed-in
    caller - whether they can still review a purchase from this shop.
    Public; reviewer names only, no ids. Authentication is optional so an
    anonymous storefront read stays open; an invalid token still 401s."""
    return await StoreService(db).store_reviews(
        store_id, limit=limit, offset=offset,
        viewer_id=current_user["id"] if current_user else None,
    )


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
    if body.campaign:
        marketing = MarketingService(db)
        if counted:
            await marketing.attribute(store_id, body.campaign, "visit")
        if body.product_view:
            # A product view is credited once per visitor per campaign per
            # window, whether or not this request was the one that counted
            # the visit. Gating it on `counted` starved the most common
            # journey: a buyer opens the campaign link (visit counted),
            # then taps a product. That page reported the same visitor
            # inside the same window, so its product view was discarded.
            first_view = await store_stats.seen.first_time(
                f"campaign_view:{store_id}:{body.campaign}:{visitor}",
                store_stats.VISIT_WINDOW_SECONDS,
            )
            if first_view:
                await marketing.attribute(store_id, body.campaign, "product_view")
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


@router.post("/{store_id}/campaign/{token}/event", status_code=202)
async def attribute_campaign_event(
    store_id: str,
    token: str,
    body: AttributionIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """A storefront page opened with a campaign link reports the view.

    Public, because the person who followed a shared link is a buyer, not a
    signed-in seller. The token must belong to this store's campaign; an
    unknown one is ignored (the page still works). Rate-limited by the real
    caller, and no visitor identifier is stored.
    """
    client = _client_key(request, None)
    await store_counter_limiter.check_and_record(client)
    await marketing_event_limiter.check_and_record(client)
    await StoreService(db).get_row(store_id)
    counted = await MarketingService(db).attribute(store_id, token, body.kind)
    return {"counted": counted}


@router.get("/{store_id}/marketing/campaigns")
async def list_campaigns(
    store_id: str,
    limit: int = Query(20, ge=1, le=50),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The owner's saved campaigns, newest first. Owner only - drafts are
    private and never appear in any public response."""
    return await MarketingService(db).list_campaigns(
        store_id, current_user["id"], limit=limit, offset=offset,
    )


@router.post("/{store_id}/marketing/campaigns", status_code=201)
async def create_campaign(
    store_id: str,
    body: CampaignIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Create a campaign and (unless generate=false) write its platform
    creatives. Prices and titles come from the seller's listings on the
    server; nothing in this body is trusted as product data."""
    await marketing_generation_limiter.check_and_record(current_user["id"])
    return await MarketingService(db).create_campaign(
        store_id, current_user["id"], body.model_dump(),
    )


@router.get("/{store_id}/marketing/campaigns/{campaign_id}")
async def get_campaign(
    store_id: str,
    campaign_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await MarketingService(db).get_campaign(
        store_id, current_user["id"], campaign_id,
    )


@router.patch("/{store_id}/marketing/campaigns/{campaign_id}")
async def update_campaign(
    store_id: str,
    campaign_id: str,
    body: CampaignPatchIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await MarketingService(db).update_campaign(
        store_id, current_user["id"], campaign_id, body.model_dump(exclude_unset=True),
    )


@router.delete("/{store_id}/marketing/campaigns/{campaign_id}")
async def delete_campaign(
    store_id: str,
    campaign_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await MarketingService(db).delete_campaign(
        store_id, current_user["id"], campaign_id,
    )


@router.post("/{store_id}/marketing/campaigns/{campaign_id}/regenerate")
async def regenerate_campaign(
    store_id: str,
    campaign_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Rewrite the creatives from the campaign's saved configuration and
    current product data. Rate-limited: this is the paid-provider call."""
    await marketing_generation_limiter.check_and_record(current_user["id"])
    return await MarketingService(db).regenerate(
        store_id, current_user["id"], campaign_id,
    )


@router.patch("/{store_id}/marketing/campaigns/{campaign_id}/creatives/{creative_id}")
async def update_creative(
    store_id: str,
    campaign_id: str,
    creative_id: str,
    body: CreativePatchIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Edit a generated caption/CTA. This changes the campaign's copy only;
    the seller's listing is never rewritten by the studio."""
    return await MarketingService(db).update_creative(
        store_id, current_user["id"], campaign_id, creative_id,
        body.model_dump(exclude_unset=True),
    )


@router.post("/{store_id}/marketing/campaigns/{campaign_id}/events")
async def record_campaign_event(
    store_id: str,
    campaign_id: str,
    body: CampaignEventIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The owner downloaded or shared a creative. Counted as an observed
    action - never as an impression or a sale."""
    await marketing_event_limiter.check_and_record(current_user["id"])
    return await MarketingService(db).record_owner_event(
        store_id, current_user["id"], campaign_id, body.kind, body.platform or "",
    )


@router.post("/{store_id}/marketing/copy")
async def copy_suggestions(
    store_id: str,
    body: CopywriterIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Suggestions for a title, description or caption, for review only.
    Nothing is written to the listing - the seller must save any change."""
    await marketing_generation_limiter.check_and_record(current_user["id"])
    return await MarketingService(db).copy_suggestions(
        store_id, current_user["id"], body.model_dump(),
    )


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


@router.get("/{store_id}/insights")
async def get_store_insights(
    store_id: str,
    days: int = Query(7, ge=1, le=store_stats.MAX_STATS_DAYS),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The store dashboard in one response. Owner only.

    Ratings, rank, period-over-period KPIs, daily series, traffic sources,
    top products and number-backed advice - everything My Store's Overview
    draws, so the screen makes one request per refresh instead of a dozen
    on a phone connection.

    Competitive information stays with the owner for the same reason the
    seller dashboard's does: product views and saves tell a rival exactly
    which lines are moving, and rank says how far they have to climb.
    """
    from . import insights as store_insights

    store = await StoreService(db).get_owned(store_id, current_user["id"])
    return await store_insights.insights_for(db, store, days=days)
