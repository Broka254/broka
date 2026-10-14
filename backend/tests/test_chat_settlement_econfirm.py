"""Chat-intent settlement ("Yes, all good" / "I want a refund") must not
settle an E-Confirm deal as if BROKA held the money.

buyer_confirms_goods_ok marked the deal released and told the seller "KES X
has been released to you" without E-Confirm ever being asked to pay;
buyer_chooses_refund paid the buyer out of BROKA's own M-Pesa account while
their money stayed in E-Confirm's escrow. Both now fail closed for E-Confirm
deals (as the dispute engine already does) and, for legacy deals, publish
the ledger event they used to skip.
"""
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core.config import settings
from api.database import (
    AsyncSessionLocal, AuditLog, Deal, DealStatus, Listing, ListingStatus, User,
    init_db, reset_engine,
)
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow
from api.security import create_access_token
from main import app


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_chat_settlement.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.fixture
def payouts(monkeypatch):
    sent = []

    async def fake_b2c(phone, amount, ref_id):
        sent.append(amount)
        return {"success": True}
    monkeypatch.setattr("api.routers.disputes._mpesa_b2c_refund", fake_b2c)
    return sent


@pytest.fixture
def published(monkeypatch):
    seen = []

    async def fake_publish(event):
        seen.append(event)
    monkeypatch.setattr("api.core.events.publish", fake_publish)
    return seen


def _tag() -> str:
    return uuid.uuid4().hex[:10]


async def _deal(status: DealStatus, *, econfirm: bool):
    async with AsyncSessionLocal() as db:
        seller = User(name="Sally Seller", phone=f"+2547{_tag()}", password_hash="x")
        buyer = User(name="Brian Buyer", phone=f"+2547{_tag()}", password_hash="x")
        db.add_all([seller, buyer])
        await db.commit()
        listing = Listing(seller_id=seller.id, name=f"Phone {_tag()}", category="Electronics",
                          price=10000, lat=-1.29, lng=36.82, status=ListingStatus.pending)
        db.add(listing)
        await db.commit()
        deal = Deal(listing_id=listing.id, buyer_id=buyer.id, seller_id=seller.id,
                    agreed_price=10000, commission=300, status=status,
                    seller_has_explained=True, dispute_branch="A2")
        db.add(deal)
        await db.commit()
        if econfirm:
            db.add(ExternalEscrow(
                deal_id=deal.id, provider_transaction_id=f"tx-{_tag()}",
                status=EConfirmEscrowStatus.FUNDED, amount=10000,
                buyer_email="b@x.test", seller_email="s@x.test", receiver_phone="+254700000000",
            ))
            await db.commit()
        return deal.id, listing.id, buyer.id


async def _say(client, listing_id, buyer_id, intent):
    return await client.post(
        "/negotiate/message",
        json={"listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer_id,
              "content": "(tap)", "intent": intent},
        headers={"Authorization": f"Bearer {create_access_token({'sub': buyer_id})}"},
    )


async def _status(deal_id: str) -> DealStatus:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(Deal.status).where(Deal.id == deal_id))).scalar_one()


async def _audited(action: str, deal_id: str) -> bool:
    async with AsyncSessionLocal() as db:
        return bool((await db.execute(
            select(AuditLog.id).where(AuditLog.action == action, AuditLog.resource_id == deal_id)
        )).first())


class TestEConfirmDealsFailClosed:
    @pytest.mark.asyncio
    async def test_goods_ok_does_not_claim_a_release_that_never_happened(self, client, published):
        deal_id, listing_id, buyer_id = await _deal(DealStatus.awaiting_condition_check, econfirm=True)
        r = await _say(client, listing_id, buyer_id, "buyer_confirms_goods_ok")
        assert r.status_code == 200, r.text
        assert "released KES" not in r.json()["content"]
        assert await _status(deal_id) == DealStatus.awaiting_condition_check
        assert await _audited("econfirm_chat_release_blocked", deal_id)
        assert published == []

    @pytest.mark.asyncio
    async def test_refund_is_not_paid_from_brokas_own_account(self, client, payouts, published):
        deal_id, listing_id, buyer_id = await _deal(DealStatus.awaiting_resolution, econfirm=True)
        r = await _say(client, listing_id, buyer_id, "buyer_chooses_refund")
        assert r.status_code == 200, r.text
        assert payouts == []
        assert await _status(deal_id) == DealStatus.awaiting_resolution
        assert await _audited("econfirm_chat_refund_blocked", deal_id)


class TestLegacyDealsSettleAndTellTheLedger:
    @pytest.mark.asyncio
    async def test_goods_ok_releases_and_publishes(self, client, published):
        from api.core.events import EscrowReleased

        deal_id, listing_id, buyer_id = await _deal(DealStatus.awaiting_condition_check, econfirm=False)
        r = await _say(client, listing_id, buyer_id, "buyer_confirms_goods_ok")
        assert r.status_code == 200, r.text
        assert await _status(deal_id) == DealStatus.released
        assert [e for e in published if isinstance(e, EscrowReleased) and e.deal_id == deal_id]

    @pytest.mark.asyncio
    async def test_refund_pays_once_and_publishes(self, client, payouts, published):
        from api.core.events import EscrowRefunded

        deal_id, listing_id, buyer_id = await _deal(DealStatus.awaiting_resolution, econfirm=False)
        r = await _say(client, listing_id, buyer_id, "buyer_chooses_refund")
        assert r.status_code == 200, r.text
        assert payouts == [9700.0]
        assert await _status(deal_id) == DealStatus.refunded
        assert [e for e in published if isinstance(e, EscrowRefunded) and e.deal_id == deal_id]
