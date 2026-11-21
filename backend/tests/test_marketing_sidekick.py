"""The AI Marketing Sidekick, platform playbooks, video scripts and Meta Ads
guidance.

Every test drives the real HTTP API against a real (SQLite) database. The AI
provider is never called for real: it is absent, replaced with canned output,
or made to fail - and the Sidekick still has to answer honestly from the
seller's catalogue.
"""
import io
import itertools

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine
from api.domains.stores import marketing as marketing_module
from api.domains.stores import marketing_sidekick as sidekick
from tests.legal_payload import legal_payload


def _jpeg() -> bytes:
    from PIL import Image

    buffer = io.BytesIO()
    Image.new("RGB", (320, 240), (30, 60, 120)).save(buffer, format="JPEG")
    return buffer.getvalue()


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_marketing_sidekick.db"
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


async def _register(client):
    n = next(_n)
    phone = f"0747{n:06d}"
    code = (await client.post("/auth/otp/request", json={"phone": phone})).json()["debug_code"]
    token = (await client.post("/auth/otp/verify", json={"phone": phone, "code": code})).json()[
        "phone_verify_token"]
    reg = await client.post("/auth/register", json={
        "phone_verify_token": token, "name": f"Sidekick Seller {n}",
        "password": "Passw0rd!x", "lat": -1.286, "lng": 36.817,
        "legal_acceptance": legal_payload(), "account_type": "buyer_seller",
        "seller_tier": "long_term", "business_name": f"Biz {n}",
        "business_category": "Electronics", "business_location": "Nairobi",
    })
    assert reg.status_code == 201, reg.text
    return reg.json()["user_id"], {"Authorization": f"Bearer {reg.json()['access_token']}"}


