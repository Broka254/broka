"""No database connection is held while Zeno waits on a model.

POST /negotiate/message reads the thread, stores the user's message and asks
a model - several times: the delivery-date extractor, the relay classifier,
the two reply drafts, the action classifier. Every one of those waits (up to
a minute and more through the provider fallbacks) was made inside an open
transaction, so each Zeno message in flight held one of the process's five
pooled connections idle for its whole length. These hold the endpoint to:

  * no transaction open on the request's session during any model call, in
    every intent that calls one;
  * the user's message stored before any model is asked, and kept when the
    model fails; a retry with the same client id neither stores it twice
    nor loses Zeno's reply;
  * the availability check arming the seller's reminder only with the
    replies it relays - never for a relay whose generation failed;
  * several slow replies at once not starving a small pool: direct
    messages, inbox polls and call polls all answered meanwhile.
"""
import asyncio
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import sessionmaker

from api import database
from api.database import (
    AsyncSessionLocal, Deal, DealStatus, Interest, Listing, NegotiationMessage, User,
    init_db, reset_engine,
)
from api.security import create_access_token
from main import app

NO_RELAY = {"needs_relay": False, "relay_summary": "", "is_availability_confirmation": False}
RELAY = {"needs_relay": True, "relay_summary": "The buyer asks whether it is still available.",
         "is_availability_confirmation": False}


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_ai_connection_release.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


async def _people(*, paid_deal: bool = False):
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().int % 10**8:08d}",
                      password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().int % 10**8:08d}",
                     password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Phone", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        deal_id = None
        if paid_deal:
            deal = Deal(listing_id=listing.id, buyer_id=buyer.id, seller_id=seller.id,
                        agreed_price=25000, commission=750, status=DealStatus.paid)
            db.add(deal)
            await db.flush()
            deal_id = deal.id
        await db.commit()
        return listing.id, seller.id, buyer.id, deal_id


def _request_sessions(monkeypatch) -> list:
    """The sessions handed to requests (get_db), as they are handed. Only
    the requests': pushes run on short sessions of their own."""
    from api.database import get_db
    handed = []

    async def recording_get_db():
        async with AsyncSessionLocal() as session:
            handed.append(session)
            yield session

    monkeypatch.setitem(app.dependency_overrides, get_db, recording_get_db)
    return handed


class _Spy:
    """Stand-ins for the model calls that note, at each one, whether any
    request session was mid-transaction - holding its connection."""

    def __init__(self, handed, *, reply="Happy to help.", relay=NO_RELAY, fail=False,
                 delay=0.0, action="NONE", delivery=None):
        self.handed, self.reply, self.relay = handed, reply, relay
        self.fail, self.delay, self.action, self.delivery = fail, delay, action, delivery
        self.held: list[tuple[str, list[bool]]] = []

    def _note(self, what):
        self.held.append((what, [s.in_transaction() for s in self.handed]))

    async def call_ai(self, system, messages, *args, **kwargs):
        self._note("call_ai")
        if self.delay:
            await asyncio.sleep(self.delay)
        if self.fail:
            raise HTTPException(status_code=502, detail="all providers failed")
        return self.reply

    async def classify_relay(self, *args, **kwargs):
        self._note("classify_relay")
        return dict(self.relay)

    async def extract_delivery_date(self, text):
        self._note("extract_delivery_date")
        return self.delivery

    async def classify_action(self, *args, **kwargs):
        self._note("classify_zeno_action")
        return self.action

    def install(self, monkeypatch):
        import api.routers.negotiate as negotiate
        monkeypatch.setattr(negotiate, "_call_ai", self.call_ai)
        monkeypatch.setattr(negotiate, "_classify_relay", self.classify_relay)
        monkeypatch.setattr(negotiate, "_extract_delivery_date", self.extract_delivery_date)
        monkeypatch.setattr(negotiate, "_classify_zeno_action", self.classify_action)
        return self

    def assert_nothing_held(self):
        assert self.held, "no model call was made"
        held = [(what, states) for what, states in self.held if any(states)]
        assert not held, f"a transaction was open during: {held}"


async def _count(model, **where):
    async with AsyncSessionLocal() as db:
        q = select(func.count()).select_from(model)
        for column, value in where.items():
            q = q.where(getattr(model, column) == value)
        return (await db.execute(q)).scalar()


@pytest.mark.asyncio
async def test_no_transaction_is_held_through_any_model_call_of_a_message(client, monkeypatch):
    listing_id, seller, buyer, deal_id = await _people(paid_deal=True)
    handed = _request_sessions(monkeypatch)
    arrives = datetime.utcnow().replace(microsecond=0) + timedelta(days=3)
    spy = _Spy(handed, relay=RELAY, delivery=arrives).install(monkeypatch)

    # Short, and no action phrase: the action classifier is asked too.
    r = await client.post("/negotiate/message", headers=_auth(buyer), json={
        "listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
        "content": "It arrives on Friday, is that fine?", "client_msg_id": "m-1"})
    assert r.status_code == 200, r.text
    assert [what for what, _ in spy.held] == [
        "extract_delivery_date", "classify_relay", "call_ai", "call_ai", "classify_zeno_action"]
    spy.assert_nothing_held()

    # Everything the request decided was stored: the message once, Zeno's
    # reply to the buyer and its relay to the seller, and the date.
    assert await _count(NegotiationMessage, listing_id=listing_id, role="buyer") == 1
    assert await _count(NegotiationMessage, listing_id=listing_id, role="broker") == 2
    async with AsyncSessionLocal() as db:
        deal = await db.get(Deal, deal_id)
        assert deal.expected_delivery_date == arrives


