"""Zeno structured action engine (Broka_HomeScreen_Zeno_BuyingAgent_Design_v2
§16-20). Zeno (the LLM) only ever produces one of these actions as JSON; it
never executes anything directly. This module is the ACTION PARSER + SCHEMA
VALIDATOR + AUTHORIZATION CHECK + EXECUTION stages of the pipeline in §26 -
"ZENO -> ACTION PARSER -> SCHEMA VALIDATOR -> AUTHORIZATION CHECK ->
BUSINESS RULE CHECK -> EXECUTION -> RESULT -> ZENO".

Scope of this first pass: the action vocabulary and optimization codes are
all defined (so an invalid one is rejected by Pydantic before any of our
code runs, per §17 "do not allow the model to invent unsupported actions"),
but only SEARCH_PRODUCTS is actually executed. Everything else returns a
clear NOT_IMPLEMENTED failure rather than silently doing nothing or
pretending to succeed - §27's "Zeno must never claim success when
execution failed" applies just as much to "not built yet" as to a real
runtime error.

SEARCH_PRODUCTS reuses ListingService.list_listings entirely for
filtering/pagination (§20: "Flutter must not perform large-scale
marketplace filtering" - and neither should this module reinvent it) and
adds the one genuinely new piece: ranking by optimization_code. Ranking
signals are real columns only - price, computed distance, User.rating /
completed_deals / is_verified. Deal Completion Rate is NOT one of them: it
doesn't exist anywhere in this codebase (see traders/service.py's own note
on this), so TRUST/BEST_VALUE use verification + rating + completed_deals
instead of inventing a DCR number.

seller_name/seller_verified/seller_rating/seller_completed_deals now reach
every match dict for free via ListingService._listing_dict's optional
`seller` param (added in this same redesign-guide audit pass) - _rank
still fetches its own full trust map (_seller_trust_map below) separately,
since ranking needs the raw numeric rating/completed_deals for scoring,
not just what a listing payload displays.
"""
from __future__ import annotations

import uuid
from enum import Enum
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Category, User
from api.domains.listings.service import ListingService
from .service import BuyAgentService
from fastapi import HTTPException


class ZenoActionName(str, Enum):
    """§17's initial + "later" vocabulary in one enum. Actions not yet
    executed (see EXECUTED_ACTIONS below) still validate fine - the model
    is allowed to *name* them, execution just isn't built for them yet."""
    SEARCH_PRODUCTS = "SEARCH_PRODUCTS"
    REFINE_SEARCH = "REFINE_SEARCH"
    SORT_RESULTS = "SORT_RESULTS"
    CREATE_BUYING_REQUEST = "CREATE_BUYING_REQUEST"
    UPDATE_BUYING_REQUEST = "UPDATE_BUYING_REQUEST"
    VIEW_MATCH = "VIEW_MATCH"
    START_NEGOTIATION = "START_NEGOTIATION"
    WATCH_LISTING = "WATCH_LISTING"
    NOTIFY_ON_MATCH = "NOTIFY_ON_MATCH"
    EXPAND_SEARCH_RADIUS = "EXPAND_SEARCH_RADIUS"
    CHANGE_BUDGET = "CHANGE_BUDGET"
    PAUSE_REQUEST = "PAUSE_REQUEST"
    RESUME_REQUEST = "RESUME_REQUEST"
    CANCEL_REQUEST = "CANCEL_REQUEST"


EXECUTED_ACTIONS = {
    ZenoActionName.SEARCH_PRODUCTS,
    ZenoActionName.CREATE_BUYING_REQUEST,
    # Added (redesign-guide audit): REFINE_SEARCH/SORT_RESULTS both delegate
    # straight to _search_products - see execute_action below for why no
    # separate execution logic is needed for either.
    ZenoActionName.REFINE_SEARCH,
    ZenoActionName.SORT_RESULTS,
    # UPDATE_BUYING_REQUEST/CANCEL_REQUEST close a real gap: with neither
    # implemented, a buyer who hit the one-active-request cap (default 1)
    # had no way to ever change or cancel their standing request from the
    # app. CHANGE_BUDGET is a narrower, common-case alias of the same update
    # path (§17 lists it as its own action name; it doesn't need distinct
    # execution logic from a full UPDATE_BUYING_REQUEST that only touches
    # price fields).
    ZenoActionName.UPDATE_BUYING_REQUEST,
    ZenoActionName.CHANGE_BUDGET,
    ZenoActionName.CANCEL_REQUEST,
    # START_NEGOTIATION: opens a real negotiation thread for a specific
    # listing on the buyer's behalf, gated on the Hub having already shown a
    # confirmation per §24 ("Zeno must not negotiate automatically...
    # Shall I start the negotiation?") before ever calling this action -
    # see _start_negotiation's docstring for why this reuses
    # buy_agent_subscribers.py's message-writing pattern rather than
    # reaching into negotiate.py's ~2700-line send_message.
    ZenoActionName.START_NEGOTIATION,
}


