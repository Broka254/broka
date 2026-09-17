"""Buy-Agent Router v1 — POST /buy-agent-requests, GET /buy-agent-requests/me,
POST /buy-agent-requests/action (Zeno structured actions, see actions.py)."""
from __future__ import annotations

from typing import Optional
from pydantic import BaseModel
from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db, Category
from api.security import get_current_user
from api.domains.ai_broker.service import AIBrokerService
from .service import BuyAgentService
from .actions import ZenoActionRequest, ZenoActionError, execute_action

router = APIRouter()


class BuyAgentRequestIn(BaseModel):
    category: str
    max_price: float
    must_have_features: list[str] = []
    # FIX (ChatGPT-review audit, 2026-08-15): added for parity with the
    # structured CREATE_BUYING_REQUEST action, which already gained this
    # field in the same pass - see actions.py/service.py. Defaults False,
    # matching the column's own safe default.
    negotiation_authorized: bool = False


class ParseBuyRequestIn(BaseModel):
    text: str


class ParseSearchIntentIn(BaseModel):
    text: str
    # Present when this is a REFINE_SEARCH follow-up rather than a fresh
    # search - the Hub's current SearchProductsParams-shaped filters, so
    # the model can merge the new text against them (Design v2 §21: "Zeno
    # must understand that 'it' refers to the active request"). None for a
    # first-time search, reproducing the original one-shot parse exactly.
    existing_filters: Optional[dict] = None


@router.post("/parse")
async def parse_buy_request(
    body: ParseBuyRequestIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Pre-fills category/max_price/must_have_features from one free-text
    sentence (e.g. "Samsung phone, 12GB RAM, under 30000") so the buy-agent
    sheet can lead with a single description box instead of three separate
    fields, while the actual POST "" below still only ever receives the
    same structured shape it always has - nothing about how a request gets
    created or matched changes, only how the form gets filled in.
    Returns nulls (never an error) if categories aren't seeded yet or the
    model call fails - same "form just stays blank, user fills it by hand"
    fallback as before this endpoint existed.
    """
    categories = (await db.execute(select(Category))).scalars().all()
    valid_names = [c.name for c in categories]
    return await AIBrokerService().parse_buy_request(text=body.text, valid_categories=valid_names)


@router.post("/parse-intent")
async def parse_search_intent(
    body: ParseSearchIntentIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Buying Agent Hub's richer sibling of /parse (Design v2 §14-15) -
    extracts into the SearchProductsParams shape instead of the plain
    sheet's 3 fields, so the Hub can feed the result straight to
    POST /buy-agent-requests/action. /parse itself is untouched - the old
    sheet keeps working exactly as before.
    """
    all_cats = (await db.execute(select(Category))).scalars().all()
    top_level = [c for c in all_cats if c.parent_id is None]
    valid_names = [c.name for c in top_level]
    subs_by_cat = {
        c.name: [s.name for s in all_cats if s.parent_id == c.id]
        for c in top_level
    }
    return await AIBrokerService().parse_search_intent(
        text=body.text, valid_categories=valid_names, subcategories_by_category=subs_by_cat,
        existing_filters=body.existing_filters,
    )


@router.post("/action")
async def zeno_action(
    body: ZenoActionRequest,
    lat: Optional[float] = None,
    lng: Optional[float] = None,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Zeno structured action endpoint (Design v2 §16-20, §26). Zeno (the
    LLM) produces the action/optimization_code/parameters; this is the
    ACTION PARSER + SCHEMA VALIDATOR + AUTHORIZATION CHECK + EXECUTION
    stages. FastAPI already rejects an unrecognized action or optimization
    code before this function body even runs, since both are enums on
    ZenoActionRequest - that's "do not allow the model to invent
    unsupported actions" (§17) enforced structurally, not by a runtime
    if/else chain. lat/lng are the caller's current position, the same as
    every other location-aware endpoint - Zeno doesn't get its own notion
    of where the user is.
    """
    try:
        return await execute_action(db, current_user["id"], body, viewer_lat=lat, viewer_lng=lng)
    except ZenoActionError as e:
        return {"action": body.action.value, "status": "FAILED", "error_code": e.error_code, "message": e.message}


@router.post("")
async def create_buy_agent_request(
    body: BuyAgentRequestIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await BuyAgentService(db).create_request(
        buyer_id=current_user["id"], category=body.category,
        max_price=body.max_price, must_have_features=body.must_have_features,
        negotiation_authorized=body.negotiation_authorized,
    )


@router.get("/me")
async def get_my_buy_agent_request(
    current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    return await BuyAgentService(db).get_active_for_buyer(current_user["id"])
