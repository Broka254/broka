"""The authoritative auction lifecycle: UPCOMING -> LIVE -> ENDED.

EVERYTHING about whether an auction is open, what a bid must beat, who won
and what happens next is decided here, on server time, against the database.
The Flutter countdown is decoration; it is told what the state is, it never
decides it.

WHAT THIS REPLACES
==================
routers/auction.py used to be the whole auction. It:

  * never looked at a clock, so a bid was accepted forever - before the
    auction opened, after it ended, on an auction with no dates at all;
  * read the highest bid in one statement and inserted in another, with no
    lock, so two simultaneous bids could both pass the same "higher than
    current" check and leave the auction's denormalized current_bid
    reflecting whichever committed last rather than the actual maximum;
  * only required amount > current, so a KES 1 raise was a valid bid;
  * REJECTED any bid below the seller's reserve price, which turns a
    reserve into a public minimum and defeats the entire point of one;
  * never closed anything. There was no winner, no deal, no notification -
    an auction simply stopped having new bids.

THE RESERVE, SPECIFICALLY
=========================
A reserve is the seller's secret walk-away price, and it is evaluated ONCE,
at close. Bids below it are perfectly valid bids:

    starting price 20,000, reserve 50,000
    bid 20,500 -> accepted        bid 30,000 -> accepted
    bid 45,000 -> accepted        close at 45,000 -> reserve not met, no sale
    close at 55,000               -> reserve met, highest bidder wins

Buyers are told whether the reserve HAS BEEN MET (a fact they need in order
to bid sensibly), never what it is.

CONCURRENCY
===========
Two layers, and the second is the one that actually carries the guarantee.

A row lock (SELECT ... FOR UPDATE) is taken first, the same strategy
escrow/service.py's lock_deal_if_status uses. But that strategy comes with
a caveat its own docstring records: SQLAlchemy drops FOR UPDATE on SQLite,
which has no row-level locking, and the codebase accepts that because
production is Postgres.

That is not enough here. "Two simultaneous bids must never corrupt the
auction's final state" is a correctness property of this feature, not a
deployment detail - and a guarantee that only holds on the dialect CI does
NOT run is a guarantee nothing tests. So the actual state changes are
COMPARE-AND-SWAP statements: a single UPDATE whose WHERE clause pins the
state that was just validated.

    bid:   UPDATE ... WHERE current_bid IS <what I validated against>
    close: UPDATE ... WHERE closed_at IS NULL

A conflicting transaction changes the row first, the WHERE no longer
matches, the UPDATE reports zero rows, and the loser re-reads and reacts
instead of overwriting. One statement, so it is atomic on every dialect -
no lock required, and the row lock above simply makes conflicts rarer on
Postgres rather than being the thing correctness rests on.

IDEMPOTENCY
===========
close_auction's claim UPDATE carries the whole outcome - closed_at, winner,
winning amount, payment deadline - and only applies WHERE closed_at IS
NULL. Exactly one caller can win that race; every other caller reads the
winner's result and returns it untouched. A retried sweep, two workers or a
manual call cannot pick a second winner, and only the caller that won the
claim goes on to create the Deal.
"""
from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.core.money import add_money, money
from api.database import AuctionMeta, Bid, Listing, ListingStatus, ListingType, User

logger = logging.getLogger(__name__)

# Lifecycle states. Lower-case strings rather than an Enum column because
# auction_meta.status already shipped as a String and the Flutter client
# already compares against these exact values.
UPCOMING = "upcoming"
LIVE = "live"
ENDED = "ended"

# Close outcomes.
OUTCOME_WON = "won"
OUTCOME_NO_BIDS = "no_bids"
OUTCOME_RESERVE_NOT_MET = "reserve_not_met"
OUTCOME_UNPAID = "unpaid"


class AuctionError(HTTPException):
    """A bid or close rejected for a business reason.

    Carries a machine-readable `code` alongside the human message so the
    Flutter client can react to the specific case (show the new minimum,
    refresh a stale auction) instead of pattern-matching on English.
    """

    def __init__(self, status_code: int, code: str, message: str):
        super().__init__(status_code=status_code, detail=message)
        self.code = code
        self.message = message


def effective_status(meta: AuctionMeta, now: Optional[datetime] = None) -> str:
    """The auction's real state, derived from the clock every time.

    `meta.status` is a cached copy of this for cheap reads and for
    filtering in SQL; it is never trusted as the answer. An auction whose
    ends_at has passed is ENDED even if no sweep has run yet and the column
    still says "live" - which is exactly the window a bid would otherwise
    sneak through.
    """
    now = now or datetime.utcnow()
    if meta.closed_at is not None:
        return ENDED
    if meta.ends_at is not None and now >= meta.ends_at:
        return ENDED
    if meta.starts_at is not None and now < meta.starts_at:
        return UPCOMING
    # No starts_at means "already open" - the reading that matches how
    # pre-0021 auctions behaved (no start gate at all). No ends_at means
    # nothing can close it, which is handled at bid time below.
    return LIVE


def minimum_next_bid(meta: AuctionMeta) -> float:
    """What the next bid must be at least.

    First bid: the starting price (or the current bid if one somehow
    exists without one). Afterwards: current + the increment. This is the
    number the UI shows and the number the server enforces - one
    definition, used by both, so they cannot disagree.
    """
    increment = meta.min_bid_increment or settings.auction_default_min_increment
    if meta.current_bid is None:
        return money(meta.starting_price or increment)
    # add_money rather than a float add: this number is shown to the bidder
    # AND enforced against their bid, so the two must be bit-identical.
    return add_money(meta.current_bid, increment)


def reserve_met(meta: AuctionMeta, reserve_price: Optional[float]) -> bool:
    """Whether the top bid clears the seller's reserve.

    No reserve set means nothing to clear - the sale stands on the highest
    bid alone.
    """
    if not reserve_price:
        return True
    return (meta.current_bid or 0.0) >= float(reserve_price)


# Terms a seller may not change once people are bidding against them.
# Named here so the message a seller gets and the fields the API refuses
# come from one list.
LOCKED_TERMS = (
    "starting price", "minimum bid increment", "start time", "end time",
    "reserve price",
)