class OptimizationCode(str, Enum):
    """§18. Combined strategies (PRICE_TRUST etc.) are deliberately NOT
    separate enum members - §18 explicitly says not to hard-code every
    combination. primary + optional secondary (below) covers the same
    ground without an exploding enum."""
    PRICE_ASC = "PRICE_ASC"
    DISTANCE = "DISTANCE"
    RELEVANCE = "RELEVANCE"
    BALANCED_MATCH = "BALANCED_MATCH"
    BEST_VALUE = "BEST_VALUE"
    TRUST = "TRUST"
    FRESHNESS = "FRESHNESS"
    AUCTION_VALUE = "AUCTION_VALUE"  # accepted, not executed - see below


class SearchProductsParams(BaseModel):
    query: Optional[str] = None
    category: Optional[str] = None       # top-level category NAME - resolved to id below
    subcategory: Optional[str] = None    # subcategory NAME - resolved to id below
    min_price: Optional[float] = None
    max_price: Optional[float] = None
    location: Optional[str] = None
    max_distance_km: Optional[float] = None
    condition: Optional[str] = None
    attributes: Optional[Dict[str, Any]] = None
    limit: int = 20
    offset: int = 0


class CreateBuyingRequestParams(BaseModel):
    """Fields match Design v2 §25's conceptual BuyingAgentRequest, checked
    against the actual doc (previous pass had reconstructed this from
    memory while the doc was temporarily missing from uploads - see
    migration 0019). category/max_price stay required, matching the
    original (pre-action-engine) BuyAgentRequestIn shape that the plain
    POST /buy-agent-requests endpoint still uses."""
    category: str
    subcategory: Optional[str] = None
    query: Optional[str] = None
    max_price: float
    min_price: Optional[float] = None
    location: Optional[str] = None
    max_distance_km: Optional[float] = None
    condition: Optional[str] = None
    attributes: Optional[Dict[str, Any]] = None
    must_have_features: List[str] = Field(default_factory=list)
    # FIX (ChatGPT-review audit, 2026-08-15): lets a buyer opt into Zeno
    # auto-messaging a seller the instant a match is found, vs. just being
    # notified and reviewing matches themselves via START_NEGOTIATION.
    # Defaults False (the safe choice, matching the column's own default) -
    # omitting this keeps the pre-existing "just notify me" behavior.
    negotiation_authorized: bool = False


class UpdateBuyingRequestParams(BaseModel):
    """All-optional partial update for UPDATE_BUYING_REQUEST (Design v2
    §17). Only fields the buyer actually wants to change should be set -
    anything left as None/omitted is left untouched on the existing
    request. Same field shape as CreateBuyingRequestParams minus the
    required-ness of category/max_price, since this is a partial patch, not
    a fresh request."""
    category: Optional[str] = None
    subcategory: Optional[str] = None
    query: Optional[str] = None
    max_price: Optional[float] = None
    min_price: Optional[float] = None
    location: Optional[str] = None
    max_distance_km: Optional[float] = None
    condition: Optional[str] = None
    attributes: Optional[Dict[str, Any]] = None
    must_have_features: Optional[List[str]] = None
    negotiation_authorized: Optional[bool] = None


class ChangeBudgetParams(BaseModel):
    """Narrower alias of UpdateBuyingRequestParams for the common "just
    change my budget" case (§17 lists CHANGE_BUDGET as its own action
    name distinct from a full UPDATE_BUYING_REQUEST)."""
    max_price: Optional[float] = None
    min_price: Optional[float] = None


class StartNegotiationParams(BaseModel):
    """§17/§24. listing_id is required - Zeno must already know which
    specific match the buyer wants to pursue (surfaced from a prior
    SEARCH_PRODUCTS response's `matches`). message is optional free text the
    buyer/Zeno wants to open with; when omitted a plain, honest default
    opener is used (same style as buy_agent_subscribers.py's auto-match
    opener, not a second AI-authored-message pipeline)."""
    listing_id: str
    message: Optional[str] = None


