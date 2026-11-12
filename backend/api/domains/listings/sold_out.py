"""Buyers reporting a listing sold out, and its seller saying it isn't.

Buyers pay sellers outside BROKA, so the app never learns that an item sold;
the stock module no longer guesses it from agreed deals (stock.deals_hold_stock).
The person who learns it is a buyer who asks and hears "it's gone". Their
report marks the listing sold out - out of the feed, search, stores and
trending (paid.live_clause) - and tells the seller, who can revoke it if the
item is still there. A report can't be repeated by the same person once
revoked (models/sold_out_report.py), so one rival can't keep a seller's
listing down.

TELLING THE SELLER (2026-11-12)
===============================
A report took the listing out of every list at once - the seller's own
dashboard included, since it reads the same live listings - and the only
word of it was a push whose tap opened nothing. A seller whose item was
still for sale had no way to find out, or to find the listing again, so a
mistaken report kept it hidden for good. Now the first report of a listing:

  * texts the seller ("Hey Xavier, it's Zeno from BROKA. A buyer marked
    your listing ... unavailable ..."), once per report - the claim on
    Listing.sold_out_texted_at - and at any hour: unlike the availability
    nudge, every hour it waits the listing is hidden from every buyer. A
    text that does not go is retried by the one-minute sweep
    (send_due_texts) for a day. The listing's own "text me" opt-out
    (Listing.sms_alerts) is honoured, as the expiry texts honour it;
  * pushes the seller, and the push opens their dashboard;
  * lists it on the dashboard (GET /listings/reported-unavailable) with
    "Still available", which is DELETE /listings/{id}/sold-out.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta
from typing import Optional

from fastapi import BackgroundTasks, HTTPException
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, ListingStatus, User
from api.models.sold_out_report import SoldOutReport

from .paid import is_live

logger = logging.getLogger(__name__)

# Reports one person can make in a day: enough for a buyer working down a
# list of dead ads, too few to sweep a rival's whole catalogue.
MAX_REPORTS_PER_DAY = 10

# How long the sweep keeps trying to text a seller whose text didn't go.
TEXT_RETRY_HOURS = 24

# Bounded per sweep pass, like every other sweep.
MAX_TEXTS_PER_PASS = 50

# One SMS part. The listing's name is shortened before the text runs into
# a second, billed part; a long first name is let through.
SMS_PART = 160
_MIN_NAME_CHARS = 16

PUSH_TYPE = "listing_sold_out_reported"


async def report(
    db: AsyncSession, listing_id: str, reporter_id: str,
    background: Optional[BackgroundTasks] = None,
) -> dict:
    listing = await db.get(Listing, listing_id)
    if listing is None or not is_live(listing):
        raise HTTPException(status_code=404, detail="Listing not found")
    if listing.seller_id == reporter_id:
        raise HTTPException(status_code=400, detail="Delete your own listing instead - it's under My listings.")
    if getattr(listing.status, "value", listing.status) != ListingStatus.active.value:
        raise HTTPException(status_code=409, detail="This listing is no longer for sale.")

    existing = (await db.execute(
        select(SoldOutReport).where(SoldOutReport.listing_id == listing_id,
                                    SoldOutReport.reporter_id == reporter_id)
    )).scalar_one_or_none()
    if existing is not None:
        if existing.revoked_at is not None:
            raise HTTPException(status_code=409, detail=(
                "The seller has said this item is still available. "
                "If it isn't, report the listing instead."))
        return _state(listing)

    today = (await db.execute(
        select(func.count(SoldOutReport.id)).where(
            SoldOutReport.reporter_id == reporter_id,
            SoldOutReport.created_at > datetime.utcnow() - timedelta(days=1))
    )).scalar() or 0
    if today >= MAX_REPORTS_PER_DAY:
        raise HTTPException(status_code=429, detail="You've reported enough listings for today. Thank you!")

    db.add(SoldOutReport(listing_id=listing_id, reporter_id=reporter_id))
    newly_marked = listing.sold_out_reported_at is None
    if newly_marked:
        listing.sold_out_reported_at = datetime.utcnow()
        # A text belongs to one report: a listing reported again after the
        # seller revoked an earlier one is texted again.
        listing.sold_out_texted_at = None
    try:
        await db.commit()
    except IntegrityError:
        # The same person's double tap: the other request recorded it.
        await db.rollback()
        listing = await db.get(Listing, listing_id)
        return _state(listing)
    if newly_marked:
        _after_commit(background, tell_seller, listing.seller_id, listing.id, listing.name or "")
    return _state(listing)


async def revoke(db: AsyncSession, listing_id: str, seller_id: str) -> dict:
    """The seller says the item is still available: back on sale."""
    listing = await db.get(Listing, listing_id)
    if listing is None or listing.seller_id != seller_id:
        raise HTTPException(status_code=404, detail="Listing not found")
    now = datetime.utcnow()
    await db.execute(
        update(SoldOutReport)
        .where(SoldOutReport.listing_id == listing_id, SoldOutReport.revoked_at.is_(None))
        .values(revoked_at=now))
    listing.sold_out_reported_at = None
    listing.sold_out_texted_at = None
    await db.commit()
    return _state(listing)


def _state(listing: Listing) -> dict:
    at = listing.sold_out_reported_at
    return {"listing_id": listing.id, "reported_sold_out": at is not None,
            "reported_at": at.isoformat() if at else None}


def _after_commit(background: Optional[BackgroundTasks], fn, *args) -> None:
    """Run `fn(*args)` after the response, never in the way of it.

    Through the request's BackgroundTasks when there is a request: they run
    once the reporter has their answer (and, under a test client, before it
    returns - so what was sent can be checked). A direct call has none, and
    gets a task on the running loop, as the push always did.
    """
    if background is not None:
        background.add_task(fn, *args)
        return
    try:
        asyncio.get_running_loop().create_task(fn(*args))
    except RuntimeError:  # no loop (a direct call in a test)
        logger.debug("[sold_out] no loop to tell the seller on")


def _short_name(name: str, limit: int) -> str:
    name = " ".join((name or "").split()) or "your item"
    return name if len(name) <= limit else name[: max(1, limit - 3)].rstrip() + "..."


def unavailable_push(name: str) -> tuple[str, str]:
    """The push's title and body."""
    return ("A buyer marked your listing unavailable",
            f'"{_short_name(name, 60)}" is hidden from buyers. Still for sale? '
            f'Open your dashboard and tap "Still available".')


