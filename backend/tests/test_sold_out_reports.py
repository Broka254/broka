"""
Sold out with payments outside BROKA: agreed deals no longer take a
listing off sale (listings/stock.py), buyers report an item gone and its
seller can revoke the report (listings/sold_out.py).
Run: pytest backend/tests/test_sold_out_reports.py -v
"""
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from main import app
from api.database import (
    AsyncSessionLocal, Deal, DealStatus, Listing, ListingStatus, User, init_db, reset_engine,
)
from api.domains.listings.stock import sync_listing_stock
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_sold_out_reports.db"
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


@pytest.fixture(autouse=True)
def no_push(monkeypatch):
    async def nothing(*a, **k):
        return 0
    monkeypatch.setattr("api.core.push_devices.push_user", nothing)


async def _user() -> tuple[str, dict]:
    u = User(name="Someone", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(client, headers) -> dict:
    r = await client.post("/listings/", headers=headers, json={
        "description": "Well kept, works perfectly - selling because I upgraded.",
        "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
        "price": 20000, "lat": -1.28, "lng": 36.82})
    assert r.status_code == 201, r.text
    return r.json()


async def _in_feed(client, listing_id) -> bool:
    items = (await client.get("/listings/", params={"limit": 100, "sort": "recent"})).json()
    return any(i["id"] == listing_id for i in items)


class TestAgreedDealsDoNotSellOut:
    @pytest.mark.asyncio
    async def test_an_agreed_deal_leaves_the_listing_on_sale(self, client, payments_off):
        # With payments off nothing is paid in the app, so an agreement
        # never released its unit: the listing went "Sold out" and stayed.
        seller_id, h = await _user()
        buyer_id, _ = await _user()
        listing = await _listing(client, h)
        async with AsyncSessionLocal() as db:
            db.add(Deal(listing_id=listing["id"], seller_id=seller_id, buyer_id=buyer_id,
                        agreed_price=19000, commission=0, status=DealStatus.agreed))
            row = await db.get(Listing, listing["id"])
            row.status = ListingStatus.pending      # what the old code left behind
            await db.commit()
        async with AsyncSessionLocal() as db:
            await sync_listing_stock(db)
        page = (await client.get(f"/listings/{listing['id']}")).json()
        assert page["status"] == "active" and page["sold_out"] is False
        assert await _in_feed(client, listing["id"])


class TestReporting:
    @pytest.mark.asyncio
    async def test_a_report_hides_it_and_the_seller_brings_it_back(self, client):
        _, seller = await _user()
        _, buyer = await _user()
        listing = await _listing(client, seller)
        r = await client.post(f"/listings/{listing['id']}/sold-out", headers=buyer)
        assert r.status_code == 200 and r.json()["reported_sold_out"] is True
        assert not await _in_feed(client, listing["id"])
        page = (await client.get(f"/listings/{listing['id']}")).json()
        assert page["sold_out"] is True and page["reported_sold_out"] is True

        # Only the seller can say it's still there.
        assert (await client.delete(f"/listings/{listing['id']}/sold-out", headers=buyer)).status_code == 404
        r = await client.delete(f"/listings/{listing['id']}/sold-out", headers=seller)
        assert r.status_code == 200 and r.json()["reported_sold_out"] is False
        assert await _in_feed(client, listing["id"])

        # The same buyer can't take it down again once the seller said no.
        again = await client.post(f"/listings/{listing['id']}/sold-out", headers=buyer)
        assert again.status_code == 409
        assert await _in_feed(client, listing["id"])

    @pytest.mark.asyncio
    async def test_a_seller_cannot_report_their_own(self, client):
        _, seller = await _user()
        listing = await _listing(client, seller)
        assert (await client.post(f"/listings/{listing['id']}/sold-out", headers=seller)).status_code == 400


# ── Telling the seller (2026-11-12) ──────────────────────────────────────────
#
# One buyer's report took the listing out of every list - the seller's own
# dashboard too, which reads the same lists - and the only word of it was a
# push whose tap opened nothing. A seller whose item was still for sale had
# no way to find it again. Now they are texted and pushed, and the
# dashboard lists it with "Still available".

class _FakeSMS:
    def __init__(self, ok=True):
        self.ok, self.sent = ok, []

    async def send(self, phone, message):
        self.sent.append((phone, message))
        return self.ok


@pytest.fixture
def sms(monkeypatch):
    fake = _FakeSMS()
    monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: fake)
    return fake


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    async def record(user_id, **kwargs):
        sent.append((user_id, kwargs))
        return 1
    monkeypatch.setattr("api.core.push_devices.push_user", record)
    return sent


