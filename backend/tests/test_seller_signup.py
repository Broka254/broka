"""Signup-time seller categorisation.

The wizard now asks buyer-vs-seller up front, and short-term vs long-term for
sellers. What matters here is that the answers actually land on the account,
that a long-term seller gets a business identity in the same call, and that a
malformed answer degrades to a buyer rather than losing the registration.
"""

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.database import init_db, reset_engine
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    mp.setenv("ENV", "test")
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


async def _register(client, phone: str, **extra):
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    v = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    body = {
        "phone_verify_token": v.json()["phone_verify_token"],
        "name": "Test Trader",
        "password": "secret123",
        "lat": -1.29,
        "lng": 36.82,
        **extra,
    }
    return await client.post("/auth/register", json=body)


async def _me(client, token: str):
    r = await client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200, r.text
    return r.json()


class TestBuyer:
    async def test_default_is_a_buyer_with_no_tier(self, client):
        r = await _register(client, "+254700222001")
        assert r.status_code == 201, r.text
        assert r.json()["account_type"] == "buyer"
        assert r.json()["seller_tier"] is None

    async def test_explicit_buyer_ignores_a_stray_tier(self, client):
        # The wizard never sends this pair, but a tier without a selling
        # account must not imply one.
        r = await _register(
            client, "+254700222002", account_type="buyer", seller_tier="long_term"
        )
        assert r.status_code == 201, r.text
        assert r.json()["account_type"] == "buyer"
        assert r.json()["seller_tier"] is None


class TestShortTermSeller:
    async def test_becomes_a_selling_account_with_no_business(self, client):
        r = await _register(
            client, "+254700222003",
            account_type="buyer_seller", seller_tier="short_term",
        )
        assert r.status_code == 201, r.text
        assert r.json()["account_type"] == "buyer_seller"
        assert r.json()["seller_tier"] == "short_term"

        me = await _me(client, r.json()["access_token"])
        assert me["business_display_name"] in (None, "")

    async def test_business_fields_are_ignored_for_a_short_term_seller(self, client):
        # They are never asked for these, so anything arriving here is noise.
        r = await _register(
            client, "+254700222004",
            account_type="buyer_seller", seller_tier="short_term",
            business_name="Clanix", business_category="Electronics",
            business_location="Sira",
        )
        assert r.status_code == 201, r.text
        me = await _me(client, r.json()["access_token"])
        assert me["business_display_name"] in (None, "")


class TestLongTermSeller:
    async def test_gets_a_business_identity_in_the_same_call(self, client):
        r = await _register(
            client, "+254700222005",
            account_type="buyer_seller", seller_tier="long_term",
            business_name="Clanix", business_category="Electronics",
            business_location="Sira",
            business_description="We sell refurbished laptops.",
        )
        assert r.status_code == 201, r.text
        assert r.json()["seller_tier"] == "long_term"

        me = await _me(client, r.json()["access_token"])
        assert me["business_name"] == "Clanix"
        assert me["business_category"] == "Electronics"
        assert me["business_location"] == "Sira"
        # The server composes the display name so it cannot drift into
        # inconsistent variants.
        assert "Clanix" in me["business_display_name"]
        assert "Electronics" in me["business_display_name"]
        assert "Sira" in me["business_display_name"]

    async def test_an_incomplete_business_is_not_half_saved(self, client):
        # A missing location would otherwise yield a display name with an
        # empty segment, which then shows up in search.
        r = await _register(
            client, "+254700222006",
            account_type="buyer_seller", seller_tier="long_term",
            business_name="Clanix", business_category="Electronics",
        )
        assert r.status_code == 201, r.text
        me = await _me(client, r.json()["access_token"])
        assert me["business_display_name"] in (None, "")
        # Still a seller — they can finish setup from Profile.
        assert me["account_type"] == "buyer_seller"

    async def test_description_is_optional(self, client):
        r = await _register(
            client, "+254700222007",
            account_type="buyer_seller", seller_tier="long_term",
            business_name="Amani Stores", business_category="Wholesale",
            business_location="Kisumu",
        )
        assert r.status_code == 201, r.text
        me = await _me(client, r.json()["access_token"])
        assert me["business_display_name"]


class TestMalformedInput:
    # Phones are fixed per case, not derived from hash(): Python randomises
    # string hashing per process, so a derived number collides with another
    # test's registration on some runs and not others.
    @pytest.mark.parametrize(
        "idx,bad",
        list(enumerate(["admin", "seller", "", "BUYER_SELLER", None])),
    )
    async def test_an_unknown_account_type_degrades_to_buyer(self, client, idx, bad):
        phone = f"+25470033300{idx}"
        r = await _register(client, phone, account_type=bad)
        assert r.status_code == 201, r.text
        assert r.json()["account_type"] == "buyer"

    async def test_an_unknown_tier_degrades_to_short_term(self, client):
        # Never silently grants the long-term path, which is the one that
        # carries a public storefront identity.
        r = await _register(
            client, "+254700222008",
            account_type="buyer_seller", seller_tier="forever",
        )
        assert r.status_code == 201, r.text
        assert r.json()["seller_tier"] == "short_term"


class TestProfileUpgrade:
    async def test_upgrading_from_profile_marks_long_term(self, client):
        r = await _register(client, "+254700222009")
        token = r.json()["access_token"]

        up = await client.post(
            "/auth/upgrade-to-seller",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "business_name": "Late Bloomer",
                "business_category": "Services",
                "business_location": "Nakuru",
            },
        )
        assert up.status_code == 200, up.text

        me = await _me(client, token)
        assert me["account_type"] == "buyer_seller"
        assert me["seller_tier"] == "long_term"
