"""
BROKA - Escrow & Deal Tests (v3.0)
Tests deal finalization, delivery confirmation, audit log creation.
Run: pytest backend/tests/test_escrow.py -v
"""

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_escrow.db"
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
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac


async def _verified_token(client, phone: str) -> str:
    """Runs otp/request -> otp/verify, returns a phone_verify_token.

    v6.1 registration is phone-first: register requires a verified-phone
    token instead of a bare phone number (see test_auth.py).
    """
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    return verify.json()["phone_verify_token"]


@pytest_asyncio.fixture(scope="module")
async def tokens(client):
    # Register seller
    # NOTE: this phone must stay unique across the whole test session, not
    # just this file. See CHANGES.md — api.database builds its engine from
    # DATABASE_URL once at import time, so every test module actually shares
    # one process-wide DB despite each file monkeypatching its own path;
    # "0711223344" used to collide with test_categories.py and caused a 409
    # here (registration is phone-first, so double-booking a phone number is
    # rejected).
    seller_phone = "0722334455"
    seller_verify_token = await _verified_token(client, seller_phone)
    await client.post("/auth/register", json={
        "phone_verify_token": seller_verify_token,
        "name": "Seller Dan", "email": "dan@test.ke",
        "password": "DanPass123!",
        "lat": -1.3, "lng": 36.8,
    })
    seller = (await client.post("/auth/login", json={
        "phone": seller_phone, "password": "DanPass123!",
    })).json()

    # Register buyer
    buyer_phone = "0755667788"
    buyer_verify_token = await _verified_token(client, buyer_phone)
    await client.post("/auth/register", json={
        "phone_verify_token": buyer_verify_token,
        "name": "Buyer Eve", "email": "eve@test.ke",
        "password": "EvePass123!",
        "lat": -1.32, "lng": 36.82,
    })
    buyer = (await client.post("/auth/login", json={
        "phone": buyer_phone, "password": "EvePass123!",
    })).json()

    return {
        "seller_token": seller["access_token"],
        "seller_id":    seller["user_id"],
        "buyer_token":  buyer["access_token"],
        "buyer_id":     buyer["user_id"],
    }


@pytest_asyncio.fixture(scope="module")
async def listing_id(client, tokens):
    resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
        "name": "MacBook Pro M3",
        "category": "electronics",
        "price": 220000,
        "lat": -1.3, "lng": 36.8,
    }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
    assert resp.status_code == 201
    return resp.json()["id"]


