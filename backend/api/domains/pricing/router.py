"""Pricing router - GET /pricing/listing-fee/quote, /pricing/plans, /pricing/categories.

Read-only: these say what things cost. Charging for them is a separate step
(PRICING.md, "What is not built yet").
"""
from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.domains.pricing import plans, service
from api.security import get_current_user

router = APIRouter()

# Matches escrow's MAX_AGREED_PRICE_KES order of magnitude: anything above is
# a typo, and the quote would only echo it back as the category's maximum.
_MAX_PRICE = 1_000_000_000


@router.get("/listing-fee/quote")
async def listing_fee_quote(
    category: str = Query(..., min_length=1, max_length=60),
    price: float = Query(..., gt=0, le=_MAX_PRICE, description="Price of one unit, KES"),
    quantity: int = Query(1, ge=1, le=100_000, description="Units offered in the listing"),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The monthly listing fee for the signed-in seller, and 1-6 month options.

    Priced on the caller's own completion record, so it needs sign-in; the
    category table (GET /pricing/categories) shows everyone the new-seller
    price.
    """
    return await service.listing_fee_quote(db, current_user["id"], category, price, quantity)


@router.get("/plans")
async def pricing_plans():
    """Premium plans, store plans and the commission."""
    return plans.catalog()


@router.get("/categories")
async def pricing_categories():
    """Every category's risk coefficient, fee ceiling and typical price."""
    return {"currency": "KES", "categories": service.category_table()}
