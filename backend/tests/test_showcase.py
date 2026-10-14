"""
BROKA - AI Showcase/Cover Image Tests
Covers: location_name derivation from county/subcounty, ownership checks,
AI covers as a premium allowance (off while PREMIUM_ENABLED is off; one
free try, then a plan's, when it is on), and the set/remove/generate flows.
The model is mocked at the api.core.hf_image_client boundary - its
HTTP/polling contract is covered in test_listing_overhaul.py's
TestHfImageClient.

Run: pytest backend/tests/test_showcase.py -v
"""
import itertools
from unittest.mock import patch

import pytest
import pytest_asyncio

from api.database import init_db, reset_engine, AsyncSessionLocal, User, Listing
from api.domains.listings.service import _derive_location_name, ListingService
from api.domains.showcase import service as showcase_service
from api.core import hf_image_client
from fastapi import HTTPException


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_showcase.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


def _jpeg_data_uri() -> str:
    import base64
    import io
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (200, 30, 30)).save(buf, format="JPEG")
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


_phone_seq = itertools.count()  # see test_completion_rate.py for why a counter, not a timestamp


async def _make_user(db, name="Seller", is_premium=False) -> User:
    u = User(name=name, phone=f"07{next(_phone_seq):08d}", password_hash="x",
              phone_verified=True, is_premium=is_premium)
    db.add(u)
    await db.flush()
    return u


async def _make_listing(db, seller_id, verified_photos="QUJDRA==") -> Listing:
    l = Listing(seller_id=seller_id, name="TVS Motorbike", category="Vehicles",
                price=50_000.0, lat=-1.28, lng=36.82, verified_photos=verified_photos)
    db.add(l)
    await db.flush()
    return l


# ── location_name derivation ─────────────────────────────────────────────────

class TestDeriveLocationName:
    def test_combines_subcounty_and_county(self):
        assert _derive_location_name("Nairobi", "Kilimani", None) == "Kilimani, Nairobi"

    def test_subcounty_only(self):
        assert _derive_location_name(None, "Kilimani", None) == "Kilimani"

    def test_county_only(self):
        assert _derive_location_name("Nairobi", None, None) == "Nairobi"

    def test_falls_back_to_legacy_location_name_when_neither_given(self):
        assert _derive_location_name(None, None, "Westlands, Nairobi") == "Westlands, Nairobi"

    def test_blank_strings_treated_as_absent(self):
        assert _derive_location_name("  ", "  ", "fallback") == "fallback"

    def test_nothing_given_returns_none(self):
        assert _derive_location_name(None, None, None) is None


# ── ownership + premium gate ─────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_get_owned_listing_404_for_missing_listing():
    async with AsyncSessionLocal() as db:
        with pytest.raises(HTTPException) as exc:
            await showcase_service._get_owned_listing(db, "does-not-exist", "someone")
        assert exc.value.status_code == 404


@pytest.mark.asyncio
async def test_get_owned_listing_403_for_wrong_seller():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Real Seller")
        other = await _make_user(db, "Not The Seller")
        listing = await _make_listing(db, seller.id)
        await db.commit()

        with pytest.raises(HTTPException) as exc:
            await showcase_service._get_owned_listing(db, listing.id, other.id)
        assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_get_owned_listing_succeeds_for_actual_seller():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Real Seller 2")
        listing = await _make_listing(db, seller.id)
        await db.commit()

        result = await showcase_service._get_owned_listing(db, listing.id, seller.id)
        assert result.id == listing.id


# AI covers are premium (PRICING.md): the showcase spends one of the seller's
# AI cover tries per generation, through api/domains/premium/entitlements.

def _premium_on():
    import dataclasses
    from api.core.config import settings
    return patch("api.domains.premium.entitlements.settings",
                 dataclasses.replace(settings, premium_enabled=True))


def _model_ok():
    return (patch("api.domains.showcase.service.hf_image_client.generate_showcase_image_url",
                  return_value="https://fal.media/fake.png"),
            patch("api.domains.showcase.service.hf_image_client.download_generated_image",
                  return_value=(b"RAWBYTES", "image/jpeg")))


async def _generate(db, seller_id):
    return await showcase_service.generate_showcase_preview_standalone(
        db, seller_id, _jpeg_data_uri(), "Sofa", "Home & Furniture", None, None, None,
    )


@pytest.mark.asyncio
async def test_ai_covers_are_off_while_premium_is_off():
    """With PREMIUM_ENABLED off nothing is counted, so every cover used to
    be a paid generation for anyone, with no plan to pay for it."""
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Free Seller")
        await db.commit()
        gen, dl = _model_ok()
        with gen as generate, dl:
            with pytest.raises(HTTPException) as exc:
                await _generate(db, seller.id)
        assert exc.value.status_code == 503
        assert exc.value.detail["code"] == "SHOWCASE_UNAVAILABLE"
        assert "gallery" in exc.value.detail["message"]
        generate.assert_not_called()


