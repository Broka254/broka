"""
BROKA - Interest Availability Nudge Tests (v6.2)
Run: pytest backend/tests/test_interest_nudges.py -v

Covers task_check_interest_nudges (api/core/workers.py): if a buyer's
interest goes unanswered past its nudge_deadline, the seller gets an SMS;
if the seller actually replied in the thread, the sweep cancels the nudge
instead. The AI draft call and the SMS provider are both mocked — this
suite checks the deterministic sweep logic (who gets texted and why), not
Gemini/Groq/Africa's Talking themselves, which are already covered
independently (ai_broker circuit breakers, sms.py sandbox routing).
"""

import pytest
import pytest_asyncio
from datetime import datetime, timedelta

from api.core.nudge_templates import EAT
from unittest.mock import AsyncMock, patch
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_interest_nudges.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    # See api/database.py:reset_engine - the engine is built once at
    # first import, so DATABASE_URL must be re-applied here or this
    # module silently shares the db every other test module is using.
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


async def _verified_token(client, phone: str) -> str:
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    return verify.json()["phone_verify_token"]


async def _register_and_login(client, phone: str, name: str, email: str, password: str) -> dict:
    token = await _verified_token(client, phone)
    await client.post("/auth/register", json={
        "phone_verify_token": token, "name": name, "email": email,
        "password": password, "lat": -1.28, "lng": 36.81,
    })
    resp = await client.post("/auth/login", json={"phone": phone, "password": password})
    return resp.json()


@pytest_asyncio.fixture(scope="module")
async def seller(client):
    return await _register_and_login(
        client, "0733111000", "Nudge Seller", "nudgeseller@test.ke", "NudgeSeller123!"
    )


async def _create_listing_and_interest(client, seller_token, buyer_token, name):
    create_resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
        "name": name, "category": "electronics", "price": 20000,
        "lat": -1.286, "lng": 36.817,
    }, headers={"Authorization": f"Bearer {seller_token}"})
    assert create_resp.status_code == 201
    listing_id = create_resp.json()["id"]

    interest_resp = await client.post(f"/listings/{listing_id}/interest", json={
        "offer_price": 18000,
    }, headers={"Authorization": f"Bearer {buyer_token}"})
    assert interest_resp.status_code == 200
    return listing_id


