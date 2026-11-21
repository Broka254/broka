"""Phase Two: listing rankings, trending and per-listing performance.

The claims worth testing are the honesty ones: duplicates must not inflate a
ranking, a window must exclude what happened outside it, growth must compare
with an equal-length window, and a listing with no history must say so rather
than draw a flat line at zero.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.database import (
    AccountType,
    AsyncSessionLocal,
    Interest,
    Listing,
    ListingLike,
    ListingView,
    NegotiationMessage,
    User,
    Wishlist,
    init_db,
    reset_engine,
)
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / f"test_listing_intel_{uuid.uuid4().hex}.db"
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


def _h(user_id: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user_id})}"}


async def _user(*, admin: bool = False, name: str | None = None) -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(
        name=name or f"User {tag}",
        phone=f"+2547{tag[:8]}",
        email=f"{tag}@listings.test",
        password_hash="x",
        is_admin=admin,
        account_type=AccountType.buyer,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


async def _listing(seller: User, name: str) -> Listing:
    listing = Listing(
        seller_id=seller.id,
        name=name,
        description=f"{name} description",
        category="Electronics",
        price=1000.0,
        lat=-1.28,
        lng=36.82,
        views=0,
    )
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    return listing


async def _seed():
    """A, B, C with distinct engagement shapes; D has views but no interest."""
    seller = await _user(name="Seller")
    a = await _listing(seller, "Listing A")
    b = await _listing(seller, "Listing B")
    c = await _listing(seller, "Listing C")
    d = await _listing(seller, "Listing D")

    viewers = [await _user(name=f"Viewer {index}") for index in range(25)]
    buyers = [await _user(name=f"Buyer {index}") for index in range(6)]
    now = datetime.utcnow()

    async with AsyncSessionLocal() as db:
        # A: 5 unique viewers, 2 negotiation threads.
        for viewer in viewers[:5]:
            db.add(ListingView(listing_id=a.id, viewer_id=viewer.id, created_at=now - timedelta(days=1)))
        for buyer in buyers[:2]:
            db.add(
                NegotiationMessage(
                    listing_id=a.id, sender_id=buyer.id, role="buyer", buyer_id=buyer.id,
                    content="Is this available?", created_at=now - timedelta(days=1),
                )
            )
        # B: 2 viewers, 2 savers.
        for viewer in viewers[5:7]:
            db.add(ListingView(listing_id=b.id, viewer_id=viewer.id, created_at=now - timedelta(days=2)))
        for viewer in viewers[7:9]:
            db.add(Wishlist(user_id=viewer.id, listing_id=b.id, created_at=now - timedelta(days=2)))
        # C: 3 viewers, 1 like, 3 interests - two of them by the SAME buyer.
        for viewer in viewers[9:12]:
            db.add(ListingView(listing_id=c.id, viewer_id=viewer.id, created_at=now - timedelta(days=3)))
        db.add(ListingLike(user_id=viewers[12].id, listing_id=c.id, created_at=now - timedelta(days=3)))
        db.add(Interest(listing_id=c.id, buyer_id=buyers[2].id, created_at=now - timedelta(days=3)))
        db.add(Interest(listing_id=c.id, buyer_id=buyers[2].id, created_at=now - timedelta(days=3, hours=1)))
        db.add(Interest(listing_id=c.id, buyer_id=buyers[3].id, created_at=now - timedelta(days=3)))
        # D: 20 viewers and nothing else - the "high views, no engagement" case.
        for viewer in viewers[:20]:
            db.add(ListingView(listing_id=d.id, viewer_id=viewer.id, created_at=now - timedelta(days=1)))
        # An old view outside any 7-day window.
        db.add(
            ListingView(
                listing_id=b.id, viewer_id=viewers[20].id,
                created_at=now - timedelta(days=40),
            )
        )
        await db.commit()

    return {"seller": seller, "a": a, "b": b, "c": c, "d": d, "buyers": buyers, "viewers": viewers}


async def test_rankings_order_by_the_chosen_signal_and_dedupe_actors(client):
    data = await _seed()
    admin = await _user(admin=True)
    now = datetime.utcnow()

    response = await client.get(
        "/admin/intelligence/listings",
        params={
            "from": (now - timedelta(days=7)).isoformat(),
            "to": now.isoformat(),
            "sort": "unique_viewers",
            "limit": 10,
        },
        headers=_h(admin.id),
    )
    assert response.status_code == 200, response.text
    body = response.json()

    by_id = {item["listing_id"]: item for item in body["items"]}
    assert by_id[data["a"].id]["unique_viewers"] == 5
    assert by_id[data["b"].id]["unique_viewers"] == 2  # the 40-day-old view is outside the window
    assert by_id[data["c"].id]["unique_viewers"] == 3
    assert by_id[data["a"].id]["negotiations"] == 2

    # Two interests by the same buyer are one contact, not two.
    assert by_id[data["c"].id]["contacts"] == 2
    assert by_id[data["c"].id]["likes"] == 1

    scores = [item["unique_viewers"] for item in body["items"]]
    assert scores == sorted(scores, reverse=True)

    # The model that produced the ordering is disclosed, not implied.
    assert body["model"]["weights"]["negotiations"] == 5.0
    assert "repeat views are not stored" in body["model"]["view_counting"]


async def test_an_empty_window_is_an_empty_answer_not_an_error(client):
    admin = await _user(admin=True)
    old = datetime.utcnow() - timedelta(days=365)
    response = await client.get(
        "/admin/intelligence/listings",
        params={
            "from": old.isoformat(),
            "to": (old + timedelta(hours=1)).isoformat(),
            "sort": "trending",
        },
        headers=_h(admin.id),
    )
    assert response.status_code == 200
    assert response.json()["items"] == []
    assert response.json()["considered"] == 0


async def test_trending_compares_with_the_previous_equal_window(client):
    seller = await _user(name="Growth Seller")
    growing = await _listing(seller, "Growing")
    flat = await _listing(seller, "Flat")
    viewers = [await _user(name=f"Growth Viewer {index}") for index in range(4)]
    now = datetime.utcnow()

    async with AsyncSessionLocal() as db:
        # Growing: two viewers now, none in the previous window.
        for viewer in viewers[:2]:
            db.add(ListingView(listing_id=growing.id, viewer_id=viewer.id, created_at=now - timedelta(days=1)))
        # Flat: two viewers in each window.
        for viewer in viewers[:2]:
            db.add(ListingView(listing_id=flat.id, viewer_id=viewer.id, created_at=now - timedelta(days=1)))
        for viewer in viewers[2:4]:
            db.add(ListingView(listing_id=flat.id, viewer_id=viewer.id, created_at=now - timedelta(days=9)))
        await db.commit()

    admin = await _user(admin=True)
    response = await client.get(
        "/admin/intelligence/listings",
        params={
            "from": (now - timedelta(days=7)).isoformat(),
            "to": now.isoformat(),
            "sort": "trending",
        },
        headers=_h(admin.id),
    )
    assert response.status_code == 200, response.text
    items = {item["listing_id"]: item for item in response.json()["items"]}
    assert items[growing.id]["growth"] == 1.0
    assert items[flat.id]["growth"] == 0.0
    assert items[growing.id]["trending_score"] > items[flat.id]["trending_score"]


async def test_insights_name_the_problem_and_its_evidence(client):
    data = await _seed()
    admin = await _user(admin=True)
    now = datetime.utcnow()
    response = await client.get(
        "/admin/intelligence/listings/insights",
        params={
            "from": (now - timedelta(days=7)).isoformat(),
            "to": now.isoformat(),
        },
        headers=_h(admin.id),
    )
    assert response.status_code == 200, response.text
    insights = response.json()["insights"]
    flagged = {item["listing_id"] for item in insights if item["code"] == "high_views_low_engagement"}
    assert data["d"].id in flagged
    for item in insights:
        assert item["detail"] and item["metrics"]


async def test_per_listing_detail_does_not_invent_history(client):
    data = await _seed()
    admin = await _user(admin=True)
    response = await client.get(
        f"/admin/intelligence/listings/{data['a'].id}",
        headers=_h(admin.id),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["listing"]["id"] == data["a"].id
    assert body["engagement"]["unique_viewers"] >= 5
    assert body["history"] == []
    assert "no per-day trend is shown" in body["history_note"].lower()


async def test_a_non_admin_cannot_read_listing_intelligence(client):
    member = await _user()
    response = await client.get(
        "/admin/intelligence/listings", headers=_h(member.id)
    )
    assert response.status_code == 403
