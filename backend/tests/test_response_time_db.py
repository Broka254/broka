"""Response time against the real message table (trust/response_time.py).

The walk itself is tested on fixtures in test_response_time.py; what is
under test here is the part SQL decides - which rows count as the buyer
asking the seller something, and conversations that began before the
window - since 2026-11-12, when the measure became the first message of a
conversation rather than every message in it.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio

from api.database import AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine
from api.domains.trust.response_time import WINDOW_DAYS, compute_all_response_times


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_response_time_db.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


async def _seller_listings(n: int) -> tuple[str, list[str]]:
    async with AsyncSessionLocal() as db:
        seller = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(seller)
        await db.flush()
        listings = [Listing(seller_id=seller.id, name=f"Phone {i}", category="Electronics",
                            price=1000.0, lat=-1.29, lng=36.82) for i in range(n)]
        db.add_all(listings)
        await db.commit()
        return seller.id, [l.id for l in listings]


def _msg(listing_id: str, buyer_id: str, role: str, minutes_ago: float, *,
         recipient=None, via_ai=False, msg_type="text") -> NegotiationMessage:
    sender = buyer_id if role == "buyer" else ("broker" if role == "broker" else "seller")
    return NegotiationMessage(
        listing_id=listing_id, buyer_id=buyer_id, sender_id=sender, role=role,
        recipient_role=recipient, via_ai=via_ai, msg_type=msg_type, content="x",
        created_at=datetime.utcnow() - timedelta(minutes=minutes_ago))


async def _measure(seller_id: str):
    async with AsyncSessionLocal() as db:
        return (await compute_all_response_times(db)).get(seller_id)


@pytest.mark.asyncio
async def test_a_buyers_private_words_to_zeno_start_no_clock_zenos_relay_does():
    """In Zeno's room the buyer talks to Zeno (via_ai, which the seller never
    sees) and Zeno relays to the seller. The clock starts when the relay
    lands: the buyer's private message used to start it - and a question
    the buyer only ever asked Zeno started a clock the seller never saw."""
    seller_id, listings = await _seller_listings(3)
    async with AsyncSessionLocal() as db:
        for i, listing_id in enumerate(listings):
            buyer = f"buyer-private-{i}"
            db.add_all([
                _msg(listing_id, buyer, "buyer", 60, via_ai=True),
                _msg(listing_id, buyer, "broker", 30, recipient="seller"),
                _msg(listing_id, buyer, "broker", 30, recipient="buyer"),
                # The seller answers through Zeno: their words are via_ai too.
                _msg(listing_id, buyer, "seller", 20, via_ai=True),
            ])
        await db.commit()
    assert await _measure(seller_id) == pytest.approx(10.0, abs=0.2)


@pytest.mark.asyncio
async def test_a_conversation_that_began_before_the_window_is_left_out():
    """Its first in-window message is the middle of a conversation - a
    "thanks" weeks after the answer - and used to be charged as an
    unanswered first message: 48 hours against a seller who replied in
    five minutes."""
    seller_id, listings = await _seller_listings(4)
    days = 24 * 60
    async with AsyncSessionLocal() as db:
        for i, listing_id in enumerate(listings[:3]):
            buyer = f"buyer-recent-{i}"
            db.add_all([_msg(listing_id, buyer, "buyer", 100, recipient="seller"),
                        _msg(listing_id, buyer, "seller", 95, recipient="buyer")])
        old = listings[3]
        db.add_all([
            _msg(old, "buyer-old", "buyer", (WINDOW_DAYS + 10) * days, recipient="seller"),
            _msg(old, "buyer-old", "seller", (WINDOW_DAYS + 10) * days - 5, recipient="buyer"),
            _msg(old, "buyer-old", "buyer", 10 * days, recipient="seller"),
        ])
        await db.commit()
    assert await _measure(seller_id) == pytest.approx(5.0, abs=0.2)


@pytest.mark.asyncio
async def test_a_buyers_call_card_starts_no_clock():
    """An answered call is a reply nobody types; timing from the call card
    charged the seller who picked up as if they had ignored it."""
    seller_id, listings = await _seller_listings(3)
    async with AsyncSessionLocal() as db:
        for i, listing_id in enumerate(listings):
            buyer = f"buyer-call-{i}"
            db.add_all([
                _msg(listing_id, buyer, "buyer", 100, msg_type="call"),
                _msg(listing_id, buyer, "buyer", 50, recipient="seller"),
                _msg(listing_id, buyer, "seller", 45, recipient="buyer"),
            ])
        await db.commit()
    assert await _measure(seller_id) == pytest.approx(5.0, abs=0.2)


@pytest.mark.asyncio
async def test_a_message_the_buyer_deleted_is_not_the_first_ask():
    seller_id, listings = await _seller_listings(3)
    async with AsyncSessionLocal() as db:
        for i, listing_id in enumerate(listings):
            buyer = f"buyer-deleted-{i}"
            gone = _msg(listing_id, buyer, "buyer", 100, recipient="seller")
            gone.deleted_at = datetime.utcnow() - timedelta(minutes=99)
            db.add_all([gone,
                        _msg(listing_id, buyer, "buyer", 50, recipient="seller"),
                        _msg(listing_id, buyer, "seller", 45, recipient="buyer")])
        await db.commit()
    assert await _measure(seller_id) == pytest.approx(5.0, abs=0.2)
