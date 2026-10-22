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
from tests.legal_payload import legal_payload


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
        "legal_acceptance": legal_payload(),
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

        # The buyer is told the text actually went out - the follow-through
        # that makes Zeno feel like a person chasing the seller, not a form.
        from api.database import NegotiationMessage
        async with AsyncSessionLocal() as session:
            note = (await session.execute(
                select(NegotiationMessage).where(
                    NegotiationMessage.listing_id == listing_id,
                    NegotiationMessage.role == "broker",
                    NegotiationMessage.recipient_role == "buyer",
                ).order_by(NegotiationMessage.created_at.desc())
            )).scalars().first()
        assert note is not None
        assert "texted" in note.content.lower()
        assert buyer["user_id"] == note.buyer_id

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


class TestWhichMessagesArmTheNudge:
    """The 5-minute SMS must follow a buyer's actual question.

    Reported as a promise with nothing behind it: Zeno tells the buyer it
    will text the seller if they stay quiet, but the timer was armed from
    exactly one place - Zeno's own screen - and not from the direct chat,
    where the question is usually typed. The two failure modes are opposite
    and both bad: a text about a question nobody asked (arming on a screen
    opening, spending the seller's SMS alerts) and no text at all about a
    question that was really sent.
    """

    async def _fresh_buyer(self, client, tag: str) -> dict:
        """A buyer on a phone number nobody else in this module has used.
        The module shares one database, so a fixed number makes the second
        run of the suite fail on a 409 that has nothing to do with the code
        under test."""
        import uuid as _uuid
        n = _uuid.uuid4().int % 100_000_000
        return await _register_and_login(
            client, f"07{n:08d}", f"Nudge Buyer {tag}",
            f"nudge{tag.lower()}{n}@test.ke", "NudgeBuyerD123!",
        )

    @pytest.mark.asyncio
    async def test_opening_the_zeno_screen_does_not_arm_a_seller_text(
            self, client, seller):
        buyer = await self._fresh_buyer(client, "D")
        create = await client.post("/listings/", json={
            "description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Zeno Greeting Phone", "category": "electronics",
            "price": 20000, "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller['access_token']}"})
        assert create.status_code == 201
        listing_id = create.json()["id"]

        with patch("api.routers.negotiate._call_ai",
                   new=AsyncMock(return_value="Hi there!")):
            r = await client.post("/negotiate/message", json={
                "listing_id": listing_id,
                "sender_role": "buyer",
                "sender_id": buyer["user_id"],
                "content": "",
                "intent": "opening_greeting",
            }, headers={"Authorization": f"Bearer {buyer['access_token']}"})
        assert r.status_code == 200, r.text

        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            due = (await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )).scalars().all()
        assert due == [], (
            "the buyer only opened Zeno - nothing was said to the seller, "
            "so there is nothing to chase"
        )

    @pytest.mark.asyncio
    async def test_a_buyers_direct_message_arms_the_seller_text(
            self, client, seller):
        buyer = await self._fresh_buyer(client, "E")
        create = await client.post("/listings/", json={
            "description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Direct Chat Phone", "category": "electronics",
            "price": 20000, "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller['access_token']}"})
        assert create.status_code == 201
        listing_id = create.json()["id"]

        r = await client.post("/negotiate/direct-message", json={
            "listing_id": listing_id,
            "sender_role": "buyer",
            "sender_id": buyer["user_id"],
            "content": "Is this still available?",
        }, headers={"Authorization": f"Bearer {buyer['access_token']}"})
        assert r.status_code == 200, r.text

        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            interest = (await session.execute(
                select(Interest).where(
                    Interest.listing_id == listing_id,
                    Interest.buyer_id == buyer["user_id"],
                )
            )).scalar_one()
        delta = interest.nudge_deadline - interest.created_at
        assert timedelta(minutes=4) < delta < timedelta(minutes=6)

    @pytest.mark.asyncio
    async def test_a_sellers_message_does_not_arm_a_text(self, client, seller):
        buyer = await self._fresh_buyer(client, "F")
        create = await client.post("/listings/", json={
            "description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Seller Reply Phone", "category": "electronics",
            "price": 20000, "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller['access_token']}"})
        assert create.status_code == 201
        listing_id = create.json()["id"]

        r = await client.post("/negotiate/direct-message", json={
            "listing_id": listing_id,
            "sender_role": "seller",
            "sender_id": seller["user_id"],
            "content": "Yes, still available.",
            "buyer_id": buyer["user_id"],
        }, headers={"Authorization": f"Bearer {seller['access_token']}"})
        assert r.status_code == 200, r.text

        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            due = (await session.execute(
                select(Interest).where(Interest.listing_id == listing_id)
            )).scalars().all()
        assert due == [], "the seller answering is the opposite of a buyer waiting"