@pytest.mark.asyncio
async def test_the_message_is_kept_when_every_model_fails_and_a_retry_completes_it(
        client, monkeypatch):
    listing_id, seller, buyer, _ = await _people()
    handed = _request_sessions(monkeypatch)
    body = {"listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
            "content": "Can you do 20,000 if I pick it up today in the evening please?",
            "client_msg_id": "retry-me"}
    failing = _Spy(handed, fail=True).install(monkeypatch)
    r = await client.post("/negotiate/message", headers=_auth(buyer), json=body)
    assert r.status_code == 502
    failing.assert_nothing_held()
    # What the buyer typed is stored, and the seller's reminder armed with
    # it; nothing Zeno would have said is.
    assert await _count(NegotiationMessage, listing_id=listing_id, role="buyer") == 1
    assert await _count(NegotiationMessage, listing_id=listing_id, role="broker") == 0
    assert await _count(Interest, listing_id=listing_id, buyer_id=buyer) == 1

    _Spy(handed, reply="Let me ask.").install(monkeypatch)
    again = await client.post("/negotiate/message", headers=_auth(buyer), json=body)
    assert again.status_code == 200, again.text
    assert again.json()["content"] == "Let me ask."
    assert await _count(NegotiationMessage, listing_id=listing_id, role="buyer") == 1
    assert await _count(NegotiationMessage, listing_id=listing_id, role="broker") == 1


@pytest.mark.asyncio
async def test_the_availability_check_arms_the_reminder_only_with_its_replies(client, monkeypatch):
    listing_id, seller, buyer, _ = await _people()
    handed = _request_sessions(monkeypatch)
    body = {"listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
            "content": "", "intent": "ask_seller_availability"}

    failing = _Spy(handed, fail=True).install(monkeypatch)
    r = await client.post("/negotiate/message", headers=_auth(buyer), json=body)
    assert r.status_code == 502
    failing.assert_nothing_held()
    assert await _count(Interest, listing_id=listing_id, buyer_id=buyer) == 0, (
        "no relay was sent, so no seller is reminded about it")
    assert await _count(NegotiationMessage, listing_id=listing_id) == 0

    working = _Spy(handed, reply="Asked them for you.").install(monkeypatch)
    r = await client.post("/negotiate/message", headers=_auth(buyer), json=body)
    assert r.status_code == 200, r.text
    working.assert_nothing_held()
    assert await _count(Interest, listing_id=listing_id, buyer_id=buyer) == 1
    assert await _count(NegotiationMessage, listing_id=listing_id, role="broker") == 2


@pytest.mark.asyncio
@pytest.mark.parametrize("intent", ["opening_greeting", "translate_for_me"])
async def test_greetings_and_translations_hold_nothing_through_the_model(
        client, monkeypatch, intent):
    listing_id, seller, buyer, _ = await _people()
    handed = _request_sessions(monkeypatch)
    spy = _Spy(handed, reply="Karibu!").install(monkeypatch)
    r = await client.post("/negotiate/message", headers=_auth(buyer), json={
        "listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
        "content": "Habari, bado iko?", "intent": intent})
    assert r.status_code == 200, r.text
    spy.assert_nothing_held()
    # Neither tells the seller anything, so neither arms a reminder.
    assert await _count(Interest, listing_id=listing_id, buyer_id=buyer) == 0


@pytest.mark.asyncio
async def test_slow_replies_do_not_starve_a_small_pool(client, monkeypatch):
    """A pool of ONE connection, three Zeno replies each waiting 1.2 s on a
    model, and everything else at the same time: direct messages, inbox
    polls and incoming-call polls. Held through the model, the first reply
    kept the only connection and the rest queued past the pool timeout
    (1 s) into 503s."""
    if database.engine.dialect.name != "sqlite":
        pytest.skip("a dedicated pooled engine is built on the module's SQLite file")
    listing_id, seller, buyer, _ = await _people()
    buyers = [buyer]
    async with AsyncSessionLocal() as db:
        for i in range(2):
            u = User(name=f"Other Buyer {i}", phone=f"+2547{uuid.uuid4().int % 10**8:08d}",
                     password_hash="x")
            db.add(u)
            await db.flush()
            buyers.append(u.id)
        await db.commit()

    small = create_async_engine(database.DATABASE_URL, pool_size=1, max_overflow=0,
                                pool_timeout=1.0, connect_args={"check_same_thread": False})
    monkeypatch.setattr(database, "_session_factory",
                        sessionmaker(small, class_=AsyncSession, expire_on_commit=False))
    _Spy([], reply="Checking with the seller.", delay=1.2).install(monkeypatch)
    try:
        async def zeno(uid, n):
            return await client.post("/negotiate/message", headers=_auth(uid), json={
                "listing_id": listing_id, "sender_role": "buyer", "sender_id": uid,
                "content": f"Would you take a lower offer for this one, number {n}, please?"})

        async def direct(n):
            return await client.post("/negotiate/direct-message", headers=_auth(buyers[1]), json={
                "listing_id": listing_id, "sender_role": "buyer", "sender_id": buyers[1],
                "content": f"Still there? ({n})"})

        requests = [zeno(uid, n) for n, uid in enumerate(buyers)]
        requests += [direct(n) for n in range(4)]
        requests += [client.get(f"/negotiate/inbox/{seller}", headers=_auth(seller))
                     for _ in range(4)]
        requests += [client.get("/calls/incoming", headers=_auth(seller)) for _ in range(4)]
        answers = await asyncio.gather(*requests)
    finally:
        await small.dispose()
    statuses = [r.status_code for r in answers]
    assert set(statuses) <= {200, 304}, statuses
    assert await _count(NegotiationMessage, listing_id=listing_id, role="broker") == 3
    assert await _count(NegotiationMessage, listing_id=listing_id, role="buyer", via_ai=False) == 4
