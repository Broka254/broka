"""Founder intelligence: the numbers the admin dashboard decides with.

The Command Center pulse, Market Intelligence (demand against supply by
category and county, seller responsiveness), Growth (funnel and weekly
retention) and the founder reports are all computed here, from durable
tables only - never process-local counters - so two reads of the same
period agree, and a report written on Monday says what the dashboard said.

Definitions, kept in one place because every page and report repeats them:

  * Staff are excluded. Administrators post test listings and chat with
    themselves; counting that as marketplace activity flatters every
    early number. A user with is_admin is staff.
  * Buyer contact on a listing is a buyer's own chat message on it
    (negotiation_messages.role = "buyer") or an interests row - the two
    records BROKA keeps when a buyer reaches out. Zeno's relayed copies
    (role "broker") are not a second contact.
  * Liquidity - BROKA's north-star (BUSINESS_MODEL_REVIEW.md 2.4): the
    share of new listings that get buyer contact within 7 days of being
    posted. Measured on the listings whose 7-day window closed inside the
    period, [start - 7d, end - 7d), so every listing counted had its full
    week. The target is half of them.
  * A seller reply is the seller's own message (role "seller") in the
    thread after the buyer's first message. Zeno answering for them is not
    a reply: the point is whether the human shows up.
  * Deals agreed are deals past negotiation (not negotiating, not
    cancelled). With payments outside BROKA this is the only sale record
    there is, alongside buyers' sold-out reports.

Every query is bounded by its window or by a GROUP BY; row-level reads of
the busiest table (negotiation_messages) carry ROW_CAP and report
`truncated` instead of silently dropping rows. Times are naive UTC like
every column; local-time boundaries (EAT) are the caller's choice.
"""
from __future__ import annotations

import bisect
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from typing import Any, Iterable, Optional

from sqlalchemy import case, exists, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.core.timeutil import to_naive_utc
from api.database import (
    AccountType,
    BuyAgentRequest,
    Deal,
    DealStatus,
    FeaturedPayment,
    FraudEvent,
    Interest,
    Listing,
    ListingLike,
    ListingStatus,
    ListingType,
    ListingView,
    MpesaTransaction,
    NegotiationMessage,
    User,
    VerificationPayment,
    Wishlist,
    ZenoConversation,
    ZenoTurn,
)

# ── Thresholds ────────────────────────────────────────────────────────────────

LIQUIDITY_WINDOW = timedelta(days=7)
# "at least half of new listings get a buyer chat within 7 days"
# (BUSINESS_MODEL_REVIEW.md 2.6, the bar a category clears before boosts).
LIQUIDITY_TARGET_PCT = 50.0
REPLY_WINDOW = timedelta(hours=24)
REPLY_TARGET_PCT = 50.0
# A buyer whose last message has gone unanswered this long is waiting;
# threads quiet for longer than the lookback are treated as abandoned.
WAITING_AFTER = timedelta(hours=24)
WAITING_LOOKBACK = timedelta(days=14)
STALE_AFTER = timedelta(days=14)
# Row-level reads of negotiation_messages stop here and say so.
ROW_CAP = 50_000

# First-reply deadlines per complaint severity, in hours. Urgent means a
# person is being harmed or charged right now.
COMPLAINT_SLA_HOURS = {"urgent": 4, "high": 24, "normal": 72, "low": 120}
OPEN_FEEDBACK_STATUSES = ("open", "acknowledged", "in_progress")

# Day-30 targets (BUSINESS_MODEL_REVIEW.md 4): 150 live listings, 5 paying
# businesses, KES 10,000 collected and 10 confirmed sales. "Paying
# businesses" is measured as paying customers - store billing is off, so a
# business pays BROKA the way any seller does - and confirmed sales as
# deals agreed, the only sale record BROKA keeps while payments are off.
DAY30_TARGETS = (
    ("live_listings", "Live listings", 150, "count"),
    ("paying_customers_30d", "Paying customers (30 days)", 5, "count"),
    ("collected_30d_minor", "Collected (30 days)", 10_000 * 100, "kes_minor"),
    ("deals_agreed_30d", "Deals agreed (30 days)", 10, "count"),
)

_AGREED_STATES = tuple(
    status for status in DealStatus
    if status not in (DealStatus.negotiating, DealStatus.cancelled)
)

# ── Small helpers ─────────────────────────────────────────────────────────────

