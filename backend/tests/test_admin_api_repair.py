"""Contract and integrity tests for the admin API repairs.

These cover the operations dashboard reads that previously 404'd, the
finance-integrity checks, filtered user/store collections and the two
mutating routes (fraud resolution is idempotent and audited).
"""
from __future__ import annotations

import asyncio
import datetime
import uuid
from decimal import Decimal

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select

from api.database import (
    AccountType, AsyncSessionLocal, AuditLog, Deal, DealStatus, Dispute,
    DisputeStatus, FraudEvent, Listing, ListingStatus, MpesaStatus,
    MpesaTransaction, NegotiationMessage, User, init_db, reset_engine,
)
from api.models.dispute import CaseBranch, CaseState, DisputeCase
from api.models.escrow_ledger import LedgerAccount, LedgerDirection, LedgerEntry
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow
from api.models.listing_payment import ListingPayment
from api.models.payment_callback import PaymentCallback
from api.models.store import Store
from api.models.zetupay import Purpose, ZetuPayPayment, ZetuPayStatus
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_admin_api_repair.db"
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


@pytest_asyncio.fixture(scope="module")
async def admin():
    return await _user(admin=True, name="Admin")


def _headers(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _user(
    *, admin: bool = False, name: str = "User",
    account_type: AccountType = AccountType.buyer,
    is_flagged: bool = False,
    created_at: datetime.datetime | None = None,
) -> User:
    tag = uuid.uuid4().hex[:12]
    user = User(
        name=f"{name} {tag}",
        nickname=f"nick-{tag}",
        phone=f"+2547{tag}",
        email=f"{tag}@admin-repair.test",
        password_hash="not-a-real-hash",
        is_admin=admin,
        account_type=account_type,
        is_flagged=is_flagged,
        created_at=created_at or datetime.datetime.utcnow(),
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


async def _listing(seller: User, *, name: str = "Listing", **overrides) -> Listing:
    listing = Listing(
        seller_id=seller.id,
        name=f"{name} {uuid.uuid4().hex[:8]}",
        category=overrides.pop("category", "phones"),
        price=overrides.pop("price", 1000.0),
        lat=-1.29,
        lng=36.82,
        status=overrides.pop("status", ListingStatus.active),
        **overrides,
    )
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    return listing


async def _deal(
    seller: User, buyer: User, listing: Listing, *,
    status: DealStatus = DealStatus.released,
    commission: float = 100.0,
    created_at: datetime.datetime | None = None,
    released_at: datetime.datetime | None = None,
    **overrides,
) -> Deal:
    deal = Deal(
        listing_id=listing.id,
        seller_id=seller.id,
        buyer_id=buyer.id,
        agreed_price=overrides.pop("agreed_price", 2000.0),
        commission=commission,
        status=status,
        created_at=created_at or datetime.datetime.utcnow(),
        released_at=released_at,
        **overrides,
    )
    async with AsyncSessionLocal() as db:
        db.add(deal)
        await db.commit()
        await db.refresh(deal)
    return deal


def _ledger(deal: Deal, account: LedgerAccount, direction: LedgerDirection,
            amount: str | Decimal, description: str = "test") -> LedgerEntry:
    return LedgerEntry(
        deal_id=deal.id,
        account=account,
        direction=direction,
        amount_kes=Decimal(str(amount)),
        description=description,
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("path", [
    "/admin/ops-snapshot", "/admin/health/services", "/admin/stores",
    "/admin/users", "/admin/deals", "/admin/listings", "/admin/disputes",
    "/admin/payments", "/admin/finance-integrity", "/admin/zeno/activity",
])
async def test_new_admin_reads_reject_anonymous_and_non_admin(client, admin, path):
    assert (await client.get(path)).status_code == 401
    ordinary = await _user()
    assert (await client.get(path, headers=_headers(ordinary))).status_code == 403
    assert (await client.get(path, headers=_headers(admin))).status_code == 200


@pytest.mark.asyncio
async def test_ops_snapshot_windows_and_definitions_are_durable(client, admin):
    old = await _user(created_at=datetime.datetime.utcnow() - datetime.timedelta(minutes=90))
    new = await _user()
    seller = await _user(account_type=AccountType.buyer_seller)
    buyer = await _user()
    listing = await _listing(seller)
    now = datetime.datetime.utcnow()
    current = await _deal(
        seller, buyer, listing, released_at=now - datetime.timedelta(minutes=5))
    previous = await _deal(
        seller, buyer, listing,
        released_at=now - datetime.timedelta(minutes=90))

    response = await client.get(
        "/admin/ops-snapshot?window_hours=1", headers=_headers(admin))
    assert response.status_code == 200
    body = response.json()
    assert body["timezone"] == "UTC"
    assert body["window_hours"] == 1
    assert {"window", "users.high_risk", "payments.zetupay", "ledger"} <= set(
        body["definitions"])
    assert body["users"]["new_current"] >= 1
    assert body["users"]["new_previous"] >= 1
    assert body["deals"]["released_current"] >= 1
    assert body["deals"]["released_previous"] >= 1
    assert body["deals"]["by_status"]["released"] >= 2
    assert body["commission"]["released_current_kes"] >= 100
    assert body["ledger"]["balanced"] in (True, False)
    assert body["payments"]["mpesa"]["pending"] >= 0
    assert body["payments"]["zetupay"]["initiated"] >= 0
    assert old.id != new.id
    assert current.id != previous.id
    assert (await client.get(
        "/admin/ops-snapshot?window_hours=0", headers=_headers(admin))).status_code == 422


@pytest.mark.asyncio
async def test_health_reports_timeout_honestly(client, admin, monkeypatch):
    import api.domains.admin.router as admin_router
    import api.database as database

    real_wait_for = asyncio.wait_for

    async def fast_wait_for(awaitable, timeout):
        return await real_wait_for(awaitable, timeout=0.05)

    async def slow_schema():
        await asyncio.sleep(0.3)
        return {"current": True, "current_version": 99, "required_version": 1}

    monkeypatch.setattr(admin_router, "_HEALTH_CHECK_TIMEOUT_SECONDS", 0.05)
    monkeypatch.setattr(admin_router.asyncio, "wait_for", fast_wait_for)
    monkeypatch.setattr(database, "schema_status", slow_schema)

    started = asyncio.get_running_loop().time()
    response = await client.get("/admin/health/services", headers=_headers(admin))
    elapsed = asyncio.get_running_loop().time() - started
    assert response.status_code == 200
    assert elapsed < 0.25
    checks = {row["name"]: row for row in response.json()["checks"]}
    assert checks["database_schema"]["status"] == "unavailable"
    assert "timed out" in checks["database_schema"]["detail"]
    assert checks["database_connectivity"]["status"] == "ok"


@pytest.mark.asyncio
async def test_health_schema_error_is_not_reported_as_healthy(client, admin, monkeypatch):
    import api.database as database

    async def broken_schema():
        raise RuntimeError("schema query failed with a credential-bearing message")

    monkeypatch.setattr(database, "schema_status", broken_schema)
    response = await client.get("/admin/health/services", headers=_headers(admin))
    assert response.status_code == 200
    checks = {row["name"]: row for row in response.json()["checks"]}
    assert checks["database_schema"]["status"] == "unavailable"
    assert "RuntimeError" in checks["database_schema"]["detail"]
    assert "credential-bearing" not in response.text
    assert all(row["probe"] == "not_run" for row in response.json()["providers"])


@pytest.mark.asyncio
async def test_user_filters_and_filtered_total_header(client, admin):
    tag = uuid.uuid4().hex[:10]
    matching = await _user(name=f"Filter {tag}", is_flagged=True)
    seller = await _user(
        name=f"Filter {tag}", account_type=AccountType.buyer_seller)
    await _user(name="No match")

    headers = {**_headers(admin), "Origin": "https://admin.example"}
    response = await client.get(
        f"/admin/users?search={tag}&limit=1&offset=0", headers=headers)
    assert response.status_code == 200
    assert response.headers["x-total-count"] == "2"
    assert response.headers["access-control-expose-headers"]
    assert "X-Total-Count" in response.headers["access-control-expose-headers"]
    assert len(response.json()) == 1

    buyers = await client.get(
        f"/admin/users?search={tag}&account_type=buyer", headers=headers)
    assert buyers.headers["x-total-count"] == "1"
    assert [row["id"] for row in buyers.json()] == [matching.id]

    flagged = await client.get(
        f"/admin/users?search={tag}&flagged_only=true", headers=headers)
    assert [row["id"] for row in flagged.json()] == [matching.id]

    assert (await client.get(
        f"/admin/users?search={tag}&account_type=not-real",
        headers=headers)).status_code == 422
    assert seller.id != matching.id


@pytest.mark.asyncio
async def test_user_detail_is_real_bounded_and_never_exposes_credentials(client, admin):
    seller = await _user(account_type=AccountType.buyer_seller)
    buyer = await _user()
    listing = await _listing(seller)
    released = await _deal(seller, buyer, listing)
    refunded = await _deal(
        seller, buyer, listing, status=DealStatus.refunded,
        refunded_at=datetime.datetime.utcnow())
    disputed = await _deal(seller, buyer, listing, status=DealStatus.disputed)
    async with AsyncSessionLocal() as db:
        db.add(FraudEvent(
            user_id=seller.id, reason="test event", trust_score_at_flag=30))
        db.add(AuditLog(
            actor_id=admin.id, action="test_admin_action",
            resource_type="user", resource_id=seller.id, detail="not a secret"))
        await db.commit()

    response = await client.get(
        f"/admin/users/{seller.id}", headers=_headers(admin))
    assert response.status_code == 200
    body = response.json()
    assert body["user"]["id"] == seller.id
    assert body["user"]["account_type"] == "buyer_seller"
    assert body["stats"]["deals_as_seller"] == 3
    assert body["stats"]["released_deals"] == 1
    assert body["stats"]["refunded_deals"] == 1
    assert body["stats"]["disputed_deals"] >= 1
    assert body["stats"]["open_fraud_events"] == 1
    assert {row["id"] for row in body["recent_deals"]} == {
        released.id, refunded.id, disputed.id}
    assert any(row["action"] == "test_admin_action" for row in body["recent_audit"])
    serialized = response.text.lower()
    assert "password_hash" not in serialized
    assert "not-a-real-hash" not in serialized
    assert (await client.get(
        "/admin/users/does-not-exist", headers=_headers(admin))).status_code == 404


@pytest.mark.asyncio
async def test_deals_list_detail_and_status_validation(client, admin):
    seller = await _user(account_type=AccountType.buyer_seller)
    buyer = await _user()
    listing = await _listing(seller)
    deal = await _deal(seller, buyer, listing, status=DealStatus.disputed)
    other_seller = await _user()
    await _deal(other_seller, buyer, await _listing(other_seller))

    async with AsyncSessionLocal() as db:
        db.add_all([
            _ledger(deal, LedgerAccount.escrow_holding, LedgerDirection.credit, "2000"),
            ExternalEscrow(
                deal_id=deal.id, payment_no=0, provider="econfirm",
                status=EConfirmEscrowStatus.FUNDED, amount=2000,
                buyer_email="buyer@test", seller_email="seller@test",
                receiver_phone="+254700000000"),
            MpesaTransaction(
                deal_id=deal.id, buyer_id=buyer.id, phone=buyer.phone,
                amount=100, checkout_request_id=f"ws_CO_{uuid.uuid4().hex}",
                status=MpesaStatus.success),
            DisputeCase(
                deal_id=deal.id, opener_id=buyer.id, state=CaseState.open,
                branch=CaseBranch.A2, dispute_type="wrong_item"),
        ])
        await db.commit()

    headers = _headers(admin)
    listing_response = await client.get(
        f"/admin/deals?seller_id={seller.id}", headers=headers)
    assert listing_response.status_code == 200
    body = listing_response.json()
    assert body["total"] == 1
    assert body["items"][0]["id"] == deal.id
    assert body["status_counts"]["disputed"] >= 1

    detail = await client.get(f"/admin/deals/{deal.id}", headers=headers)
    assert detail.status_code == 200
    detail_body = detail.json()
    assert detail_body["deal"]["id"] == deal.id
    assert [row["id"] for row in detail_body["ledger_entries"]]
    assert detail_body["external_escrows"][0]["status"] == "funded"
    assert detail_body["mpesa_transactions"][0]["status"] == "success"
    assert detail_body["dispute_cases"][0]["branch"] == "A2"

    assert (await client.get(
        "/admin/deals/does-not-exist", headers=headers)).status_code == 404
    assert (await client.get(
        "/admin/deals?status=not-real", headers=headers)).status_code == 422
    assert (await client.get(
        "/admin/deals?status=released,disputed", headers=headers)).status_code == 200


@pytest.mark.asyncio
async def test_listings_filter_and_are_not_silently_active_only(client, admin):
    seller = await _user(account_type=AccountType.buyer_seller)
    active = await _listing(seller, name="Active item")
    cancelled = await _listing(
        seller, name="Cancelled item", status=ListingStatus.cancelled)

    headers = _headers(admin)
    active_response = await client.get(
        f"/admin/listings?seller_id={seller.id}&status=active", headers=headers)
    assert active_response.status_code == 200
    active_body = active_response.json()
    assert active_body["total"] == 1
    assert [row["id"] for row in active_body["items"]] == [active.id]
    assert active_body["status_counts"]["cancelled"] >= 1

    cancelled_response = await client.get(
        f"/admin/listings?seller_id={seller.id}&status=cancelled", headers=headers)
    assert [row["id"] for row in cancelled_response.json()["items"]] == [cancelled.id]
    assert (await client.get(
        "/admin/listings?status=deleted", headers=headers)).status_code == 422


@pytest.mark.asyncio
async def test_disputes_keep_legacy_and_case_tables_separate(client, admin):
    seller = await _user(account_type=AccountType.buyer_seller)
    buyer = await _user()
    deal = await _deal(seller, buyer, await _listing(seller), status=DealStatus.disputed)

    async with AsyncSessionLocal() as db:
        db.add_all([
            DisputeCase(
                deal_id=deal.id, opener_id=buyer.id, state=CaseState.open,
                branch=CaseBranch.B, dispute_type="not_delivered"),
            Dispute(
                deal_id=deal.id, opener_id=buyer.id, issue_type="not_delivered",
                description="legacy row for the same deal",
                status=DisputeStatus.open),
        ])
        await db.commit()

    response = await client.get(
        f"/admin/disputes?deal_id={deal.id}", headers=_headers(admin))
    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 1
    assert len(body["items"]) == 1
    assert body["items"][0]["deal_id"] == deal.id
    assert body["legacy"]["total"] >= 1
    assert body["legacy"]["open"] >= 1
    assert body["state_counts"]["open"] >= 1

    branched = await client.get(
        f"/admin/disputes?deal_id={deal.id}&branch=B", headers=_headers(admin))
    assert branched.status_code == 200
    assert branched.json()["total"] == 1
    assert (await client.get(
        "/admin/disputes?state=not-real", headers=_headers(admin))).status_code == 422
    assert (await client.get(
        "/admin/disputes?branch=Z9", headers=_headers(admin))).status_code == 422


@pytest.mark.asyncio
async def test_payments_normalize_providers_without_double_counting(client, admin):
    seller = await _user(account_type=AccountType.buyer_seller)
    buyer = await _user()
    listing = await _listing(seller)
    deal = await _deal(seller, buyer, listing)
    mpesa_ref = f"QK{uuid.uuid4().hex[:10].upper()}"
    zetu_ref = f"ZT{uuid.uuid4().hex[:10].upper()}"
    checkout = f"ws_CO_{uuid.uuid4().hex}"

    async with AsyncSessionLocal() as db:
        db.add_all([
            MpesaTransaction(
                deal_id=deal.id, buyer_id=buyer.id, phone=buyer.phone,
                amount=50, checkout_request_id=checkout, mpesa_receipt=mpesa_ref,
                status=MpesaStatus.success),
            ZetuPayPayment(
                reference=zetu_ref, user_id=buyer.id, purpose=Purpose.LISTING_FEE,
                amount=250, phone=buyer.phone, target_id="target",
                status=ZetuPayStatus.SUCCESS, mpesa_receipt="ZT-RECEIPT"),
            ListingPayment(
                user_id=buyer.id, listing_id=listing.id, months=1,
                monthly_fee=250, listing_amount=250, amount=250,
                phone=buyer.phone, status="success", provider="zetupay",
                checkout_request_id=f"ZP-{uuid.uuid4().hex}",
                mpesa_receipt="ZT-RECEIPT"),
            PaymentCallback(
                provider="daraja", checkout_request_id=checkout,
                receipt=mpesa_ref, amount=Decimal("50.00")),
        ])
        await db.commit()

    headers = _headers(admin)
    response = await client.get(
        f"/admin/payments?user_id={buyer.id}", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 2
    assert {(row["source"], row["reference"]) for row in body["items"]} == {
        ("mpesa", mpesa_ref), ("zetupay", zetu_ref)}
    assert body["counts"]["mpesa"]["success"] >= 1
    assert body["counts"]["zetupay"]["success"] >= 1

    by_deal = await client.get(
        f"/admin/payments?deal_id={deal.id}", headers=headers)
    assert by_deal.json()["total"] == 1
    assert by_deal.json()["items"][0]["purpose"] == "deal_commission"

    assert (await client.get(
        "/admin/payments?source=provider-x", headers=headers)).status_code == 422
    assert (await client.get(
        "/admin/payments?status=not-real", headers=headers)).status_code == 422


@pytest.mark.asyncio
async def test_finance_integrity_finds_release_revenue_and_manual_refunds(client, admin):
    seller = await _user(account_type=AccountType.buyer_seller)
    buyer = await _user()
    listing = await _listing(seller)
    now = datetime.datetime.utcnow()
    missing_both = await _deal(seller, buyer, listing, commission=100, released_at=now)
    missing_revenue = await _deal(seller, buyer, listing, commission=50, released_at=now)
    complete = await _deal(seller, buyer, listing, commission=70, released_at=now)
    manual = await _deal(
        seller, buyer, listing, status=DealStatus.disputed, commission=0,
        refund_outcome="seller_silent", refund_requested_at=now)

    async with AsyncSessionLocal() as db:
        db.add_all([
            _ledger(missing_revenue, LedgerAccount.escrow_holding,
                    LedgerDirection.debit, "700"),
            _ledger(complete, LedgerAccount.escrow_holding,
                    LedgerDirection.credit, "1000"),
            _ledger(complete, LedgerAccount.escrow_holding,
                    LedgerDirection.debit, "700"),
            _ledger(complete, LedgerAccount.broka_revenue,
                    LedgerDirection.credit, "70"),
            ExternalEscrow(
                deal_id=manual.id, payment_no=0, provider="econfirm",
                status=EConfirmEscrowStatus.COMPLETED, amount=2000,
                buyer_email="buyer@test", seller_email="seller@test",
                receiver_phone="+254700000000"),
        ])
        await db.commit()

    response = await client.get("/admin/finance-integrity", headers=_headers(admin))
    assert response.status_code == 200
    body = response.json()
    release_ids = {
        row["deal_id"] for row in body["released_deals_without_release_entries"]["sample"]}
    revenue_ids = {
        row["deal_id"] for row in body["released_deals_without_revenue_credit"]["sample"]}
    assert missing_both.id in release_ids
    assert missing_both.id in revenue_ids
    assert missing_revenue.id in revenue_ids
    assert missing_revenue.id not in release_ids
    assert complete.id not in release_ids
    assert complete.id not in revenue_ids
    assert body["released_deals_without_release_entries"]["count"] >= 1
    assert body["released_deals_without_revenue_credit"]["count"] >= 2
    assert body["awaiting_manual_refund"]["count"] >= 1
    assert manual.id in {
        row["deal_id"] for row in body["awaiting_manual_refund"]["sample"]}
    assert body["econfirm"]["completed"] >= 1
    assert body["ledger"]["escrow_integrity_ok"] is False
    assert missing_revenue.id in {
        row["deal_id"] for row in body["ledger"]["negative_escrow_deals"]}

    async with AsyncSessionLocal() as db:
        released = (await db.execute(
            select(func.coalesce(func.sum(Deal.commission), 0))
            .where(Deal.status == DealStatus.released)
        )).scalar()
        revenue = (await db.execute(
            select(func.coalesce(func.sum(LedgerEntry.amount_kes), 0)).where(
                LedgerEntry.account == LedgerAccount.broka_revenue,
                LedgerEntry.direction == LedgerDirection.credit)
        )).scalar()
    assert body["commission"]["released_deals_kes"] == pytest.approx(float(released))
    assert body["commission"]["ledger_revenue_credits_kes"] == pytest.approx(float(revenue))
    assert body["commission"]["gap_kes"] == pytest.approx(float(released) - float(revenue))


@pytest.mark.asyncio
async def test_stores_are_paginated_filtered_and_exclude_deleted(client, admin):
    owner = await _user(account_type=AccountType.buyer_seller)
    tag = uuid.uuid4().hex[:10]
    async with AsyncSessionLocal() as db:
        db.add_all([
            Store(owner_id=owner.id, name=f"Visible {tag}", slug=f"v-{tag}",
                  category="electronics", county="Nairobi"),
            Store(owner_id=owner.id, name=f"Deleted {tag}", slug=f"d-{tag}",
                  category="electronics", county="Nairobi",
                  deleted_at=datetime.datetime.utcnow()),
        ])
        await db.commit()

    headers = _headers(admin)
    visible = await client.get(
        f"/admin/stores?search={tag}&category=electronics&county=Nairobi",
        headers=headers)
    assert visible.status_code == 200
    body = visible.json()
    assert body["total"] == 1
    assert body["items"][0]["name"] == f"Visible {tag}"
    assert body["items"][0]["deleted_at"] is None

    deleted = await client.get(
        f"/admin/stores?search={tag}&status=deleted", headers=headers)
    assert [row["name"] for row in deleted.json()["items"]] == [f"Deleted {tag}"]
    assert (await client.get(
        f"/admin/stores?search={tag}&status=archived", headers=headers)).status_code == 422


@pytest.mark.asyncio
async def test_zeno_activity_uses_durable_evidence_and_labels_local_metrics(client, admin):
    buyer = await _user()
    async with AsyncSessionLocal() as db:
        db.add_all([
            NegotiationMessage(
                sender_id=buyer.id, role="buyer", content="hello",
                via_ai=True, is_agent_initiated=False),
            NegotiationMessage(
                sender_id=buyer.id, role="buyer", content="opened by agent",
                via_ai=True, is_agent_initiated=True),
            AuditLog(
                actor_id="zeno", action="zeno_test_action",
                resource_type="deal", resource_id="deal-x"),
        ])
        await db.commit()

    response = await client.get("/admin/zeno/activity", headers=_headers(admin))
    assert response.status_code == 200
    body = response.json()
    durable = body["durable"]
    assert durable["messages_total"] >= 2
    assert durable["ai_relayed_total"] >= 2
    assert durable["agent_initiated_total"] >= 1
    assert "zeno_test_action" in durable["zeno_audit_actions"]
    assert body["process_local"]["scope"] == "process_local"
    assert body["process_local"]["durability"] == "none"
    assert {row["metric"] for row in body["not_instrumented"]} >= {
        "ai_tokens", "ai_cost", "ai_reply_provenance"}


@pytest.mark.asyncio
async def test_fraud_resolution_is_idempotent_audited_and_authorized(client, admin):
    user = await _user()
    async with AsyncSessionLocal() as db:
        event = FraudEvent(user_id=user.id, reason="manual review", trust_score_at_flag=20)
        db.add(event)
        await db.commit()
        await db.refresh(event)
    headers = _headers(admin)

    first = await client.post(
        f"/admin/fraud-events/{event.id}/resolve",
        json={"reason": "reviewed evidence"}, headers=headers)
    second = await client.post(
        f"/admin/fraud-events/{event.id}/resolve", headers=headers)
    assert first.status_code == second.status_code == 200
    assert first.json()["changed"] is True
    assert second.json()["changed"] is False

    async with AsyncSessionLocal() as db:
        stored = (await db.execute(
            select(FraudEvent).where(FraudEvent.id == event.id)
        )).scalar_one()
        audits = (await db.execute(
            select(AuditLog).where(
                AuditLog.action == "fraud_event_resolved",
                AuditLog.resource_id == event.id)
        )).scalars().all()
    assert stored.resolved is True
    assert stored.reviewed_by_admin is True
    assert len(audits) == 1
    assert audits[0].actor_id == admin.id
    assert "request_id" in audits[0].detail

    ordinary = await _user()
    third = await _user()
    async with AsyncSessionLocal() as db:
        another = FraudEvent(user_id=third.id, reason="x")
        db.add(another)
        await db.commit()
        await db.refresh(another)
    assert (await client.post(
        f"/admin/fraud-events/{another.id}/resolve",
        headers=_headers(ordinary))).status_code == 403
    assert (await client.post(
        f"/admin/fraud-events/{another.id}/resolve")).status_code == 401
    assert (await client.post(
        "/admin/fraud-events/does-not-exist/resolve",
        headers=headers)).status_code == 404
