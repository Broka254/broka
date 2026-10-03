"""What a user has paid BROKA: listing fees and premium plans, for the
Payment Receipts screen.

Separate from a seller's deal receipts (money a buyer paid them, through
escrow) because it is the other direction - money out of the seller, not
into them - and adding the two together would make "released to you" a
number that is not.

Only settled payments. A pending prompt or a cancelled one is not a
receipt: showing it would tell a seller they paid for something they did
not.
"""
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing
from api.domains.pricing.plans import PREMIUM_BY_ID
from api.models.listing_payment import ListingPayment, ListingPaymentStatus
from api.models.subscription import SubscriptionPayment, SubscriptionPaymentStatus


def _months(n: int) -> str:
    return "1 month" if n == 1 else f"{n} months"


async def charges_paid_by(db: AsyncSession, user_id: str, limit: int = 50) -> list[dict]:
    """The user's settled listing fees and plan payments, newest first."""
    fees = (await db.execute(
        select(ListingPayment, Listing.name)
        .join(Listing, Listing.id == ListingPayment.listing_id)
        .where(ListingPayment.user_id == user_id,
               ListingPayment.status == ListingPaymentStatus.SUCCESS)
        .order_by(ListingPayment.paid_at.desc())
        .limit(limit)
    )).all()
    plans = (await db.execute(
        select(SubscriptionPayment)
        .where(SubscriptionPayment.user_id == user_id,
               SubscriptionPayment.status == SubscriptionPaymentStatus.SUCCESS)
        .order_by(SubscriptionPayment.paid_at.desc())
        .limit(limit)
    )).scalars().all()

    charges = []
    for p, listing_name in fees:
        detail = _months(p.months)
        if p.featured_plan and p.featured_amount:
            detail += f" + featured (KES {p.featured_amount:,})"
        charges.append({
            "id": p.id,
            "kind": "listing_fee",
            "title": "Listing fee",
            "subject": listing_name,
            "detail": detail,
            "amount": p.amount,
            "provider": "M-Pesa",
            "reference": p.mpesa_receipt,
            # paid_at is set on success; created_at only for a row settled
            # before that column was written.
            "paid_at": (p.paid_at or p.created_at).isoformat(),
        })
    for p in plans:
        plan = PREMIUM_BY_ID.get(p.plan_id)
        charges.append({
            "id": p.id,
            "kind": "premium",
            "title": "Premium plan",
            "subject": f"BROKA {plan.name if plan else p.plan_id.title()}",
            "detail": _months(p.months),
            "amount": p.amount,
            "provider": "M-Pesa",
            "reference": p.mpesa_receipt,
            "paid_at": (p.paid_at or p.created_at).isoformat(),
        })
    # ISO strings of naive UTC sort as the times do.
    charges.sort(key=lambda c: c["paid_at"], reverse=True)
    return charges[:limit]
