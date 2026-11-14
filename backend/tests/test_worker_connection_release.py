"""The background sweeps hold no database connection through a provider.

Every sweep used to read, call out (an SMS provider, Firebase, Safaricom,
E-Confirm) and write in one transaction, so each provider round trip kept
one of the process's five pooled connections - and, in the deal-timer
sweep, every due deal's row lock - for its length. Each now reads or claims
in a short transaction, calls out with nothing open, and records the
outcome in another. These hold that, and that what the old shape got right
still holds: a failed send is retried on the next pass, two passes at once
send once, a reminder recorded before its send is taken back if the
provider refuses it, and a payment the callback settled during a provider
query is not overwritten by the sweep's stale view of it.
"""
import asyncio
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch

import pytest
import pytest_asyncio
from sqlalchemy import select

from api import database
from api.core.config import settings
from api.database import (
    AsyncSessionLocal, Deal, DealStatus, Interest, Listing, ListingStatus, MpesaStatus,
    MpesaTransaction, NegotiationMessage, User, init_db, reset_engine,
)
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow

EAT = timezone(timedelta(hours=3))


@pytest.fixture(autouse=True)
def _inprocess(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(autouse=True)
def _daytime():
    """Quiet hours would defer every text these tests expect sent."""
    with patch("api.core.nudge_templates.now_eat",
               return_value=datetime(2026, 9, 15, 14, 0, tzinfo=EAT)), \
         patch("api.domains.escrow.protection._quiet_hours", return_value=False):
        yield


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_worker_connection_release.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


def _phone() -> str:
    return f"+2547{uuid.uuid4().int % 10**8:08d}"


def _sweep_sessions(monkeypatch) -> list:
    """Every session the sweep under test opens - in this task only: a push
    a commit set off runs in a task of its own, on a session of its own, and
    one caught mid-query is not the sweep holding a connection."""
    real = database._session_factory
    me = asyncio.current_task()
    handed = []

    def recording():
        session = real()
        if asyncio.current_task() is me:
            handed.append(session)
        return session

    monkeypatch.setattr(database, "_session_factory", recording)
    return handed


class _Provider:
    """An SMS provider (or any provider call) noting, at each call, whether
    any of the watched sessions was mid-transaction."""

    def __init__(self, sessions, answers=(True,)):
        self.sessions, self.answers = sessions, list(answers)
        self.calls: list[tuple] = []

    async def send(self, phone, message):
        self.calls.append((phone, [s.in_transaction() for s in self.sessions]))
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(answer, Exception):
            raise answer
        return answer

    def held(self):
        return [states for _, states in self.calls if any(states)]


# ── Interest nudges ──────────────────────────────────────────────────────────

async def _due_interest() -> tuple[str, str, str, str]:
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=_phone(), password_hash="x")
        buyer = User(name="Bea Buyer", phone=_phone(), password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Fridge", category="Electronics",
                          price=20000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        interest = Interest(listing_id=listing.id, buyer_id=buyer.id,
                            nudge_deadline=datetime.utcnow() - timedelta(seconds=5),
                            created_at=datetime.utcnow() - timedelta(minutes=6))
        db.add(interest)
        await db.commit()
        return interest.id, listing.id, seller.phone, buyer.id


async def _interest(interest_id) -> Interest:
    async with AsyncSessionLocal() as db:
        return await db.get(Interest, interest_id)


async def _notes(listing_id) -> list:
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(NegotiationMessage.content).where(
                NegotiationMessage.listing_id == listing_id,
                NegotiationMessage.role == "broker",
                NegotiationMessage.recipient_role == "buyer",
            ))).scalars().all()