def terms_locked_reason(meta: AuctionMeta, now: Optional[datetime] = None) -> Optional[str]:
    """Why this auction's terms can no longer be changed, or None if they can.

    An auction's terms are the contract bidders are bidding against. Moving
    the reserve, the increment or the closing time after someone has
    committed money to it changes the deal underneath them - and moving the
    start or end time is also how an auction gets extended until a
    favoured bid arrives. So terms are editable only while the auction is
    genuinely still UPCOMING and untouched.

    bid_count is checked as well as status because they can disagree
    legitimately: an auction with no starts_at is LIVE from creation, and
    an auction that took a bid is settled regardless of what the clock
    says next.
    """
    now = now or datetime.utcnow()
    if meta.closed_at is not None:
        return "This auction has already ended."
    status = effective_status(meta, now)
    if status == ENDED:
        return "This auction has already ended."
    if (meta.bid_count or 0) > 0:
        return "Bidding has already started on this auction."
    if status == LIVE:
        return "This auction is already live."
    return None


def assert_terms_editable(meta: AuctionMeta, now: Optional[datetime] = None) -> None:
    reason = terms_locked_reason(meta, now)
    if reason is None:
        return
    raise AuctionError(
        409, "AUCTION_TERMS_LOCKED",
        f"{reason} The {', '.join(LOCKED_TERMS)} can't be changed once bidding "
        f"begins. You can still update photos.",
    )


def validate_terms(
    starting_price: Optional[float],
    min_bid_increment: Optional[float],
    starts_at: Optional[datetime],
    ends_at: Optional[datetime],
    reserve_price: Optional[float],
    now: Optional[datetime] = None,
) -> None:
    """The rules an auction window has to satisfy to be one.

    Enforced here rather than only in the client because the client is not
    the authority on any of it - a request that skips the app entirely has
    to hit the same wall.

    `now`, when given, also refuses a window that has already closed. An
    auction created or rescheduled that way was ended before anyone could
    bid - the sell wizard's date picker offers yesterday, and a draft
    restored a few days later still holds the closing time it was given.
    """
    if now is not None and ends_at is not None and ends_at <= now:
        raise AuctionError(422, "WINDOW_IN_PAST",
                            "The closing time has already passed. Choose a later one.")
    if starting_price is not None and starting_price <= 0:
        raise AuctionError(422, "INVALID_STARTING_PRICE",
                            "The starting price must be above zero.")
    if min_bid_increment is not None and min_bid_increment <= 0:
        raise AuctionError(422, "INVALID_INCREMENT",
                            "The minimum bid increment must be above zero.")
    if reserve_price is not None and reserve_price <= 0:
        raise AuctionError(422, "INVALID_RESERVE",
                            "A reserve price must be above zero. Leave it empty for no reserve.")
    if starts_at is not None and ends_at is not None and ends_at <= starts_at:
        raise AuctionError(422, "INVALID_WINDOW",
                            "The auction must close after it opens.")
    if (reserve_price is not None and starting_price is not None
            and reserve_price < starting_price):
        # Not fatal to the mechanics, but it is always a mistake: a reserve
        # below the starting price is met by the very first valid bid, so
        # it protects nothing and the seller thinks it does.
        raise AuctionError(422, "RESERVE_BELOW_START",
                            "A reserve below the starting price would be met by the "
                            "first bid. Raise the reserve or lower the starting price.")


@dataclass
class BidResult:
    listing_id: str
    bid_id: str
    amount: float
    bid_count: int
    min_next_bid: float
    status: str
    reserve_met: bool
    outbid_user_id: Optional[str]


