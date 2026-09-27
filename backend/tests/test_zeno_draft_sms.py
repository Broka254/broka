"""Zeno texting the other side of a negotiation (POST /negotiate/zeno-action/draft-sms).

What must hold: only the two people in a conversation about a listing can
have Zeno text each other. A text lands on a real phone and can't be
recalled, and the draft names the recipient and says whether they have a
number - so a caller with no conversation on the listing gets neither.

It used to take anyone who wasn't the seller for "the buyer": any signed-in
user could have Zeno text any seller on BROKA about any listing, with only
the five-an-hour limit in the way. A seller could name any user as the
buyer and text them too.
"""
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine
from api.security import create_access_token

URL = "/negotiate/zeno-action/draft-sms"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_zeno_draft_sms.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


@pytest.fixture
def sms():
    send = AsyncMock(return_value=True)
    with patch("api.core.sms.get_sms_provider", return_value=SimpleNamespace(send=send)):
        yield send


async def _user(name: str) -> tuple[User, dict]:
    u = User(name=name, phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(seller: User) -> str:
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller.id, name="Sofa", category="Home & Furniture",
                          price=18000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id


async def _message(listing_id: str, buyer: User) -> None:
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(listing_id=listing_id, sender_id=buyer.id, role="buyer",
                                  recipient_role="seller", buyer_id=buyer.id, content="Is it available?"))
        await db.commit()


@pytest.mark.asyncio
async def test_a_buyer_in_the_conversation_can_text_the_seller(client, sms):
    seller, _ = await _user("Wanjiru Seller")
    buyer, h = await _user("Otieno Buyer")
    listing_id = await _listing(seller)
    await _message(listing_id, buyer)
    sent = await client.post(URL, headers=h, json={"listing_id": listing_id, "text": "Still there?", "send": True})
    assert sent.status_code == 200, sent.text
    sms.assert_called_once()
    assert sms.call_args.args[0] == seller.phone


@pytest.mark.asyncio
async def test_a_stranger_cannot_text_the_seller_or_see_the_draft(client, sms):
    seller, _ = await _user("Wanjiru Seller")
    _, stranger = await _user("Nobody")
    listing_id = await _listing(seller)
    sent = await client.post(URL, headers=stranger, json={"listing_id": listing_id, "text": "Hi", "send": True})
    assert sent.status_code == 403
    sms.assert_not_called()
    drafted = await client.post(URL, headers=stranger, json={"listing_id": listing_id})
    assert drafted.status_code == 403, "the draft names the seller and says whether they have a phone"


@pytest.mark.asyncio
async def test_a_seller_can_text_only_a_buyer_in_one_of_their_conversations(client, sms):
    seller, h = await _user("Wanjiru Seller")
    buyer, _ = await _user("Otieno Buyer")
    someone, _ = await _user("Someone Else")
    listing_id = await _listing(seller)
    await _message(listing_id, buyer)

    refused = await client.post(URL, headers=h, json={
        "listing_id": listing_id, "buyer_id": someone.id, "text": "Hi", "send": True})
    assert refused.status_code == 403
    sms.assert_not_called()

    sent = await client.post(URL, headers=h, json={
        "listing_id": listing_id, "buyer_id": buyer.id, "text": "Still keen?", "send": True})
    assert sent.status_code == 200, sent.text
    assert sms.call_args.args[0] == buyer.phone


@pytest.mark.asyncio
async def test_a_conversation_on_another_listing_does_not_count(client, sms):
    seller, _ = await _user("Wanjiru Seller")
    buyer, h = await _user("Otieno Buyer")
    talked_about = await _listing(seller)
    other = await _listing(seller)
    await _message(talked_about, buyer)
    sent = await client.post(URL, headers=h, json={"listing_id": other, "text": "Hi", "send": True})
    assert sent.status_code == 403
    sms.assert_not_called()