class ZenoActionRequest(BaseModel):
    action: ZenoActionName
    optimization_code: OptimizationCode = OptimizationCode.BALANCED_MATCH
    optimization_secondary: Optional[OptimizationCode] = None
    parameters: Dict[str, Any] = Field(default_factory=dict)


class ZenoActionError(Exception):
    def __init__(self, error_code: str, message: str):
        self.error_code = error_code
        self.message = message


async def execute_action(
    db: AsyncSession,
    buyer_id: str,
    request: ZenoActionRequest,
    viewer_lat: Optional[float] = None,
    viewer_lng: Optional[float] = None,
) -> dict:
    """Single entry point - §26's pipeline from SCHEMA VALIDATOR onward.
    action/optimization_code are already schema-valid by the time this
    runs (FastAPI rejects an invalid enum value before this function is
    even called - that's the ACTION PARSER + SCHEMA VALIDATOR stages).
    This covers AUTHORIZATION CHECK, BUSINESS RULE CHECK and EXECUTION.
    """
    if request.action not in EXECUTED_ACTIONS:
        return _failure(
            request.action,
            "NOT_IMPLEMENTED",
            f"{request.action.value} is a recognized Zeno action but isn't executed yet in this build.",
        )

    if request.action in (ZenoActionName.SEARCH_PRODUCTS, ZenoActionName.REFINE_SEARCH,
                          ZenoActionName.SORT_RESULTS):
        # REFINE_SEARCH and SORT_RESULTS both execute identically to
        # SEARCH_PRODUCTS: a "refine" is a new search whose parameters
        # already have the previous constraints merged in (the merge
        # happens at parse time - see AIBrokerService.parse_search_intent's
        # existing_filters argument - not here), and "sort" is just a
        # re-search with a different optimization_code, which
        # ZenoActionRequest already carries as a top-level field. Giving
        # Zeno three distinct action names (per §17's vocabulary) costs
        # nothing extra to execute correctly, and keeps the action Zeno
        # emits semantically honest about buyer intent even though the
        # code path is shared.
        try:
            params = SearchProductsParams(**request.parameters)
        except Exception as e:
            raise ZenoActionError("INVALID_PARAMETERS", str(e))
        result = await _search_products(
            db, params, request.optimization_code, request.optimization_secondary,
            viewer_lat, viewer_lng,
        )
        result["action"] = request.action.value
        return result

    if request.action == ZenoActionName.CREATE_BUYING_REQUEST:
        try:
            params = CreateBuyingRequestParams(**request.parameters)
        except Exception as e:
            raise ZenoActionError("INVALID_PARAMETERS", str(e))
        return await _create_buying_request(
            db, buyer_id, params, request.optimization_code, request.optimization_secondary,
            viewer_lat, viewer_lng,
        )

    if request.action in (ZenoActionName.UPDATE_BUYING_REQUEST, ZenoActionName.CHANGE_BUDGET):
        try:
            if request.action == ZenoActionName.CHANGE_BUDGET:
                budget = ChangeBudgetParams(**request.parameters)
                params = UpdateBuyingRequestParams(max_price=budget.max_price, min_price=budget.min_price)
            else:
                params = UpdateBuyingRequestParams(**request.parameters)
        except Exception as e:
            raise ZenoActionError("INVALID_PARAMETERS", str(e))
        result = await _update_buying_request(db, buyer_id, params, viewer_lat, viewer_lng)
        result["action"] = request.action.value
        return result

    if request.action == ZenoActionName.CANCEL_REQUEST:
        return await _cancel_request(db, buyer_id)

    if request.action == ZenoActionName.START_NEGOTIATION:
        try:
            params = StartNegotiationParams(**request.parameters)
        except Exception as e:
            raise ZenoActionError("INVALID_PARAMETERS", str(e))
        return await _start_negotiation(db, buyer_id, params)

    # Unreachable while EXECUTED_ACTIONS matches the branches above - kept
    # so adding an action to EXECUTED_ACTIONS without a matching branch
    # here fails loudly instead of silently falling through.
    return _failure(request.action, "NOT_IMPLEMENTED", "No handler wired for this action.")


def _failure(action: ZenoActionName, error_code: str, message: str) -> dict:
    return {"action": action.value, "status": "FAILED", "error_code": error_code, "message": message}


