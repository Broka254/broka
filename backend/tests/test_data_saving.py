"""Data-saving pass: what the app no longer has to download.

  * GET /negotiate/inbox/{id} carries a weak ETag and answers 304 to a
    matching If-None-Match - the app's 7-second poll stops re-downloading an
    unchanged inbox. The tag ignores the clock-driven texts ("12s ago",
    "Active 5m ago"), or it would never match; it changes with a message,
    an unread count or a row's order. A client that sends nothing gets the
    list exactly as before.
  * GET /listings/seller/{id}/summary counts the Seller Dashboard's totals
    on the server, over the same listings GET /listings/?seller_id= returns,
    so the dashboard need not download every listing to add them up. Own
    figures only.
  * JSON is gzipped for clients that ask; images under /media/ are not.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.database import (
    AsyncSessionLocal, Listing, ListingStatus, NegotiationMessage, User, init_db, reset_engine,
)
from api.routers.negotiate import inbox_etag
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_data_saving.db"
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


async def _user(name: str) -> str:
    async with AsyncSessionLocal() as db:
        u = User(name=name, phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(u)
        await db.commit()
        return u.id


async def _thread() -> tuple[str, str, str]:
    seller = await _user("Sam Seller")
    buyer = await _user("Bea Buyer")
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller, name="Phone", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        db.add(NegotiationMessage(listing_id=listing.id, sender_id=buyer, role="buyer",
                                  content="hi", buyer_id=buyer, via_ai=False,
                                  created_at=datetime.utcnow() - timedelta(minutes=10)))
        await db.commit()
        return listing.id, seller, buyer


async def _message(listing_id: str, sender: str, buyer: str, role: str, text: str) -> None:
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(listing_id=listing_id, sender_id=sender, role=role,
                                  content=text, buyer_id=buyer, via_ai=False))
        await db.commit()


# ── Inbox ETag ───────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_an_unchanged_inbox_is_a_304_and_a_new_message_is_not(client):
    listing_id, seller, buyer = await _thread()
    first = await client.get(f"/negotiate/inbox/{seller}", headers=_auth(seller))
    assert first.status_code == 200
    etag = first.headers["etag"]
    assert etag.startswith('W/"')
    assert any(t["listing_id"] == listing_id for t in first.json())

    again = await client.get(f"/negotiate/inbox/{seller}",
                             headers={**_auth(seller), "If-None-Match": etag})
    assert again.status_code == 304
    assert again.content == b""
    assert again.headers["etag"] == etag

    await _message(listing_id, buyer, buyer, "buyer", "still available?")
    changed = await client.get(f"/negotiate/inbox/{seller}",
                               headers={**_auth(seller), "If-None-Match": etag})
    assert changed.status_code == 200
    assert changed.headers["etag"] != etag
    row = next(t for t in changed.json() if t["listing_id"] == listing_id)
    assert row["unread"] == 2


@pytest.mark.asyncio
async def test_without_if_none_match_the_inbox_is_sent_in_full_as_before(client):
    _, seller, _ = await _thread()
    r = await client.get(f"/negotiate/inbox/{seller}", headers=_auth(seller))
    assert r.status_code == 200
    assert isinstance(r.json(), list) and r.json()


@pytest.mark.asyncio
async def test_a_stale_tag_gets_the_full_inbox(client):
    _, seller, _ = await _thread()
    r = await client.get(f"/negotiate/inbox/{seller}",
                         headers={**_auth(seller), "If-None-Match": 'W/"not-the-tag"'})
    assert r.status_code == 200
    assert r.json()


def test_the_tag_ignores_the_clock_but_not_the_data():
    row = {"listing_id": "l1", "unread": 1, "last_message_id": "m1",
           "time_ago": "12s ago", "is_online": True, "last_seen": "Active now"}
    later = {**row, "time_ago": "3m ago", "is_online": False, "last_seen": "Active 3m ago"}
    assert inbox_etag([row]) == inbox_etag([later])
    assert inbox_etag([row]) != inbox_etag([{**row, "unread": 2}])
    assert inbox_etag([row]) != inbox_etag([{**row, "last_message_id": "m2"}])
    other = {**row, "listing_id": "l2"}
    assert inbox_etag([row, other]) != inbox_etag([other, row])


# ── Seller summary ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_the_summary_counts_what_the_seller_listing_feed_shows(client):
    seller = await _user("Grace")
    async with AsyncSessionLocal() as db:
        for i, (views, featured) in enumerate([(4, False), (10, True), (1, False)]):
            db.add(Listing(seller_id=seller, name=f"Item {i}", category="Electronics",
                           price=1000 + i, lat=-1.28, lng=36.82, views=views,
                           is_featured=featured))
        # Not in the seller's live feed, so not in the totals either.
        db.add(Listing(seller_id=seller, name="Sold", category="Electronics",
                       price=500, lat=-1.28, lng=36.82, views=99,
                       status=ListingStatus.completed))
        await db.commit()

    r = await client.get(f"/listings/seller/{seller}/summary", headers=_auth(seller))
    assert r.status_code == 200, r.text
    feed = (await client.get("/listings/", params={"seller_id": seller, "limit": 200})).json()
    assert r.json() == {
        "total_listings": len(feed),
        "active_listings": len(feed),
        "featured_listings": sum(1 for l in feed if l["is_featured"]),
        "total_views": sum(l["views"] for l in feed),
    }
    assert r.json()["total_listings"] == 3
    assert r.json()["total_views"] == 15


@pytest.mark.asyncio
async def test_a_seller_summary_is_its_owner_s_alone(client):
    seller = await _user("Grace")
    rival = await _user("Rival")
    r = await client.get(f"/listings/seller/{seller}/summary", headers=_auth(rival))
    assert r.status_code == 403
    r = await client.get(f"/listings/seller/{seller}/summary")
    assert r.status_code in (401, 403)


# ── Compression ──────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_json_is_gzipped_for_clients_that_ask(client):
    seller = await _user("Gzip Seller")
    async with AsyncSessionLocal() as db:
        for i in range(30):
            db.add(Listing(seller_id=seller, name=f"Gzip item {i}", category="Electronics",
                           price=1000 + i, lat=-1.28, lng=36.82,
                           description="A well kept item, works perfectly. " * 3))
        await db.commit()
    r = await client.get("/listings/", params={"seller_id": seller, "limit": 50},
                         headers={"Accept-Encoding": "gzip"})
    assert r.status_code == 200
    assert r.headers.get("content-encoding") == "gzip"
    assert len(r.json()) == 30

    plain = await client.get("/listings/", params={"seller_id": seller, "limit": 50},
                             headers={"Accept-Encoding": "identity"})
    assert plain.headers.get("content-encoding") is None
    assert plain.json() == r.json()


def test_images_are_not_gzipped():
    from api.core.compression import _UNCOMPRESSED_PREFIXES
    assert any("/media/i/img/x/thumb.webp".startswith(p) for p in _UNCOMPRESSED_PREFIXES)
    assert any("/admin/alerts/stream".startswith(p) for p in _UNCOMPRESSED_PREFIXES)