class TestTheFiveMinutePromiseIsTrueWhenMade:
    """Zeno says it will text the seller in about five minutes.

    The sentence is generated, so the only thing that keeps it honest is
    that the prompt is given the real answer: are the listing's texts on,
    is there a number, does the seller's plan still have SMS alerts. A
    promise printed with any of those closed is a reassuring lie the buyer
    discovers by waiting forever.
    """

    @pytest.mark.asyncio
    async def test_a_listing_that_opted_out_gets_no_promise(self):
        from types import SimpleNamespace
        from api.routers.negotiate import _seller_can_be_texted
        seller = SimpleNamespace(id="s1", phone="+254700000001")
        assert await _seller_can_be_texted(
            None, SimpleNamespace(sms_alerts=False), seller) is False

    @pytest.mark.asyncio
    async def test_a_seller_without_a_phone_gets_no_promise(self):
        from types import SimpleNamespace
        from api.routers.negotiate import _seller_can_be_texted
        seller = SimpleNamespace(id="s2", phone=None)
        assert await _seller_can_be_texted(
            None, SimpleNamespace(sms_alerts=True), seller) is False

    @pytest.mark.asyncio
    async def test_otherwise_the_promise_is_offered(self):
        from types import SimpleNamespace
        from api.routers.negotiate import _seller_can_be_texted
        seller = SimpleNamespace(id="s3", phone="+254700000002")
        assert await _seller_can_be_texted(
            None, SimpleNamespace(sms_alerts=True), seller) is True

    @pytest.mark.asyncio
    async def test_the_prompt_says_so_only_when_it_will_happen(
            self, client, seller):
        """End to end: the buyer's relayed question, as the model sees it."""
        from api.database import AsyncSessionLocal, Listing
        from sqlalchemy import select, update

        buyer = await _register_and_login(
            client, "0733111020", "Nudge Buyer G", "nudgebuyerg@test.ke", "NudgeBuyerG123!"
        )
        create = await client.post("/listings/", json={
            "description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Promise Phone", "category": "electronics",
            "price": 20000, "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller['access_token']}"})
        assert create.status_code == 201
        listing_id = create.json()["id"]

        prompts: list[str] = []

        async def fake_ai(sys_prompt, msgs, **kwargs):
            prompts.append(sys_prompt)
            return "ok"

        relay = {"needs_relay": True, "relay_summary": "Is it still available?",
                 "is_availability_confirmation": False}

        async def send():
            prompts.clear()
            with patch("api.routers.negotiate._call_ai", new=fake_ai), \
                 patch("api.routers.negotiate._classify_relay",
                       new=AsyncMock(return_value=relay)), \
                 patch("api.routers.negotiate._classify_zeno_action",
                       new=AsyncMock(return_value="NONE")):
                r = await client.post("/negotiate/message", json={
                    "listing_id": listing_id,
                    "sender_role": "buyer",
                    "sender_id": buyer["user_id"],
                    "content": "Is this still available?",
                }, headers={"Authorization": f"Bearer {buyer['access_token']}"})
            assert r.status_code == 200, r.text
            return "\\n".join(prompts)

        promised = await send()
        assert "five minutes" in promised.lower()

        async with AsyncSessionLocal() as db:
            await db.execute(
                update(Listing)
                .where(Listing.id == listing_id)
                .values(sms_alerts=False)
            )
            await db.commit()
            row = (await db.execute(
                select(Listing.sms_alerts).where(Listing.id == listing_id)
            )).scalar_one()
        # SQLite stores the flag as 0/1; the code path reads it as False.
        assert not bool(row)

        # Same buyer, same relay - but the listing has now opted out of
        # texts, so the sentence Zeno was told to say must change.
        withheld = await send()
        assert "about five minutes" not in withheld.lower()
        assert "do not say you will text" in withheld.lower()


