"""Physical/virtual stores, opening hours, delivery coverage, the owner's
catalogue tools, and the AI Marketing Studio.

Every test drives the real HTTP API against a real (SQLite) database, as the
app and the web storefront do - no frontend state stands in for a stored
record. The AI provider is always absent or instructed to fail here: the
studio's template writer is part of the feature, and a test that needed a
paid key could not run in CI.
"""
import io
import itertools
from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select, update

from main import app
from api.core.config import settings
from api.database import AsyncSessionLocal, Listing, ListingStatus, User, init_db, reset_engine
from api.domains.stores import opening_hours
from api.models.marketing import MarketingCampaign, MarketingCreative
from api.models.store import Store
from tests.legal_payload import legal_payload


def _jpeg() -> bytes:
    """A real image, so the poster renderer has something to draw on."""
    from PIL import Image

    buffer = io.BytesIO()
    Image.new("RGB", (640, 480), (24, 58, 120)).save(buffer, format="JPEG")
    return buffer.getvalue()


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_types.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("GEMINI_API_KEY", "")
    mp.setenv("DEEPSEEK_API_KEY", "")
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


_n = itertools.count(1)

_SHOP_PHOTO = ("data:image/png;base64,"
               "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


async def _register(client, tier="long_term"):
    n = next(_n)
    phone = f"0746{n:06d}"
    code = (await client.post("/auth/otp/request", json={"phone": phone})).json()["debug_code"]
    token = (await client.post("/auth/otp/verify", json={"phone": phone, "code": code})).json()[
        "phone_verify_token"]
    body = {
        "phone_verify_token": token, "name": f"Seller {n}", "password": "Passw0rd!x",
        "lat": -1.286, "lng": 36.817, "legal_acceptance": legal_payload(),
    }
    if tier:
        body.update(account_type="buyer_seller", seller_tier=tier)
    if tier == "long_term":
        body.update(business_name=f"Biz {n}", business_category="Electronics",
                    business_location="Nairobi")
    reg = await client.post("/auth/register", json=body)
    assert reg.status_code == 201, reg.text
    return reg.json()["user_id"], {"Authorization": f"Bearer {reg.json()['access_token']}"}


async def _create_store(client, headers, **fields):
    body = {"name": f"Shop {next(_n)}", **fields}
    return await client.post("/stores", json=body, headers=headers)


async def _store(client, headers, **fields) -> dict:
    # A current client's physical store needs a shop photo; this helper is
    # for the ordinary case. Type tests build their own bodies.
    body = {"name": f"Shop {next(_n)}", **fields}
    if "slug" in body and "photos" not in body and "photo_ids" not in body:
        body["photos"] = [_SHOP_PHOTO]
    r = await client.post("/stores", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _listing(client, headers, store_id, name=None, price=2500, category="Electronics"):
    r = await client.post("/listings/", json={
        "description": "Brand new, sealed in the box with a one-year shop receipt. "
                       "Works on all Kenyan networks.",
        "name": name or f"Product {next(_n)}", "category": category,
        "price": price, "lat": -1.0, "lng": 36.0, "store_id": store_id,
    }, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


WORKING_WEEK = {
    "mon": {"open": "08:00", "close": "18:00"},
    "tue": {"open": "08:00", "close": "18:00"},
    "wed": {"open": "08:00", "close": "18:00"},
    "thu": {"open": "08:00", "close": "18:00"},
    "fri": {"open": "08:00", "close": "18:00"},
    "sat": {"open": "09:00", "close": "14:00"},
    "sun": None,
}


# ── Physical and virtual stores ─────────────────────────────────────────────

@pytest.mark.asyncio
class TestStoreTypes:
    async def test_a_virtual_store_opens_without_premises_or_photos(self, client):
        _, headers = await _register(client)
        r = await _create_store(
            client, headers, name="Online Only", slug="online-only",
            store_type="virtual", service_areas=["Nationwide"],
        )
        assert r.status_code == 201, r.text
        store = r.json()
        assert store["store_type"] == "virtual"
        assert store["photo_images"] == [] and store["photos"] == []
        assert store["service_areas"] == ["Nationwide"]
        # No invented premises: no map point is published.
        assert store["has_location"] is False
        assert store["approx_lat"] is None and store["approx_lng"] is None

    async def test_a_physical_store_still_needs_a_shop_photo(self, client):
        _, headers = await _register(client)
        r = await _create_store(client, headers, name="No Photo", slug="no-photo",
                                store_type="physical")
        assert r.status_code == 400
        assert "photo" in r.json()["detail"].lower()

    async def test_an_old_client_gets_a_physical_store(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Legacy Shop", slug="legacy-shop")
        assert store["store_type"] == "physical"

    @pytest.mark.parametrize("bad", ["shop", "PHYSICAL_STORE", "", 3])
    async def test_invalid_store_types_are_rejected(self, client, bad):
        _, headers = await _register(client)
        r = await _create_store(client, headers, name="Bad Type", store_type=bad)
        assert r.status_code in (400, 422), r.text

    async def test_a_virtual_store_keeps_its_declared_service_area(self, client):
        _, headers = await _register(client)
        store = await _store(
            client, headers, name="Siaya Online", slug="siaya-online",
            store_type="virtual", service_areas=["Siaya"],
            delivery_note="Courier within Siaya, two days.",
        )
        assert store["service_areas"] == ["Siaya"]
        assert store["delivery_note"].startswith("Courier")
        public = (await client.get(f"/stores/{store['id']}")).json()
        assert public["service_areas"] == ["Siaya"]
        assert public["store_type"] == "virtual"

    async def test_a_physical_shop_can_deliver_countrywide(self, client):
        _, headers = await _register(client)
        store = await _store(
            client, headers, name="Kisumu Tools", slug="kisumu-tools",
            store_type="physical", county="Kisumu", subcounty="Kisumu Central",
            service_areas=["Nationwide"],
        )
        # Location and coverage are separate facts, both kept.
        assert store["county"] == "Kisumu"
        assert store["service_areas"] == ["Nationwide"]

    async def test_switching_to_physical_requires_a_shop_photo(self, client):
        _, headers = await _register(client)
        store = (await _create_store(
            client, headers, name="Virtual First", slug="virtual-first",
            store_type="virtual",
        )).json()
        r = await client.patch(f"/stores/{store['id']}", json={"store_type": "physical"},
                               headers=headers)
        assert r.status_code == 400
        assert "photo" in r.json()["detail"].lower()
        # Nothing changed on the failed switch.
        assert (await client.get(f"/stores/{store['id']}")).json()["store_type"] == "virtual"

    async def test_switching_to_physical_requires_a_location_too(self, client):
        _, headers = await _register(client)
        store = (await _create_store(
            client, headers, name="Nowhere Virtual", slug="nowhere-virtual",
            store_type="virtual",
        )).json()
        # A photo alone is not premises: a physical storefront with no place
        # a buyer can go would publish "Kenya" as its address.
        r = await client.patch(
            f"/stores/{store['id']}",
            json={"store_type": "physical", "photos": [_SHOP_PHOTO]},
            headers=headers,
        )
        assert r.status_code == 400
        assert "county" in r.json()["detail"].lower()
        assert (await client.get(f"/stores/{store['id']}")).json()["store_type"] == "virtual"

    async def test_switching_to_physical_with_a_photo_and_a_location_works(self, client):
        _, headers = await _register(client)
        store = (await _create_store(
            client, headers, name="Virtual Then Real", slug="virtual-then-real",
            store_type="virtual",
        )).json()
        r = await client.patch(
            f"/stores/{store['id']}",
            json={
                "store_type": "physical", "photos": [_SHOP_PHOTO],
                "county": "Nairobi", "subcounty": "Westlands",
            },
            headers=headers,
        )
        assert r.status_code == 200, r.text
        assert r.json()["store_type"] == "physical"
        assert r.json()["county"] == "Nairobi"

    async def test_a_store_with_a_pin_can_become_physical(self, client):
        _, headers = await _register(client)
        store = (await _create_store(
            client, headers, name="Pinned Online", slug="pinned-online",
            store_type="virtual",
        )).json()
        r = await client.patch(
            f"/stores/{store['id']}",
            json={
                "store_type": "physical", "photos": [_SHOP_PHOTO],
                "lat": -1.286, "lng": 36.817,
                "location_description": "Kimathi Street",
            },
            headers=headers,
        )
        assert r.status_code == 200, r.text
        assert r.json()["store_type"] == "physical"

    async def test_switching_to_virtual_keeps_the_address_but_stops_publishing_it(self, client):
        _, headers = await _register(client)
        store = await _store(
            client, headers, name="Shop And Online", slug="shop-and-online",
            store_type="physical", county="Nairobi", subcounty="Westlands",
            location_description="Kimathi Street", lat=-1.285, lng=36.82,
            opening_hours=WORKING_WEEK,
        )
        r = await client.patch(f"/stores/{store['id']}", json={"store_type": "virtual"},
                               headers=headers)
        assert r.status_code == 200, r.text
        owner_view = r.json()
        assert owner_view["store_type"] == "virtual"
        # The owner's own data isn't destroyed by the switch...
        assert owner_view["county"] == "Nairobi"
        assert owner_view["lat"] == -1.285
        # ...and the public page stops claiming premises or a map pin.
        public = (await client.get(f"/stores/{store['id']}")).json()
        assert public["county"] == "Nairobi"
        assert public["has_location"] is False
        assert public["approx_lat"] is None

    async def test_the_directory_lists_both_kinds_and_filters_by_type(self, client):
        _, virtual_owner = await _register(client)
        _, physical_owner = await _register(client)
        virtual = await _store(
            client, virtual_owner, name="Directory Virtual", slug="directory-virtual",
            store_type="virtual", category="Electronics",
        )
        physical = await _store(
            client, physical_owner, name="Directory Physical", slug="directory-physical",
            store_type="physical", category="Electronics", photos=[_SHOP_PHOTO],
        )
        all_items = (await client.get("/stores", params={"search": "Directory"})).json()
        ids = {s["id"] for s in all_items}
        assert {virtual["id"], physical["id"]} <= ids
        only_virtual = (await client.get(
            "/stores", params={"search": "Directory", "store_type": "virtual"})).json()
        assert [s["id"] for s in only_virtual] == [virtual["id"]]
        only_physical = (await client.get(
            "/stores", params={"search": "Directory", "store_type": "physical"})).json()
        assert [s["id"] for s in only_physical] == [physical["id"]]


# ── Opening hours ───────────────────────────────────────────────────────────

class TestOpeningHoursRules:
    def test_a_normal_week_is_normalised(self):
        schedule = opening_hours.normalize(WORKING_WEEK)
        assert schedule["mon"] == {"open": "08:00", "close": "18:00"}
        assert schedule["sun"] is None

    def test_midnight_crossing_is_allowed(self):
        schedule = opening_hours.normalize({"fri": {"open": "20:00", "close": "02:00"}})
        assert schedule["fri"] == {"open": "20:00", "close": "02:00"}

    def test_24_hours_is_explicit(self):
        assert opening_hours.normalize({"mon": {"all_day": True}})["mon"] == {"all_day": True}

    @pytest.mark.parametrize("bad,fragment", [
        ({"mon": {"open": "8:00", "close": "18:00"}}, "08:00"),
        ({"mon": {"open": "25:00", "close": "18:00"}}, "doesn't exist"),
        ({"mon": {"open": "09:00", "close": "09:00"}}, "same"),
        ({"mon": {"open": "09:00"}}, "both"),
        ({"funday": {"open": "09:00", "close": "17:00"}}, "mon to sun"),
        ({"mon": {"all_day": True, "open": "09:00", "close": "17:00"}}, "not both"),
        ({"mon": {"open": "09:00", "close": "09:30"}, "tue": {"open": "x", "close": "y"}}, "Tue"),
    ])
    def test_invalid_schedules_are_refused(self, bad, fragment):
        with pytest.raises(opening_hours.OpeningHoursError) as exc:
            opening_hours.normalize(bad)
        assert fragment in str(exc.value)

    def test_unknown_hours_are_unavailable_never_closed(self):
        status = opening_hours.open_status(None)
        assert status["state"] == "unknown"
        assert "unavailable" in status["label"]

    def test_open_now_and_closes_at(self):
        # 10:00 Nairobi on a Monday (07:00 UTC).
        now = datetime(2026, 10, 26, 7, 0, tzinfo=timezone.utc)
        schedule = opening_hours.normalize(WORKING_WEEK)
        status = opening_hours.open_status(schedule, now)
        assert status["state"] == "open"
        assert "18:00" in status["label"]

    def test_closed_before_opening_says_when_it_opens(self):
        now = datetime(2026, 10, 26, 4, 0, tzinfo=timezone.utc)  # 07:00 Nairobi
        schedule = opening_hours.normalize(WORKING_WEEK)
        status = opening_hours.open_status(schedule, now)
        assert status["state"] == "closed"
        assert status["opens_at"] == "08:00"

    def test_a_window_crossing_midnight_is_open_after_midnight(self):
        schedule = opening_hours.normalize({"mon": {"open": "20:00", "close": "02:00"},
                                            "tue": None, "wed": None, "thu": None,
                                            "fri": None, "sat": None, "sun": None})
        # 01:00 Nairobi on Tuesday: Monday night's window still running.
        now = datetime(2026, 10, 26, 22, 0, tzinfo=timezone.utc)  # Tue 01:00
        assert opening_hours.open_status(schedule, now)["state"] == "open"
        # 03:00 Nairobi on Tuesday: it has closed.
        now = datetime(2026, 10, 27, 0, 0, tzinfo=timezone.utc)   # Tue 03:00
        assert opening_hours.open_status(schedule, now)["state"] == "closed"

    def test_the_public_week_has_all_seven_days_and_closed_days(self):
        rows = opening_hours.weekly_schedule(opening_hours.normalize(WORKING_WEEK))
        assert [r["day"] for r in rows] == list(opening_hours.DAYS)
        assert rows[-1]["closed"] is True
        assert rows[0]["hours"] == "08:00 – 18:00"


@pytest.mark.asyncio
class TestOpeningHoursApi:
    async def test_hours_are_stored_and_served_with_a_current_status(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Hours Shop", slug="hours-shop",
                             store_type="physical", photos=[_SHOP_PHOTO],
                             opening_hours=WORKING_WEEK)
        public = (await client.get(f"/stores/{store['id']}")).json()
        assert public["opening_hours_available"] is True
        assert public["opening_hours"]["mon"]["close"] == "18:00"
        assert len(public["opening_hours_week"]) == 7
        assert public["open_status"]["state"] in ("open", "closed")

    async def test_invalid_hours_do_not_save(self, client):
        _, headers = await _register(client)
        r = await _create_store(
            client, headers, name="Bad Hours", slug="bad-hours",
            opening_hours={"mon": {"open": "18:00", "close": "08:00"},
                           "tue": {"open": "soon", "close": "late"}},
            photos=[_SHOP_PHOTO],
        )
        assert r.status_code == 400
        assert "Tuesday" in r.json()["detail"]

    async def test_clearing_hours_leaves_hours_unavailable(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Clear Hours", slug="clear-hours",
                             photos=[_SHOP_PHOTO], opening_hours=WORKING_WEEK)
        r = await client.patch(f"/stores/{store['id']}", json={"opening_hours": None},
                               headers=headers)
        assert r.status_code == 200
        assert r.json()["opening_hours_available"] is False


# ── Delivery coverage ───────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestDeliveryCoverage:
    async def test_an_unknown_county_is_refused(self, client):
        _, headers = await _register(client)
        r = await _create_store(
            client, headers, name="Coverage Bad", slug="coverage-bad",
            store_type="virtual", service_areas=["Atlantis"],
        )
        assert r.status_code == 400
        assert "Atlantis" in r.json()["detail"]

    async def test_duplicates_collapse_and_spellings_are_canonicalised(self, client):
        _, headers = await _register(client)
        store = await _store(
            client, headers, name="Coverage Good", slug="coverage-good",
            store_type="virtual", service_areas=["nairobi", "Nairobi County", "Kisumu"],
        )
        assert store["service_areas"] == ["Nairobi", "Kisumu"]


# ── Catalogue management ────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestOwnerCatalogue:
    async def test_products_are_paginated_with_counts_and_health(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Catalogue", slug="catalogue-shop",
                             service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Alpha", price=1000)
        await _listing(client, headers, store["id"], name="Beta", price=2000)
        first = (await client.get(
            f"/stores/{store['id']}/manage/listings",
            params={"limit": 1, "offset": 0}, headers=headers,
        )).json()
        assert len(first["items"]) == 1
        assert first["counts"]["all"] == 2
        second = (await client.get(
            f"/stores/{store['id']}/manage/listings",
            params={"limit": 1, "offset": 1}, headers=headers,
        )).json()
        assert second["items"][0]["id"] != first["items"][0]["id"]
        # Health is computed by the server from the real listing row. These
        # listings have no photo, so the issue is present and actionable.
        health = first["items"][0]["health"]
        assert health["ok"] is False
        assert {"code": "no_image", "label": "No product photo", "fix": "photos"} in health["issues"]

    async def test_the_catalogue_filters_by_category_and_sorts_by_price(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Sorted Shop", slug="sorted-shop")
        await _listing(client, headers, store["id"], name="Zed phone", price=5000,
                       category="Electronics")
        await _listing(client, headers, store["id"], name="Ama dress", price=1200,
                       category="Fashion")
        await _listing(client, headers, store["id"], name="Kite shoes", price=3000,
                       category="Fashion")

        def names(payload):
            return [item["name"] for item in payload["items"]]

        url = f"/stores/{store['id']}/manage/listings"
        fashion = (await client.get(url, params={"category": "Fashion"},
                                    headers=headers)).json()
        assert sorted(names(fashion)) == ["Ama dress", "Kite shoes"]
        # The counts describe the filtered catalogue, so the chips agree
        # with what tapping them shows.
        assert fashion["counts"]["all"] == 2

        cheapest = (await client.get(url, params={"sort": "price_low"},
                                     headers=headers)).json()
        assert names(cheapest) == ["Ama dress", "Kite shoes", "Zed phone"]
        dearest = (await client.get(url, params={"sort": "price_high"},
                                    headers=headers)).json()
        assert names(dearest) == ["Zed phone", "Kite shoes", "Ama dress"]
        alphabetical = (await client.get(url, params={"sort": "name"},
                                         headers=headers)).json()
        assert names(alphabetical) == ["Ama dress", "Kite shoes", "Zed phone"]

        # Only the fixed list is accepted; the value never reaches SQL.
        bad = await client.get(url, params={"sort": "price;DROP TABLE listings"},
                               headers=headers)
        assert bad.status_code == 422

    async def test_bulk_archive_is_owner_scoped(self, client):
        _, owner = await _register(client)
        _, other = await _register(client)
        store = await _store(client, owner, name="Bulk Shop", slug="bulk-shop")
        other_store = await _store(client, other, name="Other Bulk", slug="other-bulk")
        mine = await _listing(client, owner, store["id"], name="Mine")
        theirs = await _listing(client, other, other_store["id"], name="Theirs")

        # An id from another store makes the whole request fail - nothing is
        # silently skipped.
        r = await client.post(
            f"/stores/{store['id']}/manage/listings/bulk",
            json={"action": "archive", "listing_ids": [mine["id"], theirs["id"]]},
            headers=owner,
        )
        assert r.status_code == 400
        # Neither listing changed.
        assert (await client.get(f"/listings/{mine['id']}")).json()["status"] == "active"
        assert (await client.get(f"/listings/{theirs['id']}")).json()["status"] == "active"

        ok = await client.post(
            f"/stores/{store['id']}/manage/listings/bulk",
            json={"action": "archive", "listing_ids": [mine["id"]]},
            headers=owner,
        )
        assert ok.status_code == 200, ok.text
        assert ok.json()["archived"] == [mine["id"]]
        # Archived, not deleted: the row survives, and buyers stop seeing it.
        assert (await client.get(f"/listings/{mine['id']}")).json()["status"] == "cancelled"

    async def test_bulk_archive_refuses_a_product_in_a_deal(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Deal Shop", slug="deal-shop")
        listing = await _listing(client, headers, store["id"], name="In Deal")
        async with AsyncSessionLocal() as db:
            await db.execute(
                update(Listing).where(Listing.id == listing["id"])
                .values(status=ListingStatus.pending)
            )
            await db.commit()
        r = await client.post(
            f"/stores/{store['id']}/manage/listings/bulk",
            json={"action": "archive", "listing_ids": [listing["id"]]},
            headers=headers,
        )
        assert r.status_code == 409
        assert "deal" in r.json()["detail"].lower()

    async def test_another_seller_cannot_read_the_owners_catalogue(self, client):
        _, owner = await _register(client)
        _, other = await _register(client)
        store = await _store(client, owner, name="Private Catalogue", slug="private-catalogue")
        await _listing(client, owner, store["id"], name="Secret Product")
        r = await client.get(f"/stores/{store['id']}/manage/listings", headers=other)
        assert r.status_code == 403


# ── Marketing Studio ────────────────────────────────────────────────────────

def _campaign_body(store, listing, **extra):
    return {
        "title": "Launch the new stock",
        "objective": "new_stock",
        "platforms": ["whatsapp", "instagram", "tiktok", "facebook", "x"],
        "product_ids": [listing["id"]],
        "language": "en",
        "tone": "friendly",
        **extra,
    }


@pytest.mark.asyncio
class TestMarketingCampaigns:
    async def test_generation_uses_the_real_catalogue_and_differs_by_platform(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Marketing Shop", slug="marketing-shop",
                             store_type="virtual", service_areas=["Nairobi"])
        listing = await _listing(client, headers, store["id"], name="Solar Lantern", price=2500)

        r = await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=headers,
        )
        assert r.status_code == 201, r.text
        campaign = r.json()
        assert campaign["status"] == "generated"
        assert campaign["products"][0]["name"] == "Solar Lantern"
        assert campaign["products"][0]["price"] == 2500
        assert set(campaign["platforms"]) == {"whatsapp", "instagram", "tiktok", "facebook", "x"}
        creatives = campaign["creatives"]
        assert {c["platform"] for c in creatives} == set(campaign["platforms"])
        # Every creative carries the real price, and each platform gets its
        # own shape rather than one body copied five times.
        assert any("2,500" in c["body"] for c in creatives)
        bodies = {c["platform"]: c["body"] for c in creatives if c["format"] != "status"}
        assert len(set(bodies.values())) == len(bodies)
        x_creatives = [c for c in creatives if c["platform"] == "x"]
        assert x_creatives and all(len(c["body"]) <= 280 for c in x_creatives)
        tiktok = [c for c in creatives if c["platform"] == "tiktok"]
        assert tiktok and all(c["format"] in ("script", "video_plan") for c in tiktok)
        assert tiktok[0]["media"]["aspect_ratio"] == "9:16"
        # Tracked links identify this campaign and this platform.
        assert campaign["link_token"]
        for platform, link in campaign["links"].items():
            assert "c=" in link and "via=" in link and platform in link
        # A real, honest generation record - no key here, so template.
        assert campaign["generation"]["fallback"] is True
        assert all(c["source"] == "template" for c in creatives)
        assert campaign["plan"]

    async def test_a_virtual_store_s_copy_never_claims_premises_it_lacks(self, client):
        _, headers = await _register(client)
        # A virtual store that once had an address on file: the switch keeps
        # it, and the copy must not turn it back into "come to our shop".
        store = await _store(
            client, headers, name="Shoreline Online", slug="shoreline-online",
            store_type="virtual", county="Mombasa", subcounty="Nyali",
            service_areas=["Siaya"], delivery_note="Courier within Siaya.",
        )
        listing = await _listing(client, headers, store["id"], name="Beach Towel")
        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing),
            headers=headers,
        )).json()

        body = " ".join(c["body"] + " " + (c["headline"] or "") for c in campaign["creatives"])
        # No shopfront, and no Mombasa address dressed up as one.
        assert "Nyali" not in body
        assert "Mombasa" not in body
        # The declared coverage is what a buyer is told.
        assert "Siaya" in body

    async def test_a_physical_store_s_copy_keeps_its_shop_and_its_coverage(self, client):
        _, headers = await _register(client)
        store = await _store(
            client, headers, name="Kisumu Hardware", slug="kisumu-hardware",
            store_type="physical", county="Kisumu", subcounty="Kisumu Central",
            service_areas=["Nationwide"], photos=[_SHOP_PHOTO],
        )
        listing = await _listing(client, headers, store["id"], name="Paint Brush")
        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing),
            headers=headers,
        )).json()
        whatsapp = [c for c in campaign["creatives"] if c["platform"] == "whatsapp"][0]
        # Where to walk in and where it delivers are both true and both said.
        assert "Kisumu Central" in whatsapp["body"]
        assert "Nationwide" in whatsapp["body"]

    async def test_a_discount_needs_the_seller_to_state_it(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Discount Shop", slug="discount-shop")
        listing = await _listing(client, headers, store["id"], name="Discount Item")
        r = await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing, objective="discount"), headers=headers,
        )
        assert r.status_code == 400
        assert "won't invent" in r.json()["detail"]

        ok = await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing, objective="discount",
                                instructions="10% off until Friday 6pm"),
            headers=headers,
        )
        assert ok.status_code == 201, ok.text
        assert any("10% off" in c["body"] for c in ok.json()["creatives"]
                   if c["platform"] == "whatsapp")

    async def test_a_product_from_another_store_is_refused(self, client):
        _, mine = await _register(client)
        _, other = await _register(client)
        store = await _store(client, mine, name="Mine Store", slug="mine-store")
        other_store = await _store(client, other, name="Theirs Store", slug="theirs-store")
        listing = await _listing(client, other, other_store["id"], name="Not Mine")
        r = await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=mine,
        )
        assert r.status_code == 400
        assert "aren't in this store" in r.json()["detail"]

    async def test_unsupported_platforms_are_rejected(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Platform Shop", slug="platform-shop")
        listing = await _listing(client, headers, store["id"], name="Platform Item")
        r = await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing, platforms=["myspace"]), headers=headers,
        )
        assert r.status_code == 422

    async def test_a_campaign_is_private_to_its_owner(self, client):
        _, owner = await _register(client)
        _, other = await _register(client)
        store = await _store(client, owner, name="Private Campaign", slug="private-campaign")
        listing = await _listing(client, owner, store["id"], name="Private Item")
        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=owner,
        )).json()

        # Another seller cannot read it, even knowing its id.
        assert (await client.get(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}",
            headers=other,
        )).status_code == 403
        # And no unauthenticated route exposes it or the owner's list.
        assert (await client.get(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}",
        )).status_code == 401
        assert (await client.get(
            f"/stores/{store['id']}/marketing/campaigns",
        )).status_code == 401

    async def test_editing_a_creative_persists_and_never_rewrites_the_listing(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Editorial Shop", slug="editorial-shop")
        listing = await _listing(client, headers, store["id"], name="Original Listing Name")
        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=headers,
        )).json()
        creative = campaign["creatives"][0]
        r = await client.patch(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}/creatives/{creative['id']}",
            json={"body": "My own words, with the real price KES 2,500.",
                  "cta": "Message me on BROKA"},
            headers=headers,
        )
        assert r.status_code == 200, r.text
        saved = next(c for c in r.json()["creatives"] if c["id"] == creative["id"])
        assert saved["body"].startswith("My own words")
        assert saved["cta"] == "Message me on BROKA"

        # Reopening the campaign shows the edit.
        reopened = (await client.get(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}", headers=headers,
        )).json()
        assert next(c for c in reopened["creatives"] if c["id"] == creative["id"])["body"] == saved["body"]
        # The listing itself is untouched.
        assert (await client.get(f"/listings/{listing['id']}")).json()["name"] == "Original Listing Name"

    async def test_campaigns_are_saved_listed_and_deleted(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Archive Shop", slug="archive-shop")
        listing = await _listing(client, headers, store["id"], name="Archived Campaign Item")
        draft = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing, generate=False), headers=headers,
        )).json()
        assert draft["status"] == "draft" and draft["creatives"] == []

        listed = (await client.get(
            f"/stores/{store['id']}/marketing/campaigns", headers=headers,
        )).json()
        assert listed["total"] == 1 and listed["items"][0]["id"] == draft["id"]

        regenerated = await client.post(
            f"/stores/{store['id']}/marketing/campaigns/{draft['id']}/regenerate",
            headers=headers,
        )
        assert regenerated.status_code == 200
        assert regenerated.json()["status"] == "generated"
        assert regenerated.json()["creatives"]

        deleted = await client.delete(
            f"/stores/{store['id']}/marketing/campaigns/{draft['id']}", headers=headers,
        )
        assert deleted.status_code == 200
        assert (await client.get(
            f"/stores/{store['id']}/marketing/campaigns", headers=headers,
        )).json()["total"] == 0

    async def test_a_provider_failure_falls_back_without_losing_the_campaign(self, client, monkeypatch):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Fallback Shop", slug="fallback-shop")
        listing = await _listing(client, headers, store["id"], name="Fallback Item")

        async def broken(prompt):
            raise RuntimeError("provider is down")

        import api.domains.stores.marketing as marketing
        monkeypatch.setattr(marketing, "_provider_available", lambda: "gemini")
        monkeypatch.setattr(marketing, "_call_gemini", broken)

        r = await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=headers,
        )
        assert r.status_code == 201, r.text
        body = r.json()
        assert body["status"] == "generated"
        assert body["creatives"]
        assert body["generation"]["fallback"] is True
        # Saved and readable afterwards - a failed model call is not a lost
        # campaign.
        again = await client.get(
            f"/stores/{store['id']}/marketing/campaigns/{body['id']}", headers=headers,
        )
        assert again.status_code == 200
        assert len(again.json()["creatives"]) == len(body["creatives"])

    async def test_a_failed_regenerate_keeps_the_seller_s_edited_posts(self, client, monkeypatch):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Edits Shop", slug="edits-shop")
        listing = await _listing(client, headers, store["id"], name="Edited Item")
        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=headers,
        )).json()
        creative = campaign["creatives"][0]
        edited = "My own caption, written by hand at KES 2,500."
        assert (await client.patch(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}/creatives/{creative['id']}",
            json={"body": edited}, headers=headers,
        )).status_code == 200

        async def broken(prompt):
            raise RuntimeError("provider is down")

        import api.domains.stores.marketing as marketing
        monkeypatch.setattr(marketing, "_provider_available", lambda: "gemini")
        monkeypatch.setattr(marketing, "_call_gemini", broken)

        r = await client.post(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}/regenerate",
            headers=headers,
        )
        # Actionable failure, and the edited post is exactly as it was.
        assert r.status_code == 502
        assert "unchanged" in r.json()["detail"]
        kept = (await client.get(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}", headers=headers,
        )).json()
        assert [c["body"] for c in kept["creatives"] if c["id"] == creative["id"]] == [edited]

    async def test_an_unusable_provider_answer_also_keeps_edited_posts(self, client, monkeypatch):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Garbled Shop", slug="garbled-shop")
        listing = await _listing(client, headers, store["id"], name="Garbled Item")
        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=headers,
        )).json()
        creative = campaign["creatives"][0]
        edited = "Hand-written caption with the true price KES 2,500."
        await client.patch(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}/creatives/{creative['id']}",
            json={"body": edited}, headers=headers,
        )

        async def garbled(prompt):
            return "not json at all"

        import api.domains.stores.marketing as marketing
        monkeypatch.setattr(marketing, "_provider_available", lambda: "gemini")
        monkeypatch.setattr(marketing, "_call_gemini", garbled)

        r = await client.post(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}/regenerate",
            headers=headers,
        )
        assert r.status_code == 502
        kept = (await client.get(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}", headers=headers,
        )).json()
        assert [c["body"] for c in kept["creatives"] if c["id"] == creative["id"]] == [edited]

    async def test_editing_a_poster_backed_creative_redraws_the_image(self, client):
        from api.models.media import AttachState, MediaAsset

        _, headers = await _register(client)
        store = await _store(client, headers, name="Redraw Shop", slug="redraw-shop")
        upload = await client.post(
            "/media/images", headers=headers, data={"purpose": "listing_photo"},
            files={"file": ("photo.jpg", _jpeg(), "image/jpeg")},
        )
        assert upload.status_code == 201, upload.text
        listing = (await client.post("/listings/", json={
            "description": "Brand new, sealed in the box with a one-year shop receipt. "
                           "Works on all Kenyan networks.",
            "name": "Redraw Item", "category": "Electronics", "price": 3200,
            "lat": -1.0, "lng": 36.0, "store_id": store["id"],
            "photo_ids": [upload.json()["id"]],
        }, headers=headers)).json()

        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=headers,
        )).json()
        creative = campaign["creatives"][0]
        assert creative["asset"], "a campaign with a real photo gets a poster"
        old_asset = creative["asset"]["id"]

        edited = "Now KES 2,900 - the shop's own words."
        r = await client.patch(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}/creatives/{creative['id']}",
            json={"body": edited}, headers=headers,
        )
        assert r.status_code == 200, r.text
        updated = next(c for c in r.json()["creatives"] if c["id"] == creative["id"])
        # The saved image says what the post now says: a new file, not the
        # old one that still carries the previous caption.
        assert updated["asset"]["id"] != old_asset

        async with AsyncSessionLocal() as db:
            old = (await db.execute(
                select(MediaAsset).where(MediaAsset.id == old_asset)
            )).scalar_one()
        assert old.attach_state in (AttachState.DELETING, AttachState.PURGED)

    async def test_a_campaign_poster_is_retired_when_the_campaign_is_deleted(self, client):
        from api.models.media import AttachState, MediaAsset, MediaPurpose

        _, headers = await _register(client)
        store = await _store(client, headers, name="Poster Shop", slug="poster-shop")
        listing = await _listing(client, headers, store["id"], name="Poster Item")
        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=headers,
        )).json()

        # A poster asset standing in for the rendered PNG (no object storage
        # in the test): the row is what the sweep reads.
        async with AsyncSessionLocal() as db:
            asset = MediaAsset(
                owner_id=(await db.execute(
                    select(Store).where(Store.id == store["id"])
                )).scalar_one().owner_id,
                purpose=MediaPurpose.MARKETING_CREATIVE, storage="db",
                width=1080, height=1080, sha256="0" * 64, variants="{}",
                attach_state=AttachState.ATTACHED,
            )
            db.add(asset)
            await db.flush()
            await db.execute(
                update(MarketingCreative)
                .where(MarketingCreative.campaign_id == campaign["id"])
                .values(asset_id=asset.id)
            )
            await db.commit()
            asset_id = asset.id

        assert (await client.delete(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}", headers=headers,
        )).status_code == 200

        async with AsyncSessionLocal() as db:
            row = (await db.execute(
                select(MediaAsset).where(MediaAsset.id == asset_id)
            )).scalar_one()
        # Queued for the media sweep, not left attached forever.
        assert row.attach_state == AttachState.DELETING
        assert row.deleted_at is not None

    async def test_download_and_share_events_are_counted_as_actions(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Events Shop", slug="events-shop")
        listing = await _listing(client, headers, store["id"], name="Event Item")
        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=headers,
        )).json()
        r = await client.post(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}/events",
            json={"kind": "shared", "platform": "whatsapp"}, headers=headers,
        )
        assert r.status_code == 200
        assert r.json()["by_kind"]["shared"] == 1
        assert "impressions" in r.json()["not_measured"]
        assert "sales" in r.json()["not_measured"]

    async def test_a_campaign_link_visit_is_attributed_and_unknown_tokens_are_not(self, client):
        _, owner = await _register(client)
        _, buyer = await _register(client, tier=None)
        store = await _store(client, owner, name="Attribution Shop", slug="attribution-shop")
        listing = await _listing(client, owner, store["id"], name="Attributed Item")
        campaign = (await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json=_campaign_body(store, listing), headers=owner,
        )).json()

        visited = await client.post(
            f"/stores/{store['id']}/visit",
            json={"via": "whatsapp", "campaign": campaign["link_token"], "visitor": "buyer-visit-01"},
            headers=buyer,
        )
        assert visited.status_code == 202
        assert visited.json()["counted"] is True

        seen = (await client.get(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}", headers=owner,
        )).json()
        assert seen["events"]["by_kind"]["visit"] >= 1

        # A product view from a storefront carrying the token.
        pv = await client.post(
            f"/stores/{store['id']}/campaign/{campaign['link_token']}/event",
            json={"kind": "product_view"},
        )
        assert pv.status_code == 202
        assert pv.json()["counted"] is True
        later = (await client.get(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}", headers=owner,
        )).json()
        assert later["events"]["by_kind"]["product_view"] >= 1

        # A product page opened from a campaign link credits the product
        # view in the same counted visit - and a reload inside the visit
        # window credits nothing, so it cannot be inflated.
        _, reader = await _register(client, tier=None)
        pv1 = await client.post(
            f"/stores/{store['id']}/visit",
            json={"via": "tiktok", "campaign": campaign["link_token"],
                  "product_view": True, "visitor": "buyer-prodview-1"},
            headers=reader,
        )
        assert pv1.status_code == 202
        assert pv1.json()["counted"] is True
        pv2 = await client.post(
            f"/stores/{store['id']}/visit",
            json={"via": "tiktok", "campaign": campaign["link_token"],
                  "product_view": True, "visitor": "buyer-prodview-1"},
            headers=reader,
        )
        assert pv2.json()["counted"] is False
        after = (await client.get(
            f"/stores/{store['id']}/marketing/campaigns/{campaign['id']}", headers=owner,
        )).json()
        assert after["events"]["by_kind"]["product_view"] == later["events"]["by_kind"]["product_view"] + 1

        # Another store cannot be credited with this campaign's token.
        _, other = await _register(client)
        other_store = await _store(client, other, name="Wrong Store", slug="wrong-store")
        wrong = await client.post(
            f"/stores/{other_store['id']}/campaign/{campaign['link_token']}/event",
            json={"kind": "visit"},
        )
        assert wrong.status_code == 202
        assert wrong.json()["counted"] is False

    async def test_copywriter_suggests_without_a_provider_and_never_edits(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Copy Shop", slug="copy-shop")
        listing = await _listing(client, headers, store["id"], name="Copy Item")
        r = await client.post(
            f"/stores/{store['id']}/marketing/copy",
            json={"field": "title", "listing_id": listing["id"]}, headers=headers,
        )
        assert r.status_code == 200
        assert r.json()["available"] is False
        assert r.json()["suggestions"] == []
        assert (await client.get(f"/listings/{listing['id']}")).json()["name"] == "Copy Item"

    async def test_the_owner_can_save_a_draft_without_a_provider(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Draft Shop", slug="draft-shop")
        r = await client.post(
            f"/stores/{store['id']}/marketing/campaigns",
            json={
                "title": "Draft only", "objective": "storefront",
                "platforms": ["x"], "language": "sw", "generate": False,
            },
            headers=headers,
        )
        assert r.status_code == 201
        assert r.json()["language"] == "sw"
        assert r.json()["creatives"] == []
