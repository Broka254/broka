"""
BROKA - Deal Completion Rate / Leak Detection Tests
Regression coverage for two bugs an external audit caught against
domains/trust/completion_rate.py and this session fixed:
  1. Leak timing: silence must be measured from when the 7-day leak
     window CLOSED, not from `now` - a deal agreed 8 days ago with a
     5-day-old last message must NOT flag (that's only 8 days elapsed,
     not the required 12).
  2. Cross-deal contamination: evidence must be scoped to the specific
     deal being evaluated - an earlier, unrelated deal between the same
     buyer+listing must not leak evidence into a later one.

Run: pytest backend/tests/test_completion_rate.py -v
"""
import itertools
import pytest
import pytest_asyncio
from datetime import datetime, timedelta

from api.database import (
    init_db, reset_engine, AsyncSessionLocal,
    User, Listing, Deal, DealStatus, NegotiationMessage, AuditLog,
)
from api.domains.trust.completion_rate import (
    _compute_dcr_from_ages, flag_leaked_deals,
    LEAK_WINDOW_DAYS, SILENCE_WINDOW_DAYS, PRIOR_MEAN,
)


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_completion_rate.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()  # see api/database.py - engine is built once at first import
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


# Was datetime.utcnow().timestamp() truncated to 12 chars, which chops off
# right at the decimal point and keeps only whole-second precision - two
# _make_user() calls in the same second (the normal case: every test here
# makes a seller then a buyer back to back) collided on an identical phone
# and hit users.phone's UNIQUE constraint. A plain per-session counter can't
# collide regardless of timing.
_phone_seq = itertools.count()


async def _make_user(db, name="Test User") -> User:
    u = User(name=name, phone=f"07{next(_phone_seq):08d}",
              password_hash="x", phone_verified=True)
    db.add(u)
    await db.flush()
    return u


async def _make_listing(db, seller_id: str) -> Listing:
    l = Listing(seller_id=seller_id, name="Test Item", category="electronics",
                price=10_000.0, lat=-1.28, lng=36.82)
    db.add(l)
    await db.flush()
    return l


async def _make_deal(db, listing_id: str, seller_id: str, buyer_id: str,
                      created_at: datetime) -> Deal:
    d = Deal(listing_id=listing_id, seller_id=seller_id, buyer_id=buyer_id,
              agreed_price=10_000.0, commission=300.0, status=DealStatus.agreed,
              created_at=created_at)
    db.add(d)
    await db.flush()
    return d


async def _make_message(db, listing_id: str, buyer_id: str, sender_id: str,
                         created_at: datetime) -> NegotiationMessage:
    m = NegotiationMessage(listing_id=listing_id, buyer_id=buyer_id, sender_id=sender_id,
                             role="buyer", content="hi", created_at=created_at)
    db.add(m)
    await db.flush()
    return m


# ── Pure-function tests (no DB) ─────────────────────────────────────────────

def test_dcr_cold_start_returns_neutral_prior():
    """Zero deal history -> exactly PRIOR_MEAN*100, not 0%."""
    assert _compute_dcr_from_ages([], []) == PRIOR_MEAN * 100


def test_dcr_all_completed_beats_mixed():
    all_completed = _compute_dcr_from_ages([1.0, 2.0, 3.0], [])
    mixed = _compute_dcr_from_ages([1.0, 2.0], [1.0])
    assert all_completed > mixed


# ── Leak timing (the audit's primary finding) ───────────────────────────────

@pytest.mark.asyncio
async def test_leak_not_flagged_before_full_window_plus_silence():
    """
    The exact bug the audit caught: deal agreed 8 days ago (past the
    7-day window), last message 5 days ago. Old code flagged this - only
    8 days have elapsed, not the required 7+5=12. Must NOT flag yet.
    """
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Seller8")
        buyer  = await _make_user(db, "Buyer8")
        listing = await _make_listing(db, seller.id)
        now = datetime.utcnow()
        deal = await _make_deal(db, listing.id, seller.id, buyer.id, now - timedelta(days=8))
        await _make_message(db, listing.id, buyer.id, buyer.id, now - timedelta(days=5))
        await db.commit()

        await flag_leaked_deals(db)
        await db.refresh(deal)
        assert deal.leak_flag is False, (
            "flagged after only 8 days - silence must be measured from when "
            "the 7-day window closed, not from now"
        )


@pytest.mark.asyncio
async def test_leak_flagged_after_full_window_plus_silence():
    """Same shape, but the full 7+5=12 days have genuinely elapsed - must flag."""
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Seller13")
        buyer  = await _make_user(db, "Buyer13")
        listing = await _make_listing(db, seller.id)
        now = datetime.utcnow()
        deal = await _make_deal(
            db, listing.id, seller.id, buyer.id,
            now - timedelta(days=LEAK_WINDOW_DAYS + SILENCE_WINDOW_DAYS),
        )
        # last message right as the leak window closed - genuinely silent
        # for the full SILENCE_WINDOW_DAYS since
        await _make_message(
            db, listing.id, buyer.id, buyer.id,
            now - timedelta(days=SILENCE_WINDOW_DAYS),
        )
        await db.commit()

        await flag_leaked_deals(db)
        await db.refresh(deal)
        assert deal.leak_flag is True
        assert deal.leak_detected_at is not None


# ── Cross-deal contamination (the audit's second finding) ──────────────────

@pytest.mark.asyncio
async def test_earlier_deal_evidence_does_not_contaminate_later_deal():
    """
    Deal A (same buyer+listing) had an off-platform-solicitation flag fire
    and then completed successfully. Deal B, negotiated later, sits silent
    long enough to be a leak candidate on its own timing, but has NO
    solicitation evidence of its own and no silence signal within ITS OWN
    window. Old code's evidence queries had no time bound, so Deal A's
    old flag could count as evidence for Deal B. Must not.
    """
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "SellerX")
        buyer  = await _make_user(db, "BuyerX")
        listing = await _make_listing(db, seller.id)
        now = datetime.utcnow()

        # Deal A: far in the past, completed (not a leak candidate itself -
        # status is paid, not agreed) - but its thread has a solicitation
        # flag on record.
        deal_a_time = now - timedelta(days=60)
        deal_a = await _make_deal(db, listing.id, seller.id, buyer.id, deal_a_time)
        deal_a.status = DealStatus.paid
        msg_a = await _make_message(db, listing.id, buyer.id, seller.id,
                                      deal_a_time + timedelta(hours=1))
        db.add(AuditLog(
            actor_id=seller.id, action="off_platform_solicitation_detected",
            resource_type="negotiation_message", resource_id=msg_a.id,
            created_at=deal_a_time + timedelta(hours=1),
        ))

        # Deal B: negotiated much later, old enough to be a leak candidate,
        # but with a message AFTER its own leak window closed (genuinely
        # recent activity, not silence) and no solicitation flag of its own.
        deal_b_time = now - timedelta(days=LEAK_WINDOW_DAYS + SILENCE_WINDOW_DAYS)
        deal_b = await _make_deal(db, listing.id, seller.id, buyer.id, deal_b_time)
        window_b_close = deal_b_time + timedelta(days=LEAK_WINDOW_DAYS)
        await _make_message(db, listing.id, buyer.id, buyer.id,
                              window_b_close + timedelta(days=1))  # after B's own window closed
        await db.commit()

        await flag_leaked_deals(db)
        await db.refresh(deal_b)
        assert deal_b.leak_flag is False, (
            "Deal A's old solicitation flag contaminated Deal B's evaluation - "
            "evidence queries must be scoped to messages at/after the deal "
            "being evaluated, not just matched by listing_id+buyer_id"
        )
