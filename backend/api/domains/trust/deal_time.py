"""How long a seller's deals take to complete, from agreement to payout.

Shown to buyers on a listing's screen and on the seller's profile, and to the
seller on their dashboard: "deals with this seller usually take about 2 days".
The profile screen used to read an `avg_deal_time_minutes` the API never
returned, so every seller showed "N/A" beside a made-up response rate.

MEASURED FROM ROWS THAT ALREADY EXIST
=====================================
A deal row is created when the price is agreed (Deal.created_at), and every
path that pays the seller out - the buyer confirming delivery, the auto-
release sweep, a dispute resolved for the seller - stamps Deal.released_at
in the same transaction that sets the status to released. So the figure
needs no new instrumentation and covers the account's history from day one.

Only released deals count. A refunded or cancelled deal did not complete, and
an open one has no end yet; counting its age so far would make a seller with
one slow buyer look slow on deals that have not finished.

THE MEAN, OVER RECENT DEALS
===========================
The mean, because a buyer asking "how long will this take" is asking about
the whole distribution, the slow deals included - a dispute that held the
money for three weeks is part of what dealing with this seller was like.
Over the latest RECENT_DEALS completions only: that bounds the query for a
busy seller, and it is the seller's current form rather than their first
year.

Computed in Python rather than SQL: SQLite and PostgreSQL subtract
timestamps differently, and at RECENT_DEALS rows the difference is nothing.
"""
from __future__ import annotations

from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Deal, DealStatus

RECENT_DEALS = 50


async def deal_completion_time(db: AsyncSession, seller_id: str) -> dict:
    """{avg_deal_time_minutes, timed_deals} - the minutes are None when the
    seller has no completed deal to time, never 0: "no deals yet" is not
    "instant"."""
    rows = (await db.execute(
        select(Deal.created_at, Deal.released_at)
        .where(
            Deal.seller_id == seller_id,
            Deal.status == DealStatus.released,
            Deal.released_at.is_not(None),
            Deal.created_at.is_not(None),
        )
        .order_by(Deal.released_at.desc())
        .limit(RECENT_DEALS)
    )).all()

    minutes = [
        (released - created).total_seconds() / 60.0
        for created, released in rows
        # A payout stamped before the deal was agreed is a clock or data
        # error; it would pull the mean below zero, not tell a buyer anything.
        if released >= created
    ]
    if not minutes:
        return {"avg_deal_time_minutes": None, "timed_deals": 0}
    return {
        "avg_deal_time_minutes": round(sum(minutes) / len(minutes), 1),
        "timed_deals": len(minutes),
    }