async def _search_products(
    db: AsyncSession,
    params: SearchProductsParams,
    optimization_code: OptimizationCode,
    optimization_secondary: Optional[OptimizationCode],
    viewer_lat: Optional[float],
    viewer_lng: Optional[float],
) -> dict:
    category_id = None
    subcategory_id = None

    if params.category:
        cat = (await db.execute(
            select(Category).where(Category.parent_id.is_(None), Category.name.ilike(params.category.strip()))
        )).scalar_one_or_none()
        if not cat:
            raise ZenoActionError("INVALID_CATEGORY", f"'{params.category}' is not a recognized category.")
        category_id = cat.id

        if params.subcategory:
            sub = (await db.execute(
                select(Category).where(Category.parent_id == cat.id, Category.name.ilike(params.subcategory.strip()))
            )).scalar_one_or_none()
            if not sub:
                raise ZenoActionError(
                    "INVALID_SUBCATEGORY",
                    f"'{params.subcategory}' is not a recognized subcategory of {cat.name}.",
                )
            subcategory_id = sub.id

    if params.max_distance_km is not None and (viewer_lat is None or viewer_lng is None):
        # Can't rank/filter by distance without an origin - fail clearly
        # rather than silently ignoring the constraint the user asked for.
        raise ZenoActionError("MISSING_LOCATION", "A location is needed to search within a distance.")

    svc = ListingService(db)
    # Fetch a candidate pool sized for ranking, not just the final page -
    # ranking has to see everything worth comparing before pagination cuts
    # it down, same reasoning as the attribute/distance post-filter added
    # in Phase 3.
    POOL_SIZE = 100
    pool = await svc.list_listings(
        category_id=category_id,
        subcategory_id=subcategory_id,
        condition=params.condition,
        min_price=params.min_price,
        max_price=params.max_price,
        search=params.query,
        location=params.location,
        attributes=params.attributes,
        viewer_lat=viewer_lat,
        viewer_lng=viewer_lng,
        max_km=params.max_distance_km,
        sort=None,
        limit=POOL_SIZE,
        offset=0,
        with_total=True,
    )
    candidates: List[dict] = pool["items"]
    total = pool["total"]

    trust_by_seller = await _seller_trust_map(db, {c["seller_id"] for c in candidates})
    ranked = _rank(candidates, params.query, optimization_code, optimization_secondary, trust_by_seller)
    page = ranked[params.offset: params.offset + params.limit]
    # NOTE: match dicts already carry seller_name/seller_verified/
    # seller_rating/seller_completed_deals from ListingService._listing_dict
    # (fixed in this same audit pass - see listings/service.py) via the
    # list_listings() call above, so no extra per-match overlay is needed
    # here anymore. trust_by_seller above is still needed separately for
    # _rank's TRUST/BEST_VALUE/BALANCED_MATCH scoring, which uses the full
    # numeric rating/completed_deals, not just the verified flag.

    return {
        "action": "SEARCH_PRODUCTS",
        "status": "SUCCESS",
        "request_id": f"BA-{uuid.uuid4().hex[:8]}",
        "optimization_code": optimization_code.value,
        "result_count": total,
        "matches": page,
    }