async def _seller(name="Xavier Bravin") -> tuple[str, dict, str]:
    """A seller with a number an SMS can go to (digits only)."""
    phone = "07" + "".join(str(int(c, 16) % 10) for c in uuid.uuid4().hex[:8])
    u = User(name=name, phone=phone, password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}, phone


async def _named_listing(client, headers, name="Oraimo Spacebuds") -> dict:
    r = await client.post("/listings/", headers=headers, json={
        "description": "Well kept, works perfectly - selling because I upgraded.",
        "name": name, "category": "Electronics", "price": 1500, "lat": -1.28, "lng": 36.82})
    assert r.status_code == 201, r.text
    return r.json()


class TestTellingTheSeller:
    @pytest.mark.asyncio
    async def test_the_first_report_texts_and_pushes_the_seller(self, client, sms, pushes):
        seller_id, seller, phone = await _seller()
        _, buyer = await _user()
        listing = await _named_listing(client, seller)
        r = await client.post(f"/listings/{listing['id']}/sold-out", headers=buyer)
        assert r.status_code == 200, r.text

        assert len(sms.sent) == 1
        to, text = sms.sent[0]
        assert to == phone
        assert text.startswith("Hey Xavier, it's Zeno from BROKA.")
        assert '"Oraimo Spacebuds"' in text and "unavailable" in text
        assert "Revoke it on your BROKA dashboard" in text
        assert len(text) <= 160, "one SMS part for an ordinary name"

        assert [(u, k["data"]["type"], k["data"]["listing_id"]) for u, k in pushes] == [
            (seller_id, "listing_sold_out_reported", listing["id"])]
        async with AsyncSessionLocal() as db:
            assert (await db.get(Listing, listing["id"])).sold_out_texted_at is not None

    @pytest.mark.asyncio
    async def test_a_second_buyers_report_texts_nobody_again(self, client, sms, pushes):
        _, seller, _phone = await _seller()
        _, first = await _user()
        _, second = await _user()
        listing = await _named_listing(client, seller)
        await client.post(f"/listings/{listing['id']}/sold-out", headers=first)
        await client.post(f"/listings/{listing['id']}/sold-out", headers=second)
        assert len(sms.sent) == 1 and len(pushes) == 1

    @pytest.mark.asyncio
    async def test_a_seller_who_turned_texts_off_for_the_listing_is_only_pushed(self, client, sms, pushes):
        _, seller, _phone = await _seller()
        _, buyer = await _user()
        listing = await _named_listing(client, seller)
        async with AsyncSessionLocal() as db:
            (await db.get(Listing, listing["id"])).sms_alerts = False
            await db.commit()
        await client.post(f"/listings/{listing['id']}/sold-out", headers=buyer)
        assert sms.sent == []
        assert len(pushes) == 1

    @pytest.mark.asyncio
    async def test_a_text_that_did_not_go_is_sent_by_the_sweep_once(self, client, sms):
        from api.domains.listings.sold_out import send_due_texts

        _, seller, _phone = await _seller()
        _, buyer = await _user()
        listing = await _named_listing(client, seller)
        sms.ok = False
        await client.post(f"/listings/{listing['id']}/sold-out", headers=buyer)
        assert len(sms.sent) == 1
        async with AsyncSessionLocal() as db:
            assert (await db.get(Listing, listing["id"])).sold_out_texted_at is None, \
                "a text that didn't go is not marked sent"

        sms.ok = True
        assert await send_due_texts() >= 1
        assert len([m for m in sms.sent if listing["name"] in m[1]]) == 2
        await send_due_texts()
        assert len([m for m in sms.sent if listing["name"] in m[1]]) == 2, "sent once, not every minute"

    @pytest.mark.asyncio
    async def test_the_seller_finds_it_on_the_dashboard_and_puts_it_back(self, client, sms):
        seller_id, seller, _phone = await _seller()
        _, buyer = await _user()
        _, stranger = await _user()
        listing = await _named_listing(client, seller)
        await client.post(f"/listings/{listing['id']}/sold-out", headers=buyer)

        # Buyers browsing the seller's listings no longer see it...
        public = (await client.get("/listings/", params={"seller_id": seller_id})).json()
        assert listing["id"] not in [i["id"] for i in public]
        as_stranger = (await client.get(
            "/listings/", params={"seller_id": seller_id}, headers=stranger)).json()
        assert listing["id"] not in [i["id"] for i in as_stranger]
        # ...but its seller's own catalogue keeps it, flagged, so the
        # dashboard card can offer "Still available". It used to read the
        # buyers' list and the listing vanished from the dashboard the text
        # sends the seller to.
        mine = (await client.get(
            "/listings/", params={"seller_id": seller_id}, headers=seller)).json()
        card = next(i for i in mine if i["id"] == listing["id"])
        assert card["reported_sold_out"] is True and card["sold_out"] is True
        assert card["reported_at"]
        reported = (await client.get("/listings/reported-unavailable", headers=seller)).json()
        assert [r["id"] for r in reported] == [listing["id"]]
        assert reported[0]["reported_sold_out"] is True and reported[0]["open_reports"] == 1
        assert reported[0]["reported_at"]
        assert (await client.get("/listings/reported-unavailable", headers=stranger)).json() == []

        assert (await client.delete(f"/listings/{listing['id']}/sold-out", headers=seller)).status_code == 200
        assert (await client.get("/listings/reported-unavailable", headers=seller)).json() == []
        assert await _in_feed(client, listing["id"])
        mine = (await client.get(
            "/listings/", params={"seller_id": seller_id}, headers=seller)).json()
        card = next(i for i in mine if i["id"] == listing["id"])
        assert card.get("reported_sold_out") is not True

        # Reported again by someone else: a new report, so a new text.
        _, other = await _user()
        await client.post(f"/listings/{listing['id']}/sold-out", headers=other)
        assert len([m for m in sms.sent if '"Oraimo Spacebuds"' in m[1]]) >= 2

    @pytest.mark.asyncio
    async def test_a_stale_session_still_reads_the_public_list(self, client):
        # The owner's view reads the caller's token if there is one. The
        # list is public: a token that no longer works must not 401 it.
        seller_id, _seller_headers, _ = await _seller()
        r = await client.get("/listings/", params={"seller_id": seller_id},
                             headers={"Authorization": "Bearer not-a-real-token"})
        assert r.status_code == 200, r.text

    def test_a_long_listing_name_gives_way_before_the_text_runs_to_two_parts(self):
        from api.domains.listings.sold_out import unavailable_sms

        text = unavailable_sms("Arnold", "Samsung Galaxy S23 Ultra 512GB Phantom Black - like new, with box")
        assert len(text) <= 160
        assert text.startswith("Hey Arnold, it's Zeno from BROKA.") and text.endswith("BROKA dashboard.")
        assert '"Samsung Galaxy' in text and '..."' in text
        # Nothing the provider can't send (GSM-7 only).
        assert unavailable_sms("Zeno", "📱 iPhone 13 🔥").isascii()
