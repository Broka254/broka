"""AI Broker Router v3.0 — broker chat + scam detection + price recommendations."""
from __future__ import annotations

from typing import Optional
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.security import get_current_user
from api.core.rate_limit import message_limiter
from .service import AIBrokerService

router = APIRouter()


class ChatIn(BaseModel):
    content: str
    history: list = []
    user_name: Optional[str] = None
    system_override: Optional[str] = None
    language: Optional[str] = "english"


class ScamCheckIn(BaseModel):
    message: str


class PriceRecommendIn(BaseModel):
    item_name: str
    category: str
    description: str
    location: Optional[str] = "Nairobi"


class DisputeAnalysisIn(BaseModel):
    buyer_claim: str
    seller_claim: str
    deal_amount: float
    item_name: str


@router.post("/chat")
async def broker_chat(
    body: ChatIn,
    current_user: dict = Depends(get_current_user),
):
    await message_limiter.check_and_record(current_user["id"])
    svc = AIBrokerService()
    return await svc.broker_chat(
        content=body.content,
        history=body.history,
        user_name=body.user_name,
        system_override=body.system_override,
        language=body.language or "english",
    )


@router.post("/scam-check")
async def scam_check(
    body: ScamCheckIn,
    current_user: dict = Depends(get_current_user),
):
    svc = AIBrokerService()
    return await svc.detect_scam(body.message)


@router.post("/price-recommend")
async def price_recommend(
    body: PriceRecommendIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = AIBrokerService()
    return await svc.price_recommend(
        item_name=body.item_name,
        category=body.category,
        description=body.description,
        location=body.location or "Nairobi",
        db=db,
    )


@router.post("/dispute-analysis")
async def dispute_analysis(
    body: DisputeAnalysisIn,
    current_user: dict = Depends(get_current_user),
):
    svc = AIBrokerService()
    return await svc.dispute_analysis(
        buyer_claim=body.buyer_claim,
        seller_claim=body.seller_claim,
        deal_amount=body.deal_amount,
        item_name=body.item_name,
    )


class ShoppingAdvisorIn(BaseModel):
    query: str
    history: list = []


@router.post("/shopping-advisor")
async def shopping_advisor(
    body: ShoppingAdvisorIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from sqlalchemy import select
    from api.database import Category
    from api.domains.listings.service import ListingService

    # Resolves the doc's own TODO: an unfiltered call defeats the point of
    # a pre-filtered shortlist. This is a first pass, same scope the doc
    # itself scoped this to (a keyword match against real category names,
    # not full query parsing, which it flags as "genuinely open") - a
    # category name appearing anywhere in the buyer's free-text query
    # narrows the shortlist to that category (or its children, matching
    # the same semantics as GET /listings?category_id=).
    category_id = None
    query_lower = body.query.lower()
    categories = (await db.execute(select(Category))).scalars().all()
    for cat in categories:
        if cat.name.lower() in query_lower:
            category_id = cat.id
            break

    svc = ListingService(db)
    shortlist = await svc.list_listings(category_id=category_id, limit=20)
    advisor = AIBrokerService()
    result = await advisor.shopping_advisor(query=body.query, shortlist=shortlist, history=body.history)
    # shortlist included alongside the reply (not just prose) so the
    # client can render the items as tappable cards - a text description
    # of matching listings with no way to actually reach them would
    # defeat the point of a shopping advisor.
    result["shortlist"] = shortlist
    return result