class TestInterestNudgeSweep:

    @pytest_asyncio.fixture(autouse=True)
    async def _isolate_pending_nudges(self):
        """Clear leftover interests so each test's sweep sees only its own.

        WHY (2026-09-15): `set_test_db`/`setup_db` are module-scoped, so
        every test in this class shares one database, and
        `task_check_interest_nudges` is a GLOBAL sweep - it processes every
        due interest it finds, not just the one the calling test created.

        That was survivable only by accident. Each test happened to leave
        its interest terminal (sent, or cancelled), so nothing was ever
        still-due when the next test swept. Adding
        `test_sweep_defers_during_quiet_hours` broke the accident: it
        asserts, correctly, that a deferred nudge stays neither sent nor
        cancelled so a later pass retries it. That leftover row was then
        picked up by the very next test's sweep and sent at the class's
        pinned 14:00, so `test_sweep_cancels_when_seller_already_replied`
        failed with an SMS about "Quiet Hours Phone" - a listing it had
        never heard of.

        The assertion that caught it (`mock_sms.assert_not_called()`) is
        global, which is the right assertion to make and is worth keeping;
        what was missing was the isolation that makes it mean what it says.
        Clearing here rather than cleaning up afterwards keeps the class
        order-independent: a test that fails partway through cannot poison
        the rest of the file.
        """
        from sqlalchemy import delete
        from api.database import AsyncSessionLocal, Interest
        async with AsyncSessionLocal() as session:
            await session.execute(delete(Interest))
            await session.commit()
        yield

    @pytest.fixture(autouse=True)
    def _pin_clock_to_daytime(self):
        """Freeze the sweep's clock at 14:00 EAT for every test in this class.

        WHY THIS EXISTS (2026-09-15): without it these tests pass or fail
        depending on what time of day CI happens to run.

        `_fire_availability_nudge` calls `is_quiet_hours()` and defers the
        SMS between 21:00 and 07:00 EAT - correct behaviour, deliberately
        designed, and nothing to do with the code under test here. But
        `test_sweep_sends_sms_when_seller_silent` asserts an SMS WAS sent,
        so it can only pass during Kenyan daytime. The run that caught this
        started at 20:24 UTC = 23:24 EAT and failed with "Expected 'send'
        to have been called once. Called 0 times." The same commit would
        have passed a few hours earlier.

        It was invisible until now only because the whole suite had never
        executed - the route-ordering guard was aborting collection before
        any test ran.

        `test_sweep_cancels_when_seller_already_replied` is worse, not
        better, for being green: at night it passes VACUOUSLY, because
        quiet hours suppress the SMS whether or not the cancellation logic
        works at all. Pinning the clock is what makes its assertion mean
        something.

        Patching `now_eat` rather than `is_quiet_hours` keeps the real
        quiet-hours logic under test and also fixes the greeting the
        templates derive from the same clock.
        """
        fixed = datetime(2026, 9, 15, 14, 0, tzinfo=EAT)
        with patch("api.core.nudge_templates.now_eat", return_value=fixed):
            yield

    @pytest.mark.asyncio
    async def test_express_interest_sets_nudge_deadline(self, client, seller):
        buyer = await _register_and_login(
            client, "0733111001", "Nudge Buyer A", "nudgebuyera@test.ke", "NudgeBuyerA123!"
        )
        listing_id = await _create_listing_and_interest(
            client, seller["access_token"], buyer["access_token"], "Deadline Check Phone"
        )

        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            interest = r.scalar_one()

        assert interest.nudge_deadline is not None
        assert interest.nudge_sent_at is None
        assert interest.nudge_cancelled_at is None
        # Should be ~5 minutes out, not e.g. 5 hours or unset-and-defaulted.
        delta = interest.nudge_deadline - interest.created_at
        assert timedelta(minutes=4) < delta < timedelta(minutes=6)

    @pytest.mark.asyncio
    async def test_sweep_sends_sms_when_seller_silent(self, client, seller):
        buyer = await _register_and_login(
            client, "0733111002", "Nudge Buyer B", "nudgebuyerb@test.ke", "NudgeBuyerB123!"
        )
        listing_id = await _create_listing_and_interest(
            client, seller["access_token"], buyer["access_token"], "Silent Seller Phone"
        )

        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            interest = r.scalar_one()
            # Simulate 5 minutes having already passed, instead of sleeping.
            interest.nudge_deadline = datetime.utcnow() - timedelta(seconds=1)
            await session.commit()

        mock_sms = AsyncMock(return_value=True)
        with patch("api.core.sms.get_sms_provider", return_value=AsyncMock(send=mock_sms)), \
             patch(
                "api.domains.ai_broker.service.AIBrokerService.draft_availability_nudge_sms",
                new=AsyncMock(return_value="Hi Seller, it's Zeno — following up on that interest."),
             ):
            from api.core.workers import task_check_interest_nudges
            await task_check_interest_nudges({})

        mock_sms.assert_called_once()
        called_phone = mock_sms.call_args.args[0]
        assert called_phone == "+254733111000"  # seller's registered phone, normalized

        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            refreshed = r.scalar_one()
        assert refreshed.nudge_sent_at is not None
        assert refreshed.nudge_cancelled_at is None

    @pytest.mark.asyncio
    async def test_sweep_defers_during_quiet_hours(self, client, seller):
        """A due nudge at 23:30 EAT is held, not sent - and not lost.

        This is the behaviour that was quietly deciding the outcome of the
        two tests around it while being covered by neither. Worth asserting
        directly for its own sake: the deferral is the whole reason BROKA
        does not text sellers about second-hand goods at 3am, and the
        retry is what stops "deferred" from meaning "dropped".
        """
        buyer = await _register_and_login(
            client, "0733111004", "Nudge Buyer D", "nudgebuyerd@test.ke", "NudgeBuyerD123!"
        )
        listing_id = await _create_listing_and_interest(
            client, seller["access_token"], buyer["access_token"], "Quiet Hours Phone"
        )

        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            interest = r.scalar_one()
            interest.nudge_deadline = datetime.utcnow() - timedelta(seconds=1)
            await session.commit()

        mock_sms = AsyncMock(return_value=True)
        # Overrides the class fixture's daytime pin for this test only.
        with patch("api.core.nudge_templates.now_eat",
                   return_value=datetime(2026, 9, 15, 23, 30, tzinfo=EAT)), \
             patch("api.core.sms.get_sms_provider", return_value=AsyncMock(send=mock_sms)), \
             patch(
                "api.domains.ai_broker.service.AIBrokerService.draft_availability_nudge_sms",
                new=AsyncMock(return_value="Hi Seller, it's Zeno - following up."),
             ):
            from api.core.workers import task_check_interest_nudges
            await task_check_interest_nudges({})

        mock_sms.assert_not_called()

        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            refreshed = r.scalar_one()
        # Still due. Neither sent nor cancelled, so the next sweep after
        # 07:00 picks it up rather than the nudge being silently dropped.
        assert refreshed.nudge_sent_at is None
        assert refreshed.nudge_cancelled_at is None

    @pytest.mark.asyncio
    async def test_sweep_cancels_when_seller_already_replied(self, client, seller):
        buyer = await _register_and_login(
            client, "0733111003", "Nudge Buyer C", "nudgebuyerc@test.ke", "NudgeBuyerC123!"
        )
        listing_id = await _create_listing_and_interest(
            client, seller["access_token"], buyer["access_token"], "Responsive Seller Phone"
        )

        from api.database import AsyncSessionLocal, Interest, NegotiationMessage
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            interest = r.scalar_one()
            interest.nudge_deadline = datetime.utcnow() - timedelta(seconds=1)
            # Seller actually replied in the thread, after the interest was created.
            session.add(NegotiationMessage(
                listing_id=listing_id,
                sender_id=seller["user_id"],
                role="seller",
                recipient_role="buyer",
                content="Yes it's still available!",
                buyer_id=buyer["user_id"],
                via_ai=False,
                msg_type="text",
            ))
            await session.commit()

        mock_sms = AsyncMock(return_value=True)
        with patch("api.core.sms.get_sms_provider", return_value=AsyncMock(send=mock_sms)):
            from api.core.workers import task_check_interest_nudges
            await task_check_interest_nudges({})

        mock_sms.assert_not_called()

        async with AsyncSessionLocal() as session:
            r = await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )
            refreshed = r.scalar_one()
        assert refreshed.nudge_cancelled_at is not None
        assert refreshed.nudge_sent_at is None
