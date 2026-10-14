"""Likes, apart from saves (2026-10-09).

A buyer could only save a listing (the heart, which kept it in their Saved
items), and nothing counted a like. Now a like and a save are two things,
both counted for the seller:
  * POST/DELETE /listings/{id}/like, idempotent; not on one's own listing;
  * GET /listings/{id}/engagement: the caller's own liked/saved, and for
    the seller only, how many people liked and saved it;
  * the listing's metrics carry like_count beside the saves.
Neither count is shown to other buyers - which products are moving is what
a rival would price against.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.database import AsyncSessionLocal, Listing, User, init_db, reset_engine
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_listing_likes.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module")
async def client():
    await init_db()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


async def _setup():
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyers = [User(name=f"Buyer {i}", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
                  for i in range(2)]
        db.add_all([seller, *buyers])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Casio watch", category="Fashion",
                          price=1500, lat=-1.1, lng=37.0, views=10,
                          description="Casio G-Shock, two years old, works perfectly.",
                          created_at=datetime.utcnow() - timedelta(days=3))
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, [b.id for b in buyers]


@pytest.mark.asyncio
async def test_a_buyer_likes_and_unlikes(client):
    listing_id, seller, (buyer, _) = await _setup()
    r = await client.post(f"/listings/{listing_id}/like", headers=_auth(buyer))
    assert r.status_code == 200, r.text
    assert r.json() == {"liked": True}
    # Idempotent: a second tap is still one like.
    assert (await client.post(f"/listings/{listing_id}/like", headers=_auth(buyer))).status_code == 200
    assert (await client.get(f"/listings/{listing_id}/engagement", headers=_auth(buyer))).json() == {
        "liked": True, "saved": False}

    r = await client.delete(f"/listings/{listing_id}/like", headers=_auth(buyer))
    assert r.json() == {"liked": False}
    assert (await client.get(f"/listings/{listing_id}/engagement", headers=_auth(buyer))).json() == {
        "liked": False, "saved": False}


@pytest.mark.asyncio
async def test_a_like_is_not_a_save(client):
    listing_id, _, (buyer, _) = await _setup()
    await client.post(f"/listings/{listing_id}/like", headers=_auth(buyer))
    # Liked, not kept: Saved items stays empty.
    assert (await client.get("/listings/saved", headers=_auth(buyer))).json() == []
    await client.post(f"/listings/{listing_id}/save", headers=_auth(buyer))
    assert (await client.get(f"/listings/{listing_id}/engagement", headers=_auth(buyer))).json() == {
        "liked": True, "saved": True}


@pytest.mark.asyncio
async def test_the_seller_sees_the_counts_and_nobody_else_does(client):
    listing_id, seller, (b1, b2) = await _setup()
    await client.post(f"/listings/{listing_id}/like", headers=_auth(b1))
    await client.post(f"/listings/{listing_id}/like", headers=_auth(b2))
    await client.post(f"/listings/{listing_id}/save", headers=_auth(b2))

    mine = (await client.get(f"/listings/{listing_id}/engagement", headers=_auth(seller))).json()
    assert mine["likes"] == 2 and mine["saves"] == 1
    theirs = (await client.get(f"/listings/{listing_id}/engagement", headers=_auth(b1))).json()
    assert "likes" not in theirs and "saves" not in theirs

    m = (await client.get(f"/listings/{listing_id}/metrics", headers=_auth(seller))).json()
    assert m["current"]["like_count"] == 2
    assert m["current"]["saves"] == 1
    # Older builds read saves as "likes", and still get saves.
    assert m["current"]["likes"] == 1


@pytest.mark.asyncio
async def test_a_seller_cannot_like_their_own(client):
    listing_id, seller, _ = await _setup()
    r = await client.post(f"/listings/{listing_id}/like", headers=_auth(seller))
    assert r.status_code == 400


@pytest.mark.asyncio
async def test_no_like_without_an_account(client):
    listing_id, _, _ = await _setup()
    assert (await client.post(f"/listings/{listing_id}/like")).status_code in (401, 403)


@pytest.mark.asyncio
async def test_a_listing_that_isnt_there_cant_be_liked(client):
    _, _, (buyer, _) = await _setup()
    r = await client.post(f"/listings/{uuid.uuid4()}/like", headers=_auth(buyer))
    assert r.status_code == 404