async def _create_buying_request(
    db: AsyncSession,
    buyer_id: str,
    params: CreateBuyingRequestParams,
    optimization_code: OptimizationCode,
    optimization_secondary: Optional[OptimizationCode],
    viewer_lat: Optional[float],
    viewer_lng: Optional[float],
) -> dict:
    cat = (await db.execute(
        select(Category).where(Category.parent_id.is_(None), Category.name.ilike(params.category.strip()))
    )).scalar_one_or_none()
    if not cat:
        raise ZenoActionError("INVALID_CATEGORY", f"'{params.category}' is not a recognized category.")

    subcategory_id = None
    if params.subcategory:
        sub = (await db.execute(
            select(Category).where(Category.parent_id == cat.id, Category.name.ilike(params.subcategory.strip()))
        )).scalar_one_or_none()
        if not sub:
            raise ZenoActionError(
                "INVALID_SUBCATEGORY",
                f"'{params.subcategory}' is not a recognized subcategory of {cat.name}.",
            )
        subcategory_id = sub.id

    if params.min_price is not None and params.min_price > params.max_price:
        raise ZenoActionError("INVALID_PRICE_RANGE", "min_price cannot be greater than max_price.")

    try:
        # BuyAgentService enforces the one-active-request-per-buyer cap by
        # raising HTTPException(409, ...) - converted to a ZenoActionError
        # here so it flows through the same FAILED-response shape as every
        # other validation error, rather than surfacing as a raw HTTP
        # error the router's ZenoActionError handler wouldn't catch (§27:
        # "Zeno must never claim success when execution failed", which
        # applies equally to "failed in an inconsistent shape").
        request_dict = await BuyAgentService(db).create_request(
            buyer_id=buyer_id,
            category=cat.name,
            max_price=params.max_price,
            must_have_features=params.must_have_features,
            subcategory_id=subcategory_id,
            query=params.query,
            min_price=params.min_price,
            location_name=params.location,
            lat=viewer_lat,
            lng=viewer_lng,
            max_distance_km=params.max_distance_km,
            condition=params.condition,
            attributes=params.attributes,
            optimization_code=optimization_code.value,
            # FIX (ChatGPT-review audit, 2026-08-15): optimization_configuration
            # was accepted by BuyAgentService.create_request and stored on the
            # model, but nothing here ever actually built or passed it - a
            # secondary optimization preference picked for CREATE_BUYING_REQUEST
            # was silently dropped instead of being remembered on the standing
            # request the way it already is for one-off SEARCH_PRODUCTS/
            # REFINE_SEARCH/SORT_RESULTS calls.
            optimization_configuration=(
                {"secondary": optimization_secondary.value} if optimization_secondary else None
            ),
            negotiation_authorized=params.negotiation_authorized,
        )
    except HTTPException as e:
        raise ZenoActionError("ACTIVE_REQUEST_EXISTS", str(e.detail))

    return {
        "action": "CREATE_BUYING_REQUEST",
        "status": "SUCCESS",
        "request": request_dict,
    }


async def _update_buying_request(
    db: AsyncSession,
    buyer_id: str,
    params: UpdateBuyingRequestParams,
    viewer_lat: Optional[float],
    viewer_lng: Optional[float],
) -> dict:
    """UPDATE_BUYING_REQUEST / CHANGE_BUDGET execution. Resolves
    category/subcategory names to ids exactly like _create_buying_request
    (same validation rules), then delegates the actual row mutation to
    BuyAgentService.update_request, which owns the "only touch keys that
    were actually provided" partial-update semantics.
    """
    update_fields: Dict[str, Any] = {}

    if params.category is not None:
        cat = (await db.execute(
            select(Category).where(Category.parent_id.is_(None), Category.name.ilike(params.category.strip()))
        )).scalar_one_or_none()
        if not cat:
            raise ZenoActionError("INVALID_CATEGORY", f"'{params.category}' is not a recognized category.")
        update_fields["category"] = cat.name

        # A category change invalidates any previously-set subcategory
        # unless a new one is given in the same call - avoids leaving a
        # subcategory_id on the row that belongs to the OLD category.
        if params.subcategory:
            sub = (await db.execute(
                select(Category).where(Category.parent_id == cat.id, Category.name.ilike(params.subcategory.strip()))
            )).scalar_one_or_none()
            if not sub:
                raise ZenoActionError(
                    "INVALID_SUBCATEGORY",
                    f"'{params.subcategory}' is not a recognized subcategory of {cat.name}.",
                )
            update_fields["subcategory_id"] = sub.id
        else:
            update_fields["subcategory_id"] = None
    elif params.subcategory is not None:
        raise ZenoActionError(
            "INVALID_SUBCATEGORY",
            "A subcategory change requires the category it belongs to.",
        )

    if params.query is not None:
        update_fields["query"] = params.query
    if params.max_price is not None:
        update_fields["max_price"] = params.max_price
    if params.min_price is not None:
        update_fields["min_price"] = params.min_price
    if params.location is not None:
        update_fields["location_name"] = params.location
        # A new location name without fresh coordinates would silently
        # desync location_name from lat/lng - only apply viewer coordinates
        # alongside a location change, same pairing _create_buying_request
        # uses (both come from the same "where the buyer is now" moment).
        if viewer_lat is not None and viewer_lng is not None:
            update_fields["lat"] = viewer_lat
            update_fields["lng"] = viewer_lng
    if params.max_distance_km is not None:
        update_fields["max_distance_km"] = params.max_distance_km
    if params.condition is not None:
        update_fields["condition"] = params.condition
    if params.attributes is not None:
        update_fields["attributes"] = params.attributes
    if params.must_have_features is not None:
        update_fields["must_have_features"] = params.must_have_features
    if params.negotiation_authorized is not None:
        update_fields["negotiation_authorized"] = params.negotiation_authorized

    if not update_fields:
        raise ZenoActionError("NO_CHANGES", "No fields were provided to update.")

    try:
        request_dict = await BuyAgentService(db).update_request(buyer_id, **update_fields)
    except HTTPException as e:
        raise ZenoActionError("INVALID_PRICE_RANGE", str(e.detail))

    if request_dict is None:
        return _failure(
            ZenoActionName.UPDATE_BUYING_REQUEST, "NO_ACTIVE_REQUEST",
            "You don't have an active buy request to update. Create one first.",
        )

    return {
        "action": "UPDATE_BUYING_REQUEST",
        "status": "SUCCESS",
        "request": request_dict,
    }