def unavailable_sms(seller_name: Optional[str], listing_name: str) -> str:
    """The text to the seller: who is writing, what happened, and the way back.

    Plain GSM-7 (the provider sends nothing else) and one 160-character
    part where the names allow it: the listing's name gives way first,
    since what the seller has to do is the part that must survive.
    """
    from api.core.nudge_templates import _first_name
    from api.core.sms import sms_to_gsm7

    seller = sms_to_gsm7(_first_name(seller_name, "there")).strip() or "there"
    listing = sms_to_gsm7(" ".join((listing_name or "").split())).strip() or "your item"

    def text(name: str) -> str:
        return (f"Hey {seller}, it's Zeno from BROKA. A buyer marked your listing "
                f"\"{name}\" unavailable, so it's hidden. Not true? Revoke it on your "
                f"BROKA dashboard.")

    out = text(listing)
    over = len(out) - SMS_PART
    if over > 0 and len(listing) > _MIN_NAME_CHARS:
        out = text(_short_name(listing, max(_MIN_NAME_CHARS, len(listing) - over)))
    return out


async def tell_seller(seller_id: str, listing_id: str, name: str) -> None:
    """The push and the text to the seller, after the report is committed."""
    from api.core import push_devices

    title, body = unavailable_push(name)
    try:
        await push_devices.push_user(
            seller_id, title=title, body=body,
            data={"type": PUSH_TYPE, "listing_id": listing_id,
                  "listing_name": (name or "")[:80], "title": title, "body": body},
        )
    except Exception as exc:  # push_user never raises; a stand-in might
        logger.warning("[sold_out] push to the seller failed for %s: %s", listing_id, type(exc).__name__)
    await text_seller(listing_id)


