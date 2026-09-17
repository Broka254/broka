"""Buy-Agent Router v1 — POST /buy-agent-requests, GET /buy-agent-requests/me,
POST /buy-agent-requests/action (Zeno structured actions, see actions.py)."""
from __future__ import annotations

import logging
from typing import Optional
from pydantic import BaseModel, Field
from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db, Category
from api.security import get_current_user
from api.core.rate_limit import ai_chat_limiter, message_limiter
from api.domains.ai_broker.service import AIBrokerService
from .service import BuyAgentService
from .actions import ZenoActionRequest, ZenoActionError, ZenoActionName, execute_action
from . import conversation

router = APIRouter()


class BuyAgentRequestIn(BaseModel):
    category: str = Field(min_length=1, max_length=60)
    # FIX (buying-agent bug-hunt, 2026-09-17): max_price was an unbounded
    # float, so 0 and negatives were accepted here and stored as a standing
    # request that can never match anything (ListingCreate already requires
    # price > 0). BuyAgentService validates this too - both, deliberately:
    # the schema so the caller gets a 422 naming the field, the service so
    # the rule holds for every path into it, not just this one.
    max_price: float = Field(gt=0)
    must_have_features: list[str] = Field(default_factory=list, max_length=20)
    # FIX (ChatGPT-review audit, 2026-08-15): added for parity with the
    # structured CREATE_BUYING_REQUEST action, which already gained this
    # field in the same pass - see actions.py/service.py. Defaults False,
    # matching the column's own safe default.
    negotiation_authorized: bool = False


class ParseBuyRequestIn(BaseModel):
    # Bounded because this string is pasted into an LLM prompt and billed
    # per token - it was previously an unbounded `str`.
    text: str = Field(min_length=1, max_length=1000)


class ParseSearchIntentIn(BaseModel):
    text: str = Field(min_length=1, max_length=1000)
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

    Rate-limited (FIX, buying-agent bug-hunt 2026-09-17): this and
    /parse-intent are the only two endpoints in the feature that spend real
    money per call - each one is a live LLM round-trip through
    AIBrokerService - and neither had any limit at all, so a single logged-in
    account could run the AI bill up as fast as it could issue requests.
    ai_chat_limiter has been defined in api/core/rate_limit.py all along
    with zero call sites anywhere in the codebase (grepped); these are the
    endpoints it was written for.
    """
    await ai_chat_limiter.check_and_record(current_user["id"])
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

    Rate-limited for the same reason as /parse above - see its docstring.
    """
    await ai_chat_limiter.check_and_record(current_user["id"])
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


class ConverseTurnIn(BaseModel):
    """One turn of the conversational Buying Agent.

    Stateless by design - the client sends back the transcript and the
    criteria gathered so far, the same way the existing Zeno chat already
    does. `slots` and `questions_asked` are re-validated server-side every
    turn (see conversation.converse), so a client cannot use them to reach
    anything outside its own search.
    """
    message: str = Field(min_length=1, max_length=1000)
    history: list[dict] = Field(default_factory=list, max_length=40)
    slots: Optional[dict] = None
    # How many questions Zeno has already asked in this conversation. Caps
    # the interrogation - see conversation.MAX_QUESTIONS.
    questions_asked: int = Field(default=0, ge=0, le=20)


@router.post("/converse")
async def converse_with_zeno(
    body: ConverseTurnIn,
    lat: Optional[float] = None,
    lng: Optional[float] = None,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The Buying Agent as a conversation rather than a form.

    Replaces the parse -> confirm -> search wizard (/parse-intent plus a
    SEARCH_PRODUCTS action) for the Zeno buying screen. Each call returns
    either phase=ASKING with Zeno's next question, or phase=RESULTS with
    real listings and what Zeno says about them. /parse-intent and /action
    are untouched - they still back the plain sheet and every programmatic
    caller.

    Rate-limited on ai_chat_limiter like the other two model-backed
    endpoints here: a search turn is two LLM round-trips, so this is the
    most expensive thing in the feature.
    """
    await ai_chat_limiter.check_and_record(current_user["id"])
    return await conversation.converse(
        db=db,
        buyer_id=current_user["id"],
        message=body.message,
        history=body.history,
        slots=body.slots,
        questions_asked=body.questions_asked,
        viewer_lat=lat,
        viewer_lng=lng,
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
    # FIX (buying-agent bug-hunt, 2026-09-17): START_NEGOTIATION writes a
    # message into another user's inbox, so it is rate-limited on the same
    # per-user message_limiter every other human-to-human message on this
    # platform goes through - it was the one messaging path with no limit
    # of any kind. The other actions are reads or touch only the caller's
    # own standing request, so they stay unlimited.
    if body.action == ZenoActionName.START_NEGOTIATION:
        await message_limiter.check_and_record(current_user["id"])
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
    """Plain (non-Zeno) create, used by the Flutter buy-agent sheet.

    FIX (buying-agent bug-hunt, 2026-09-17): the category string went
    straight to the DB unchecked and un-normalised. Two consequences, both
    silent: a typo'd or unknown category produced a standing request that
    could never match anything (the matcher compares against
    Listing.category), and a valid category typed in a different case was
    stored in that case. api/core/buy_agent_subscribers.py now compares
    case-insensitively, but canonicalising here as well keeps what the row
    stores - and therefore what Home's "Zeno is watching for you" card
    displays - equal to the real category name, exactly as the
    CREATE_BUYING_REQUEST action path has always done.

    Deliberately permissive about the unknown case rather than a hard 422:
    Category rows are seeded data, and an unseeded/partially-seeded install
    must not make the sheet unusable. An unrecognised name is kept verbatim
    and logged, which is the pre-existing behaviour.
    """
    category = body.category.strip()
    match = (await db.execute(
        select(Category).where(Category.parent_id.is_(None), Category.name.ilike(category))
    )).scalar_one_or_none()
    if match:
        category = match.name
    else:
        logging.getLogger(__name__).info(
            "[buy_agent] standing request created with an unrecognised category %r "
            "- it will only match listings whose own category text equals it", category,
        )

    return await BuyAgentService(db).create_request(
        buyer_id=current_user["id"], category=category,
        max_price=body.max_price, must_have_features=body.must_have_features,
        negotiation_authorized=body.negotiation_authorized,
    )


@router.get("/me")
async def get_my_buy_agent_request(
    current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    return await BuyAgentService(db).get_active_for_buyer(current_user["id"])