async def _locked_meta(db: AsyncSession, listing_id: str) -> Optional[AuctionMeta]:
    """Row-locked auction_meta. See the module docstring on concurrency.

    populate_existing so the row's CURRENT values replace any copy this
    session already holds - see escrow/service.py lock_deal_if_status.
    """
    return (await db.execute(
        select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()


async def ensure_meta(
    db: AsyncSession,
    listing: Listing,
    *,
    commit: bool = True,
) -> AuctionMeta:
    """Get or create the lifecycle record for an auction listing.

    Listings created before auction_meta existed - and any created by a
    path that forgets - have no row. Rather than crashing on the first bid
    (which is what the old code guarded against) or inventing a window,
    this seeds the window from what the listing already carries:
    Listing.auction_date as the end, and "open now" as the start. That is
    the same interpretation migration 0021 backfills with, so a lazily
    created row and a migrated one describe the same auction.
    """
    meta = (await db.execute(
        select(AuctionMeta).where(AuctionMeta.listing_id == listing.id)
    )).scalar_one_or_none()
    if meta is not None:
        return meta

    now = datetime.utcnow()
    meta = AuctionMeta(
        id=str(uuid.uuid4()),
        listing_id=listing.id,
        status=UPCOMING,
        min_bid_increment=settings.auction_default_min_increment,
        starting_price=listing.price,
        starts_at=now,
        ends_at=listing.auction_date,
        bid_count=0,
    )
    meta.status = effective_status(meta, now)
    db.add(meta)
    if commit:
        await db.commit()
        await db.refresh(meta)
    else:
        await db.flush()
    return meta


async def place_bid(
    db: AsyncSession,
    listing_id: str,
    bidder_id: str,
    amount: float,
) -> BidResult:
    """Place one bid, atomically.

      1. lock the auction row (Postgres; a no-op on SQLite)
      2. verify it is LIVE *by server time*, not by the cached status
      3. read the current top bid
      4. validate the increment
      5. claim the lead with an UPDATE that pins the bid it was validated
         against - if someone else got there first, that UPDATE matches
         nothing and this bid is re-evaluated against the new leader
      6. insert the Bid
      7. commit

    Step 5 is what makes two simultaneous bids safe on every dialect. See
    the module docstring.
    """
    try:
        amount = float(amount)
    except (TypeError, ValueError):
        raise AuctionError(422, "INVALID_AMOUNT", "That bid amount is not a number.")
    if amount != amount or amount in (float("inf"), float("-inf")) or amount <= 0:
        raise AuctionError(422, "INVALID_AMOUNT", "That bid amount is not valid.")
    # Quantize at the door, so what is compared, stored and later becomes a
    # Deal's goods amount is one clean 2dp number rather than whatever
    # float the client's own arithmetic produced. See api/core/money.py.
    amount = money(amount)

    listing = (await db.execute(
        select(Listing).where(Listing.id == listing_id)
    )).scalar_one_or_none()
    if not listing:
        raise AuctionError(404, "LISTING_NOT_FOUND", "Listing not found.")
    if listing.listing_type != ListingType.auction:
        raise AuctionError(400, "NOT_AN_AUCTION", "This listing is not an auction.")
    if listing.seller_id == bidder_id:
        raise AuctionError(403, "OWN_LISTING", "You can't bid on your own auction.")

    # Bounded retry: a lost compare-and-swap means somebody else took the
    # lead in the microseconds since this bid was validated. If the bid
    # still clears the NEW leader it deserves another attempt rather than a
    # spurious rejection; if it no longer does, the loop exits through the
    # normal BID_TOO_LOW below. Three is plenty - each round requires
    # another bidder to win the race again.
    for _attempt in range(3):
        meta = await _locked_meta(db, listing_id)
        if meta is None:
            await ensure_meta(db, listing, commit=True)
            meta = await _locked_meta(db, listing_id)
            if meta is None:
                raise AuctionError(500, "NO_AUCTION_META", "This auction could not be opened.")

        now = datetime.utcnow()
        status = effective_status(meta, now)

        if status == UPCOMING:
            raise AuctionError(
                409, "AUCTION_NOT_STARTED",
                f"Bidding opens {meta.starts_at:%d %b %Y at %H:%M} UTC." if meta.starts_at
                else "Bidding hasn't opened on this auction yet.",
            )
        if status == ENDED:
            raise AuctionError(409, "AUCTION_ENDED", "This auction has ended.")
        if meta.ends_at is None:
            # LIVE with no end is not a lifecycle, it is the old bug. Refuse
            # rather than accept a bid into an auction that can never close.
            raise AuctionError(
                409, "AUCTION_NOT_SCHEDULED",
                "This auction has no closing time set, so it isn't accepting bids.",
            )

        required = minimum_next_bid(meta)
        if amount < required:
            raise AuctionError(
                400, "BID_TOO_LOW",
                f"Your bid must be at least KES {required:,.0f}.",
            )

        previous_bid = meta.current_bid
        outbid_user_id = meta.current_bidder_id if meta.current_bidder_id != bidder_id else None

        # THE claim. Applies only while current_bid is still exactly what
        # `required` was computed from, so a concurrent bid that changed it
        # makes this match zero rows instead of silently overwriting a
        # higher bid with a lower one.
        claim = await db.execute(
            update(AuctionMeta)
            .where(
                AuctionMeta.listing_id == listing_id,
                AuctionMeta.closed_at.is_(None),
                AuctionMeta.current_bid.is_(None) if previous_bid is None
                else AuctionMeta.current_bid == previous_bid,
            )
            .values(
                current_bid=amount,
                current_bidder_id=bidder_id,
                bid_count=AuctionMeta.bid_count + 1,
                status=LIVE,
            )
        )
        if claim.rowcount == 0:
            # Somebody else moved the auction between the read and the
            # write. Drop what this session thinks it knows and go again.
            await db.rollback()
            db.expire_all()
            continue

        bid = Bid(listing_id=listing_id, bidder_id=bidder_id, amount=amount, created_at=now)
        db.add(bid)
        await db.commit()
        await db.refresh(bid)

        meta = (await db.execute(
            select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
        )).scalar_one()

        return BidResult(
            listing_id=listing_id,
            bid_id=bid.id,
            amount=amount,
            bid_count=meta.bid_count,
            min_next_bid=minimum_next_bid(meta),
            status=effective_status(meta),
            reserve_met=reserve_met(meta, listing.reserve_price),
            outbid_user_id=outbid_user_id,
        )

    # Three lost races in a row means the auction is genuinely moving
    # faster than this bid. Report it as what it is rather than retrying
    # forever.
    raise AuctionError(
        409, "BID_CONFLICT",
        "Another bid landed first. Check the new minimum and try again.",
    )


@dataclass
class CloseResult:
    listing_id: str
    outcome: str
    winner_id: Optional[str]
    winning_amount: Optional[float]
    deal_id: Optional[str]
    payment_deadline: Optional[datetime]
    already_closed: bool


async def close_auction(db: AsyncSession, listing_id: str) -> Optional[CloseResult]:
    """Close one auction and, if it sold, create the winner's Deal.

    Idempotent by construction. The whole outcome - closed_at, winner,
    winning amount, payment deadline - is written by ONE claim UPDATE that
    only applies WHERE closed_at IS NULL. Exactly one caller can win that,
    on any dialect; every other caller reads back what the winner wrote and
    returns it. Running the closing job twice cannot produce two winners,
    and only the caller that won the claim goes on to create the Deal, so
    it cannot produce two deals either.

    Returns None only when there is no such auction to close.
    """
    meta = await _locked_meta(db, listing_id)
    if meta is None:
        return None

    if meta.closed_at is not None:
        # Already closed. One thing still needs doing on a re-run: a won
        # auction whose Deal creation failed.
        #
        # The close commits before the Deal is created, deliberately - a
        # downstream failure must never roll back a finished auction and
        # reopen it for more bids. The cost is a window where the auction
        # is correctly closed with a winner and a price but has no Deal,
        # so the winner has nothing to pay. Without this branch that state
        # was permanent: the sweep only looks for unclosed auctions, so
        # nothing ever came back for it.
        if await _needs_deal_retry(db, meta):
            return await _retry_winner_deal(db, listing_id, meta)
        return _existing_close(listing_id, meta)

    listing = (await db.execute(
        select(Listing).where(Listing.id == listing_id)
    )).scalar_one_or_none()
    if listing is None:
        return None

    now = datetime.utcnow()

    # The highest bid, read from Bid rather than from the denormalized
    # current_bid: at close time it is worth paying for the authoritative
    # answer. Ties break on the earlier bid, which is the convention every
    # auction house uses - being first to a price beats matching it.
    #
    # Safe to read before the claim: bidding is already closed by the clock
    # (effective_status is ENDED once ends_at passes), so no new bid can
    # arrive between this read and the UPDATE below.
    top = (await db.execute(
        select(Bid)
        .where(Bid.listing_id == listing_id)
        .order_by(Bid.amount.desc(), Bid.created_at.asc())
        .limit(1)
    )).scalars().first()

    if top is None:
        outcome, winner_id, winning_amount, deadline = OUTCOME_NO_BIDS, None, None, None
    elif listing.reserve_price and top.amount < float(listing.reserve_price):
        # The reserve is evaluated HERE and only here. Every bid below it
        # was a valid bid; what it could not do is complete a sale.
        outcome, winner_id, winning_amount, deadline = (
            OUTCOME_RESERVE_NOT_MET, None, None, None,
        )
    else:
        outcome = OUTCOME_WON
        winner_id = top.bidder_id
        winning_amount = money(top.amount)
        deadline = now + timedelta(hours=settings.auction_payment_deadline_hours)

    claim = await db.execute(
        update(AuctionMeta)
        .where(
            AuctionMeta.listing_id == listing_id,
            AuctionMeta.closed_at.is_(None),
        )
        .values(
            status=ENDED,
            closed_at=now,
            outcome=outcome,
            winner_id=winner_id,
            winning_amount=winning_amount,
            payment_deadline=deadline,
        )
    )
    await db.commit()

    if claim.rowcount == 0:
        # Another close won the race and has already written its outcome.
        # Return theirs; do NOT create a deal.
        db.expire_all()
        meta = (await db.execute(
            select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
        )).scalar_one_or_none()
        if meta is None:
            return None
        return _existing_close(listing_id, meta)

    if outcome != OUTCOME_WON:
        logger.info("[auction] CLOSED_%s listing=%s", outcome.upper(), listing_id)
        return CloseResult(listing_id, outcome, None, None, None, None, False)

    # Only the caller that won the claim reaches here, so at most one Deal
    # is ever created for an auction.
    deal_id = await _create_winner_deal(db, listing, winner_id, winning_amount)
    if deal_id:
        await db.execute(
            update(AuctionMeta)
            .where(AuctionMeta.listing_id == listing_id)
            .values(deal_id=deal_id)
        )
        await db.commit()

    logger.info(
        "[auction] CLOSED_WON listing=%s winner=%s amount=%.2f deal=%s",
        listing_id, winner_id, winning_amount, deal_id,
    )
    return CloseResult(
        listing_id=listing_id,
        outcome=OUTCOME_WON,
        winner_id=winner_id,
        winning_amount=winning_amount,
        deal_id=deal_id,
        payment_deadline=deadline,
        already_closed=False,
    )


async def _needs_deal_retry(db: AsyncSession, meta: AuctionMeta) -> bool:
    """A closed, won auction whose Deal does not exist.

    Two shapes, and the second is the one that needs a database round trip:

      * deal_id is NULL - creation never succeeded.
      * deal_id is SET but no Deal has that id - a claim that was never
        redeemed, because the process died between claiming the id and
        writing the row. Indistinguishable from the first case in effect:
        the winner has nothing to pay.

    Detecting the orphan is what lets the claim below be a strict
    compare-and-swap without stranding an auction forever.
    """
    from api.database import Deal

    if not (
        meta.closed_at is not None
        and meta.outcome == OUTCOME_WON
        and meta.winner_id is not None
        and meta.winning_amount is not None
    ):
        return False
    if not meta.deal_id:
        return True
    exists = (await db.execute(
        select(Deal.id).where(Deal.id == meta.deal_id).limit(1)
    )).scalar_one_or_none()
    return exists is None


async def _retry_winner_deal(
    db: AsyncSession, listing_id: str, meta: AuctionMeta,
) -> CloseResult:
    """Re-attempt the Deal for an already-closed win.

    Safe to call repeatedly. EscrowService.finalize_deal returns the
    EXISTING deal for a (listing, buyer) pair it has already created rather
    than making another, so a retry that follows a partial success adopts
    that deal instead of duplicating it - which is also what makes this
    correct if the original failure happened AFTER the deal was written but
    before deal_id was persisted.

    Nothing here touches closed_at, the winner or the amount. The auction
    stays closed and the result stays exactly as it was decided.
    """
    listing = (await db.execute(
        select(Listing).where(Listing.id == listing_id)
    )).scalar_one_or_none()
    if listing is None:
        return _existing_close(listing_id, meta)

    # CLAIM the right to create this deal, with the id the deal will have.
    #
    # Compare-and-swap against the deal_id we just observed, so two workers
    # retrying the same auction cannot both proceed: the second one's WHERE
    # no longer matches and it backs off. Claiming with the REAL id rather
    # than a sentinel is what makes a crash recoverable - a claim that is
    # never redeemed leaves a deal_id pointing at a Deal that does not
    # exist, which _needs_deal_retry detects on the next pass. A sentinel
    # would be indistinguishable from a live in-flight claim.
    observed = meta.deal_id
    claimed_id = str(uuid.uuid4())
    claim = await db.execute(
        update(AuctionMeta)
        .where(
            AuctionMeta.listing_id == listing_id,
            AuctionMeta.deal_id.is_(None) if observed is None
            else AuctionMeta.deal_id == observed,
        )
        .values(deal_id=claimed_id)
    )
    await db.commit()
    if claim.rowcount == 0:
        # Another retry owns this one. Do not create a second deal.
        db.expire_all()
        current = (await db.execute(
            select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
        )).scalar_one_or_none()
        return _existing_close(listing_id, current or meta)

    logger.info("[auction] DEAL_RETRY listing=%s winner=%s", listing_id, meta.winner_id)
    deal_id = await _create_winner_deal(
        db, listing, meta.winner_id, float(meta.winning_amount),
        deal_id=claimed_id,
    )
    if not deal_id:
        # Release the claim so the next pass can try again immediately,
        # rather than waiting for the orphan check to notice.
        await db.execute(
            update(AuctionMeta)
            .where(AuctionMeta.listing_id == listing_id,
                    AuctionMeta.deal_id == claimed_id)
            .values(deal_id=None)
        )
        await db.commit()
    if deal_id:
        # Only fill an EMPTY deal_id. If a concurrent retry got there
        # first, theirs stands and this one is a no-op rather than an
        # overwrite - the same compare-and-swap shape the close itself uses.
        # Normally a no-op - the claim above already wrote this id. It
        # matters only when finalize_deal ADOPTED a pre-existing deal for
        # this (listing, buyer) and returned that one instead.
        if deal_id != claimed_id:
            await db.execute(
                update(AuctionMeta)
                .where(AuctionMeta.listing_id == listing_id,
                        AuctionMeta.deal_id == claimed_id)
                .values(deal_id=deal_id)
            )
            await db.commit()

    # Re-read unconditionally rather than reusing the `meta` passed in.
    # A failed attempt rolls the session back (see _create_winner_deal),
    # which EXPIRES that instance - reading its attributes afterwards
    # triggers a lazy refresh from inside a sync context and raises
    # SQLAlchemy's greenlet_spawn error, turning a handled deal failure
    # into an unhandled one. Found by the sweep test doing exactly that.
    db.expire_all()
    fresh = (await db.execute(
        select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
    )).scalar_one_or_none()
    if fresh is None:
        return _existing_close(listing_id, meta)
    if deal_id:
        logger.info(
            "[auction] DEAL_RETRY_OK listing=%s deal=%s", listing_id, fresh.deal_id,
        )
    return _existing_close(listing_id, fresh)


def _existing_close(listing_id: str, meta: AuctionMeta) -> CloseResult:
    return CloseResult(
        listing_id=listing_id,
        outcome=meta.outcome or OUTCOME_NO_BIDS,
        winner_id=meta.winner_id,
        winning_amount=meta.winning_amount,
        deal_id=meta.deal_id,
        payment_deadline=meta.payment_deadline,
        already_closed=True,
    )


async def _create_winner_deal(
    db: AsyncSession, listing: Listing, winner_id: str, winning_amount: float,
    deal_id: Optional[str] = None,
) -> Optional[str]:
    """Hand the win straight to the existing Deal + E-Confirm flow.

    Deliberately EscrowService.finalize_deal and not a bespoke auction
    payment path: that is the one function that knows how a BROKA sale
    becomes a payable obligation - it validates the price, refuses to
    create a second deal for the same (listing, buyer), applies
    the auction commission rate (settings.auction_commission_rate - it
    reads the listing's type), moves the listing to `pending` so it cannot
    also be sold through negotiation, writes the audit row, and publishes
    DealFinalized, which is what already drives the "tap to pay" push and
    the whole escrow lifecycle after it. An auction winner should arrive in
    exactly the same place a negotiated buyer does, because from the
    payment system's point of view they are the same thing.

    The winner is passed as current_user_id because finalize_deal
    authorises "the caller is the buyer" - and they are. Nobody is being
    impersonated: winning is what entitles them to this purchase, and the
    close routine is acting on that entitlement.
    """
    from api.domains.escrow.service import EscrowService

    try:
        result = await EscrowService(db).finalize_deal(
            listing_id=listing.id,
            buyer_id=winner_id,
            agreed_price=float(winning_amount),
            current_user_id=winner_id,
            deal_id=deal_id,
        )
        return result.get("deal_id")
    except Exception as exc:
        # A failed deal does not un-win the auction. It is logged loudly and
        # the close stands; close_auction can be re-run and will pick up
        # from the already-closed branch, and finalize_deal's own duplicate
        # guard makes that retry safe.
        logger.error(
            "[auction] DEAL_CREATION_FAILED listing=%s winner=%s: %s",
            listing.id, winner_id, exc,
        )
        # Leave the session usable for the caller's own follow-up writes -
        # a failed finalize_deal may have left it mid-transaction.
        try:
            await db.rollback()
        except Exception:
            pass
        return None


async def due_for_close(db: AsyncSession, limit: int = 100) -> list[str]:
    """Auction listing ids whose window has closed but which are still open."""
    now = datetime.utcnow()
    rows = (await db.execute(
        select(AuctionMeta.listing_id)
        .where(
            AuctionMeta.closed_at.is_(None),
            AuctionMeta.ends_at.is_not(None),
            AuctionMeta.ends_at <= now,
        )
        .limit(limit)
    )).scalars().all()
    return list(rows)


async def due_for_deal_retry(db: AsyncSession, limit: int = 100) -> list[str]:
    """Closed, won auctions that still have no Deal.

    Separate from due_for_close because that query filters on
    closed_at IS NULL by definition - these auctions are closed, which is
    exactly why nothing was coming back for them.
    """
    from api.database import Deal

    # deal_id IS NULL, or it points at a Deal that does not exist - a claim
    # whose process died before writing the row. See _needs_deal_retry.
    rows = (await db.execute(
        select(AuctionMeta.listing_id)
        .outerjoin(Deal, Deal.id == AuctionMeta.deal_id)
        .where(
            AuctionMeta.closed_at.is_not(None),
            AuctionMeta.outcome == OUTCOME_WON,
            AuctionMeta.winner_id.is_not(None),
            Deal.id.is_(None),
        )
        .limit(limit)
    )).scalars().all()
    return list(rows)


# How many times the ending-soon reminder may be attempted before the sweep
# gives up on it. Three is enough to ride out a transient push/Redis
# failure across three minutes of 60-second sweeps, and small enough that a
# permanently broken delivery cannot produce an unbounded number of
# duplicate reminders if the failure is actually in the confirmation rather
# than the send.
MAX_ENDING_SOON_ATTEMPTS = 3

# How long a claimed attempt keeps other workers off the reminder: long
# enough to send and confirm, shorter than the 60-second sweep so the next
# tick's retry of a failed send is not refused. See claim_ending_soon_attempt.
ENDING_SOON_RETRY_AFTER = timedelta(seconds=45)


async def due_for_ending_soon(db: AsyncSession, limit: int = 100) -> list[AuctionMeta]:
    """Live auctions inside the ending-soon window still owed a reminder.

    "Owed" means ending_soon_notified_at IS NULL - the reminder has not
    been CONFIRMED sent. It used to mean the same column, but the sweep
    wrote it before sending, so the column really meant "we intended to
    send this", and an emission that failed left the auction excluded from
    this query forever with no reminder ever delivered.

    Now the column is written only after a successful emit, and this query
    keeps returning the auction until that happens or the attempt budget
    runs out. See claim_ending_soon_attempt.
    """
    now = datetime.utcnow()
    horizon = now + timedelta(minutes=settings.auction_ending_soon_minutes)
    rows = (await db.execute(
        select(AuctionMeta)
        .where(
            AuctionMeta.closed_at.is_(None),
            AuctionMeta.ending_soon_notified_at.is_(None),
            AuctionMeta.ending_soon_attempts < MAX_ENDING_SOON_ATTEMPTS,
            AuctionMeta.ends_at.is_not(None),
            AuctionMeta.ends_at > now,
            AuctionMeta.ends_at <= horizon,
        )
        .limit(limit)
    )).scalars().all()
    return list(rows)


async def claim_ending_soon_attempt(db: AsyncSession, listing_id: str) -> bool:
    """Take ownership of one ending-soon delivery attempt.

    The durable half of the outbox. A compare-and-swap increments
    ending_soon_attempts against the value just observed, so:

      * two workers sweeping the same tick cannot both send - the loser's
        WHERE matches nothing and it skips the auction. That takes the
        claim time as well as the count: a worker reading the row just
        after another's claim committed saw a count it could increment,
        and sent a second reminder while the first was still going out;
      * the attempt is recorded BEFORE the send, so a process that dies
        mid-emit has still spent its attempt and cannot retry forever;
      * the reminder stays owed (ending_soon_notified_at still NULL) until
        confirm_ending_soon_sent runs, so a failed send IS retried.

    Delivery is therefore at-least-once with a hard ceiling of
    MAX_ENDING_SOON_ATTEMPTS: the duplicate window is a send that succeeded
    but whose confirmation did not commit, and it can repeat at most twice
    more rather than indefinitely.

    Returns False when the claim was lost or the auction no longer
    qualifies - the caller must not send in that case.
    """
    meta = (await db.execute(
        select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
    )).scalar_one_or_none()
    if meta is None or meta.ending_soon_notified_at is not None:
        return False
    observed = meta.ending_soon_attempts or 0
    if observed >= MAX_ENDING_SOON_ATTEMPTS:
        return False

    now = datetime.utcnow()
    claim = await db.execute(
        update(AuctionMeta)
        .where(
            AuctionMeta.listing_id == listing_id,
            AuctionMeta.ending_soon_notified_at.is_(None),
            AuctionMeta.ending_soon_attempts == observed,
            or_(AuctionMeta.ending_soon_claimed_at.is_(None),
                AuctionMeta.ending_soon_claimed_at <= now - ENDING_SOON_RETRY_AFTER),
        )
        .values(ending_soon_attempts=observed + 1, ending_soon_claimed_at=now)
    )
    await db.commit()
    return claim.rowcount > 0


async def confirm_ending_soon_sent(db: AsyncSession, listing_id: str) -> None:
    """Mark the reminder delivered. Called only after a successful emit.

    Guarded on the column still being NULL so a late confirmation from a
    retry cannot overwrite the timestamp of the attempt that actually
    landed first.
    """
    await db.execute(
        update(AuctionMeta)
        .where(
            AuctionMeta.listing_id == listing_id,
            AuctionMeta.ending_soon_notified_at.is_(None),
        )
        .values(ending_soon_notified_at=datetime.utcnow())
    )
    await db.commit()


async def due_for_payment_lapse(db: AsyncSession, limit: int = 100) -> list[AuctionMeta]:
    """Won auctions whose payment deadline has passed."""
    now = datetime.utcnow()
    rows = (await db.execute(
        select(AuctionMeta)
        .where(
            AuctionMeta.outcome == OUTCOME_WON,
            AuctionMeta.payment_deadline.is_not(None),
            AuctionMeta.payment_deadline <= now,
        )
        .limit(limit)
    )).scalars().all()
    return list(rows)


# ── Payment lapse ─────────────────────────────────────────────────────────────
#
# A lapse CANCELS a deal and puts the item back on sale, so it must never run
# while the winner's money might be moving. "deal.status is still agreed" is
# not evidence of that: `agreed` is exactly the status a deal sits in while an
# STK prompt is on the buyer's phone, and it stays `agreed` until the provider
# reports the escrow funded. Lapsing on status alone let a buyer who paid in
# the last minute end up with money held against a cancelled deal and the item
# re-listed for someone else.
#
# So the lapse first asks what became of any payment attempt, and only a
# confirmed answer lets it proceed:
#
#   no attempt at all                       -> lapse
#   attempt younger than the settle window  -> in flight, look again later
#   E-Confirm attempt past the window       -> ask E-Confirm; lapse only on a
#                                              definite "not funded"
#   provider says funded / money moved      -> never lapse; let the escrow
#                                              service apply it, and alert if
#                                              the deal did not follow
#   provider unreachable or unclear         -> look again later
#
# Then everything is re-checked under the deal and escrow row locks, which
# are the same locks the funding path takes before it claims an attempt - so
# a Pay tap and a lapse cannot both win.

_VERDICT_NONE = "none"                    # nothing is or was in flight
_VERDICT_IN_FLIGHT = "in_flight"          # too recent to judge
_VERDICT_NEEDS_PROVIDER = "needs_provider"  # old enough; the provider must answer
_VERDICT_UNCONFIRMED = "unconfirmed"      # provider could not give a definite answer
_VERDICT_FUNDED = "funded"                # money reached the provider


def _money_moved_statuses() -> tuple:
    from api.models.external_escrow import EConfirmEscrowStatus as S
    return (S.FUNDED, S.RELEASE_PENDING, S.COMPLETED, S.PAYOUT_FAILED)


async def _payment_evidence(db: AsyncSession, deal_id: str, *, lock: bool):
    """The deal's E-Confirm escrow row and legacy M-Pesa transactions.

    populate_existing so a re-read after a commit sees current values rather
    than this session's cached copies (sessions use expire_on_commit=False).
    """
    from api.database import MpesaTransaction
    from api.models.external_escrow import ExternalEscrow

    # An auction is paid in one payment (EscrowService refuses part
    # payments on one), so this is its only row; ordered and limited anyway,
    # since external_escrows holds one row per payment.
    q = (select(ExternalEscrow).where(ExternalEscrow.deal_id == deal_id)
         .order_by(ExternalEscrow.payment_no).limit(1))
    if lock:
        q = q.with_for_update()
    escrow = (await db.execute(
        q.execution_options(populate_existing=True)
    )).scalars().first()
    txns = (await db.execute(
        select(MpesaTransaction)
        .where(MpesaTransaction.deal_id == deal_id)
        .execution_options(populate_existing=True)
    )).scalars().all()
    return escrow, list(txns)


def _local_verdict(escrow, txns, now: datetime, confirmed_dead_attempt: Optional[datetime]):
    """What the rows alone say. Returns (verdict, recheck_at).

    `confirmed_dead_attempt` is the funding_initiated_at the provider has
    ALREADY been asked about and answered "not funded" - that attempt, and
    only that one, no longer blocks the lapse.
    """
    from api.database import MpesaStatus

    settle = timedelta(minutes=settings.auction_funding_settle_minutes)

    if escrow is not None and escrow.status in _money_moved_statuses():
        return _VERDICT_FUNDED, None
    if any(t.status == MpesaStatus.success for t in txns):
        return _VERDICT_FUNDED, None

    if escrow is not None and escrow.funding_initiated_at is not None \
            and escrow.funding_initiated_at != confirmed_dead_attempt:
        settle_at = escrow.funding_initiated_at + settle
        if now < settle_at:
            return _VERDICT_IN_FLIGHT, settle_at
        return _VERDICT_NEEDS_PROVIDER, None

    # Legacy Daraja STK pushes (commission-only deals). Safaricom resolves an
    # STK prompt - paid, cancelled or timed out - within a couple of minutes
    # and posts the result to the callback, so a transaction still pending
    # after the settle window is one whose prompt died unanswered. A callback
    # that somehow arrives later still lands safely: _process_mpesa_callback
    # refuses to move a non-agreed deal and raises a reconciliation alert.
    pending_until = [
        (t.created_at or now) + settle
        for t in txns
        if t.status == MpesaStatus.pending and not t.callback_processed
    ]
    in_flight_until = [at for at in pending_until if now < at]
    if in_flight_until:
        return _VERDICT_IN_FLIGHT, max(in_flight_until)

    return _VERDICT_NONE, None


async def _ask_provider(db: AsyncSession, deal_id: str, escrow) -> str:
    """Resolve an E-Confirm attempt that is past its settle window.

    Returns _VERDICT_NONE only on a definite "still pending, never funded"
    from E-Confirm itself. A funded answer is handed to the escrow service,
    which owns that transition (deal -> paid, ledger, events); anything
    unclear - an unreachable provider included - defers the decision.
    """
    from api.domains.escrow.providers import get_escrow_provider
    from api.domains.escrow.service import EscrowService
    from api.models.external_escrow import EConfirmEscrowStatus

    if not escrow.provider_transaction_id:
        return _VERDICT_UNCONFIRMED
    try:
        result = await get_escrow_provider().get_status(escrow.provider_transaction_id)
    except Exception as exc:
        logger.warning(
            "[auction] lapse: E-Confirm status check failed deal=%s: %s",
            deal_id, type(exc).__name__,
        )
        return _VERDICT_UNCONFIRMED

    if result.status == EConfirmEscrowStatus.PENDING:
        return _VERDICT_NONE
    if result.status in _money_moved_statuses():
        try:
            await EscrowService(db).reconcile_econfirm_escrow(deal_id)
        except Exception as exc:
            logger.error("[auction] lapse: reconcile failed deal=%s: %s", deal_id, exc)
            try:
                await db.rollback()
            except Exception:
                pass
        return _VERDICT_FUNDED
    return _VERDICT_UNCONFIRMED


async def _defer_lapse(
    db: AsyncSession, listing_id: str, recheck_at: Optional[datetime], why: str,
) -> None:
    """Push the payment deadline out so the sweep looks again later.

    Guarded on the auction still being an open win, so a deferral can never
    resurrect a deadline another path has already cleared.
    """
    recheck_at = recheck_at or (
        datetime.utcnow() + timedelta(minutes=settings.auction_funding_settle_minutes)
    )
    await db.execute(
        update(AuctionMeta)
        .where(
            AuctionMeta.listing_id == listing_id,
            AuctionMeta.outcome == OUTCOME_WON,
            AuctionMeta.payment_deadline.is_not(None),
        )
        .values(payment_deadline=recheck_at)
    )
    await db.commit()
    logger.info(
        "[auction] PAYMENT_LAPSE_DEFERRED listing=%s until=%s reason=%s",
        listing_id, recheck_at.isoformat(), why,
    )


async def _alert_funded_but_unpaid(db: AsyncSession, meta: AuctionMeta, deal, escrow) -> None:
    """Money reached the provider but the deal never became paid.

    Never lapsed and never auto-corrected: which side is right needs a human
    with the provider's dashboard. The deadline is cleared so the sweep stops
    re-examining it; the audit row is the durable record
    (GET /admin/audit-logs) and report_reconciliation raises the Sentry
    alert.
    """
    from api.core.audit import record_audit
    from api.core.events import EConfirmReconciliationRequired, publish

    tx = getattr(escrow, "provider_transaction_id", None) or ""
    reason = (
        f"auction payment deadline reached with money moved "
        f"(escrow={getattr(escrow, 'status', 'none')}) but deal still "
        f"{deal.status.value if deal is not None else 'missing'}"
    )
    meta.payment_deadline = None
    if deal is not None:
        await record_audit(
            db, "system", "auction_payment_reconciliation_required", "deal", deal.id, reason,
        )
    await db.commit()
    from api.core.reconciliation import report_reconciliation
    report_reconciliation(
        "auction_payment_reconciliation_required", deal_id=getattr(deal, "id", None),
        provider_transaction_id=tx or None, listing_id=meta.listing_id,
        reason=f"{reason} - the item was NOT relisted; confirm the payment and move the "
               f"deal on by hand",
    )
    if deal is not None:
        await publish(EConfirmReconciliationRequired(
            deal_id=deal.id, provider_transaction_id=tx, reason=reason,
        ))


async def lapse_unpaid_win(db: AsyncSession, listing_id: str) -> Optional[str]:
    """Handle a winner who never paid.

    The policy is deliberately the simple one the brief asks for - no
    bidder penalties, no automatic offer to the runner-up. The win lapses,
    the deal is cancelled, and the listing goes back to `active` so the
    seller can relist or sell it another way. What must NOT happen is the
    listing staying locked in `pending` forever because somebody won it and
    walked away - nor, just as much, cancelling a deal the winner is in the
    middle of paying for. See the section comment above.

    Returns OUTCOME_UNPAID when it lapsed the win, or None when there was
    nothing to do, the buyer paid, or the decision was deferred.
    """
    from api.database import Deal, DealStatus

    # ── Phase 1: what became of any payment attempt? No locks held. ─────────
    meta = (await db.execute(
        select(AuctionMeta)
        .where(AuctionMeta.listing_id == listing_id)
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if meta is None or meta.outcome != OUTCOME_WON:
        return None
    if meta.payment_deadline is None or datetime.utcnow() < meta.payment_deadline:
        return None

    confirmed_dead_attempt: Optional[datetime] = None
    if meta.deal_id:
        escrow, txns = await _payment_evidence(db, meta.deal_id, lock=False)
        verdict, recheck_at = _local_verdict(escrow, txns, datetime.utcnow(), None)
        if verdict == _VERDICT_NEEDS_PROVIDER:
            attempt = escrow.funding_initiated_at
            # End the read transaction before a network call: nothing may
            # be held open while waiting on E-Confirm.
            await db.commit()
            verdict = await _ask_provider(db, meta.deal_id, escrow)
            if verdict == _VERDICT_NONE:
                confirmed_dead_attempt = attempt
        if verdict in (_VERDICT_IN_FLIGHT, _VERDICT_UNCONFIRMED):
            await _defer_lapse(db, listing_id, recheck_at, verdict)
            return None
        # _VERDICT_FUNDED falls through: Phase 2 either finds the deal paid
        # (the normal case) or raises the reconciliation alert.

    # ── Phase 2: re-check everything under the row locks, then act. ─────────
    meta = await _locked_meta(db, listing_id)
    if meta is None or meta.outcome != OUTCOME_WON:
        await db.rollback()
        return None
    now = datetime.utcnow()
    if meta.payment_deadline is None or now < meta.payment_deadline:
        await db.rollback()
        return None

    deal = None
    escrow = None
    txns: list = []
    if meta.deal_id:
        deal = (await db.execute(
            select(Deal).where(Deal.id == meta.deal_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )).scalar_one_or_none()
        escrow, txns = await _payment_evidence(db, meta.deal_id, lock=True)

    if deal is not None and deal.status != DealStatus.agreed:
        # They paid (or the deal moved on some other way). Clearing the
        # deadline stops the sweep re-examining it forever.
        meta.payment_deadline = None
        await db.commit()
        return None

    verdict, recheck_at = _local_verdict(escrow, txns, now, confirmed_dead_attempt)
    if verdict == _VERDICT_FUNDED:
        await _alert_funded_but_unpaid(db, meta, deal, escrow)
        return None
    if verdict != _VERDICT_NONE:
        # A payment attempt started between the two phases. Release the
        # locks and judge it on its own schedule.
        await db.rollback()
        await _defer_lapse(db, listing_id, recheck_at, verdict)
        return None

    meta.outcome = OUTCOME_UNPAID
    meta.payment_deadline = None
    if deal is not None:
        deal.status = DealStatus.cancelled

    listing = (await db.execute(
        select(Listing).where(Listing.id == listing_id)
    )).scalar_one_or_none()
    if listing is not None and listing.status != ListingStatus.completed:
        listing.status = ListingStatus.active

    await db.commit()
    logger.info(
        "[auction] PAYMENT_LAPSED listing=%s winner=%s deal=%s",
        listing_id, meta.winner_id, meta.deal_id,
    )
    return OUTCOME_UNPAID


async def public_state(db: AsyncSession, listing: Listing, meta: AuctionMeta) -> dict:
    """What a client is allowed to know about an auction.

    Note what is NOT here: reserve_price. The client is told whether the
    reserve has been met - which it needs, to bid sensibly - and never what
    it is. `has_reserve` is public because "this may not sell below a
    hidden price" is itself information a bidder is entitled to.
    """
    now = datetime.utcnow()
    status = effective_status(meta, now)
    winner_name = None
    if meta.winner_id:
        winner_name = (await db.execute(
            select(User.name).where(User.id == meta.winner_id)
        )).scalar_one_or_none()

    return {
        "status": status,
        "starts_at": meta.starts_at.isoformat() if meta.starts_at else None,
        "ends_at": meta.ends_at.isoformat() if meta.ends_at else None,
        "server_time": now.isoformat(),
        "seconds_remaining": (
            max(0, int((meta.ends_at - now).total_seconds())) if meta.ends_at else None
        ),
        "starting_price": meta.starting_price,
        "current_bid": meta.current_bid,
        "bid_count": meta.bid_count or 0,
        "min_bid_increment": meta.min_bid_increment,
        "min_next_bid": minimum_next_bid(meta),
        "has_reserve": bool(listing.reserve_price),
        "reserve_met": reserve_met(meta, listing.reserve_price),
        "outcome": meta.outcome,
        "winner_id": meta.winner_id,
        "winner_name": winner_name,
        "winning_amount": meta.winning_amount,
        "deal_id": meta.deal_id,
        "payment_deadline": meta.payment_deadline.isoformat() if meta.payment_deadline else None,
    }