@pytest.mark.asyncio
async def test_the_seller_is_texted_with_no_connection_held(monkeypatch):
    interest_id, listing_id, seller_phone, _ = await _due_interest()
    sessions = _sweep_sessions(monkeypatch)
    sms = _Provider(sessions)
    with patch("api.core.sms.get_sms_provider", return_value=sms):
        from api.core.workers import task_check_interest_nudges
        await task_check_interest_nudges({})
    assert [phone for phone, _ in sms.calls] == [seller_phone]
    assert sessions and not sms.held(), "a sweep session was mid-transaction during the SMS"
    assert (await _interest(interest_id)).nudge_sent_at is not None
    assert any("texted" in n for n in await _notes(listing_id))


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", [False, RuntimeError("provider down")])
async def test_a_text_that_does_not_go_is_retried_on_the_next_pass(monkeypatch, failure):
    interest_id, listing_id, _, _ = await _due_interest()
    from api.core.workers import task_check_interest_nudges
    with patch("api.core.sms.get_sms_provider", return_value=_Provider([], answers=[failure])):
        await task_check_interest_nudges({})
    after_failure = await _interest(interest_id)
    assert after_failure.nudge_sent_at is None, "the claim is given back"
    assert after_failure.nudge_cancelled_at is None
    assert not [n for n in await _notes(listing_id) if "texted" in n], "no claim to have texted"

    sms = _Provider([])
    with patch("api.core.sms.get_sms_provider", return_value=sms):
        await task_check_interest_nudges({})
        await task_check_interest_nudges({})
    assert len(sms.calls) == 1, "sent on the retry, and only once"
    assert (await _interest(interest_id)).nudge_sent_at is not None
    assert len([n for n in await _notes(listing_id) if "texted" in n]) == 1


@pytest.mark.asyncio
async def test_two_passes_at_once_text_the_seller_once():
    interest_id, _, _, _ = await _due_interest()
    sms = _Provider([])
    from api.core.workers import task_check_interest_nudges
    with patch("api.core.sms.get_sms_provider", return_value=sms):
        await asyncio.gather(task_check_interest_nudges({}), task_check_interest_nudges({}))
    assert len(sms.calls) == 1
    assert (await _interest(interest_id)).nudge_sent_at is not None


# ── Deal-timer reminders ─────────────────────────────────────────────────────

async def _paid_deal(**fields) -> tuple[str, str]:
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=_phone(), password_hash="x")
        buyer = User(name="Bea Buyer", phone=_phone(), password_hash="x",
                     fcm_token=f"fcm-{uuid.uuid4().hex[:8]}")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Bike", category="Electronics",
                          price=10000, lat=0, lng=0, status=ListingStatus.pending)
        db.add(listing)
        await db.flush()
        deal = Deal(listing_id=listing.id, buyer_id=buyer.id, seller_id=seller.id,
                    agreed_price=10000, commission=300, status=DealStatus.paid,
                    timer_deadline=datetime.utcnow() - timedelta(minutes=1), **fields)
        db.add(deal)
        await db.commit()
        return deal.id, buyer.phone


async def _deal(deal_id) -> Deal:
    async with AsyncSessionLocal() as db:
        return await db.get(Deal, deal_id)


@pytest.mark.asyncio
async def test_a_delivery_check_in_push_goes_after_the_deal_is_committed(monkeypatch):
    deal_id, _ = await _paid_deal(
        timer_type="buyer_delivery_silence", checkin_count=0,
        buyer_delivery_silence_started_at=datetime.utcnow() - timedelta(days=1, hours=1))
    sessions = _sweep_sessions(monkeypatch)
    pushes = []

    async def fake_fcm(token, title, body, data):
        pushes.append((data.get("type"), [s.in_transaction() for s in sessions]))

    monkeypatch.setattr("api.routers.calls._send_fcm", fake_fcm)
    from api.core.workers import task_check_deal_timers
    await task_check_deal_timers({})
    assert [kind for kind, _ in pushes] == ["delivery_checkin"]
    assert not any(states for _, states in pushes if any(states)), pushes
    assert (await _deal(deal_id)).checkin_count == 1


@pytest.mark.asyncio
async def test_a_reminder_text_the_provider_refuses_is_recorded_unsent(monkeypatch):
    # 25 hours after the seller's delivery claim: the day-2 text is due.
    deal_id, buyer_phone = await _paid_deal(
        timer_type="seller_claimed_delivery", checkin_count=2, reminder_sms_count=0,
        seller_claimed_delivery_at=datetime.utcnow() - timedelta(hours=25))
    monkeypatch.setattr("api.routers.calls._send_fcm", lambda *a, **k: asyncio.sleep(0))
    sessions = _sweep_sessions(monkeypatch)
    from api.core.workers import task_check_deal_timers

    refused = _Provider(sessions, answers=[False])
    monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: refused)
    await task_check_deal_timers({})
    assert [phone for phone, _ in refused.calls] == [buyer_phone]
    assert not refused.held(), "the text went with the deal's transaction still open"
    assert (await _deal(deal_id)).reminder_sms_count == 0, "taken back: the next pass retries"

    accepted = _Provider(sessions)
    monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: accepted)
    await task_check_deal_timers({})
    await task_check_deal_timers({})
    assert len(accepted.calls) == 1, "sent on the retry, then not again"
    assert (await _deal(deal_id)).reminder_sms_count == 1