async def _cancel_request(db: AsyncSession, buyer_id: str) -> dict:
    request_dict = await BuyAgentService(db).cancel_request(buyer_id)
    if request_dict is None:
        return _failure(
            ZenoActionName.CANCEL_REQUEST, "NO_ACTIVE_REQUEST",
            "You don't have an active buy request to cancel.",
        )
    return {
        "action": "CANCEL_REQUEST",
        "status": "SUCCESS",
        "request": request_dict,
    }


async def _start_negotiation(db: AsyncSession, buyer_id: str, params: StartNegotiationParams) -> dict:
    """§17/§24 START_NEGOTIATION. The Hub is expected to have already shown
    the buyer a confirmation ("Shall I start the negotiation?") before ever
    calling this action - per the established confirm-then-call pattern
    CREATE_BUYING_REQUEST already uses - so no separate DB-persisted
    authorization flag is checked here (BuyAgentRequest.negotiation_authorized
    governs the *automatic* opener buy_agent_subscribers.py sends on a
    standing request's behalf, which is a different authorization moment
    from a buyer directly confirming "yes, message this specific seller
    now").

    Deliberately reuses the exact NegotiationMessage-writing pattern
    buy_agent_subscribers.py already established for auto-matched openers
    (role="broker", is_agent_initiated=True, plain honest copy) rather than
    reaching into negotiate.py's send_message (~2700 lines, built for a
    live HTTP request's own context - see that file's module docstring for
    the full reasoning, which applies identically here). This still lands
    in the same NegotiationMessage table negotiate_screen.dart already
    reads, so the thread shows up exactly like any other negotiation.
    """
    from api.database import Listing, NegotiationMessage

    listing = await db.get(Listing, params.listing_id)
    if not listing:
        raise ZenoActionError("LISTING_NOT_FOUND", "That listing could not be found.")
    if listing.seller_id == buyer_id:
        raise ZenoActionError("INVALID_TARGET", "You can't start a negotiation on your own listing.")

    opening = params.message or (
        f"Hi! I'm Zeno, negotiating on behalf of a buyer interested in your "
        f"listing \"{listing.name}\" at KES {listing.price:,.0f}. "
        f"Would you be open to a conversation?"
    )
    msg = NegotiationMessage(
        listing_id=params.listing_id, sender_id="broker", role="broker",
        recipient_role="seller", content=opening, buyer_id=buyer_id,
        msg_type="text", via_ai=True, is_agent_initiated=True,
    )
    db.add(msg)
    await db.commit()
    await db.refresh(msg)

    # Best-effort live WS push, same guarded pattern routers/negotiate.py's
    # direct_message endpoint uses - a missing/idle socket must never fail
    # the action itself, the message is already durably saved.
    try:
        from api.routers.media import broadcast_text_message
        await broadcast_text_message(params.listing_id, buyer_id, msg, "broker", False)
    except Exception:
        pass

    return {
        "action": "START_NEGOTIATION",
        "status": "SUCCESS",
        "listing_id": params.listing_id,
        "message_id": msg.id,
        "opening_message": opening,
    }


async def _seller_trust_map(db: AsyncSession, seller_ids: set) -> Dict[str, dict]:
    if not seller_ids:
        return {}
    rows = (await db.execute(
        select(User.id, User.is_verified, User.rating, User.completed_deals).where(User.id.in_(seller_ids))
    )).all()
    return {r.id: {"is_verified": r.is_verified, "rating": r.rating or 0, "completed_deals": r.completed_deals or 0}
            for r in rows}


