"""BROKA with payments hidden (2026-10-09): VERIFIED_BADGE_ENABLED and
ESCROW_GUIDANCE_ENABLED off, as the app hides every way to a payment
(flutter_app payments_shown.dart).

What must hold:
  * the Verified badge can't be bought - an older build, which still
    offers it, is told why;
  * Zeno doesn't open verification or the escrow services, and doesn't
    suggest getting verified;
  * Zeno isn't told to recommend escrow whenever a price is agreed, or to
    send people to a "Pay with escrow" button the app no longer shows -
    while in-app payments stay off, it still knows BROKA holds no money.
With both on (the rest of the suite), everything is as before.
"""
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.domains.pricing import safe_payment
from api.domains.zeno_assistant import guides, intents
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_payments_hidden.db"
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


async def _user() -> tuple[str, dict]:
    u = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


class TestVerifiedBadgeOff:
    @pytest.mark.asyncio
    async def test_a_badge_cant_be_bought_and_an_old_build_is_told_why(self, client, payments_hidden):
        _, h = await _user()
        r = await client.post("/verify/purchase", headers=h, json={
            "tier": "basic", "phone_number": "0712345678"})
        assert r.status_code == 409, r.text
        detail = r.json()["detail"]
        assert detail["code"] == "VERIFIED_BADGE_OFF"
        assert "Verified badge" in detail["message"]

    # Switched on, a badge is bought as before: test_zetupay.py's
    # test_a_badge_is_paid_through_zetupay runs with it on (conftest).

    def test_zeno_cant_open_verification(self, payments_hidden):
        assert intents.clean_action({"type": "NAVIGATE", "destination": "verify"}) == {"type": "NONE"}
        assert "verify" not in intents.destinations()
        assert "get_verified" not in guides.available()
        assert intents.clean_action({"type": "GUIDE", "guide": "get_verified"}) == {"type": "NONE"}

    def test_zeno_can_open_it_when_on(self):
        assert intents.clean_action({"type": "NAVIGATE", "destination": "verify"}) == {
            "type": "NAVIGATE", "destination": "verify"}

    @pytest.mark.asyncio
    async def test_selling_tips_dont_suggest_getting_verified(self, payments_hidden):
        uid, _ = await _user()
        async with AsyncSessionLocal() as db:
            guide = await guides.build(db, uid, "sell_faster")
        assert all(step.get("destination") != "verify" for step in guide["steps"])
        assert not any("verified" in step["title"].lower() for step in guide["steps"])


class TestEscrowGuidanceOff:
    def test_zeno_isnt_sent_to_a_button_that_isnt_there(self, payments_off, payments_hidden):
        policy = safe_payment.ai_payment_policy()
        # Still knows BROKA holds no money and how to pay safely...
        assert "does not handle deal payments" in policy
        assert "never send a deposit" in policy
        # ...but doesn't push escrow or name the hidden button.
        assert "Pay with escrow" not in policy
        assert "recommend escrow" not in policy

    def test_with_guidance_on_escrow_is_recommended_as_before(self, payments_off):
        policy = safe_payment.ai_payment_policy()
        assert "Pay with escrow" in policy

    def test_zeno_doesnt_open_the_escrow_services(self, payments_hidden):
        assert intents.clean_action({"type": "NAVIGATE", "destination": "escrow_services"}) == {
            "type": "NONE"}
        assert "escrow_services" not in intents.destinations()