async def text_seller(listing_id: str, now: Optional[datetime] = None) -> bool:
    """Text the seller that `listing_id` was marked unavailable, once per
    report. True when a text went. Never raises."""
    from api.database import AsyncSessionLocal

    try:
        async with AsyncSessionLocal() as db:
            return await _text_seller(db, listing_id, now or datetime.utcnow())
    except Exception as exc:
        logger.error("[sold_out] texting the seller failed for %s: %s", listing_id, type(exc).__name__)
        return False


async def _text_seller(db: AsyncSession, listing_id: str, now: datetime) -> bool:
    from api.core.sms import get_sms_provider, normalize_ke_phone

    listing = await db.get(Listing, listing_id)
    if (listing is None or listing.sold_out_reported_at is None
            or listing.sold_out_texted_at is not None):
        return False
    if getattr(listing, "sms_alerts", True) is False:
        # The seller asked not to be texted about this listing. The push
        # and the dashboard still tell them.
        return False
    # Claim the text before sending it: the request's own task and the
    # sweep may both reach here, and only one of them may text.
    won = (await db.execute(
        update(Listing)
        .where(Listing.id == listing_id,
               Listing.sold_out_reported_at.is_not(None),
               Listing.sold_out_texted_at.is_(None))
        .values(sold_out_texted_at=now)
        .execution_options(synchronize_session=False)
    )).rowcount
    await db.commit()
    if not won:
        return False
    seller = await db.get(User, listing.seller_id)
    phone = (getattr(seller, "phone", None) or "").strip()
    if not phone or normalize_ke_phone(phone) is None:
        # Nobody to text. The claim stays, so the sweep doesn't try a
        # number that can never take a text every minute for a day.
        logger.info("[sold_out] seller of %s has no number to text", listing_id)
        return False
    message = unavailable_sms(getattr(seller, "nickname", None) or seller.name, listing.name or "")
    try:
        sent = bool(await get_sms_provider().send(phone, message))
    except Exception as exc:
        logger.error("[sold_out] SMS send raised for %s: %s", listing_id, type(exc).__name__)
        sent = False
    if not sent:
        # Not delivered: give the claim back for the sweep to try again.
        await db.execute(
            update(Listing)
            .where(Listing.id == listing_id, Listing.sold_out_texted_at == now)
            .values(sold_out_texted_at=None)
            .execution_options(synchronize_session=False)
        )
        await db.commit()
    return sent


async def send_due_texts(now: Optional[datetime] = None) -> int:
    """One sweep pass: text every seller whose report text has not gone
    yet - the request's own attempt failed, or the process stopped before
    it ran. Returns how many went."""
    from api.database import AsyncSessionLocal

    now = now or datetime.utcnow()
    async with AsyncSessionLocal() as db:
        ids = (await db.execute(
            select(Listing.id).where(
                Listing.sold_out_reported_at.is_not(None),
                Listing.sold_out_reported_at >= now - timedelta(hours=TEXT_RETRY_HOURS),
                Listing.sold_out_texted_at.is_(None),
                Listing.sms_alerts.is_not(False),
            ).order_by(Listing.sold_out_reported_at).limit(MAX_TEXTS_PER_PASS)
        )).scalars().all()
    sent = 0
    for listing_id in ids:
        if await text_seller(listing_id, now):
            sent += 1
    if sent:
        logger.info("[sold_out] texted %d seller(s) about listings marked unavailable", sent)
    return sent