def _relevance(listing: dict, query: Optional[str]) -> float:
    """Word-overlap heuristic, not a search engine - see module docstring.
    0-1 range so it composes cleanly with the other normalized signals in
    _rank."""
    if not query:
        return 0.5  # neutral - no query means "not applicable", not "bad"
    q_words = {w for w in query.lower().split() if w}
    name_words = {w for w in (listing.get("name") or "").lower().split() if w}
    if not q_words:
        return 0.5
    overlap = len(q_words & name_words)
    return min(1.0, overlap / len(q_words))


def _trust_score(listing: dict, trust_by_seller: Dict[str, dict]) -> float:
    t = trust_by_seller.get(listing["seller_id"])
    if not t:
        return 0.0
    # rating is 0-5, completed_deals is uncapped - compress with a log-ish
    # curve so one seller with 500 deals doesn't totally dominate one with
    # 20 solid deals; verification is a flat bonus, not the whole signal.
    rating_component = (t["rating"] / 5.0) * 0.5
    deals_component = min(1.0, t["completed_deals"] / 50.0) * 0.35
    verified_component = 0.15 if t["is_verified"] else 0.0
    return rating_component + deals_component + verified_component


def _price_score(listing: dict, prices: List[float]) -> float:
    if not prices or listing["price"] is None:
        return 0.5
    lo, hi = min(prices), max(prices)
    if hi == lo:
        return 1.0
    return 1.0 - ((listing["price"] - lo) / (hi - lo))  # cheaper = higher score


def _distance_score(listing: dict, distances: List[float]) -> float:
    d = listing.get("distance_km")
    if d is None or not distances:
        return 0.5
    lo, hi = min(distances), max(distances)
    if hi == lo:
        return 1.0
    return 1.0 - ((d - lo) / (hi - lo))  # closer = higher score


def _freshness_score(listing: dict, created_ats: List[str]) -> float:
    c = listing.get("created_at")
    if c is None or not created_ats:
        return 0.5
    ordered = sorted(created_ats)  # ISO strings sort chronologically
    idx = ordered.index(c)
    return idx / max(1, len(ordered) - 1)  # newest = highest index = highest score


def _rank(
    candidates: List[dict],
    query: Optional[str],
    primary: OptimizationCode,
    secondary: Optional[OptimizationCode],
    trust_by_seller: Dict[str, dict],
) -> List[dict]:
    if not candidates:
        return []

    prices = [c["price"] for c in candidates if c.get("price") is not None]
    distances = [c["distance_km"] for c in candidates if c.get("distance_km") is not None]
    created_ats = [c["created_at"] for c in candidates if c.get("created_at") is not None]

    def component(code: OptimizationCode, listing: dict) -> float:
        if code == OptimizationCode.PRICE_ASC:
            return _price_score(listing, prices)
        if code == OptimizationCode.DISTANCE:
            return _distance_score(listing, distances)
        if code == OptimizationCode.RELEVANCE:
            return _relevance(listing, query)
        if code == OptimizationCode.TRUST:
            return _trust_score(listing, trust_by_seller)
        if code == OptimizationCode.FRESHNESS:
            return _freshness_score(listing, created_ats)
        if code == OptimizationCode.BEST_VALUE:
            return (
                _price_score(listing, prices) * 0.4
                + _trust_score(listing, trust_by_seller) * 0.35
                + _distance_score(listing, distances) * 0.25
            )
        if code == OptimizationCode.AUCTION_VALUE:
            # Auctions aren't part of SEARCH_PRODUCTS's candidate pool
            # (that's Listing rows, not Auction rows) - accepted as a
            # valid code so the schema doesn't reject it, scored neutrally
            # here rather than silently mis-ranking regular listings by it.
            return 0.5
        # BALANCED_MATCH (default) and any future/unhandled code
        return (
            _relevance(listing, query) * 0.3
            + _price_score(listing, prices) * 0.25
            + _distance_score(listing, distances) * 0.2
            + _trust_score(listing, trust_by_seller) * 0.25
        )

    def score(listing: dict) -> float:
        primary_score = component(primary, listing)
        if secondary is None:
            return primary_score
        # Primary dominates, secondary breaks ties - not a 50/50 blend,
        # since "cheapest, then break ties by trust" should still mean
        # "cheapest" (§19's PRICE_TRUST example), not something in between.
        return primary_score * 0.85 + component(secondary, listing) * 0.15

    return sorted(candidates, key=score, reverse=True)