# ── Listing-expiry texts ─────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_an_expiry_text_is_claimed_before_it_goes_and_retried_if_it_fails(monkeypatch):
    from api.domains.pricing import expiry_alerts
    enabled_before = settings.expiry_sms_enabled
    object.__setattr__(settings, "expiry_sms_enabled", True)
    now = datetime(2026, 9, 15, 11, 0)  # 14:00 in Nairobi
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=_phone(), password_hash="x")
        db.add(seller)
        await db.flush()
        db.add(Listing(seller_id=seller.id, name="Sofa", category="Furniture", price=9000,
                       lat=0, lng=0, status=ListingStatus.active,
                       created_at=now - timedelta(days=28), paid_until=now + timedelta(days=1)))
        await db.commit()
    try:
        async with AsyncSessionLocal() as db:
            failing = _Provider([db], answers=[False])
            monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: failing)
            assert (await expiry_alerts.send_due_expiry_alerts(db, now))["listings"] == 0
            assert failing.calls and not failing.held()

            working = _Provider([db])
            monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: working)
            assert (await expiry_alerts.send_due_expiry_alerts(db, now))["listings"] == 1
            assert not working.held()
            assert (await expiry_alerts.send_due_expiry_alerts(db, now))["listings"] == 0
    finally:
        object.__setattr__(settings, "expiry_sms_enabled", enabled_before)


# ── Payment reconciliation ───────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_an_mpesa_query_holds_nothing_and_never_overwrites_a_settled_payment(monkeypatch):
    deal_id, _ = await _paid_deal()
    async with AsyncSessionLocal() as db:
        deal = await db.get(Deal, deal_id)
        deal.status = DealStatus.agreed
        tx = MpesaTransaction(deal_id=deal_id, buyer_id=deal.buyer_id, phone=_phone(),
                              amount=10000, checkout_request_id=f"ws_CO_{uuid.uuid4().hex[:10]}",
                              created_at=datetime.utcnow() - timedelta(minutes=20))
        db.add(tx)
        await db.commit()
        tx_id = tx.id
    sessions = _sweep_sessions(monkeypatch)
    held = []

    async def stk_query(checkout_request_id):
        held.append([s.in_transaction() for s in sessions])
        # Safaricom's callback lands while the query is out, and settles it.
        async with AsyncSessionLocal() as db:
            row = await db.get(MpesaTransaction, tx_id)
            row.status = MpesaStatus.success
            row.callback_processed = True
            await db.commit()
        return {"ResultCode": "1032"}  # a stale "cancelled" from the query

    from api.core import mpesa_stk
    monkeypatch.setattr(mpesa_stk, "stk_query", stk_query)
    from api.core.workers import task_reconcile_mpesa
    await task_reconcile_mpesa({}, database.DATABASE_URL)
    assert held and not any(any(states) for states in held), held
    async with AsyncSessionLocal() as db:
        assert (await db.get(MpesaTransaction, tx_id)).status == MpesaStatus.success


@pytest.mark.asyncio
async def test_an_econfirm_status_poll_holds_nothing_while_e_confirm_answers(monkeypatch):
    deal_id, _ = await _paid_deal()
    async with AsyncSessionLocal() as db:
        db.add(ExternalEscrow(
            deal_id=deal_id, provider_transaction_id=f"tx-{uuid.uuid4().hex[:8]}",
            status=EConfirmEscrowStatus.PENDING, amount=10000,
            buyer_email="b@x.test", seller_email="s@x.test", receiver_phone="+254700000000"))
        await db.commit()
    held = []

    class FakeEConfirm:
        async def get_status(self, provider_transaction_id):
            held.append(svc.db.in_transaction())
            return SimpleNamespace(status=EConfirmEscrowStatus.PENDING, raw_status="Pending")

    monkeypatch.setattr("api.domains.escrow.service.get_escrow_provider", lambda: FakeEConfirm())
    from api.domains.escrow.service import EscrowService
    async with AsyncSessionLocal() as db:
        svc = EscrowService(db)
        await svc.reconcile_econfirm_escrow(deal_id)
    assert held == [False]
