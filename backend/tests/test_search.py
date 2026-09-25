"""
BROKA - Search Tests (listings and traders)
Run: pytest backend/tests/test_search.py -v

Home's search box (GET /listings/?search=) and the Traders screen's
(GET /traders?search=) take whatever a user typed. These pin down what that
text means: every word must match, in any order; a word in the description
counts; LIKE wildcards in the text mean themselves; and a title match leads.
"""

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.database import init_db, reset_engine, AsyncSessionLocal, Listing, User
from api.core.text_search import MAX_TERMS, contains_pattern, search_terms


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    # Same reason as test_traders.py: with REDIS_URL set, events would go to
    # a stream nothing in this test consumes.
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_search.db"
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


async def _register(client, phone, name, email) -> str:
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    reg = await client.post("/auth/register", json={
        "phone_verify_token": verify.json()["phone_verify_token"], "name": name,
        "email": email, "password": "TestPass123!", "lat": -1.286, "lng": 36.817,
    })
    return reg.json()["user_id"]


# (name, category, description, price, location_name)
_CATALOGUE = [
    ("iPhone 13 Pro 256GB", "Electronics", "Face ID works, battery 89%", 95000, "Westlands, Nairobi"),
    ("Galaxy A54 (Samsung)", "Electronics", "Dual SIM, with box", 38000, "Kisumu Central, Kisumu"),
    ("Fast charger", "Electronics", "Works with iPhone 13 and later", 1500, "Westlands, Nairobi"),
    ("Maize 90kg bag", "Agriculture", "Dry, 100 kg available", 4200, "Bondo, Siaya"),
    ("Office desk", "Home & Furniture", None, 12000, "Nakuru Town East, Nakuru"),
]


@pytest_asyncio.fixture(scope="module")
async def catalogue(client):
    seller_id = await _register(client, "0745551100", "Search Seller", "search.seller@test.ke")
    async with AsyncSessionLocal() as db:
        for name, category, description, price, place in _CATALOGUE:
            db.add(Listing(
                seller_id=seller_id, name=name, category=category,
                description=description, price=price, lat=-1.28, lng=36.8,
                location_name=place,
            ))
        await db.commit()
    return seller_id


async def _names(client, **params) -> list[str]:
    res = await client.get("/listings/", params={"limit": 50, **params})
    assert res.status_code == 200, res.text
    return [item["name"] for item in res.json()]


class TestSearchTerms:
    def test_words_are_split_lowered_and_deduplicated(self):
        assert search_terms("  iPhone  13 iphone PRO ") == ["iphone", "13", "pro"]
        assert search_terms("") == []
        assert search_terms(None) == []

    def test_a_pasted_paragraph_is_bounded(self):
        words = " ".join(f"w{i}" for i in range(50))
        assert len(search_terms(words)) == MAX_TERMS

    def test_wildcards_are_escaped(self):
        assert contains_pattern("100%") == "%100\\%%"
        assert contains_pattern("a_b") == "%a\\_b%"
        assert contains_pattern("c:\\x") == "%c:\\\\x%"


class TestListingSearch:
    @pytest.mark.asyncio
    async def test_words_match_in_any_order(self, client, catalogue):
        # The old search was one ILIKE of the whole phrase: "13 pro iphone"
        # found nothing.
        assert "iPhone 13 Pro 256GB" in await _names(client, search="13 pro iphone")
        assert "Galaxy A54 (Samsung)" in await _names(client, search="samsung a54")

    @pytest.mark.asyncio
    async def test_every_word_must_match(self, client, catalogue):
        assert await _names(client, search="iphone tractor") == []

    @pytest.mark.asyncio
    async def test_description_and_category_count(self, client, catalogue):
        assert "Galaxy A54 (Samsung)" in await _names(client, search="dual sim")
        assert "Maize 90kg bag" in await _names(client, search="agriculture")

    @pytest.mark.asyncio
    async def test_like_wildcards_mean_themselves(self, client, catalogue):
        # "_" was a single-character wildcard: it matched every listing.
        assert await _names(client, search="_") == []
        # "100%" was "100" followed by anything, so it matched "100 kg".
        assert await _names(client, search="100%") == []
        assert "iPhone 13 Pro 256GB" in await _names(client, search="89%")

    @pytest.mark.asyncio
    async def test_a_title_match_leads(self, client, catalogue):
        # The charger only mentions an iPhone 13 in its description; the
        # phone is one. Default order puts the phone first.
        names = await _names(client, search="iphone 13")
        assert set(names) == {"iPhone 13 Pro 256GB", "Fast charger"}
        assert names[0] == "iPhone 13 Pro 256GB"

    @pytest.mark.asyncio
    async def test_a_price_sort_is_not_reordered_by_relevance(self, client, catalogue):
        names = await _names(client, search="iphone 13", sort="price_low")
        assert names == ["Fast charger", "iPhone 13 Pro 256GB"]

    @pytest.mark.asyncio
    async def test_total_counts_the_same_matches(self, client, catalogue):
        res = await client.get("/listings/", params={"search": "iphone 13", "with_total": "true"})
        assert res.json()["total"] == 2

    @pytest.mark.asyncio
    async def test_location_filter_escapes_wildcards(self, client, catalogue):
        assert await _names(client, location="_") == []
        assert set(await _names(client, location="westlands")) == {
            "iPhone 13 Pro 256GB", "Fast charger"}


class TestTraderSearch:
    @pytest_asyncio.fixture(scope="class")
    async def traders(self, client):
        ids = {}
        for phone, name, business, email in [
            ("0745552201", "Grace Akinyi", "Clanix Electronics", "grace.clanix@test.ke"),
            ("0745552202", "Peter Mwangi", None, "peter.m@test.ke"),
        ]:
            uid = await _register(client, phone, name, email)
            async with AsyncSessionLocal() as db:
                user = (await db.execute(select(User).where(User.id == uid))).scalar_one()
                user.completed_deals = 2
                user.business_name = business
                await db.commit()
            ids[name] = uid
        return ids

    @pytest.mark.asyncio
    async def test_finds_by_business_or_personal_name(self, client, traders):
        res = await client.get("/traders", params={"search": "electronics clanix"})
        assert [t["id"] for t in res.json()] == [traders["Grace Akinyi"]]
        res = await client.get("/traders", params={"search": "mwangi"})
        assert [t["business_name"] for t in res.json()] == ["Peter Mwangi"]

    @pytest.mark.asyncio
    async def test_never_matches_email(self, client, traders):
        res = await client.get("/traders", params={"search": "grace.clanix@test.ke"})
        assert res.json() == []

    @pytest.mark.asyncio
    async def test_no_search_lists_everyone(self, client, traders):
        ids = {t["id"] for t in (await client.get("/traders")).json()}
        assert set(traders.values()) <= ids

    @pytest.mark.asyncio
    async def test_search_length_is_bounded(self, client, traders):
        res = await client.get("/traders", params={"search": "x" * 101})
        assert res.status_code == 422
