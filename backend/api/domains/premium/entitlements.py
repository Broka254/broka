"""What a user's plan lets them do this month - and spending it.

Every premium feature asks here before it does the thing that costs money
(consume), and gives the allowance back if that thing then did not happen
(release). With PREMIUM_ENABLED off, everything is allowed and nothing is
counted: the features stay free, as they were before plans existed.

Allowances are per plan month (models/subscription.py): month n of a plan
runs from its start + n x 30 days. Someone without a plan has only
FREE_TRIAL - one AI cover, once.

A refusal is a 402 whose detail the app reads: {"code", "message",
"feature", "plan", "upgrade_to"}. PREMIUM_REQUIRED means the user has no
plan with this feature; ALLOWANCE_USED that this month's is spent. The
message says what to do in words, because older app builds show it as is.
"""
from __future__ import annotations

import math
from datetime import datetime, timedelta
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.domains.pricing import costs
from api.domains.pricing.plans import FREE_TRIAL, PREMIUM_BY_ID, PREMIUM_PLANS, PremiumPlan
from api.models.subscription import FeatureUsage, Subscription

MONTH = timedelta(days=30)


class Feature:
    """The counted allowances - each a PremiumPlan field of the same name."""
    VOICE = "voice_requests"
    SMS = "sms_alerts"
    AUTO_NEGOTIATION = "auto_negotiations"
    AI_COVER = "ai_covers"
    AUCTION = "auctions_hosted"
    AI_DESCRIPTION = "ai_descriptions"
    PRICE_CHECK = "price_checks"
    COUNTED = (VOICE, SMS, AUTO_NEGOTIATION, AI_COVER, AUCTION, AI_DESCRIPTION, PRICE_CHECK)
    # Not counted per month but held at once: watches running now.
    WATCHES = "agent_watches"


# How each feature is named to a user, singular and plural.
_NAMES = {
    Feature.VOICE: ("voice request", "voice requests", "Talking to Zeno in voice mode"),
    Feature.SMS: ("text from Zeno", "texts from Zeno", "Texts from Zeno"),
    Feature.AUTO_NEGOTIATION: ("negotiation by Zeno", "negotiations by Zeno", "Zeno negotiating for you"),
    Feature.AI_COVER: ("AI cover try", "AI cover tries", "AI covers"),
    Feature.AUCTION: ("auction", "auctions", "Hosting auctions"),
    Feature.AI_DESCRIPTION: ("description by Zeno", "descriptions by Zeno",
                             "Zeno writing your description from your photo"),
    Feature.PRICE_CHECK: ("price check", "price checks", "Pricing your listing with Zeno"),
    Feature.WATCHES: ("Buying Agent watch", "Buying Agent watches", "The Buying Agent"),
}


def enabled() -> bool:
    return settings.premium_enabled


async def active_subscription(
    db: AsyncSession, user_id: str, now: Optional[datetime] = None,
) -> Optional[Subscription]:
    now = now or datetime.utcnow()
    sub = (await db.execute(
        select(Subscription).where(Subscription.user_id == user_id)
    )).scalar_one_or_none()
    return sub if sub is not None and sub.paid_until > now else None


def plan_of(sub: Optional[Subscription]) -> Optional[PremiumPlan]:
    return PREMIUM_BY_ID.get(sub.plan_id) if sub is not None else None


def month_index(sub: Subscription, now: datetime) -> int:
    return max(0, math.floor((now - sub.started_at) / MONTH))


def period_key(sub: Subscription, now: datetime) -> str:
    return f"{sub.started_at:%Y%m%dT%H%M%S}:{month_index(sub, now)}"


def renews_at(sub: Subscription, now: datetime) -> datetime:
    """When this month's allowances start again - or the plan ends first."""
    return min(sub.started_at + (month_index(sub, now) + 1) * MONTH, sub.paid_until)


def first_plan_with(feature: str) -> Optional[PremiumPlan]:
    """The cheapest plan that includes `feature` - the one to suggest."""
    return next((p for p in PREMIUM_PLANS if p.allowance(feature) > 0), None)


def _next_plan_up(plan: Optional[PremiumPlan], feature: str) -> Optional[PremiumPlan]:
    have = plan.allowance(feature) if plan else 0
    return next((p for p in PREMIUM_PLANS if p.allowance(feature) > have
                 and (plan is None or p.monthly_price > plan.monthly_price)), None)