class TestZenoTellsTheBuyerWhenTheSellerStaysSilent:
    """The beat after the SMS.

    Zeno promised the buyer it would chase. The text went out and the
    seller still didn't answer, so the buyer is left in a conversation
    that has stopped - from their side, indistinguishable from being
    ignored. One honest update, once, is what an actual intermediary
    does; a second copy of it on the next pass is what a bot does.
    """

    async def _buyer(self, client, tag: str) -> dict:
        import uuid as _uuid
        n = _uuid.uuid4().int % 100_000_000
        return await _register_and_login(
            client, f"07{n:08d}", f"Waiting Buyer {tag}",
            f"waiting{tag.lower()}{n}@test.ke", "Waiting123!",
        )

    async def _due_for_followup(self, listing_id, buyer_id, *, minutes_since_text=60):
        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            interest = (await session.execute(
                select(Interest).where(
                    Interest.listing_id == listing_id,
                    Interest.buyer_id == buyer_id,
                )
            )).scalar_one()
            interest.nudge_sent_at = datetime.utcnow() - timedelta(minutes=minutes_since_text)
            await session.commit()
            return interest.id

    async def _notes(self, listing_id):
        from api.database import AsyncSessionLocal, NegotiationMessage
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            return (await session.execute(
                select(NegotiationMessage).where(
                    NegotiationMessage.listing_id == listing_id,
                    NegotiationMessage.role == "broker",
                    NegotiationMessage.recipient_role == "buyer",
                )
            )).scalars().all()

    @pytest.mark.asyncio
    async def test_one_honest_update_and_only_one(self, client, seller):
        buyer = await self._buyer(client, "A")
        listing_id = await _create_listing_and_interest(
            client, seller["access_token"], buyer["access_token"], "Silent After Text Phone"
        )
        interest_id = await self._due_for_followup(listing_id, buyer["user_id"])
        # Expressing interest already posts Zeno's "I've asked the seller"
        # note, so the check is what THIS pass added, not the total.
        before = {n.id for n in await self._notes(listing_id)}

        from api.core.workers import task_check_interest_nudges
        await task_check_interest_nudges({})
        added = [n for n in await self._notes(listing_id) if n.id not in before]
        assert len(added) == 1, [n.content for n in added]
        # It says the seller is the one who went quiet, names the listing,
        # and is for the buyer only.
        assert "Silent After Text Phone" in added[0].content
        assert added[0].buyer_id == buyer["user_id"]

        from api.database import AsyncSessionLocal, Interest
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            refreshed = (await session.execute(
                select(Interest).where(Interest.id == interest_id)
            )).scalar_one()
        assert refreshed.buyer_followup_at is not None

        # Next pass: same state, same silence - and no second note.
        after_first = {n.id for n in await self._notes(listing_id)}
        await task_check_interest_nudges({})
        assert {n.id for n in await self._notes(listing_id)} == after_first

    @pytest.mark.asyncio
    async def test_no_note_when_the_seller_did_answer(self, client, seller):
        buyer = await self._buyer(client, "B")
        listing_id = await _create_listing_and_interest(
            client, seller["access_token"], buyer["access_token"], "Answered Late Phone"
        )
        await self._due_for_followup(listing_id, buyer["user_id"])

        from api.database import AsyncSessionLocal, NegotiationMessage
        async with AsyncSessionLocal() as session:
            session.add(NegotiationMessage(
                listing_id=listing_id,
                sender_id=seller["user_id"],
                role="seller",
                recipient_role="buyer",
                content="Sorry, was out - yes it's available.",
                buyer_id=buyer["user_id"],
                via_ai=False,
                msg_type="text",
            ))
            await session.commit()

        before = {n.id for n in await self._notes(listing_id)}
        from api.core.workers import task_check_interest_nudges
        await task_check_interest_nudges({})
        assert {n.id for n in await self._notes(listing_id)} == before, (
            "the seller answered - there is no silence to report"
        )