class TestDealFlow:
    deal_id: str = ""

    @pytest.mark.asyncio
    async def test_finalize_deal(self, client, tokens, listing_id):
        resp = await client.post("/deal/finalize", json={
            "listing_id":   listing_id,
            "buyer_id":     tokens["buyer_id"],
            "agreed_price": 210000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        assert resp.status_code == 201
        data = resp.json()
        assert data["agreed_price"] == 210000
        assert data["commission"] == pytest.approx(7329, abs=0.01)  # 3.49%
        assert data["status"] == "agreed"
        TestDealFlow.deal_id = data["deal_id"]

    @pytest.mark.asyncio
    async def test_get_deal(self, client, tokens):
        deal_id = TestDealFlow.deal_id
        resp = await client.get(f"/deal/{deal_id}",
            headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert resp.status_code == 200
        assert resp.json()["id"] == deal_id

    @pytest.mark.asyncio
    async def test_only_buyer_confirms_delivery(self, client, tokens):
        """Seller should not be able to confirm delivery."""
        deal_id = TestDealFlow.deal_id
        resp = await client.post(f"/deal/{deal_id}/confirm-delivery",
            headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        assert resp.status_code in (403, 400)

    @pytest.mark.asyncio
    async def test_duplicate_deal_returns_existing(self, client, tokens, listing_id):
        """Finalizing same listing+buyer again should return existing deal."""
        resp = await client.post("/deal/finalize", json={
            "listing_id":   listing_id,
            "buyer_id":     tokens["buyer_id"],
            "agreed_price": 200000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        data = resp.json()
        # Should either 201 with existed=True or 200 — not a brand new deal
        assert data.get("existed") is True or data.get("deal_id") == TestDealFlow.deal_id

    @pytest.mark.asyncio
    async def test_buyer_can_also_finalize(self, client, tokens, listing_id):
        """Phase 17 fix: negotiate_screen.dart's _acceptDeal lets EITHER
        party tap Accept, and negotiation_screen.dart's Finalize button is
        buyer-only — both would 403 against the old seller-only check.
        A second listing is used so this doesn't collide with
        TestDealFlow's own listing_id/deal (duplicate-deal short-circuit
        above)."""
        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "iPhone 15", "category": "electronics",
            "price": 120000, "lat": -1.3, "lng": 36.8,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        assert resp.status_code == 201
        second_listing_id = resp.json()["id"]

        resp = await client.post("/deal/finalize", json={
            "listing_id":   second_listing_id,
            "buyer_id":     tokens["buyer_id"],
            "agreed_price": 115000,
        }, headers={"Authorization": f"Bearer {tokens['buyer_token']}"})  # buyer, not seller
        assert resp.status_code == 201
        data = resp.json()
        assert data["seller_id"] == tokens["seller_id"]
        assert data["buyer_id"] == tokens["buyer_id"]

    @pytest.mark.asyncio
    async def test_stranger_cannot_finalize(self, client, tokens, listing_id):
        """Confirms the Phase 17 fix didn't open finalize up to anyone —
        only the listing's real seller, or the claimed buyer themselves."""
        stranger_phone = "0733445566"
        stranger_verify_token = await _verified_token(client, stranger_phone)
        await client.post("/auth/register", json={
            "phone_verify_token": stranger_verify_token,
            "name": "Stranger Sam", "email": "sam@test.ke",
            "password": "SamPass123!", "lat": -1.3, "lng": 36.8,
        })
        stranger = (await client.post("/auth/login", json={
            "phone": stranger_phone, "password": "SamPass123!",
        })).json()

        resp = await client.post("/deal/finalize", json={
            "listing_id":   listing_id,
            "buyer_id":     tokens["buyer_id"],  # claims to finalize FOR the real buyer
            "agreed_price": 200000,
        }, headers={"Authorization": f"Bearer {stranger['access_token']}"})
        assert resp.status_code == 403


# ─────────────────────────────────────────────────────────────────────────────
# E-Confirm marketplace escrow (2026-09 integration)
#
# Never calls the real E-Confirm API (Phase 21) — get_escrow_provider is
# monkeypatched to return FakeEscrowProvider, a minimal stand-in
# implementing the same EscrowProvider interface real code depends on.
# HTTP-level (through the actual /deal endpoints), matching this file's
# existing style, rather than calling EscrowService methods directly, so
# these also exercise the router/auth/idempotency wiring, not just the
# service logic in isolation.
# ─────────────────────────────────────────────────────────────────────────────
from api.domains.escrow.providers import EscrowProvider, EscrowProviderResult, FeeQuote
from api.models.external_escrow import EConfirmEscrowStatus


class FakeEscrowProvider(EscrowProvider):
    """Configurable fake — tests set .next_status / .next_release_status
    between calls to simulate the provider's state changing over time,
    and read .create_calls / .fund_calls / .release_calls to assert
    BROKA never re-does a call it shouldn't (Phase 21 items 7, 9)."""

    def __init__(self):
        self.create_calls: list[dict] = []
        self.fund_calls: list[tuple] = []
        self.release_calls: list[tuple] = []
        self.status_calls = 0
        self.confirmation_code = "ZAC-TEST-CODE-999"
        self.provider_transaction_id = None  # assigned fresh per create_escrow() call, see below
        self.next_status = "pending"          # what get_status()/create_escrow() report
        self.next_release_status = "Completed"  # what release_escrow() reports
        self.raise_connection_error_on_next_fund = False  # simulates an ambiguous network timeout
        self.raise_connection_error_on_next_create = False

    async def get_fee_quote(self, amount: float) -> FeeQuote:
        return FeeQuote(fee_amount=round(amount * 0.01, 2), currency="KES", raw={})

    async def create_escrow(self, **kwargs) -> EscrowProviderResult:
        self.create_calls.append(kwargs)
        if self.raise_connection_error_on_next_create:
            self.raise_connection_error_on_next_create = False
            from api.core.econfirm_client import EConfirmConnectionError
            raise EConfirmConnectionError("simulated network timeout")
        # A fresh id every call, not a fixed literal: ExternalEscrow.
        # provider_transaction_id is UNIQUE (correctly — two different
        # deals must never cross-wire to the same real provider
        # transaction), and this fake is used by many tests that each
        # create their own deal+escrow against a shared, persisted DB
        # across the whole module. A single hard-coded literal here
        # collided across tests and crashed on that constraint — not an
        # application bug, a test-fixture one (see job-logs__11_: 3
        # failures, all this exact IntegrityError, everywhere else green).
        import uuid as _uuid_mod
        self.provider_transaction_id = f"ec_txn_test_{_uuid_mod.uuid4().hex[:12]}"
        return EscrowProviderResult(
            provider_transaction_id=self.provider_transaction_id,
            status=_map(self.next_status),
            raw_status=self.next_status,
            confirmation_code=self.confirmation_code,
            fee_amount=round(kwargs.get("amount", 0) * 0.01, 2),
            raw={},
        )

    async def fund_escrow(self, provider_transaction_id: str, payer_phone: str) -> EscrowProviderResult:
        self.fund_calls.append((provider_transaction_id, payer_phone))
        if self.raise_connection_error_on_next_fund:
            self.raise_connection_error_on_next_fund = False
            from api.core.econfirm_client import EConfirmConnectionError
            raise EConfirmConnectionError("simulated network timeout")
        return EscrowProviderResult(
            provider_transaction_id=provider_transaction_id,
            status=_map(self.next_status),
            raw_status=self.next_status,
            raw={},
        )

    async def get_status(self, provider_transaction_id: str) -> EscrowProviderResult:
        self.status_calls += 1
        return EscrowProviderResult(
            provider_transaction_id=provider_transaction_id,
            status=_map(self.next_status),
            raw_status=self.next_status,
            raw={},
        )

    async def release_escrow(self, provider_transaction_id: str, confirmation_code: str, notes=None) -> EscrowProviderResult:
        self.release_calls.append((provider_transaction_id, confirmation_code))
        return EscrowProviderResult(
            provider_transaction_id=provider_transaction_id,
            status=_map(self.next_release_status),
            raw_status=self.next_release_status,
            raw={},
        )


def _map(raw: str) -> str:
    from api.domains.escrow.providers import EConfirmProvider
    return EConfirmProvider.map_status(raw)


@pytest_asyncio.fixture
async def fake_provider(monkeypatch):
    """Function-scoped: every test gets its own fresh fake + call log."""
    fake = FakeEscrowProvider()
    monkeypatch.setattr("api.domains.escrow.service.get_escrow_provider", lambda: fake)
    yield fake


@pytest_asyncio.fixture(scope="module")
async def econfirm_listing_id(client, tokens):
    """A dedicated listing/deal for the E-Confirm tests, kept separate
    from TestDealFlow's — both agreed_price and the buyer/seller pairing
    need to stay stable across this class's tests, which run in order and
    build on each other's state (same pattern TestDealFlow above uses)."""
    resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
        "name": "Sony A7 IV Camera", "category": "electronics",
        "price": 300000, "lat": -1.3, "lng": 36.8,
    }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
    assert resp.status_code == 201
    return resp.json()["id"]


class TestEConfirmEscrow:
    deal_id: str = ""

    @pytest.mark.asyncio
    async def test_setup_deal(self, client, tokens, econfirm_listing_id):
        resp = await client.post("/deal/finalize", json={
            "listing_id": econfirm_listing_id,
            "buyer_id": tokens["buyer_id"],
            "agreed_price": 300000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        assert resp.status_code == 201
        TestEConfirmEscrow.deal_id = resp.json()["deal_id"]

    @pytest.mark.asyncio
    async def test_fee_quote(self, client, tokens, fake_provider):
        resp = await client.get(
            f"/deal/{TestEConfirmEscrow.deal_id}/fee-quote",
            headers={"Authorization": f"Bearer {tokens['buyer_token']}"},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["goods_amount"] == 300000
        assert data["merchant_commission"] == pytest.approx(10470, abs=0.01)  # 3.49%
        assert data["provider_fee"] == pytest.approx(3000, rel=0.01)  # fake's 1%
        assert data["total_to_pay"] == pytest.approx(313470, abs=0.01)  # 4.49% all-in

    @pytest.mark.asyncio
    async def test_release_before_funded_rejected(self, client, tokens, fake_provider):
        """Phase 21 item 9: release before funded must be rejected."""
        resp = await client.post(
            f"/deal/{TestEConfirmEscrow.deal_id}/confirm-delivery",
            headers={"Authorization": f"Bearer {tokens['buyer_token']}"},
        )
        assert resp.status_code == 400  # deal is still 'agreed', not 'paid'

    @pytest.mark.asyncio
    async def test_fund_creates_escrow_and_sends_stk(self, client, tokens, fake_provider):
        fake_provider.next_status = "stk_initiated"
        resp = await client.post(
            f"/deal/{TestEConfirmEscrow.deal_id}/fund",
            json={"payer_phone": "254700111222"},
            headers={"Authorization": f"Bearer {tokens['buyer_token']}"},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["payment_status"] == "stk_prompt_sent"
        assert len(fake_provider.create_calls) == 1
        assert fake_provider.create_calls[0]["buyer_email"] == "eve@test.ke"
        assert fake_provider.create_calls[0]["seller_email"] == "dan@test.ke"
        assert len(fake_provider.fund_calls) == 1
        assert fake_provider.fund_calls[0][1] == "254700111222"
        # confirmation_code must never appear anywhere in the response
        assert "ZAC-TEST-CODE-999" not in resp.text
        assert "confirmation_code" not in resp.text

    @pytest.mark.asyncio
    async def test_duplicate_fund_does_not_recreate_escrow(self, client, tokens, fake_provider):
        """2026-09 hardening pass, Section 1: a second /fund tap while
        still PENDING must not create a second escrow AND must not send
        a second STK push — reconciliation is used instead (see
        EscrowService.fund_deal_escrow's docstring for why "the buyer
        tapped Pay again" isn't sufficient authorization for a second
        real money-moving request, corrected from an earlier version of
        this integration that allowed it).

        fake_provider is function-scoped (a fresh instance per test), so
        the escrow/deal state this test exercises comes entirely from
        what test_fund_creates_escrow_and_sends_stk already persisted to
        the DB — this test's own fake_provider should see ZERO calls to
        create_escrow/fund_escrow, only a read-only get_status() as part
        of the safe reconciliation pass.
        """
        resp = await client.post(
            f"/deal/{TestEConfirmEscrow.deal_id}/fund",
            json={"payer_phone": "254700111222"},
            headers={"Authorization": f"Bearer {tokens['buyer_token']}"},
        )
        assert resp.status_code == 200
        assert len(fake_provider.create_calls) == 0  # never re-created — escrow already existed in the DB
        assert len(fake_provider.fund_calls) == 0    # never re-sent — funding_initiated_at was already set
        assert fake_provider.status_calls == 1       # reconciled instead (read-only, safe)

    @pytest.mark.asyncio
    async def test_payment_status_reconciles_to_funded_and_moves_deal_to_paid(self, client, tokens, fake_provider):
        fake_provider.next_status = "Escrow Funded"
        resp = await client.get(
            f"/deal/{TestEConfirmEscrow.deal_id}/payment-status",
            headers={"Authorization": f"Bearer {tokens['buyer_token']}"},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["payment_status"] == "secured_in_escrow"
        assert data["deal_status"] == "paid"
        assert data["can_confirm_delivery"] is True

    @pytest.mark.asyncio
    async def test_release_completes_and_marks_deal_released(self, client, tokens, fake_provider, caplog):
        fake_provider.next_release_status = "Completed"
        resp = await client.post(
            f"/deal/{TestEConfirmEscrow.deal_id}/confirm-delivery",
            headers={"Authorization": f"Bearer {tokens['buyer_token']}"},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "released"
        assert len(fake_provider.release_calls) == 1
        assert fake_provider.release_calls[0][1] == "ZAC-TEST-CODE-999"  # decrypted correctly
        # Phase 2/23: confirmation_code must never appear in the response...
        assert "ZAC-TEST-CODE-999" not in resp.text
        # ...nor in anything logged during this request.
        assert "ZAC-TEST-CODE-999" not in caplog.text

    @pytest.mark.asyncio
    async def test_payout_failed_keeps_deal_paid_not_released(self, client, tokens, fake_provider, econfirm_listing_id):
        """Separate deal: this one's release call reports payout_failed,
        which must NOT mark Deal.released (Phase 10/20)."""
        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "PS5 Console", "category": "electronics",
            "price": 60000, "lat": -1.3, "lng": 36.8,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        listing2 = resp.json()["id"]
        resp = await client.post("/deal/finalize", json={
            "listing_id": listing2, "buyer_id": tokens["buyer_id"], "agreed_price": 60000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        deal2 = resp.json()["deal_id"]

        fake_provider.next_status = "stk_initiated"
        await client.post(f"/deal/{deal2}/fund", json={"payer_phone": "254700111333"},
                           headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        fake_provider.next_status = "Escrow Funded"
        await client.get(f"/deal/{deal2}/payment-status",
                          headers={"Authorization": f"Bearer {tokens['buyer_token']}"})

        fake_provider.next_release_status = "payout_failed"
        resp = await client.post(f"/deal/{deal2}/confirm-delivery",
                                  headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert resp.status_code == 502

        status_resp = await client.get(f"/deal/{deal2}/payment-status",
                                        headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert status_resp.json()["deal_status"] == "paid"  # NOT released

    @pytest.mark.asyncio
    async def test_duplicate_release_request_does_not_release_twice(
        self, client, tokens, fake_provider, econfirm_listing_id,
    ):
        """Finalization pass, Section 10/20 test 13: a release whose
        IMMEDIATE provider response is payout_initiated (not Completed)
        used to leave Deal.status at 'paid', which meant a second,
        concurrent/retried confirm-delivery call could pass the old
        lock's re-check (it only looked at deal.status) and call
        release_escrow() a second time. Fixed by re-checking
        escrow.status fresh, under the lock, before the provider call —
        see EscrowService._confirm_delivery_econfirm's docstring."""
        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "MacBook Air M3", "category": "electronics",
            "price": 150000, "lat": -1.3, "lng": 36.8,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        listing3 = resp.json()["id"]
        resp = await client.post("/deal/finalize", json={
            "listing_id": listing3, "buyer_id": tokens["buyer_id"], "agreed_price": 150000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        deal3 = resp.json()["deal_id"]

        fake_provider.next_status = "stk_initiated"
        await client.post(f"/deal/{deal3}/fund", json={"payer_phone": "254700111444"},
                           headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        fake_provider.next_status = "Escrow Funded"
        await client.get(f"/deal/{deal3}/payment-status",
                          headers={"Authorization": f"Bearer {tokens['buyer_token']}"})

        # First release: provider's immediate response is payout_initiated,
        # not Completed — Deal.status stays 'paid' by design.
        fake_provider.next_release_status = "payout_initiated"
        resp1 = await client.post(f"/deal/{deal3}/confirm-delivery",
                                   headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert resp1.status_code == 200
        assert resp1.json()["status"] == "release_pending"
        assert len(fake_provider.release_calls) == 1

        # Second confirm-delivery call (retry/double-tap) while still
        # release_pending: must NOT call release_escrow() again.
        resp2 = await client.post(f"/deal/{deal3}/confirm-delivery",
                                   headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert len(fake_provider.release_calls) == 1  # still just the one
        assert resp2.status_code in (200, 409)  # either a no-op status echo or a clean rejection

    @pytest.mark.asyncio
    async def test_unauthorized_user_cannot_fund_or_release_others_deal(
        self, client, tokens, fake_provider, econfirm_listing_id,
    ):
        """Finalization pass, Section 15/20 test 19."""
        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Dell XPS 13", "category": "electronics",
            "price": 90000, "lat": -1.3, "lng": 36.8,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        listing4 = resp.json()["id"]
        resp = await client.post("/deal/finalize", json={
            "listing_id": listing4, "buyer_id": tokens["buyer_id"], "agreed_price": 90000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        deal4 = resp.json()["deal_id"]

        stranger_phone = "0722998877"
        stranger_verify_token = await _verified_token(client, stranger_phone)
        await client.post("/auth/register", json={
            "phone_verify_token": stranger_verify_token,
            "name": "Nosy Nick", "email": "nick@test.ke",
            "password": "NickPass123!", "lat": -1.3, "lng": 36.8,
        })
        stranger = (await client.post("/auth/login", json={
            "phone": stranger_phone, "password": "NickPass123!",
        })).json()
        stranger_headers = {"Authorization": f"Bearer {stranger['access_token']}"}

        resp = await client.post(f"/deal/{deal4}/fund", json={"payer_phone": "254700555666"},
                                  headers=stranger_headers)
        assert resp.status_code == 403
        assert len(fake_provider.create_calls) == 0

        resp = await client.get(f"/deal/{deal4}/fee-quote", headers=stranger_headers)
        assert resp.status_code == 403

        resp = await client.post(f"/deal/{deal4}/confirm-delivery", headers=stranger_headers)
        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_network_timeout_during_fund_sends_zero_duplicate_stk(
        self, client, tokens, fake_provider, econfirm_listing_id,
    ):
        """Hardening pass, Section 5 test D: a fund attempt that fails
        ambiguously (network timeout — E-Confirm may or may not have
        actually received the STK request) must not be retried
        automatically by a follow-up /fund call."""
        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "iPad Pro", "category": "electronics",
            "price": 80000, "lat": -1.3, "lng": 36.8,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        listing5 = resp.json()["id"]
        resp = await client.post("/deal/finalize", json={
            "listing_id": listing5, "buyer_id": tokens["buyer_id"], "agreed_price": 80000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        deal5 = resp.json()["deal_id"]

        fake_provider.next_status = "stk_initiated"
        fake_provider.raise_connection_error_on_next_fund = True
        resp1 = await client.post(f"/deal/{deal5}/fund", json={"payer_phone": "254700111555"},
                                   headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert resp1.status_code == 503  # ambiguous outcome, surfaced honestly rather than guessed at
        assert len(fake_provider.fund_calls) == 1  # the attempt WAS made once

        # Retry after the "timeout" — must NOT send a second STK push.
        resp2 = await client.post(f"/deal/{deal5}/fund", json={"payer_phone": "254700111555"},
                                   headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert resp2.status_code == 200
        assert len(fake_provider.fund_calls) == 1  # still just the one attempt — not resent
        assert fake_provider.status_calls == 1     # reconciled (read-only) instead of retrying

    @pytest.mark.asyncio
    async def test_ambiguous_create_does_not_duplicate_provider_transaction(
        self, client, tokens, fake_provider, econfirm_listing_id,
    ):
        """Hardening pass, Section 2/5 test E: an ambiguous
        create_transaction failure (network timeout, outcome unknown)
        must not let a quick retry silently create a second provider-side
        transaction. The full 20-second-then-UNKNOWN transition beyond
        this immediate-retry window runs through the same code path (see
        fund_deal_escrow's CREATING branch) but isn't re-verified here
        with a real 20-second sleep in the test suite — this covers the
        more common real-world case (an impatient near-immediate retry)."""
        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Nikon Z6", "category": "electronics",
            "price": 200000, "lat": -1.3, "lng": 36.8,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        listing6 = resp.json()["id"]
        resp = await client.post("/deal/finalize", json={
            "listing_id": listing6, "buyer_id": tokens["buyer_id"], "agreed_price": 200000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        deal6 = resp.json()["deal_id"]

        fake_provider.raise_connection_error_on_next_create = True
        resp1 = await client.post(f"/deal/{deal6}/fund", json={"payer_phone": "254700111666"},
                                   headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert resp1.status_code == 503
        assert len(fake_provider.create_calls) == 1

        # Immediate retry, still well within the grace window — must NOT
        # create a second provider-side transaction.
        resp2 = await client.post(f"/deal/{deal6}/fund", json={"payer_phone": "254700111666"},
                                   headers={"Authorization": f"Bearer {tokens['buyer_token']}"})
        assert resp2.status_code == 409
        assert len(fake_provider.create_calls) == 1  # still just the one attempt
        assert len(fake_provider.fund_calls) == 0    # never even reached funding

    @pytest.mark.asyncio
    async def test_pending_blocks_fund_regardless_of_idempotency_key(
        self, client, tokens, fake_provider, econfirm_listing_id,
    ):
        """
        Direct response to the explicit ask: PENDING + a DIFFERENT
        Idempotency-Key, PENDING + NO Idempotency-Key, and PENDING +
        repeated identical requests must all result in zero additional
        STK pushes.

        This is deliberately exercised with Redis unavailable/disabled
        (the normal state in this test environment — see core/config.py's
        redis_enabled), where idempotency_guard's header-based response
        caching is a no-op (core/idempotency.py: no Redis configured ->
        cached=False every time, regardless of the header). That's the
        point: the protection under test here is EscrowService's own
        state check (escrow.status == PENDING and funding_initiated_at
        is set), not the caching layer — so this proves the guarantee
        holds even when request-level idempotency caching contributes
        nothing at all.
        """
        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Canon R6", "category": "electronics",
            "price": 250000, "lat": -1.3, "lng": 36.8,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        listing7 = resp.json()["id"]
        resp = await client.post("/deal/finalize", json={
            "listing_id": listing7, "buyer_id": tokens["buyer_id"], "agreed_price": 250000,
        }, headers={"Authorization": f"Bearer {tokens['seller_token']}"})
        deal7 = resp.json()["deal_id"]

        buyer_auth = {"Authorization": f"Bearer {tokens['buyer_token']}"}
        fake_provider.next_status = "stk_initiated"

        # First call — legitimate, real STK push.
        resp = await client.post(f"/deal/{deal7}/fund", json={"payer_phone": "254700111777"},
                                  headers={**buyer_auth, "X-Idempotency-Key": "key-A"})
        assert resp.status_code == 200
        assert len(fake_provider.fund_calls) == 1

        # Same key repeated (the "buyer tapped Pay again, same request"
        # case Idempotency-Key exists for).
        resp = await client.post(f"/deal/{deal7}/fund", json={"payer_phone": "254700111777"},
                                  headers={**buyer_auth, "X-Idempotency-Key": "key-A"})
        assert resp.status_code == 200
        assert len(fake_provider.fund_calls) == 1

        # DIFFERENT key — exactly the case the prior implementation got
        # wrong (a different key bypassed the cache entirely and reached
        # fund_escrow() again). Must still be zero additional calls.
        resp = await client.post(f"/deal/{deal7}/fund", json={"payer_phone": "254700111777"},
                                  headers={**buyer_auth, "X-Idempotency-Key": "key-B-completely-different"})
        assert resp.status_code == 200
        assert len(fake_provider.fund_calls) == 1

        # NO key at all.
        resp = await client.post(f"/deal/{deal7}/fund", json={"payer_phone": "254700111777"},
                                  headers=buyer_auth)
        assert resp.status_code == 200
        assert len(fake_provider.fund_calls) == 1

        # A few more rapid repeats for good measure.
        for _ in range(3):
            resp = await client.post(f"/deal/{deal7}/fund", json={"payer_phone": "254700111777"},
                                      headers=buyer_auth)
            assert resp.status_code == 200
        assert len(fake_provider.fund_calls) == 1  # still exactly one real STK push, ever
        assert len(fake_provider.create_calls) == 1  # and exactly one escrow, ever


class TestEConfirmProviderStatusNormalization:
    """Section 7 of the finalization spec: provider status casing/format
    must not affect behavior. Exercised directly against
    EConfirmProvider.map_status rather than over HTTP — this is pure
    string-normalization logic with no I/O, so a unit test is the right
    level rather than spinning up a full request for each variant."""

    def test_casing_and_spacing_variants_all_map_the_same(self):
        from api.domains.escrow.providers import EConfirmProvider
        from api.models.external_escrow import EConfirmEscrowStatus

        variants = ["Escrow Funded", "escrow_funded", "ESCROW FUNDED", "escrow-funded", "  Escrow Funded  "]
        for v in variants:
            assert EConfirmProvider.map_status(v) == EConfirmEscrowStatus.FUNDED, f"failed for {v!r}"

    def test_unrecognized_status_maps_to_unknown_not_guessed(self):
        from api.domains.escrow.providers import EConfirmProvider
        from api.models.external_escrow import EConfirmEscrowStatus

        assert EConfirmProvider.map_status("something_new_v3") == EConfirmEscrowStatus.UNKNOWN
        assert EConfirmProvider.map_status(None) == EConfirmEscrowStatus.UNKNOWN
        assert EConfirmProvider.map_status("") == EConfirmEscrowStatus.UNKNOWN


class TestEConfirmClientContract:
    """
    Finalization pass, Section 2A/2B: exercises EConfirmClient directly
    (not through the fake provider used above, which intentionally
    bypasses this layer entirely) to verify the actual wire-level
    corrections: GET+query-param for fee_quote, and response-envelope
    normalization. Mocks _raw_call rather than real httpx, per Phase 21 -
    no real network call.

    NOTE ON EXECUTION: this class needs `httpx` importable (econfirm_client.py
    imports it at module level) — same requirement backend/requirements.txt
    already declares, just flagging it since it's the one dependency this
    specific test class can't avoid touching.
    """

    @staticmethod
    def _fake_response(status_code: int, body: dict):
        class _Resp:
            def __init__(self, sc, b):
                self.status_code = sc
                self._b = b
            def json(self):
                return self._b
        return _Resp(status_code, body)

    @pytest.mark.asyncio
    async def test_fee_quote_uses_get_with_query_param(self, monkeypatch):
        from api.core.econfirm_client import EConfirmClient
        client = EConfirmClient(api_key="test-key", base_url="https://api.econfirm.co.ke/api/2")

        captured = {}
        async def fake_raw_call(self_, method, url, json_body, params, headers):
            captured["method"] = method
            captured["url"] = url
            captured["json_body"] = json_body
            captured["params"] = params
            return TestEConfirmClientContract._fake_response(200, {"fee": 100, "currency": "KES"})

        monkeypatch.setattr(EConfirmClient, "_raw_call", fake_raw_call)
        result = await client.fee_quote(10000.0)

        assert captured["method"] == "GET"
        assert captured["url"].endswith("/fee-quote")
        assert captured["json_body"] is None  # NOT sent as a POST body
        assert captured["params"] == {"amount": 10000}  # integer, as a query param
        assert result["fee"] == 100

    @pytest.mark.asyncio
    async def test_enveloped_response_is_unwrapped(self, monkeypatch):
        from api.core.econfirm_client import EConfirmClient
        client = EConfirmClient(api_key="test-key", base_url="https://api.econfirm.co.ke/api/2")

        async def fake_raw_call(self_, method, url, json_body, params, headers):
            return TestEConfirmClientContract._fake_response(200, {
                "success": True,
                "data": {"id": "ec_txn_abc", "status": "pending", "amount": 5000},
            })

        monkeypatch.setattr(EConfirmClient, "_raw_call", fake_raw_call)
        result = await client.get_transaction("ec_txn_abc")
        assert result == {"id": "ec_txn_abc", "status": "pending", "amount": 5000}

    @pytest.mark.asyncio
    async def test_flat_response_passes_through_unchanged(self, monkeypatch):
        from api.core.econfirm_client import EConfirmClient
        client = EConfirmClient(api_key="test-key", base_url="https://api.econfirm.co.ke/api/2")

        async def fake_raw_call(self_, method, url, json_body, params, headers):
            return TestEConfirmClientContract._fake_response(200, {"id": "ec_txn_xyz", "status": "pending"})

        monkeypatch.setattr(EConfirmClient, "_raw_call", fake_raw_call)
        result = await client.get_transaction("ec_txn_xyz")
        assert result == {"id": "ec_txn_xyz", "status": "pending"}

    @pytest.mark.asyncio
    async def test_success_false_envelope_raises_even_on_http_200(self, monkeypatch):
        from api.core.econfirm_client import EConfirmClient, EConfirmAPIError
        client = EConfirmClient(api_key="test-key", base_url="https://api.econfirm.co.ke/api/2")

        async def fake_raw_call(self_, method, url, json_body, params, headers):
            return TestEConfirmClientContract._fake_response(200, {
                "success": False, "message": "transaction not found",
            })

        monkeypatch.setattr(EConfirmClient, "_raw_call", fake_raw_call)
        with pytest.raises(EConfirmAPIError):
            await client.get_transaction("ec_txn_missing")

    @pytest.mark.asyncio
    async def test_malformed_non_dict_response_raises_controlled_error(self, monkeypatch):
        from api.core.econfirm_client import EConfirmClient, EConfirmError
        client = EConfirmClient(api_key="test-key", base_url="https://api.econfirm.co.ke/api/2")

        async def fake_raw_call(self_, method, url, json_body, params, headers):
            return TestEConfirmClientContract._fake_response(200, ["not", "a", "dict"])

        monkeypatch.setattr(EConfirmClient, "_raw_call", fake_raw_call)
        with pytest.raises(EConfirmError):
            await client.get_transaction("ec_txn_weird")