@pytest.mark.asyncio
async def test_one_free_try_then_a_plan_is_needed():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Trial Seller")
        await db.commit()
        gen, dl = _model_ok()
        with _premium_on(), gen, dl:
            await _generate(db, seller.id)
            with pytest.raises(HTTPException) as exc:
                await _generate(db, seller.id)
        assert exc.value.status_code == 402
        assert exc.value.detail["code"] == "ALLOWANCE_USED"
        assert exc.value.detail["upgrade_to"] == "plus"
        assert "gallery" in exc.value.detail["message"]


@pytest.mark.asyncio
async def test_a_plan_gives_its_months_tries():
    from datetime import datetime, timedelta
    from api.domains.pricing.plans import PREMIUM_BY_ID
    from api.models.subscription import Subscription
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Plus Seller")
        now = datetime.utcnow()
        db.add(Subscription(user_id=seller.id, plan_id="plus", started_at=now,
                            paid_until=now + timedelta(days=30)))
        await db.commit()
        gen, dl = _model_ok()
        with _premium_on(), gen, dl:
            for _ in range(PREMIUM_BY_ID["plus"].ai_covers):
                await _generate(db, seller.id)
            with pytest.raises(HTTPException) as exc:
                await _generate(db, seller.id)
        assert exc.value.status_code == 402
        assert exc.value.detail["plan"] == "plus" and exc.value.detail["upgrade_to"] == "pro"


@pytest.mark.asyncio
async def test_a_cover_the_model_failed_to_make_does_not_use_a_try():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Unlucky Seller")
        await db.commit()
        failing = patch("api.domains.showcase.service.hf_image_client.generate_showcase_image_url",
                        side_effect=hf_image_client.ImageGenerationError("model down", code="failed"))
        with _premium_on():
            with failing:
                for _ in range(3):
                    with pytest.raises(HTTPException) as exc:
                        await _generate(db, seller.id)
                    assert exc.value.status_code == 502
            gen, dl = _model_ok()
            with gen, dl:
                await _generate(db, seller.id)  # the free try is still there


# ── set / remove ──────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_set_showcase_image_persists_and_returns_it():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Setter Seller")
        listing = await _make_listing(db, seller.id)
        await db.commit()

        result = await showcase_service.set_showcase_image(
            db, listing.id, seller.id, "data:image/png;base64,AAAA", "gallery",
        )
        assert result["showcase_image_url"] == "data:image/png;base64,AAAA"
        assert result["showcase_image_source"] == "gallery"

        refreshed = await showcase_service._get_owned_listing(db, listing.id, seller.id)
        assert refreshed.showcase_image_url == "data:image/png;base64,AAAA"
        assert refreshed.showcase_image_source == "gallery"


@pytest.mark.asyncio
async def test_set_showcase_image_rejects_bad_source():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Setter Seller 2")
        listing = await _make_listing(db, seller.id)
        await db.commit()
        with pytest.raises(HTTPException) as exc:
            await showcase_service.set_showcase_image(db, listing.id, seller.id, "data:image/png;base64,AAAA", "made_up")
        assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_set_showcase_image_rejects_non_image_data():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Setter Seller 3")
        listing = await _make_listing(db, seller.id)
        await db.commit()
        with pytest.raises(HTTPException) as exc:
            await showcase_service.set_showcase_image(db, listing.id, seller.id, "not-a-data-uri", "gallery")
        assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_set_showcase_image_blocked_for_non_owner():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Setter Seller 4")
        other = await _make_user(db, "Not Setter Seller 4")
        listing = await _make_listing(db, seller.id)
        await db.commit()
        with pytest.raises(HTTPException) as exc:
            await showcase_service.set_showcase_image(db, listing.id, other.id, "data:image/png;base64,AAAA", "gallery")
        assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_remove_showcase_image_clears_both_fields_but_not_verified_photos():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Remover Seller")
        listing = await _make_listing(db, seller.id, verified_photos="realphoto==")
        await db.commit()
        await showcase_service.set_showcase_image(db, listing.id, seller.id, "data:image/png;base64,AAAA", "ai")

        result = await showcase_service.remove_showcase_image(db, listing.id, seller.id)
        assert result["showcase_image_url"] is None
        assert result["showcase_image_source"] is None

        refreshed = await showcase_service._get_owned_listing(db, listing.id, seller.id)
        assert refreshed.showcase_image_url is None
        assert refreshed.verified_photos == "realphoto=="  # untouched