def _refusal(feature: str, plan: Optional[PremiumPlan], sub: Optional[Subscription],
             now: datetime, spent: bool) -> HTTPException:
    one, many, title = _NAMES[feature]
    up = _next_plan_up(plan, feature)
    if spent and plan is not None:
        renew = renews_at(sub, now)
        message = (f"You've used this month's {plan.allowance(feature)} {many} on "
                   f"BROKA {plan.name}. They renew on {renew.day} {renew:%b}"
                   + (f" - or move up to {up.name} for {up.allowance(feature)} a month." if up else "."))
        code = "ALLOWANCE_USED"
    elif spent:
        message = (f"You've used your free {many}. "
                   + (f"BROKA {up.name} gives you {up.allowance(feature)} a month, from "
                      f"KES {up.monthly_price}." if up else ""))
        code = "ALLOWANCE_USED"
    else:
        message = (f"{title} is part of BROKA "
                   + (f"{up.name} - from KES {up.monthly_price} a month." if up else "Premium."))
        code = "PREMIUM_REQUIRED"
    if feature == Feature.AI_COVER:
        message += (" A cover that stands out on Home gets more taps, and more taps sell "
                    "faster. You can still upload a cover from your gallery, free.")
    if feature == Feature.AUCTION:
        message += " Bidding stays free for everyone."
    # The selling help says why it is worth paying for - a seller deciding
    # whether to upgrade is deciding whether it sells their item sooner -
    # and that the free way is still there.
    if feature == Feature.AI_DESCRIPTION:
        message += (" Listings with a clear, detailed description sell faster - buyers don't "
                    "have to ask the basics. You can still write your own, free.")
    if feature == Feature.PRICE_CHECK:
        message += (" A listing priced right from the start sells faster - Zeno checks it "
                    "against similar listings on BROKA.")
    return HTTPException(status_code=402, detail={
        "code": code, "message": message.strip(), "feature": feature,
        "plan": plan.id if plan else None, "upgrade_to": up.id if up else None,
    })


async def _add(db: AsyncSession, user_id: str, feature: str, key: str, n: int, limit: int) -> bool:
    """used += n if that stays within `limit`, as one UPDATE: two requests
    racing for the last try cannot both get it."""
    now = datetime.utcnow()
    guarded = (
        update(FeatureUsage)
        .where(FeatureUsage.user_id == user_id, FeatureUsage.feature == feature,
               FeatureUsage.period_key == key, FeatureUsage.used + n <= limit)
        .values(used=FeatureUsage.used + n, updated_at=now)
        .execution_options(synchronize_session=False)
    )
    # Never a full rollback here: callers spend an allowance in the middle
    # of their own work (a Buying Agent match loop), and rolling the session
    # back would throw that away. Only the usage row's insert is undone, to
    # a savepoint.
    if (await db.execute(guarded)).rowcount:
        await db.commit()
        return True
    exists = (await db.execute(select(FeatureUsage.id).where(
        FeatureUsage.user_id == user_id, FeatureUsage.feature == feature,
        FeatureUsage.period_key == key))).scalar()
    if exists or n > limit:
        return False
    try:
        async with db.begin_nested():
            db.add(FeatureUsage(user_id=user_id, feature=feature, period_key=key, used=n, updated_at=now))
        await db.commit()
        return True
    except IntegrityError:
        # Another request made the row first: go through the guard again.
        ok = bool((await db.execute(guarded)).rowcount)
        if ok:
            await db.commit()
        return ok


async def _allowance(db: AsyncSession, user_id: str, feature: str, now: datetime):
    sub = await active_subscription(db, user_id, now)
    plan = plan_of(sub)
    if plan is not None:
        return sub, plan, plan.allowance(feature), period_key(sub, now)
    return None, None, FREE_TRIAL.get(feature, 0), "trial"


async def consume(db: AsyncSession, user_id: str, feature: str, n: int = 1) -> None:
    """Spend `n` of `feature`, or raise the 402 that says why not.

    Commits its own small transaction, so call it before the costly thing -
    and release() if that thing then fails. Anything the caller has pending
    in the session is committed with it.
    """
    if not enabled():
        return
    now = datetime.utcnow()
    sub, plan, limit, key = await _allowance(db, user_id, feature, now)
    if limit <= 0:
        raise _refusal(feature, plan, sub, now, spent=False)
    if not await _add(db, user_id, feature, key, n, limit):
        raise _refusal(feature, plan, sub, now, spent=True)