async def _store(client, headers, **fields):
    body = {"name": f"Sidekick Shop {next(_n)}", **fields}
    if "slug" in body and "photos" not in body and "photo_ids" not in body:
        body["photos"] = [_SHOP_PHOTO]
    r = await client.post("/stores", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _listing(client, headers, store_id, name="Solar Lantern", price=2500,
                   category="Electronics"):
    r = await client.post("/listings/", json={
        "description": "Brand new, sealed in the box. Works on all Kenyan networks.",
        "name": name, "category": category, "price": price,
        "lat": -1.0, "lng": 36.0, "store_id": store_id,
    }, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


def _campaign_body(store, listing, **overrides):
    body = {
        "objective": "product",
        "product_ids": [listing["id"]],
        "platforms": ["whatsapp", "instagram"],
        "language": "en",
        "generate": True,
    }
    body.update(overrides)
    return body


@pytest.mark.asyncio
class TestSidekickChat:
    async def test_it_answers_from_the_store_and_its_real_catalogue(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Kisumu Kicks", slug="kisumu-kicks",
                             store_type="virtual", service_areas=["Nairobi"],
                             description="Quality shoes for everyday wear.")
        listing = await _listing(client, headers, store["id"], name="Canvas Sneaker",
                                 price=3200, category="Fashion")

        r = await client.post(
            f"/stores/{store['id']}/marketing/sidekick",
            json={"message": "How should I market my store this week?",
                  "platform": "instagram"},
            headers=headers,
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["reply"]
        assert body["available"] is False
        assert body["fallback_reason"]
        # Real facts from the catalogue, not a generated product.
        assert "Canvas Sneaker" in body["reply"]
        assert "3,200" in body["reply"]
        assert "Kisumu Kicks" in body["reply"]
        # Instagram's own advice, not WhatsApp's.
        assert "Instagram" in body["reply"]
        assert body["products"][0]["id"] == listing["id"]
        # The next step is a real tool with this product already chosen.
        action = next(a for a in body["actions"] if a["type"] == "creative_studio")
        assert action["product_id"] == listing["id"]
        assert action["platform"] == "instagram"
        assert body["suggestions"]

    async def test_another_seller_cannot_use_this_store(self, client):
        _, owner = await _register(client)
        _, other = await _register(client)
        store = await _store(client, owner, name="Private Sidekick", slug="private-sidekick",
                            store_type="virtual", service_areas=["Nairobi"])
        r = await client.post(
            f"/stores/{store['id']}/marketing/sidekick",
            json={"message": "How should I market this store?"},
            headers=other,
        )
        assert r.status_code == 403
        assert (await client.post(
            f"/stores/{store['id']}/marketing/sidekick",
            json={"message": "How should I market this store?"},
        )).status_code == 401

    async def test_a_product_from_another_store_is_refused(self, client):
        _, mine = await _register(client)
        _, other = await _register(client)
        store = await _store(client, mine, name="Action Shop", slug="action-shop",
                            store_type="virtual", service_areas=["Nairobi"])
        theirs = await _store(client, other, name="Other Shop", slug="other-shop",
                             store_type="virtual", service_areas=["Nairobi"])
        not_mine = await _listing(client, other, theirs["id"], name="Not Mine")
        r = await client.post(
            f"/stores/{store['id']}/marketing/sidekick",
            json={"message": "Promote this product", "product_ids": [not_mine["id"]]},
            headers=mine,
        )
        assert r.status_code == 400
        assert "aren't in this store" in r.json()["detail"]

    async def test_provider_output_is_used_when_it_supports_the_catalogue(
            self, client, monkeypatch):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Tailor Shop", slug="tailor-shop",
                            store_type="virtual", service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Kikoi Scarf", price=1500,
                       category="Fashion")

        async def good(prompt, reply_tokens=900):
            assert "Kikoi Scarf" in prompt
            assert "KES 1,500" in prompt or "1500" in prompt
            return "gemini", (
                "Start with the Kikoi Scarf at KES 1,500 in your store. Post a close-up "
                "photo on Instagram, then share the store link. Ask buyers to message you."
            )

        monkeypatch.setattr(marketing_module, "_provider_available", lambda: "gemini")
        monkeypatch.setattr(sidekick, "_ask_model", good)

        body = (await client.post(
            f"/stores/{store['id']}/marketing/sidekick",
            json={"message": "What should I post this week?", "platform": "instagram"},
            headers=headers,
        )).json()
        assert body["available"] is True and body["provider"] == "gemini"
        assert body["reply"].startswith("Start with the Kikoi Scarf")
        assert body["fallback_reason"] is None

    async def test_an_invented_price_is_dropped_for_honest_guidance(
            self, client, monkeypatch):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Price Guard Shop", slug="price-guard-shop",
                            store_type="virtual", service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Table Fan", price=1800)

        async def inventing(prompt, reply_tokens=900):
            return "gemini", "Sell the Table Fan at only KES 999 this week with free delivery."

        monkeypatch.setattr(marketing_module, "_provider_available", lambda: "gemini")
        monkeypatch.setattr(sidekick, "_ask_model", inventing)

        body = (await client.post(
            f"/stores/{store['id']}/marketing/sidekick",
            json={"message": "How do I market this?"},
            headers=headers,
        )).json()
        assert body["available"] is False
        assert "999" not in body["reply"]
        assert "do not support" in body["fallback_reason"]
        assert "1,800" in body["reply"]

    async def test_a_provider_failure_is_reported_not_hidden(self, client, monkeypatch):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Outage Shop", slug="outage-shop",
                            store_type="virtual", service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Thermos Flask", price=1200)

        async def broken(prompt, reply_tokens=900):
            raise RuntimeError("provider is down")

        monkeypatch.setattr(marketing_module, "_provider_available", lambda: "deepseek")
        monkeypatch.setattr(sidekick, "_ask_model", broken)

        r = await client.post(
            f"/stores/{store['id']}/marketing/sidekick",
            json={"message": "Which platform suits my business?"},
            headers=headers,
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["available"] is False
        assert "didn't answer" in body["fallback_reason"]
        assert "Thermos Flask" in body["reply"]
        # Honest about BROKA's role in every answer.
        assert "does not post" in body["reply"]


@pytest.mark.asyncio
class TestPlatformGuides:
    async def test_each_platform_gets_its_own_guidance(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Guide Shop", slug="guide-shop",
                            store_type="virtual", service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Ankara Dress", price=2800,
                       category="Fashion")

        instagram = (await client.get(
            f"/stores/{store['id']}/marketing/platforms/instagram/guide", headers=headers,
        )).json()
        tiktok = (await client.get(
            f"/stores/{store['id']}/marketing/platforms/tiktok/guide", headers=headers,
        )).json()
        assert instagram["label"] == "Instagram"
        assert tiktok["label"] == "TikTok"
        assert instagram["summary"] != tiktok["summary"]
        insta_text = " ".join(s["summary"] for s in instagram["sections"])
        tiktok_text = " ".join(s["summary"] for s in tiktok["sections"])
        assert insta_text != tiktok_text
        # Every section the brief asks for is present on both.
        keys = {s["key"] for s in instagram["sections"]}
        assert {"content", "engaging", "promotion", "reach", "cta",
                "organic", "paid"} <= keys
        # The caption starter uses the real product and price.
        assert instagram["example"]["body"].startswith("Ankara Dress")
        assert "2,800" in instagram["example"]["body"]
        assert instagram["example"]["hashtags"]
        assert "does not post" in instagram["note"]

    async def test_an_unsupported_platform_is_a_clear_404(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Unknown Platform", slug="unknown-platform",
                            store_type="virtual", service_areas=["Nairobi"])
        r = await client.get(
            f"/stores/{store['id']}/marketing/platforms/myspace/guide", headers=headers,
        )
        assert r.status_code == 404
        assert "not supported" in r.json()["detail"]

    async def test_the_guide_is_owner_only(self, client):
        _, owner = await _register(client)
        _, other = await _register(client)
        store = await _store(client, owner, name="Guide Owner", slug="guide-owner",
                            store_type="virtual", service_areas=["Nairobi"])
        r = await client.get(
            f"/stores/{store['id']}/marketing/platforms/whatsapp/guide", headers=other,
        )
        assert r.status_code == 403


@pytest.mark.asyncio
class TestVideoScripts:
    async def test_it_returns_a_labelled_storyboard_not_a_video(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Reel Shop", slug="reel-shop",
                            store_type="virtual", service_areas=["Nairobi"])
        listing = await _listing(client, headers, store["id"], name="Beaded Sandal",
                                 price=2200, category="Fashion")
        r = await client.post(
            f"/stores/{store['id']}/marketing/video-script",
            json={"platform": "instagram", "kind": "storyboard",
                  "product_ids": [listing["id"]]},
            headers=headers,
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["is_video"] is False
        assert "not filmed" in body["disclaimer"]
        assert body["label"].startswith("Instagram")
        assert len(body["scenes"]) >= 3
        assert all(s["shot"] for s in body["scenes"])
        assert body["duration_seconds"] > 0
        assert body["aspect_ratio"] == "9:16"
        assert "Beaded Sandal" in body["caption"]
        assert body["provider"] == "template"
        assert all("Beaded Sandal" in s["shot"] or s["voice_over"] for s in body["scenes"])

    async def test_facebook_gets_a_different_script_from_tiktok(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Two Platform Shop",
                            slug="two-platform-shop", store_type="virtual",
                            service_areas=["Nairobi"])
        listing = await _listing(client, headers, store["id"], name="Desk Lamp", price=1400)
        tiktok = (await client.post(
            f"/stores/{store['id']}/marketing/video-script",
            json={"platform": "tiktok", "kind": "concept",
                  "product_ids": [listing["id"]]}, headers=headers,
        )).json()
        facebook = (await client.post(
            f"/stores/{store['id']}/marketing/video-script",
            json={"platform": "facebook", "kind": "script",
                  "product_ids": [listing["id"]]}, headers=headers,
        )).json()
        assert tiktok["aspect_ratio"] == "9:16"
        assert facebook["aspect_ratio"] == "1:1"
        assert tiktok["label"] != facebook["label"]
        assert tiktok["duration_seconds"] != facebook["duration_seconds"]

    async def test_an_invented_claim_in_a_script_is_replaced(self, client, monkeypatch):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Script Guard Shop",
                            slug="script-guard-shop", store_type="virtual",
                            service_areas=["Nairobi"])
        listing = await _listing(client, headers, store["id"], name="Ceramic Mug", price=900)

        async def inventing(prompt, reply_tokens=900):
            import json as _json
            return "gemini", _json.dumps({
                "title": "Mug warranty",
                "hook": "This mug has a two-year warranty",
                "scenes": [
                    {"shot": "Hold the mug", "on_screen_text": "Ceramic Mug",
                     "voice_over": "A two-year warranty", "seconds": 3},
                    {"shot": "Fill it", "on_screen_text": "KES 900",
                     "voice_over": "Only KES 900", "seconds": 5},
                    {"shot": "End card", "on_screen_text": "Open the store",
                     "voice_over": "Open the store", "seconds": 4},
                ],
                "caption": "Ceramic Mug with a two-year warranty.",
                "hashtags": ["BROKA"], "cta": "Open the store",
            })

        monkeypatch.setattr(marketing_module, "_provider_available", lambda: "gemini")
        monkeypatch.setattr(sidekick, "_ask_model", inventing)

        body = (await client.post(
            f"/stores/{store['id']}/marketing/video-script",
            json={"platform": "tiktok", "kind": "script",
                  "product_ids": [listing["id"]]}, headers=headers,
        )).json()
        assert body["provider"] == "template"
        assert "warranty" not in body["caption"].lower()
        assert "do not support" in body["fallback_reason"]

    async def test_only_video_platforms_are_accepted(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Video Platform Shop",
                            slug="video-platform-shop", store_type="virtual",
                            service_areas=["Nairobi"])
        r = await client.post(
            f"/stores/{store['id']}/marketing/video-script",
            json={"platform": "whatsapp", "kind": "script"}, headers=headers,
        )
        assert r.status_code == 422


@pytest.mark.asyncio
class TestMetaAdsGuidance:
    async def test_the_plan_never_pretends_a_campaign_exists(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Ads Shop", slug="ads-shop",
                            store_type="physical", county="Kisumu",
                            subcounty="Kisumu Central", service_areas=["Nationwide"])
        listing = await _listing(client, headers, store["id"], name="Office Chair",
                                 price=4500, category="Home & Furniture")

        r = await client.post(
            f"/stores/{store['id']}/marketing/ads-plan",
            json={"product_id": listing["id"], "objective": "traffic"},
            headers=headers,
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["campaign_created"] is False
        assert body["currency"] == "KES"
        assert "has not created or published" in body["disclaimer"]
        assert body["manager_url"].startswith("https://adsmanager.facebook.com/")
        assert body["product"]["name"] == "Office Chair"
        # No budget was given, so none is invented - not even from the price.
        assert body["budget"]["specified"] is False
        assert body["budget"]["daily_kes"] is None
        assert body["budget"]["total_kes"] is None
        keys = [stage["key"] for stage in body["stages"]]
        assert keys == ["objective", "audience", "location", "budget", "creative",
                        "placements", "review", "launch"]
        assert all(stage["steps"] for stage in body["stages"])
        assert "Kisumu" in body["location"]

    async def test_a_virtual_store_is_not_given_a_shop_radius(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Virtual Ads Shop",
                            slug="virtual-ads-shop", store_type="virtual",
                            service_areas=["Mombasa"])
        await _listing(client, headers, store["id"], name="Beach Bag", price=1000)
        body = (await client.post(
            f"/stores/{store['id']}/marketing/ads-plan",
            json={"objective": "engagement"}, headers=headers,
        )).json()
        assert "Mombasa" in body["location"]
        assert body["objective_label"] == "Engagement"

    async def test_a_product_from_another_store_is_refused(self, client):
        _, mine = await _register(client)
        _, other = await _register(client)
        store = await _store(client, mine, name="Ads Mine", slug="ads-mine",
                            store_type="virtual", service_areas=["Nairobi"])
        theirs = await _store(client, other, name="Ads Theirs", slug="ads-theirs",
                             store_type="virtual", service_areas=["Nairobi"])
        listing = await _listing(client, other, theirs["id"], name="Their Chair")
        r = await client.post(
            f"/stores/{store['id']}/marketing/ads-plan",
            json={"product_id": listing["id"]}, headers=mine,
        )
        assert r.status_code == 400
        assert "aren't in this store" in r.json()["detail"]

    async def test_a_seller_chosen_budget_is_kept(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Budget Shop", slug="budget-shop",
                            store_type="virtual", service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Budget Item", price=2000)
        body = (await client.post(
            f"/stores/{store['id']}/marketing/ads-plan",
            json={"objective": "sales", "budget_kes": 750}, headers=headers,
        )).json()
        assert body["budget"]["specified"] is True
        assert body["budget"]["daily_kes"] == 750
        assert body["budget"]["total_kes"] == 3750
        budget_stage = next(s for s in body["stages"] if s["key"] == "budget")
        assert "KES 750" in budget_stage["summary"]
        assert budget_stage["suggestion"] == "KES 750 / day"

    async def test_an_unusual_but_real_budget_is_not_rounded(self, client):
        """The seller's number is theirs: no minimum padding, no rounding."""
        _, headers = await _register(client)
        store = await _store(client, headers, name="Odd Budget Shop",
                            slug="odd-budget-shop", store_type="virtual",
                            service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Odd Item", price=2000)
        body = (await client.post(
            f"/stores/{store['id']}/marketing/ads-plan",
            json={"budget_kes": 137}, headers=headers,
        )).json()
        assert body["budget"]["daily_kes"] == 137
        assert body["budget"]["total_kes"] == 685

    async def test_no_budget_is_inferred_from_the_product_price(self, client):
        """A price cannot tell us what a seller can afford to advertise with."""
        _, headers = await _register(client)
        store = await _store(client, headers, name="Pricey Shop", slug="pricey-shop",
                            store_type="virtual", service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Leather Sofa",
                       price=85000, category="Home & Furniture")
        body = (await client.post(
            f"/stores/{store['id']}/marketing/ads-plan",
            json={"objective": "traffic"}, headers=headers,
        )).json()
        budget = body["budget"]
        assert budget["specified"] is False
        assert budget["daily_kes"] is None
        assert budget["total_kes"] is None
        assert "No daily budget" in budget["note"]
        budget_stage = next(s for s in body["stages"] if s["key"] == "budget")
        assert budget_stage["suggestion"] == "Not selected yet"
        assert "No daily budget chosen yet" in budget_stage["summary"]
        # Neither the old 20% formula nor its KES 3,000 ceiling appears.
        assert "3,000" not in budget_stage["summary"]
        assert "17,000" not in budget_stage["summary"]
        review = next(s for s in body["stages"] if s["key"] == "review")
        assert any("Set the daily budget" in step for step in review["steps"])

    async def test_sales_guidance_does_not_promise_purchase_tracking(self, client):
        """There is no Meta Pixel or Conversions API here, so the plan says so."""
        _, headers = await _register(client)
        store = await _store(client, headers, name="Tracking Shop",
                            slug="tracking-shop", store_type="virtual",
                            service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Tracking Item", price=3000)
        body = (await client.post(
            f"/stores/{store['id']}/marketing/ads-plan",
            json={"objective": "sales", "budget_kes": 500}, headers=headers,
        )).json()
        tracking = body["tracking"]
        assert tracking["website_purchases_measured"] is False
        assert tracking["setup_required"] is True
        assert "does not send purchase events" in tracking["summary"]
        assert any("Pixel" in step for step in tracking["steps"])
        assert any("not a payment" in step for step in tracking["steps"])
        options = {o["value"]: o for o in body["objective_options"]}
        assert options["sales"]["needs_tracking"] is True
        assert options["traffic"]["needs_tracking"] is False
        objective_stage = next(s for s in body["stages"] if s["key"] == "objective")
        assert any("does not send purchase events" in s
                   for s in objective_stage["steps"])
        assert "not a payment" in body["disclaimer"]

    async def test_a_traffic_plan_does_not_claim_purchase_measurement(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Traffic Shop", slug="traffic-shop",
                            store_type="virtual", service_areas=["Nairobi"])
        await _listing(client, headers, store["id"], name="Traffic Item", price=3000)
        body = (await client.post(
            f"/stores/{store['id']}/marketing/ads-plan",
            json={"objective": "traffic"}, headers=headers,
        )).json()
        assert body["tracking"]["website_purchases_measured"] is False
        objective_stage = next(s for s in body["stages"] if s["key"] == "objective")
        assert not any("does not send purchase events" in s
                       for s in objective_stage["steps"])


def test_the_prompt_carries_store_facts_and_the_payment_boundary():
    """The model is told what it may state, and what BROKA does not do. This
    is the prompt half of the honesty guarantee the output check backs up."""

    class FakeStore:
        name = "Prompt Shop"
        category = "Fashion"
        description = "Handmade bags."
        store_type = "virtual"
        county = "Nairobi"
        subcounty = "Westlands"
        service_areas = '["Nationwide"]'
        delivery_note = None

    products = [{
        "id": "l1", "name": "Woven Bag", "price": 2500.0, "price_unit": None,
        "category": "Fashion", "description": "Hand-woven sisal bag.",
        "brand": None, "image": None, "image_asset_id": None,
        "condition": "new",
    }]
    prompt = sidekick._chat_prompt(
        FakeStore(), products, [], "instagram", [], "How do I market this?", "en",
    )
    assert "Woven Bag" in prompt
    assert "KES 2,500" in prompt
    assert "Instagram" in prompt
    assert "does not process buyer-to-seller payments" in prompt
    assert "Never invent a price" in prompt