# ── generate (model mocked) ─────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_generate_requires_actual_photos_first():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "No Photos Seller")
        listing = await _make_listing(db, seller.id, verified_photos=None)
        await db.commit()
        with pytest.raises(HTTPException) as exc:
            await showcase_service.generate_showcase_preview(db, listing.id, seller.id, "make it nice")
        assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_generate_does_not_persist_to_the_listing():
    """Spec requirement: generation is preview-only. Only set_showcase_image
    (a separate, explicit call) may write to the listing row."""
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Preview Seller")
        listing = await _make_listing(db, seller.id, verified_photos="cGhvdG8=")
        await db.commit()

        with _premium_on(), \
             patch("api.domains.showcase.service.hf_image_client.generate_showcase_image_url",
                    return_value="https://fal.media/fake.png"), \
             patch("api.domains.showcase.service.hf_image_client.download_generated_image",
                    return_value=(b"FAKEPNGDATA", "image/png")):
            result = await showcase_service.generate_showcase_preview(db, listing.id, seller.id, "cinematic lighting")

        assert result["image_data_uri"].startswith("data:image/png;base64,")
        assert "cinematic lighting" in result["prompt_used"]

        refreshed = await showcase_service._get_owned_listing(db, listing.id, seller.id)
        assert refreshed.showcase_image_url is None  # preview only - not saved


# ── standalone (pre-creation / wizard) generation path ──────────────────────

@pytest.mark.asyncio
async def test_standalone_generate_works_without_any_listing():
    """The wizard calls this before a Listing row exists at all - must not
    require or touch one."""
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Wizard Seller")
        await db.commit()

        with _premium_on(), \
             patch("api.domains.showcase.service.hf_image_client.generate_showcase_image_url",
                    return_value="https://fal.media/fake2.png"), \
             patch("api.domains.showcase.service.hf_image_client.download_generated_image",
                    return_value=(b"RAWBYTES", "image/jpeg")):
            # A real photo: anything else is refused before reaching the model
            # (test_listing_overhaul.py covers that).
            result = await showcase_service.generate_showcase_preview_standalone(
                db, seller.id, _jpeg_data_uri(),
                "iPhone 12", "Electronics", "used", 45000.0, "clean studio background",
            )

        assert result["image_data_uri"] == "data:image/jpeg;base64,UkFXQllURVM="
        assert "iPhone 12" in result["prompt_used"]
        assert "clean studio background" in result["prompt_used"]


@pytest.mark.asyncio
async def test_standalone_generate_requires_a_photo():
    async with AsyncSessionLocal() as db:
        seller = await _make_user(db, "Wizard Seller No Photo")
        await db.commit()
        with pytest.raises(HTTPException) as exc:
            await showcase_service.generate_showcase_preview_standalone(
                db, seller.id, "", "iPhone 12", "Electronics", None, None, None,
            )
        assert exc.value.status_code == 400


# ── create_listing: showcase fields set at creation time ───────────────────

class TestCreateListingWithShowcase:
    @pytest_asyncio.fixture
    async def svc_and_seller(self):
        async with AsyncSessionLocal() as db:
            seller = await _make_user(db, "Creator Seller")
            await db.commit()
            yield ListingService(db), seller

    @staticmethod
    def _base_payload(**overrides):
        payload = dict(name="Test Item", category="Electronics", price=1000.0, lat=-1.28, lng=36.82)
        payload.update(overrides)
        return payload

    @pytest.mark.asyncio
    async def test_creates_with_no_showcase_fields_at_all(self, svc_and_seller):
        svc, seller = svc_and_seller
        result = await svc.create_listing(seller.id, self._base_payload())
        assert result["showcase_image_url"] is None
        assert result["showcase_image_source"] is None

    @pytest.mark.asyncio
    async def test_creates_with_valid_gallery_showcase(self, svc_and_seller):
        svc, seller = svc_and_seller
        result = await svc.create_listing(seller.id, self._base_payload(
            showcase_image_url="data:image/png;base64,AAAA", showcase_image_source="gallery",
        ))
        assert result["showcase_image_url"] == "data:image/png;base64,AAAA"
        assert result["showcase_image_source"] == "gallery"

    @pytest.mark.asyncio
    async def test_rejects_url_without_source(self, svc_and_seller):
        svc, seller = svc_and_seller
        with pytest.raises(HTTPException) as exc:
            await svc.create_listing(seller.id, self._base_payload(showcase_image_url="data:image/png;base64,AAAA"))
        assert exc.value.status_code == 400

    @pytest.mark.asyncio
    async def test_rejects_source_without_url(self, svc_and_seller):
        svc, seller = svc_and_seller
        with pytest.raises(HTTPException) as exc:
            await svc.create_listing(seller.id, self._base_payload(showcase_image_source="ai"))
        assert exc.value.status_code == 400

    @pytest.mark.asyncio
    async def test_rejects_invalid_source_value(self, svc_and_seller):
        svc, seller = svc_and_seller
        with pytest.raises(HTTPException) as exc:
            await svc.create_listing(seller.id, self._base_payload(
                showcase_image_url="data:image/png;base64,AAAA", showcase_image_source="not_a_real_source",
            ))
        assert exc.value.status_code == 400