async def require(db: AsyncSession, user_id: str, feature: str) -> None:
    """The 402 PREMIUM_REQUIRED unless the user's plan includes `feature` -
    without spending any of it. For a screen the feature opens (Zeno's
    pricing conversation), where only the costly step inside it is
    counted: a spent month still opens it, and is refused at that step."""
    if not enabled():
        return
    now = datetime.utcnow()
    sub, plan, limit, _key = await _allowance(db, user_id, feature, now)
    if limit <= 0:
        raise _refusal(feature, plan, sub, now, spent=False)


async def try_consume(db: AsyncSession, user_id: str, feature: str, n: int = 1) -> bool:
    """consume() for background work, where there is nobody to show a 402
    to: True if spent (or premium is off), False if not allowed."""
    try:
        await consume(db, user_id, feature, n)
        return True
    except HTTPException as exc:
        if exc.status_code != 402:
            raise
        return False


async def release(db: AsyncSession, user_id: str, feature: str, n: int = 1) -> None:
    """Give back what consume() took for something that did not happen - a
    cover the model failed to make, a text that did not send."""
    if not enabled():
        return
    now = datetime.utcnow()
    _sub, _plan, _limit, key = await _allowance(db, user_id, feature, now)
    await db.execute(
        update(FeatureUsage)
        .where(FeatureUsage.user_id == user_id, FeatureUsage.feature == feature,
               FeatureUsage.period_key == key, FeatureUsage.used >= n)
        .values(used=FeatureUsage.used - n, updated_at=now)
        .execution_options(synchronize_session=False)
    )
    await db.commit()


async def watch_cap(db: AsyncSession, user_id: str) -> int:
    """How many Buying Agent watches may run at once."""
    if not enabled():
        return settings.buy_agent_max_active
    plan = plan_of(await active_subscription(db, user_id))
    return plan.agent_watches if plan else 0


def watches_refusal() -> HTTPException:
    """The 402 for a user whose plan runs no watches at all."""
    return _refusal(Feature.WATCHES, None, None, datetime.utcnow(), spent=False)


async def summary(db: AsyncSession, user_id: str) -> dict:
    """GET /premium/me: the plan, how long it runs, and what is left."""
    now = datetime.utcnow()
    if not enabled():
        return {"enabled": False, "plan": None, "paid_until": None, "renews_at": None,
                "usage": {}, "trial": {}}
    sub = await active_subscription(db, user_id, now)
    plan = plan_of(sub)
    keys = {f: (period_key(sub, now) if plan else "trial") for f in Feature.COUNTED}
    rows = (await db.execute(select(FeatureUsage.feature, FeatureUsage.period_key, FeatureUsage.used)
                             .where(FeatureUsage.user_id == user_id))).all()
    used = {feature: n for feature, key, n in rows if keys.get(feature) == key}

    def entry(feature: str) -> dict:
        allowance = plan.allowance(feature) if plan else FREE_TRIAL.get(feature, 0)
        spent = used.get(feature, 0)
        return {"allowance": allowance, "used": spent, "left": max(0, allowance - spent)}

    usage = {f: entry(f) for f in Feature.COUNTED}
    from api.domains.buy_agent.service import CAPPED_STATUSES
    from api.database import BuyAgentRequest
    watching = (await db.execute(select(func.count(BuyAgentRequest.id)).where(
        BuyAgentRequest.buyer_id == user_id, BuyAgentRequest.status.in_(CAPPED_STATUSES)))).scalar() or 0
    cap = plan.agent_watches if plan else 0
    usage[Feature.WATCHES] = {"allowance": cap, "used": watching, "left": max(0, cap - watching)}
    return {
        "enabled": True,
        "plan": ({"id": plan.id, "name": plan.name, "monthly_price": plan.monthly_price}
                 if plan else None),
        "paid_until": sub.paid_until.isoformat() if plan else None,
        "renews_at": renews_at(sub, now).isoformat() if plan else None,
        "priority_support": bool(plan and plan.priority_support_minutes),
        "usage": usage,
        "trial": {f: usage[f]["left"] for f in FREE_TRIAL} if plan is None else {},
        "ai_cover_tries_per_listing": costs.AI_COVER_TRIES_PER_LISTING,
    }