def iso(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    return to_naive_utc(value).isoformat() + "Z"


def pct(numerator: float, denominator: float) -> Optional[float]:
    """Percentage with one decimal, or None when there is nothing to divide."""
    if not denominator:
        return None
    return round(numerator / denominator * 100, 1)


def change_pct(current: float, previous: Optional[float]) -> Optional[float]:
    """Relative change; None when the previous value is zero or unknown
    (a jump from 0 to 3 is not "+infinity percent")."""
    if not previous:
        return None
    return round((current - previous) / previous * 100, 1)


def median(values: Iterable[float]) -> Optional[float]:
    data = [float(v) for v in values]
    if not data:
        return None
    return round(statistics.median(data), 1)


def metric(current: float, previous: Optional[float] = None) -> dict:
    return {
        "current": current,
        "previous": previous,
        "change_pct": change_pct(current, previous) if previous is not None else None,
    }


def _staff():
    """Administrator ids, as a subquery for NOT IN filters."""
    return select(User.id).where(User.is_admin == True)  # noqa: E712


def _real_listing_chat():
    """A chat that is not on a staff test listing. Store-general threads
    (no listing) are kept; their store owner is checked where it matters."""
    staff_listings = select(Listing.id).where(Listing.seller_id.in_(_staff()))
    return or_(NegotiationMessage.listing_id.is_(None),
               NegotiationMessage.listing_id.not_in(staff_listings))


def _not_auction():
    # IS NULL kept: listing_type is nullable and NULL != 'auction' is NULL.
    return or_(Listing.listing_type.is_(None), Listing.listing_type != ListingType.auction)


def _category_key(raw: Optional[str]) -> tuple[str, str]:
    """(merge key, label). Categories are canonical names, but an older
    app build wrote other casings; one category must not split in two."""
    label = (raw or "").strip() or "Uncategorised"
    return label.lower(), label


def _county_key(raw: Optional[str]) -> tuple[str, str]:
    label = (raw or "").strip() or "Unknown"
    return label.lower(), label


async def _count(db: AsyncSession, column, *where) -> int:
    return int((await db.execute(select(func.count(column)).where(*where))).scalar() or 0)


async def _distinct_ids(db: AsyncSession, column, *where) -> set[str]:
    rows = (await db.execute(select(column).where(*where).distinct())).all()
    return {value for (value,) in rows if value}


def _windows(start: datetime, end: datetime) -> tuple[tuple[datetime, datetime], tuple[datetime, datetime]]:
    width = end - start
    return (start, end), (start - width, start)


# ── Liquidity ─────────────────────────────────────────────────────────────────

async def listing_contacts(
    db: AsyncSession, cohort_start: datetime, cohort_end: datetime,
) -> list[dict]:
    """Every listing posted in [cohort_start, cohort_end) with when a buyer
    first reached out (None if never). One row per listing, so callers can
    group by category or county."""
    staff = _staff()
    filters = (
        Listing.created_at >= cohort_start,
        Listing.created_at < cohort_end,
        Listing.seller_id.not_in(staff),
        _not_auction(),
    )
    rows = (await db.execute(
        select(Listing.id, Listing.created_at, Listing.category, Listing.location_county)
        .where(*filters)
    )).all()
    if not rows:
        return []
    cohort_ids = select(Listing.id).where(*filters)
    # visibility-ok: earliest buyer message time per listing, no content.
    first_message = dict((await db.execute(
        select(NegotiationMessage.listing_id, func.min(NegotiationMessage.created_at))
        .where(NegotiationMessage.role == "buyer", NegotiationMessage.listing_id.in_(cohort_ids), NegotiationMessage.sender_id.not_in(staff))
        .group_by(NegotiationMessage.listing_id)
    )).all())
    first_interest = dict((await db.execute(
        select(Interest.listing_id, func.min(Interest.created_at))
        .where(Interest.listing_id.in_(cohort_ids), Interest.buyer_id.not_in(staff))
        .group_by(Interest.listing_id)
    )).all())
    out = []
    for listing_id, created_at, category, county in rows:
        if created_at is None:
            continue
        created = to_naive_utc(created_at)
        stamps = [to_naive_utc(t) for t in (first_message.get(listing_id), first_interest.get(listing_id)) if t]
        first = min(stamps) if stamps else None
        out.append({
            "listing_id": listing_id,
            "created_at": created,
            "category": category,
            "county": county,
            "first_contact_at": first,
            "contacted_in_window": bool(first is not None and first - created <= LIQUIDITY_WINDOW),
        })
    return out


def summarise_liquidity(rows: list[dict], cohort_start: datetime, cohort_end: datetime) -> dict:
    contacted = [r for r in rows if r["contacted_in_window"]]
    hours = [
        (r["first_contact_at"] - r["created_at"]).total_seconds() / 3600
        for r in contacted
    ]
    return {
        "cohort_from": iso(cohort_start),
        "cohort_to": iso(cohort_end),
        "eligible": len(rows),
        "with_buyer_contact": len(contacted),
        "rate_pct": pct(len(contacted), len(rows)),
        "median_hours_to_first_contact": median(hours),
    }


async def liquidity_between(db: AsyncSession, start: datetime, end: datetime) -> dict:
    """Liquidity of the listings whose 7-day window closed in [start, end)."""
    cohort_start, cohort_end = start - LIQUIDITY_WINDOW, end - LIQUIDITY_WINDOW
    rows = await listing_contacts(db, cohort_start, cohort_end)
    return summarise_liquidity(rows, cohort_start, cohort_end)


# ── Seller replies ────────────────────────────────────────────────────────────

async def _thread_starts(db: AsyncSession, since: datetime) -> dict[tuple, datetime]:
    """(listing_id, store_id, buyer_id) -> first buyer message, for threads
    a buyer started at or after `since`."""
    staff = _staff()
    # visibility-ok: thread keys and first-message times, never content.
    rows = (await db.execute(
        select(NegotiationMessage.listing_id, NegotiationMessage.store_id, NegotiationMessage.buyer_id, func.min(NegotiationMessage.created_at))
        .where(NegotiationMessage.role == "buyer", NegotiationMessage.sender_id.not_in(staff),
               _real_listing_chat())
        .group_by(NegotiationMessage.listing_id, NegotiationMessage.store_id, NegotiationMessage.buyer_id)
        .having(func.min(NegotiationMessage.created_at) >= since)
    )).all()
    return {
        (listing_id, store_id, buyer_id): to_naive_utc(first)
        for listing_id, store_id, buyer_id, first in rows
        if first is not None
    }


async def _seller_message_times(db: AsyncSession, since: datetime) -> tuple[dict[tuple, list[datetime]], bool]:
    # visibility-ok: thread keys and timestamps of seller messages only.
    rows = (await db.execute(
        select(NegotiationMessage.listing_id, NegotiationMessage.store_id, NegotiationMessage.buyer_id, NegotiationMessage.created_at)
        .where(NegotiationMessage.role == "seller", NegotiationMessage.created_at >= since)
        .order_by(NegotiationMessage.created_at)
        .limit(ROW_CAP + 1)
    )).all()
    truncated = len(rows) > ROW_CAP
    by_thread: dict[tuple, list[datetime]] = defaultdict(list)
    for listing_id, store_id, buyer_id, at in rows[:ROW_CAP]:
        if at is not None:
            by_thread[(listing_id, store_id, buyer_id)].append(to_naive_utc(at))
    return by_thread, truncated


def _reply_summary(starts: list[tuple[tuple, datetime]], seller_times: dict, now: datetime) -> dict:
    eligible = 0
    replied = 0
    delays: list[float] = []
    for key, first in starts:
        if first + REPLY_WINDOW > now:
            continue  # its 24 hours are not up yet
        eligible += 1
        times = seller_times.get(key, [])
        i = bisect.bisect_left(times, first)
        if i < len(times):
            delay = times[i] - first
            delays.append(delay.total_seconds() / 60)
            if delay <= REPLY_WINDOW:
                replied += 1
    return {
        "eligible": eligible,
        "replied_24h": replied,
        "rate_pct": pct(replied, eligible),
        "median_reply_minutes": median(delays),
    }


# ── Money ─────────────────────────────────────────────────────────────────────

async def _revenue_totals(db: AsyncSession, start: datetime, end: datetime) -> dict:
    from api.core.revenue import revenue_report

    report = await revenue_report(
        db, from_raw=start.isoformat(), to_raw=end.isoformat(), bucket="month")
    return {
        "income_minor": int(report["income"]["total_minor"]),
        "costs_minor": int(report["costs"]["total_minor"]),
        "estimated_costs_minor": int(report["costs"]["estimated_minor"]),
        "profit_minor": int(report["profit_minor"]),
        "streams": [
            {"key": s["key"], "label": s["label"], "amount_minor": int(s["amount_minor"]), "count": int(s["count"])}
            for s in report["income"]["streams"]
        ],
    }


async def paying_customers(db: AsyncSession, start: datetime, end: datetime) -> int:
    """Distinct users who paid BROKA anything in [start, end): fees, plans,
    store billing, boosts, badges or (when on) deal commission. Test
    charges excluded; one payment counted once (see revenue.py's header)."""
    from api.models.listing_payment import ListingPayment
    from api.models.store_billing import StorePayment
    from api.models.subscription import SubscriptionPayment
    from api.models.zetupay import Purpose, ZetuPayPayment, ZetuPayStatus

    payers: set[str] = set()
    for model in (ListingPayment, SubscriptionPayment, StorePayment):
        payers |= await _distinct_ids(
            db, model.user_id, model.status == "success", model.provider != "zetupay",
            model.created_at >= start, model.created_at < end)
    # Enum status columns: filtered in Python, as revenue.py does.
    for model in (FeaturedPayment, VerificationPayment):
        rows = (await db.execute(select(model.user_id, model.status).where(
            model.created_at >= start, model.created_at < end, model.provider != "zetupay",
        ))).all()
        payers |= {uid for uid, status in rows if uid and getattr(status, "value", status) == "success"}
    rows = (await db.execute(select(MpesaTransaction.buyer_id, MpesaTransaction.status).where(
        MpesaTransaction.created_at >= start, MpesaTransaction.created_at < end,
        MpesaTransaction.deal_id.is_not(None),
    ))).all()
    payers |= {uid for uid, status in rows if uid and getattr(status, "value", status) == "success"}
    payers |= await _distinct_ids(
        db, ZetuPayPayment.user_id, ZetuPayPayment.status == ZetuPayStatus.SUCCESS,
        ZetuPayPayment.purpose != Purpose.TEST,
        ZetuPayPayment.created_at >= start, ZetuPayPayment.created_at < end)
    return len(payers)


# ── Complaints ────────────────────────────────────────────────────────────────

async def complaints_overview(db: AsyncSession, start: datetime, end: datetime, *, now: datetime) -> dict:
    """The complaint queue as a founder reads it: what is open, what is past
    its first-reply deadline, and who keeps being complained about."""
    from api.models.feedback import UserFeedback

    open_rows = (await db.execute(
        select(UserFeedback.id, UserFeedback.kind, UserFeedback.severity,
               UserFeedback.created_at, UserFeedback.responded_at)
        .where(UserFeedback.status.in_(OPEN_FEEDBACK_STATUSES))
    )).all()
    open_complaints = [r for r in open_rows if r.kind == "complaint"]
    unanswered = [r for r in open_complaints if r.responded_at is None and r.created_at is not None]
    breached = [
        r for r in unanswered
        if now - to_naive_utc(r.created_at) > timedelta(hours=COMPLAINT_SLA_HOURS.get(r.severity, 72))
    ]
    oldest_hours = max(
        ((now - to_naive_utc(r.created_at)).total_seconds() / 3600 for r in unanswered),
        default=None,
    )
    (cs, ce), (ps, pe) = _windows(start, end)
    filed_current = await _count(
        db, UserFeedback.id, UserFeedback.kind == "complaint",
        UserFeedback.created_at >= cs, UserFeedback.created_at < ce)
    filed_previous = await _count(
        db, UserFeedback.id, UserFeedback.kind == "complaint",
        UserFeedback.created_at >= ps, UserFeedback.created_at < pe)
    feedback_current = await _count(
        db, UserFeedback.id, UserFeedback.kind == "feedback",
        UserFeedback.created_at >= cs, UserFeedback.created_at < ce)
    by_category = {
        str(category): int(count)
        for category, count in (await db.execute(
            select(UserFeedback.category, func.count(UserFeedback.id))
            .where(UserFeedback.kind == "complaint",
                   UserFeedback.created_at >= cs, UserFeedback.created_at < ce)
            .group_by(UserFeedback.category)
        )).all()
    }
    responded = (await db.execute(
        select(UserFeedback.created_at, UserFeedback.responded_at).where(
            UserFeedback.responded_at.is_not(None),
            UserFeedback.created_at >= now - timedelta(days=90),
        )
    )).all()
    response_hours = [
        (to_naive_utc(r) - to_naive_utc(c)).total_seconds() / 3600
        for c, r in responded if c is not None and r is not None and r >= c
    ]
    repeat_rows = (await db.execute(
        select(UserFeedback.related_user_id, func.count(UserFeedback.id))
        .where(UserFeedback.kind == "complaint",
               UserFeedback.related_user_id.is_not(None),
               UserFeedback.created_at >= now - timedelta(days=90))
        .group_by(UserFeedback.related_user_id)
        .having(func.count(UserFeedback.id) >= 2)
        .order_by(func.count(UserFeedback.id).desc())
        .limit(5)
    )).all()
    names = {}
    if repeat_rows:
        names = dict((await db.execute(
            select(User.id, User.name).where(User.id.in_([uid for uid, _ in repeat_rows]))
        )).all())
    return {
        "open": len(open_complaints),
        "open_feedback": len(open_rows) - len(open_complaints),
        "open_by_severity": dict(Counter(r.severity for r in open_complaints)),
        "unanswered": len(unanswered),
        "sla_breached": len(breached),
        "sla_breached_urgent": sum(1 for r in breached if r.severity == "urgent"),
        "oldest_unanswered_hours": round(oldest_hours, 1) if oldest_hours is not None else None,
        "filed": metric(filed_current, filed_previous),
        "feedback_filed": feedback_current,
        "by_category": by_category,
        "median_response_hours_90d": median(response_hours),
        "repeat_reported_users": [
            {"user_id": uid, "name": names.get(uid), "complaints_90d": int(count)}
            for uid, count in repeat_rows
        ],
        "sla_hours": dict(COMPLAINT_SLA_HOURS),
    }


# ── Pulse ─────────────────────────────────────────────────────────────────────

async def pulse_between(db: AsyncSession, start: datetime, end: datetime, *, now: Optional[datetime] = None) -> dict:
    """The period [start, end) against the same-length period before it.

    Point-in-time figures (live listings, open complaints, unmet Buying
    Agent requests, targets) are as of `now`."""
    from api.domains.listings.paid import live_clause
    from api.models.dispute import DisputeCase
    from api.models.sold_out_report import SoldOutReport

    now = now or datetime.utcnow()
    (cs, ce), (ps, pe) = _windows(start, end)
    staff = _staff()

    async def both(fn):
        return await fn(cs, ce), await fn(ps, pe)

    async def new_users(s, e):
        return await _count(db, User.id, User.created_at >= s, User.created_at < e,
                            User.is_admin == False)  # noqa: E712

    async def new_listings(s, e):
        return await _count(db, Listing.id, Listing.created_at >= s, Listing.created_at < e,
                            Listing.seller_id.not_in(staff))

    async def active_buyers(s, e):
        # visibility-ok: distinct sender ids only.
        ids = await _distinct_ids(db, NegotiationMessage.sender_id, NegotiationMessage.role == "buyer",
                                  NegotiationMessage.created_at >= s, NegotiationMessage.created_at < e,
                                  NegotiationMessage.sender_id.not_in(staff), _real_listing_chat())
        ids |= await _distinct_ids(db, Interest.buyer_id, Interest.created_at >= s,
                                   Interest.created_at < e, Interest.buyer_id.not_in(staff))
        ids |= await _distinct_ids(db, BuyAgentRequest.buyer_id, BuyAgentRequest.created_at >= s,
                                   BuyAgentRequest.created_at < e, BuyAgentRequest.buyer_id.not_in(staff))
        return len(ids)

    async def active_sellers(s, e):
        # visibility-ok: distinct sender ids only.
        ids = await _distinct_ids(db, NegotiationMessage.sender_id, NegotiationMessage.role == "seller",
                                  NegotiationMessage.created_at >= s, NegotiationMessage.created_at < e,
                                  NegotiationMessage.sender_id.not_in(staff), _real_listing_chat())
        ids |= await _distinct_ids(db, Listing.seller_id, Listing.created_at >= s,
                                   Listing.created_at < e, Listing.seller_id.not_in(staff))
        return len(ids)

    async def messages(s, e):
        # visibility-ok: a count of human messages.
        return await _count(db, NegotiationMessage.id, NegotiationMessage.role.in_(("buyer", "seller")),
                            NegotiationMessage.created_at >= s, NegotiationMessage.created_at < e,
                            NegotiationMessage.sender_id.not_in(staff), _real_listing_chat())

    async def zeno_conversations(s, e):
        return await _count(db, ZenoConversation.id, ZenoConversation.created_at >= s,
                            ZenoConversation.created_at < e, ZenoConversation.owner_id.not_in(staff))

    async def zeno_turns(s, e):
        return int((await db.execute(
            select(func.count(ZenoTurn.id)).select_from(ZenoTurn)
            .join(ZenoConversation, ZenoConversation.id == ZenoTurn.conversation_id)
            .where(ZenoTurn.role == "user", ZenoTurn.created_at >= s, ZenoTurn.created_at < e,
                   ZenoConversation.owner_id.not_in(staff))
        )).scalar() or 0)

    async def deals_agreed(s, e):
        return await _count(db, Deal.id, Deal.created_at >= s, Deal.created_at < e,
                            Deal.status.in_(_AGREED_STATES), Deal.seller_id.not_in(staff),
                            Deal.buyer_id.not_in(staff))

    async def sold_out(s, e):
        return await _count(db, SoldOutReport.id, SoldOutReport.created_at >= s,
                            SoldOutReport.created_at < e, SoldOutReport.revoked_at.is_(None))

    async def agent_requests(s, e):
        return await _count(db, BuyAgentRequest.id, BuyAgentRequest.created_at >= s,
                            BuyAgentRequest.created_at < e, BuyAgentRequest.buyer_id.not_in(staff))

    async def disputes(s, e):
        return await _count(db, DisputeCase.id, DisputeCase.created_at >= s, DisputeCase.created_at < e)

    async def fraud(s, e):
        return await _count(db, FraudEvent.id, FraudEvent.created_at >= s, FraudEvent.created_at < e)

    # New sellers: users whose first listing ever falls in the window.
    first_listing_rows = (await db.execute(
        select(Listing.seller_id, func.min(Listing.created_at))
        .where(Listing.seller_id.not_in(staff))
        .group_by(Listing.seller_id)
        .having(func.min(Listing.created_at) >= ps)
    )).all()
    first_listings = [to_naive_utc(t) for _, t in first_listing_rows if t is not None]

    # Conversations a buyer started, and how sellers answered them.
    starts = await _thread_starts(db, ps)
    seller_times, truncated = await _seller_message_times(db, ps)
    current_starts = [(k, t) for k, t in starts.items() if cs <= t < ce]
    previous_starts = [(k, t) for k, t in starts.items() if ps <= t < pe]

    live_listings = await _count(
        db, Listing.id, Listing.status == ListingStatus.active, live_clause(now),
        Listing.seller_id.not_in(staff))
    unmet_requests = await _count(
        db, BuyAgentRequest.id, BuyAgentRequest.status == "active",
        BuyAgentRequest.match_count == 0, BuyAgentRequest.buyer_id.not_in(staff))

    users_c, users_p = await both(new_users)
    listings_c, listings_p = await both(new_listings)
    buyers_c, buyers_p = await both(active_buyers)
    sellers_c, sellers_p = await both(active_sellers)
    revenue_c, revenue_p = await _revenue_totals(db, cs, ce), await _revenue_totals(db, ps, pe)

    metrics = {
        "new_users": metric(users_c, users_p),
        "new_sellers": metric(
            sum(1 for t in first_listings if cs <= t < ce),
            sum(1 for t in first_listings if ps <= t < pe)),
        "new_listings": metric(listings_c, listings_p),
        "live_listings": {"current": live_listings, "previous": None, "change_pct": None},
        "active_buyers": metric(buyers_c, buyers_p),
        "active_sellers": metric(sellers_c, sellers_p),
        "conversations_started": metric(len(current_starts), len(previous_starts)),
        "messages": metric(*await both(messages)),
        "zeno_conversations": metric(*await both(zeno_conversations)),
        "zeno_user_turns": metric(*await both(zeno_turns)),
        "deals_agreed": metric(*await both(deals_agreed)),
        "sold_out_reports": metric(*await both(sold_out)),
        "buy_agent_requests": metric(*await both(agent_requests)),
        "buy_agent_unmet_open": {"current": unmet_requests, "previous": None, "change_pct": None},
        "disputes_opened": metric(*await both(disputes)),
        "fraud_flags": metric(*await both(fraud)),
        "income_minor": metric(revenue_c["income_minor"], revenue_p["income_minor"]),
        "costs_minor": metric(revenue_c["costs_minor"], revenue_p["costs_minor"]),
        "profit_minor": metric(revenue_c["profit_minor"], revenue_p["profit_minor"]),
    }

    complaints = await complaints_overview(db, cs, ce, now=now)
    metrics["complaints_filed"] = complaints["filed"]

    # Targets and break-even run on the trailing 30 days, whatever the
    # period: they are about where BROKA stands, not what one week did.
    month_start = now - timedelta(days=30)
    revenue_30d = await _revenue_totals(db, month_start, now)
    actuals = {
        "live_listings": live_listings,
        "paying_customers_30d": await paying_customers(db, month_start, now),
        "collected_30d_minor": revenue_30d["income_minor"],
        "deals_agreed_30d": await deals_agreed(month_start, now),
    }
    targets = []
    for key, label, target, unit in DAY30_TARGETS:
        actual = actuals[key]
        targets.append({
            "key": key, "label": label, "target": target, "actual": actual, "unit": unit,
            "progress_pct": min(100.0, round(actual / target * 100, 1)) if target else None,
            "met": actual >= target,
        })
    fixed_minor = settings.platform_fixed_monthly_cost_kes * 100
    net_30d = revenue_30d["income_minor"] - revenue_30d["costs_minor"]

    return {
        "generated_at": iso(now),
        "window": {
            "from": iso(cs), "to": iso(ce), "previous_from": iso(ps), "previous_to": iso(pe),
            "days": round((ce - cs).total_seconds() / 86400, 2),
        },
        "metrics": metrics,
        "liquidity": {
            "target_pct": LIQUIDITY_TARGET_PCT,
            "current": await liquidity_between(db, cs, ce),
            "previous": await liquidity_between(db, ps, pe),
        },
        "seller_response": {
            "target_pct": REPLY_TARGET_PCT,
            "current": _reply_summary(current_starts, seller_times, now),
            "previous": _reply_summary(previous_starts, seller_times, now),
            "truncated": truncated,
        },
        "balance": {
            "active_buyers": buyers_c,
            "active_sellers": sellers_c,
            "buyers_per_seller": round(buyers_c / sellers_c, 2) if sellers_c else None,
        },
        "complaints": complaints,
        "revenue": {"current": revenue_c, "previous": revenue_p, "trailing_30d": revenue_30d},
        "targets": targets,
        "break_even": {
            "fixed_monthly_cost_minor": fixed_minor,
            "income_30d_minor": revenue_30d["income_minor"],
            "costs_30d_minor": revenue_30d["costs_minor"],
            "net_30d_minor": net_30d,
            "coverage_pct": pct(net_30d, fixed_minor),
            "gap_minor": max(0, fixed_minor - net_30d),
        },
        "monetisation": {
            "listing_fees_enabled": bool(settings.listing_fees_enabled),
            "premium_enabled": bool(settings.premium_enabled),
            "store_billing_enabled": bool(settings.store_billing_enabled),
            "in_app_payments_enabled": bool(settings.in_app_payments_enabled),
        },
        "staff_excluded": True,
        "definitions": DEFINITIONS,
    }


async def pulse(db: AsyncSession, *, window_days: int = 7, now: Optional[datetime] = None) -> dict:
    now = now or datetime.utcnow()
    return await pulse_between(db, now - timedelta(days=window_days), now, now=now)


DEFINITIONS = {
    "staff": "Administrator accounts and their listings, chats and payments are excluded.",
    "buyer_contact": "A buyer's own chat message on the listing, or an interests row.",
    "liquidity": (
        "Share of listings that got buyer contact within 7 days of posting, over the "
        "listings whose 7-day window closed in the period. Target: 50%."
    ),
    "seller_reply": (
        "A seller's own message after the buyer's first one, within 24 hours. Zeno "
        "answering for the seller is not counted. Threads younger than 24 hours are not yet eligible."
    ),
    "active_buyers": "Distinct users who sent a buyer message, showed interest or asked the Buying Agent.",
    "active_sellers": "Distinct users who sent a seller message or posted a listing.",
    "deals_agreed": "Deals past negotiation (not negotiating or cancelled).",
    "new_sellers": "Users whose first listing ever was posted in the period.",
    "targets": "Day-30 targets from BUSINESS_MODEL_REVIEW.md 4, measured over the trailing 30 days.",
    "break_even": "Trailing-30-day income less recorded costs, against the fixed monthly running cost.",
}


# ── Demand and supply by category ─────────────────────────────────────────────

def _classify(supply: int, demand: int, liquidity_rate: Optional[float]) -> tuple[str, str]:
    """(signal, recommendation) for one category."""
    if supply == 0 and demand > 0:
        return "unserved", "Buyers are asking and nothing is listed: recruit sellers here first."
    per_listing = demand / supply if supply else 0.0
    if demand >= 3 and per_listing >= 1.0:
        return "undersupplied", "More buyer demand than listings: recruit sellers and invite stores."
    if supply >= 5 and per_listing < 0.2:
        return "oversupplied", "Listings are not reaching buyers: promote the category or review prices."
    if liquidity_rate is not None and liquidity_rate >= LIQUIDITY_TARGET_PCT:
        return "healthy", "Listings here find buyers within a week."
    return "developing", "Too little activity yet to call."


async def categories_between(db: AsyncSession, start: datetime, end: datetime, *, now: Optional[datetime] = None) -> dict:
    from api.domains.listings.paid import live_clause
    from api.models.sold_out_report import SoldOutReport

    now = now or datetime.utcnow()
    staff = _staff()
    rows: dict[str, dict[str, Any]] = {}

    def row(raw: Optional[str]) -> dict:
        key, label = _category_key(raw)
        return rows.setdefault(key, {
            "key": key, "label": label, "supply_live": 0, "new_listings": 0,
            "buyer_threads": 0, "interests": 0, "viewers": 0, "buy_agent_requests": 0,
            "buy_agent_unmatched": 0, "sold_out_reports": 0, "deals_agreed": 0, "_prices": [],
        })

    for category, price in (await db.execute(
        select(Listing.category, Listing.price).where(
            Listing.status == ListingStatus.active, live_clause(now), Listing.seller_id.not_in(staff))
    )).all():
        entry = row(category)
        entry["supply_live"] += 1
        if price is not None:
            entry["_prices"].append(float(price))

    for category, count in (await db.execute(
        select(Listing.category, func.count(Listing.id)).where(
            Listing.created_at >= start, Listing.created_at < end, Listing.seller_id.not_in(staff))
        .group_by(Listing.category)
    )).all():
        row(category)["new_listings"] += int(count)

    # visibility-ok: one row per (category, thread); no content.
    for category, _listing_id, _buyer_id in (await db.execute(
        select(Listing.category, NegotiationMessage.listing_id, NegotiationMessage.buyer_id).select_from(NegotiationMessage)
        .join(Listing, Listing.id == NegotiationMessage.listing_id)
        .where(NegotiationMessage.role == "buyer", NegotiationMessage.created_at >= start,
               NegotiationMessage.created_at < end, NegotiationMessage.sender_id.not_in(staff),
               Listing.seller_id.not_in(staff))
        .group_by(Listing.category, NegotiationMessage.listing_id, NegotiationMessage.buyer_id)
    )).all():
        row(category)["buyer_threads"] += 1

    for model, column, field in (
        (Interest, Interest.buyer_id, "interests"),
        (ListingView, ListingView.viewer_id, "viewers"),
    ):
        for category, count in (await db.execute(
            select(Listing.category, func.count(model.id)).select_from(model)
            .join(Listing, Listing.id == model.listing_id)
            .where(model.created_at >= start, model.created_at < end, column.not_in(staff),
                   Listing.seller_id.not_in(staff))
            .group_by(Listing.category)
        )).all():
            row(category)[field] += int(count)

    for category, count, unmatched in (await db.execute(
        select(BuyAgentRequest.category, func.count(BuyAgentRequest.id),
               func.sum(case((BuyAgentRequest.match_count == 0, 1), else_=0)))
        .where(BuyAgentRequest.created_at >= start, BuyAgentRequest.created_at < end,
               BuyAgentRequest.buyer_id.not_in(staff))
        .group_by(BuyAgentRequest.category)
    )).all():
        entry = row(category)
        entry["buy_agent_requests"] += int(count)
        entry["buy_agent_unmatched"] += int(unmatched or 0)

    for category, count in (await db.execute(
        select(Listing.category, func.count(SoldOutReport.id)).select_from(SoldOutReport)
        .join(Listing, Listing.id == SoldOutReport.listing_id)
        .where(SoldOutReport.created_at >= start, SoldOutReport.created_at < end,
               SoldOutReport.revoked_at.is_(None))
        .group_by(Listing.category)
    )).all():
        row(category)["sold_out_reports"] += int(count)

    for category, count in (await db.execute(
        select(Listing.category, func.count(Deal.id)).select_from(Deal)
        .join(Listing, Listing.id == Deal.listing_id)
        .where(Deal.created_at >= start, Deal.created_at < end, Deal.status.in_(_AGREED_STATES),
               Deal.seller_id.not_in(staff))
        .group_by(Listing.category)
    )).all():
        row(category)["deals_agreed"] += int(count)

    cohort_start, cohort_end = start - LIQUIDITY_WINDOW, end - LIQUIDITY_WINDOW
    contacts = await listing_contacts(db, cohort_start, cohort_end)
    by_category: dict[str, list[dict]] = defaultdict(list)
    for contact in contacts:
        key, _ = _category_key(contact["category"])
        by_category[key].append(contact)
        row(contact["category"])

    out = []
    for key, entry in rows.items():
        prices = entry.pop("_prices")
        demand = entry["buyer_threads"] + entry["interests"] + entry["buy_agent_requests"]
        liquidity = summarise_liquidity(by_category.get(key, []), cohort_start, cohort_end)
        signal, recommendation = _classify(entry["supply_live"], demand, liquidity["rate_pct"])
        if entry["supply_live"] == 0 and demand == 0 and entry["new_listings"] == 0 and not liquidity["eligible"]:
            continue
        out.append({
            **entry,
            "demand": demand,
            "demand_per_listing": round(demand / entry["supply_live"], 2) if entry["supply_live"] else None,
            "median_price_kes": median(prices),
            "liquidity": liquidity,
            "signal": signal,
            "recommendation": recommendation,
        })
    out.sort(key=lambda c: (-c["demand"], -c["supply_live"], c["label"]))
    totals = {
        field: sum(c[field] for c in out)
        for field in ("supply_live", "new_listings", "buyer_threads", "interests", "viewers",
                      "buy_agent_requests", "buy_agent_unmatched", "sold_out_reports", "deals_agreed",
                      "demand")
    }
    return {
        "generated_at": iso(now),
        "window": {"from": iso(start), "to": iso(end),
                   "days": round((end - start).total_seconds() / 86400, 2)},
        "categories": out,
        "totals": totals,
        "signals": dict(Counter(c["signal"] for c in out)),
        "definitions": {
            "demand": "Buyer threads + interests + Buying Agent requests in the window.",
            "supply_live": "Listings buyers can see right now (active, paid or free, not sold out).",
            "signals": (
                "unserved: demand, no supply; undersupplied: at least 1 demand signal per "
                "live listing (min 3); oversupplied: 5+ live listings, under 0.2 demand per "
                "listing; healthy: liquidity at or above 50%; developing: everything else."
            ),
            **{k: DEFINITIONS[k] for k in ("staff", "liquidity", "buyer_contact")},
        },
    }


async def categories(db: AsyncSession, *, window_days: int = 30, now: Optional[datetime] = None) -> dict:
    now = now or datetime.utcnow()
    return await categories_between(db, now - timedelta(days=window_days), now, now=now)


# ── Geography ─────────────────────────────────────────────────────────────────

async def geography(db: AsyncSession, *, window_days: int = 30, now: Optional[datetime] = None) -> dict:
    from api.domains.listings.paid import live_clause
    from api.models.store import Store

    now = now or datetime.utcnow()
    start = now - timedelta(days=window_days)
    staff = _staff()
    rows: dict[str, dict[str, Any]] = {}

    def row(raw: Optional[str]) -> dict:
        key, label = _county_key(raw)
        return rows.setdefault(key, {
            "key": key, "label": label, "supply_live": 0, "new_listings": 0,
            "buyer_threads": 0, "stores": 0,
        })

    for county, count in (await db.execute(
        select(Listing.location_county, func.count(Listing.id)).where(
            Listing.status == ListingStatus.active, live_clause(now), Listing.seller_id.not_in(staff))
        .group_by(Listing.location_county)
    )).all():
        row(county)["supply_live"] += int(count)
    for county, count in (await db.execute(
        select(Listing.location_county, func.count(Listing.id)).where(
            Listing.created_at >= start, Listing.created_at < now, Listing.seller_id.not_in(staff))
        .group_by(Listing.location_county)
    )).all():
        row(county)["new_listings"] += int(count)
    # visibility-ok: one row per (county, thread); no content.
    for county, _listing_id, _buyer_id in (await db.execute(
        select(Listing.location_county, NegotiationMessage.listing_id, NegotiationMessage.buyer_id).select_from(NegotiationMessage)
        .join(Listing, Listing.id == NegotiationMessage.listing_id)
        .where(NegotiationMessage.role == "buyer", NegotiationMessage.created_at >= start,
               NegotiationMessage.created_at < now, NegotiationMessage.sender_id.not_in(staff),
               Listing.seller_id.not_in(staff))
        .group_by(Listing.location_county, NegotiationMessage.listing_id, NegotiationMessage.buyer_id)
    )).all():
        row(county)["buyer_threads"] += 1
    for county, count in (await db.execute(
        select(Store.county, func.count(Store.id)).where(
            Store.deleted_at.is_(None), Store.is_active == True)  # noqa: E712
        .group_by(Store.county)
    )).all():
        row(county)["stores"] += int(count)

    cohort_start, cohort_end = start - LIQUIDITY_WINDOW, now - LIQUIDITY_WINDOW
    by_county: dict[str, list[dict]] = defaultdict(list)
    for contact in await listing_contacts(db, cohort_start, cohort_end):
        key, _ = _county_key(contact["county"])
        by_county[key].append(contact)
        row(contact["county"])
    out = []
    for key, entry in rows.items():
        liquidity = summarise_liquidity(by_county.get(key, []), cohort_start, cohort_end)
        if not (entry["supply_live"] or entry["new_listings"] or entry["buyer_threads"]
                or entry["stores"] or liquidity["eligible"]):
            continue
        out.append({
            **entry,
            "threads_per_listing": round(entry["buyer_threads"] / entry["supply_live"], 2)
            if entry["supply_live"] else None,
            "liquidity": liquidity,
        })
    out.sort(key=lambda c: (-c["supply_live"], -c["buyer_threads"], c["label"]))
    return {
        "generated_at": iso(now),
        "window": {"from": iso(start), "to": iso(now), "days": window_days},
        "counties": out,
        "definitions": {
            "county": "The listing's county; listings from older app builds without one are 'Unknown'.",
            **{k: DEFINITIONS[k] for k in ("staff", "liquidity")},
        },
    }


# ── Funnel ────────────────────────────────────────────────────────────────────

def _step(key: str, label: str, count: int, first: int, previous: Optional[int]) -> dict:
    return {
        "key": key, "label": label, "count": count,
        "pct_of_start": pct(count, first),
        "pct_of_previous": pct(count, previous) if previous is not None else None,
    }


async def funnel(db: AsyncSession, *, start: datetime, end: datetime) -> dict:
    """Users who signed up in [start, end), followed through both sides of
    the marketplace to today."""
    staff = _staff()
    cohort = select(User.id).where(User.created_at >= start, User.created_at < end,
                                   User.is_admin == False)  # noqa: E712
    users = dict((await db.execute(
        select(User.id, User.created_at).where(User.created_at >= start, User.created_at < end,
                                               User.is_admin == False)  # noqa: E712
    )).all())
    signed_up = len(users)
    sellers = await _count(db, User.id, User.id.in_(cohort), User.account_type == AccountType.buyer_seller)
    first_listing = dict((await db.execute(
        select(Listing.seller_id, func.min(Listing.created_at))
        .where(Listing.seller_id.in_(cohort)).group_by(Listing.seller_id)
    )).all())
    # visibility-ok: distinct seller ids only.
    contacted = await _distinct_ids_join(
        db,
        select(Listing.seller_id).select_from(NegotiationMessage).join(Listing, Listing.id == NegotiationMessage.listing_id)
        .where(NegotiationMessage.role == "buyer", Listing.seller_id.in_(cohort), NegotiationMessage.sender_id.not_in(staff)),
    )
    sold = await _distinct_ids(db, Deal.seller_id, Deal.seller_id.in_(cohort),
                               Deal.status.in_(_AGREED_STATES))

    # visibility-ok: earliest buyer message per sender, no content.
    first_buyer_message = dict((await db.execute(
        select(NegotiationMessage.sender_id, func.min(NegotiationMessage.created_at))
        .where(NegotiationMessage.role == "buyer", NegotiationMessage.sender_id.in_(cohort)).group_by(NegotiationMessage.sender_id)
    )).all())
    engaged = set(first_buyer_message)
    for column, model_filter in (
        (Interest.buyer_id, Interest.buyer_id.in_(cohort)),
        (ListingLike.user_id, ListingLike.user_id.in_(cohort)),
        (Wishlist.user_id, Wishlist.user_id.in_(cohort)),
        (ZenoConversation.owner_id, ZenoConversation.owner_id.in_(cohort)),
        (BuyAgentRequest.buyer_id, BuyAgentRequest.buyer_id.in_(cohort)),
    ):
        engaged |= await _distinct_ids(db, column, model_filter)
    bought = await _distinct_ids(db, Deal.buyer_id, Deal.buyer_id.in_(cohort),
                                 Deal.status.in_(_AGREED_STATES))

    def hours_after_signup(firsts: dict) -> Optional[float]:
        spans = []
        for uid, first in firsts.items():
            joined = users.get(uid)
            if joined is None or first is None:
                continue
            delta = (to_naive_utc(first) - to_naive_utc(joined)).total_seconds() / 3600
            if delta >= 0:
                spans.append(delta)
        return median(spans)

    seller_steps = [
        ("signed_up", "Signed up", signed_up),
        ("became_seller", "Became a seller", sellers),
        ("posted_listing", "Posted a listing", len(first_listing)),
        ("got_buyer_contact", "Got a buyer chat", len(contacted)),
        ("agreed_deal", "Agreed a deal", len(sold)),
    ]
    buyer_steps = [
        ("signed_up", "Signed up", signed_up),
        ("engaged", "Showed interest", len(engaged)),
        ("messaged_seller", "Messaged a seller", len(first_buyer_message)),
        ("agreed_deal", "Agreed a deal", len(bought)),
    ]

    def build(steps):
        out, previous = [], None
        for key, label, count in steps:
            out.append(_step(key, label, count, signed_up, previous))
            previous = count
        return out

    return {
        "generated_at": iso(datetime.utcnow()),
        "cohort": {"from": iso(start), "to": iso(end), "users": signed_up},
        "seller_journey": build(seller_steps),
        "buyer_journey": build(buyer_steps),
        "timing": {
            "median_hours_to_first_listing": hours_after_signup(first_listing),
            "median_hours_to_first_buyer_message": hours_after_signup(first_buyer_message),
        },
        "definitions": {
            "cohort": "Users (not staff) who signed up in the range, followed to today.",
            "became_seller": "Account type is buyer_seller now (the upgrade has no timestamp).",
            "engaged": "Messaged, showed interest, liked, saved, opened Zeno or asked the Buying Agent.",
            "deals_agreed": DEFINITIONS["deals_agreed"],
        },
    }


async def _distinct_ids_join(db: AsyncSession, statement) -> set[str]:
    rows = (await db.execute(statement.distinct())).all()
    return {value for (value,) in rows if value}


# ── Weekly retention ──────────────────────────────────────────────────────────

def local_week_start(value: datetime) -> datetime:
    """Monday 00:00 of `value`'s week in report-local time, as naive UTC."""
    offset = timedelta(hours=settings.report_tz_offset_hours)
    local = value + offset
    monday = (local - timedelta(days=local.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    return monday - offset


async def cohorts(db: AsyncSession, *, weeks: int = 8, now: Optional[datetime] = None) -> dict:
    """Weekly signup cohorts and the share of each that did something on
    BROKA (messaged, listed, showed interest, talked to Zeno, liked, saved
    or asked the Buying Agent) in each week after signing up. Week 0 is the
    signup week; signing up alone is not activity, so week 0 is activation."""
    now = now or datetime.utcnow()
    first_week = local_week_start(now) - timedelta(weeks=weeks - 1)
    cohort = select(User.id).where(User.created_at >= first_week,
                                   User.is_admin == False)  # noqa: E712
    users = (await db.execute(
        select(User.id, User.created_at).where(User.created_at >= first_week,
                                               User.is_admin == False)  # noqa: E712
    )).all()
    week_of = lambda t: int((to_naive_utc(t) - first_week).days // 7)  # noqa: E731
    user_week = {uid: week_of(created) for uid, created in users if created is not None}

    sources = (
        # visibility-ok: sender ids and timestamps only.
        select(NegotiationMessage.sender_id, NegotiationMessage.created_at).where(
            NegotiationMessage.role.in_(("buyer", "seller")), NegotiationMessage.created_at >= first_week, NegotiationMessage.sender_id.in_(cohort)),
        select(Listing.seller_id, Listing.created_at).where(
            Listing.created_at >= first_week, Listing.seller_id.in_(cohort)),
        select(Interest.buyer_id, Interest.created_at).where(
            Interest.created_at >= first_week, Interest.buyer_id.in_(cohort)),
        select(ZenoConversation.owner_id, ZenoTurn.created_at).select_from(ZenoTurn)
        .join(ZenoConversation, ZenoConversation.id == ZenoTurn.conversation_id)
        .where(ZenoTurn.role == "user", ZenoTurn.created_at >= first_week,
               ZenoConversation.owner_id.in_(cohort)),
        select(ListingLike.user_id, ListingLike.created_at).where(
            ListingLike.created_at >= first_week, ListingLike.user_id.in_(cohort)),
        select(Wishlist.user_id, Wishlist.created_at).where(
            Wishlist.created_at >= first_week, Wishlist.user_id.in_(cohort)),
        select(BuyAgentRequest.buyer_id, BuyAgentRequest.created_at).where(
            BuyAgentRequest.created_at >= first_week, BuyAgentRequest.buyer_id.in_(cohort)),
    )
    active: dict[str, set[int]] = defaultdict(set)
    truncated = False
    for statement in sources:
        rows = (await db.execute(statement.limit(ROW_CAP + 1))).all()
        truncated = truncated or len(rows) > ROW_CAP
        for uid, at in rows[:ROW_CAP]:
            if uid in user_week and at is not None:
                active[uid].add(week_of(at))

    current_week = week_of(now)
    out = []
    for index in range(weeks):
        members = [uid for uid, w in user_week.items() if w == index]
        span = max(0, current_week - index + 1)
        retention = []
        for k in range(span):
            retention.append(pct(sum(1 for uid in members if index + k in active.get(uid, ())), len(members)))
        out.append({
            "week_start": iso(first_week + timedelta(weeks=index)),
            "size": len(members),
            "retention_pct": retention,
        })
    return {
        "generated_at": iso(now),
        "weeks": weeks,
        "cohorts": out,
        "truncated": truncated,
        "definitions": {
            "activity": (
                "Messaged, posted a listing, showed interest, talked to Zeno, liked, saved or "
                "asked the Buying Agent. Signing up alone is not activity."
            ),
            "week": "Monday-to-Sunday weeks in report time (EAT by default).",
            "week_0": "The signup week: the share who did something beyond signing up (activation).",
        },
    }


# ── Sellers ───────────────────────────────────────────────────────────────────

async def sellers_overview(db: AsyncSession, *, now: Optional[datetime] = None, limit: int = 20) -> dict:
    """Buyers left waiting, the busiest sellers, and listings nobody has
    contacted - the three places a founder can intervene seller by seller."""
    from api.domains.listings.paid import live_clause
    from api.models.store import Store

    now = now or datetime.utcnow()
    since = now - WAITING_LOOKBACK
    staff_ids = {uid for (uid,) in (await db.execute(_staff())).all()}

    # visibility-ok: per-thread last message time by role, no content.
    rows = (await db.execute(
        select(NegotiationMessage.listing_id, NegotiationMessage.store_id, NegotiationMessage.buyer_id, NegotiationMessage.role, func.max(NegotiationMessage.created_at))
        .where(NegotiationMessage.role.in_(("buyer", "seller")), NegotiationMessage.created_at >= since)
        .group_by(NegotiationMessage.listing_id, NegotiationMessage.store_id, NegotiationMessage.buyer_id, NegotiationMessage.role)
    )).all()
    threads: dict[tuple, dict[str, datetime]] = defaultdict(dict)
    for listing_id, store_id, buyer_id, role, at in rows:
        if at is not None and buyer_id not in staff_ids:
            threads[(listing_id, store_id, buyer_id)][role] = to_naive_utc(at)

    listing_ids = {key[0] for key in threads if key[0]}
    store_ids = {key[1] for key in threads if key[1] and not key[0]}
    listing_owner: dict[str, tuple[str, str]] = {}
    for chunk in _chunks(sorted(listing_ids), 500):
        for lid, seller_id, name in (await db.execute(
            select(Listing.id, Listing.seller_id, Listing.name).where(Listing.id.in_(chunk))
        )).all():
            listing_owner[lid] = (seller_id, name)
    store_owner: dict[str, tuple[str, str]] = {}
    for chunk in _chunks(sorted(store_ids), 500):
        for sid, owner_id, name in (await db.execute(
            select(Store.id, Store.owner_id, Store.name).where(Store.id.in_(chunk))
        )).all():
            store_owner[sid] = (owner_id, name)

    per_seller: dict[str, dict[str, Any]] = {}
    waiting_total = 0
    for (listing_id, store_id, _buyer_id), last in threads.items():
        owner = listing_owner.get(listing_id) if listing_id else store_owner.get(store_id)
        if owner is None or owner[0] in staff_ids:
            continue
        seller_id, item_name = owner
        entry = per_seller.setdefault(seller_id, {
            "seller_id": seller_id, "threads": 0, "answered": 0, "waiting": 0,
            "oldest_wait_hours": None, "items": [],
        })
        buyer_at, seller_at = last.get("buyer"), last.get("seller")
        if buyer_at is None:
            continue
        entry["threads"] += 1
        if seller_at is not None and seller_at >= buyer_at:
            entry["answered"] += 1
        elif now - buyer_at >= WAITING_AFTER:
            entry["waiting"] += 1
            waiting_total += 1
            hours = round((now - buyer_at).total_seconds() / 3600, 1)
            entry["oldest_wait_hours"] = max(hours, entry["oldest_wait_hours"] or 0)
            if item_name and item_name not in entry["items"] and len(entry["items"]) < 3:
                entry["items"].append(item_name)

    profiles = {}
    seller_ids = list(per_seller)
    for chunk in _chunks(seller_ids, 500):
        for uid, name, phone, display, trust in (await db.execute(
            select(User.id, User.name, User.phone, User.business_display_name, User.trust_score)
            .where(User.id.in_(chunk))
        )).all():
            profiles[uid] = {"name": display or name, "phone": phone,
                             "trust_score": trust if trust is not None else 100}

    def present(entry: dict) -> dict:
        profile = profiles.get(entry["seller_id"], {})
        return {
            **entry,
            "name": profile.get("name"),
            "phone": profile.get("phone"),
            "trust_score": profile.get("trust_score"),
            "answered_pct": pct(entry["answered"], entry["threads"]),
        }

    waiting = sorted((e for e in per_seller.values() if e["waiting"]),
                     key=lambda e: (-e["waiting"], -(e["oldest_wait_hours"] or 0)))
    busiest = sorted(per_seller.values(), key=lambda e: (-e["threads"], -e["answered"]))

    stale_filters = (
        Listing.status == ListingStatus.active,
        live_clause(now),
        Listing.created_at <= now - STALE_AFTER,
        Listing.seller_id.not_in(_staff()),
        # visibility-ok: existence of a buyer message, no content.
        ~exists().where(NegotiationMessage.listing_id == Listing.id, NegotiationMessage.role == "buyer"),
        ~exists().where(Interest.listing_id == Listing.id),
    )
    stale_total = await _count(db, Listing.id, *stale_filters)
    stale = (await db.execute(
        select(Listing.id, Listing.name, Listing.category, Listing.seller_id, Listing.created_at,
               Listing.price, Listing.views)
        .where(*stale_filters).order_by(Listing.created_at).limit(limit)
    )).all()

    return {
        "generated_at": iso(now),
        "lookback_days": WAITING_LOOKBACK.days,
        "waiting_total": waiting_total,
        "sellers_with_waiting_buyers": len(waiting),
        "waiting": [present(e) for e in waiting[:limit]],
        "busiest": [present(e) for e in busiest[:limit]],
        "stale_total": stale_total,
        "stale_listings": [
            {
                "id": lid, "name": name, "category": category, "seller_id": seller_id,
                "created_at": iso(created), "price": float(price) if price is not None else None,
                "views": int(views or 0),
                "age_days": int((now - to_naive_utc(created)).days) if created else None,
            }
            for lid, name, category, seller_id, created, price, views in stale
        ],
        "definitions": {
            "waiting": (
                "A thread whose last buyer message is over 24 hours old with no seller "
                "message after it, among threads active in the last 14 days."
            ),
            "answered": "The seller's last message in the thread is newer than the buyer's.",
            "stale": "Live listings at least 14 days old that no buyer has ever contacted.",
            "staff": DEFINITIONS["staff"],
        },
    }


def _chunks(items: list, size: int):
    for i in range(0, len(items), size):
        yield items[i:i + size]
