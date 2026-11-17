"""Store orders, end to end through the API: a buyer with no app signs in
with an SMS code, sends a store an order request, the store confirms or
changes it, the buyer confirms, the store hands it over and the buyer
confirms receipt - and every rule on the way: who may see and do what,
idempotent submission, tracked stock that cannot be over-reserved and is
always given back, payment records that stay reports, notifications that
never undo an order, and insights that keep requests apart from
completed orders.

The rules themselves are pinned in test_store_order_rules.py; this file is
what only the database and the HTTP layer can show. Same fixture shape as
test_stores.py: a module-scoped database and client, a fresh seller and
buyer per test.
"""
import asyncio
import itertools
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text, update

import api.database as db_module
from api.database import Deal, DealStatus, Listing, init_db, reset_engine
from api.models.store_order import (
    StoreOrder, StoreOrderEvent, StoreOrderNotification, StoreOrderPaymentReport,
)
from main import app
from tests.legal_payload import legal_payload


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_orders.db"
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


_phones = itertools.count(1)


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _key() -> str:
    return uuid.uuid4().hex


async def _seller(client) -> tuple[str, str, str]:
    """(user_id, token, store_id): a long-term seller with an open store."""
    n = next(_phones)
    phone = f"0711{n:06d}"
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    reg = await client.post("/auth/register", json={
        "phone_verify_token": verify.json()["phone_verify_token"], "name": f"Seller {n}",
        "password": "SellerPass123!", "lat": -1.286, "lng": 36.817,
        "account_type": "buyer_seller", "seller_tier": "long_term",
        "business_name": f"Shop {n}", "business_category": "Electronics",
        "business_location": "Nairobi", "legal_acceptance": legal_payload(),
    })
    assert reg.status_code == 201, reg.text
    token = reg.json()["access_token"]
    store = await client.post("/stores", json={"name": f"Order Test Store {n}"}, headers=_auth(token))
    assert store.status_code == 201, store.text
    return reg.json()["user_id"], token, store.json()["id"]


async def _buyer(client, name: str = "Amina Wanjiku") -> tuple[str, str]:
    """(user_id, token): a buyer who never installed the app - signed up
    on the web with an SMS code, no password and no location."""
    phone = f"0722{next(_phones):06d}"
    req = await client.post("/auth/otp/sign-in/request", json={"phone": phone})
    assert req.status_code == 200, req.text
    assert req.json()["account_exists"] is False
    verify = await client.post("/auth/otp/sign-in/verify",
                               json={"phone": phone, "code": req.json()["debug_code"]})
    assert verify.status_code == 200, verify.text
    assert verify.json()["account_exists"] is False
    reg = await client.post("/auth/otp/sign-in/register", json={
        "phone_verify_token": verify.json()["phone_verify_token"], "name": name,
        "legal_acceptance": legal_payload(),
    })
    assert reg.status_code == 201, reg.text
    return reg.json()["user_id"], reg.json()["access_token"]


async def _listing(client, token: str, store_id: str, *, name: str = "Samsung A15 phone",
                   price: float = 12500, quantity=None) -> str:
    body = {
        "name": name, "category": "electronics", "price": price, "lat": -1.286, "lng": 36.817,
        "description": "Brand new in the box, with charger and a one year warranty.",
        "store_id": store_id,
    }
    if quantity is not None:
        body["quantity"] = quantity
    resp = await client.post("/listings/", json=body, headers=_auth(token))
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def _track(client, token: str, store_id: str, listing_id: str, quantity: int, **extra):
    resp = await client.patch(
        f"/stores/{store_id}/manage/listings/{listing_id}/stock",
        json={"stock_tracked": True, "quantity": quantity, **extra}, headers=_auth(token),
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


async def _submit(client, token: str, store_id: str, items, *, key=None, fulfilment="delivery",
                  address="Kilimani, opposite Yaya Centre", **extra):
    body = {"store_id": store_id, "items": items, "fulfilment": fulfilment, **extra}
    if fulfilment == "delivery" and address is not None:
        body["delivery_address"] = address
    return await client.post("/orders", json=body,
                             headers={**_auth(token), "X-Idempotency-Key": key or _key()})


async def _order(client, token, store_id, listing_id, quantity=1, **extra) -> dict:
    resp = await _submit(client, token, store_id, [{"listing_id": listing_id, "quantity": quantity}], **extra)
    assert resp.status_code == 201, resp.text
    return resp.json()


async def _post(client, token, path, body=None):
    return await client.post(path, json=body if body is not None else {}, headers=_auth(token))


async def _listing_row(listing_id: str):
    async with db_module.AsyncSessionLocal() as db:
        return (await db.execute(
            select(Listing.quantity, Listing.stock_reserved).where(Listing.id == listing_id)
        )).one()


# ── 1-2: submitting ─────────────────────────────────────────────────────────

class TestSubmission:
    @pytest.mark.asyncio
    async def test_a_buyer_without_the_app_submits_an_order(self, client):
        _, seller_token, store_id = await _seller(client)
        # A stated quantity: a listing without one is a single item, and two
        # of it is refused (stock.request_limit).
        lid = await _listing(client, seller_token, store_id, price=12500, quantity=5)
        _, buyer_token = await _buyer(client)
        order = await _order(client, buyer_token, store_id, lid, quantity=2, note="Call when near")
        assert order["status"] == "submitted"
        assert order["role"] == "buyer"
        assert order["reference"].startswith("BK-")
        assert order["items"][0]["requested_quantity"] == 2
        # The price is the listing's, in cents, whatever the browser showed.
        assert order["items"][0]["requested_unit_price_minor"] == 1_250_000
        assert order["totals"]["requested_subtotal_minor"] == 2_500_000
        assert order["totals"]["total_minor"] is None
        assert order["expires_at"] and order["expiry_stage"] == "seller_response"
        assert order["allowed_actions"] == ["cancel"]
        assert order["payment"]["arrangement"] is None
        assert order["fulfilment"]["contact_phone"].startswith("+254")
        # The store hears about it, in its updates feed.
        feed = await client.get("/orders/notifications", headers=_auth(seller_token))
        assert feed.json()["unread"] == 1
        assert feed.json()["items"][0]["title"] == "New order request"
        assert feed.json()["items"][0]["order_id"] == order["id"]

    @pytest.mark.asyncio
    async def test_unauthenticated_and_invalid_requests_are_refused(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        items = [{"listing_id": lid, "quantity": 1}]
        body = {"store_id": store_id, "items": items, "fulfilment": "collection"}
        assert (await client.post("/orders", json=body, headers={"X-Idempotency-Key": _key()})).status_code == 401
        # No idempotency key: refused, nothing created.
        r = await client.post("/orders", json=body, headers=_auth(buyer_token))
        assert r.status_code == 400 and r.json()["detail"]["code"] == "IDEMPOTENCY_KEY_REQUIRED"
        # A price, a total or a status from the client is not ignored - it is refused.
        for extra in ({"price": 1}, {"total_minor": 1}, {"status": "completed"}, {"buyer_id": "x"}):
            r = await client.post("/orders", json={**body, **extra},
                                  headers={**_auth(buyer_token), "X-Idempotency-Key": _key()})
            assert r.status_code == 422, extra
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 0}])
        assert r.status_code == 422
        r = await _submit(client, buyer_token, store_id, items, address=None)
        assert r.status_code == 400 and r.json()["detail"]["code"] == "ORDER_ADDRESS_REQUIRED"
        r = await _submit(client, buyer_token, store_id, items + items)
        assert r.status_code == 400 and r.json()["detail"]["code"] == "ORDER_DUPLICATE_ITEM"
        r = await _submit(client, buyer_token, store_id, items, contact_phone="not a phone")
        assert r.status_code == 400 and r.json()["detail"]["code"] == "ORDER_PHONE_INVALID"
        async with db_module.AsyncSessionLocal() as db:
            count = (await db.execute(
                select(StoreOrder.id).where(StoreOrder.store_id == store_id))).all()
        assert count == []

    @pytest.mark.asyncio
    async def test_one_checkout_is_one_store(self, client):
        _, token_a, store_a = await _seller(client)
        _, token_b, store_b = await _seller(client)
        mine = await _listing(client, token_a, store_a)
        theirs = await _listing(client, token_b, store_b)
        _, buyer_token = await _buyer(client)
        r = await _submit(client, buyer_token, store_a, [
            {"listing_id": mine, "quantity": 1}, {"listing_id": theirs, "quantity": 1}])
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "ORDER_ITEM_UNAVAILABLE"
        assert r.json()["detail"]["listing_id"] == theirs

    @pytest.mark.asyncio
    async def test_a_seller_cannot_order_from_their_own_store(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        r = await _submit(client, seller_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert r.status_code == 400 and r.json()["detail"]["code"] == "ORDER_OWN_STORE"

    @pytest.mark.asyncio
    async def test_orders_follow_the_switch(self, client):
        from api.core.config import settings
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        store = await client.get(f"/stores/{store_id}")
        assert store.json()["orders_enabled"] is True and store.json()["accepting_orders"] is True
        before = settings.store_orders_enabled
        object.__setattr__(settings, "store_orders_enabled", False)
        try:
            r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 1}])
            assert r.status_code == 409 and r.json()["detail"]["code"] == "ORDERS_OFF"
            assert (await client.get(f"/stores/{store_id}")).json()["orders_enabled"] is False
        finally:
            object.__setattr__(settings, "store_orders_enabled", before)


# ── 7: idempotency ─────────────────────────────────────────────────────────

class TestIdempotency:
    @pytest.mark.asyncio
    async def test_a_retried_submission_is_the_same_order(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        key = _key()
        items = [{"listing_id": lid, "quantity": 1}]
        first = await _submit(client, buyer_token, store_id, items, key=key)
        second = await _submit(client, buyer_token, store_id, items, key=key)
        assert first.status_code == 201 and second.status_code == 200
        assert second.json()["id"] == first.json()["id"]
        assert second.json()["replayed"] is True and first.json()["replayed"] is False
        # The same key for a different request is refused, never merged.
        other = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 1}],
                              key=key, fulfilment="collection")
        assert other.status_code == 409 and other.json()["detail"]["code"] == "IDEMPOTENCY_KEY_REUSED"
        async with db_module.AsyncSessionLocal() as db:
            orders = (await db.execute(select(StoreOrder.id).where(StoreOrder.store_id == store_id))).all()
            notes = (await db.execute(select(StoreOrderNotification.id).where(
                StoreOrderNotification.order_id == first.json()["id"]))).all()
        assert len(orders) == 1
        assert len(notes) == 1   # one "new order" for the store, not one per attempt

    @pytest.mark.asyncio
    async def test_simultaneous_retries_make_one_order(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        key = _key()
        items = [{"listing_id": lid, "quantity": 1}]
        results = await asyncio.gather(*(
            _submit(client, buyer_token, store_id, items, key=key) for _ in range(3)
        ), return_exceptions=True)
        ok = [r for r in results if not isinstance(r, Exception) and r.status_code in (200, 201)]
        assert ok, results
        assert len({r.json()["id"] for r in ok}) == 1
        async with db_module.AsyncSessionLocal() as db:
            orders = (await db.execute(select(StoreOrder.id).where(StoreOrder.store_id == store_id))).all()
        assert len(orders) == 1


# ── 4-6: who may see and change an order ───────────────────────────────────

class TestAccess:
    @pytest.mark.asyncio
    async def test_another_buyer_cannot_read_an_order(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        _, other_token = await _buyer(client, name="Other Buyer")
        order = await _order(client, buyer_token, store_id, lid)
        r = await client.get(f"/orders/{order['id']}", headers=_auth(other_token))
        assert r.status_code == 404
        assert (await client.get("/orders", headers=_auth(other_token))).json()["total"] == 0
        assert (await _post(client, other_token, f"/orders/{order['id']}/cancel")).status_code == 404

    @pytest.mark.asyncio
    async def test_another_seller_cannot_see_or_change_a_stores_orders(self, client):
        _, seller_token, store_id = await _seller(client)
        _, rival_token, rival_store = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        order = await _order(client, buyer_token, store_id, lid)
        assert (await client.get(f"/stores/{store_id}/orders", headers=_auth(rival_token))).status_code == 403
        assert (await client.get(f"/stores/{store_id}/orders/summary",
                                 headers=_auth(rival_token))).status_code == 403
        assert (await client.get(f"/orders/{order['id']}", headers=_auth(rival_token))).status_code == 404
        for action in ("accept", "decline", "preparing", "dispatch", "delivered"):
            r = await _post(client, rival_token, f"/orders/{order['id']}/{action}", {"reason": "nope"})
            assert r.status_code == 404, action
        # Its own list never shows another store's order.
        own = await client.get(f"/stores/{rival_store}/orders?group=all", headers=_auth(rival_token))
        assert own.json()["total"] == 0
        # And the real store's owner does see it, with the buyer's details.
        mine = await client.get(f"/stores/{store_id}/orders", headers=_auth(seller_token))
        assert [o["id"] for o in mine.json()["items"]] == [order["id"]]
        seen = await client.get(f"/orders/{order['id']}", headers=_auth(seller_token))
        assert seen.json()["role"] == "seller"
        assert seen.json()["buyer"]["name"] == "Amina Wanjiku"
        assert seen.json()["fulfilment"]["address"] == "Kilimani, opposite Yaya Centre"


# ── 8-10, 13-14: the lifecycle ─────────────────────────────────────────────

class TestLifecycle:
    @pytest.mark.asyncio
    async def test_the_full_journey_to_completed(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, price=1500, quantity=5)
        _, buyer_token = await _buyer(client)
        order = await _order(client, buyer_token, store_id, lid, quantity=2)
        oid = order["id"]

        accepted = await _post(client, seller_token, f"/orders/{oid}/accept",
                               {"delivery_fee_minor": 30000, "fulfilment_note": "Delivered by 5pm"})
        assert accepted.status_code == 200, accepted.text
        a = accepted.json()
        assert a["status"] == "awaiting_buyer_confirmation"
        assert a["revision"] == 1
        assert a["totals"]["seller_subtotal_minor"] == 300_000
        assert a["totals"]["total_minor"] == 330_000
        assert a["expiry_stage"] == "buyer_confirmation"

        # Fulfilment can't start before the buyer confirms.
        early = await _post(client, seller_token, f"/orders/{oid}/preparing")
        assert early.status_code == 409 and early.json()["detail"]["code"] == "ORDER_STATE_CONFLICT"

        confirmed = await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        assert confirmed.status_code == 200, confirmed.text
        c = confirmed.json()
        assert c["status"] == "confirmed" and c["totals"]["final"] is True
        assert c["items"][0]["final_quantity"] == 2
        assert c["expires_at"] is None

        for step, status in (("preparing", "preparing"), ("dispatch", "dispatched"),
                             ("delivered", "delivered")):
            r = await _post(client, seller_token, f"/orders/{oid}/{step}",
                            {"dispatch_note": "Rider Kevin, 0700 000 000"} if step == "dispatch" else None)
            assert r.status_code == 200, (step, r.text)
            assert r.json()["status"] == status
        # The store reports delivery; only the buyer completes.
        assert (await _post(client, seller_token, f"/orders/{oid}/received")).status_code == 403
        done = await _post(client, buyer_token, f"/orders/{oid}/received")
        assert done.status_code == 200 and done.json()["status"] == "completed"
        assert done.json()["allowed_actions"] == ["report_problem"]

        history = [e["kind"] for e in done.json()["events"]]
        assert history == ["submitted", "seller_accepted", "buyer_confirmed", "preparing",
                           "dispatched", "delivered", "completed"]
        completed = await client.get(f"/stores/{store_id}/orders?group=completed",
                                     headers=_auth(seller_token))
        assert [o["id"] for o in completed.json()["items"]] == [oid]

    @pytest.mark.asyncio
    async def test_a_proposal_must_be_accepted_by_the_buyer(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, price=1000, quantity=10)
        _, buyer_token = await _buyer(client)
        order = await _order(client, buyer_token, store_id, lid, quantity=5)
        oid, item_id = order["id"], order["items"][0]["id"]

        proposed = await _post(client, seller_token, f"/orders/{oid}/propose", {
            "items": [{"item_id": item_id, "quantity": 3, "unit_price_minor": 90_000}],
            "fulfilment": "collection", "seller_note": "Only 3 left; collect from the shop",
        })
        assert proposed.status_code == 200, proposed.text
        p = proposed.json()
        assert p["status"] == "seller_proposed_changes"
        assert p["items"][0]["changed"] is True
        assert p["items"][0]["proposed_quantity"] == 3
        # Totals are the server's: 3 x 900, and no delivery charge on collection.
        assert p["totals"]["total_minor"] == 270_000
        assert p["fulfilment"]["method"] == "collection"
        event = p["events"][-1]
        assert event["kind"] == "seller_proposed_changes"
        assert event["detail"]["changes"][0]["to_quantity"] == 3

        # The store can't skip the buyer.
        assert (await _post(client, seller_token, f"/orders/{oid}/preparing")).status_code == 409
        # A confirmation of an older offer is refused.
        revised = await _post(client, seller_token, f"/orders/{oid}/propose", {
            "items": [{"item_id": item_id, "quantity": 2}]})
        assert revised.json()["revision"] == 2
        stale = await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        assert stale.status_code == 409 and stale.json()["detail"]["code"] == "ORDER_REVISION_STALE"
        ok = await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 2})
        assert ok.status_code == 200 and ok.json()["status"] == "confirmed"
        assert ok.json()["totals"]["total_minor"] == 180_000

    @pytest.mark.asyncio
    async def test_rejecting_a_proposal_returns_it_to_the_store(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, price=1000)
        _, buyer_token = await _buyer(client)
        order = await _order(client, buyer_token, store_id, lid)
        oid, item_id = order["id"], order["items"][0]["id"]
        await _post(client, seller_token, f"/orders/{oid}/propose",
                    {"items": [{"item_id": item_id, "quantity": 1, "unit_price_minor": 150_000}]})
        r = await _post(client, buyer_token, f"/orders/{oid}/reject-proposal", {"note": "Too expensive"})
        assert r.status_code == 200
        assert r.json()["status"] == "submitted"
        assert r.json()["totals"]["total_minor"] is None
        assert r.json()["items"][0]["proposed_quantity"] is None
        again = await _post(client, seller_token, f"/orders/{oid}/accept")
        assert again.json()["status"] == "awaiting_buyer_confirmation"
        assert again.json()["revision"] == 2

    @pytest.mark.asyncio
    async def test_invalid_transitions_are_refused(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        order = await _order(client, buyer_token, store_id, lid)
        oid = order["id"]
        # The buyer can't act for the store, and vice versa.
        assert (await _post(client, buyer_token, f"/orders/{oid}/accept")).status_code == 403
        assert (await _post(client, seller_token, f"/orders/{oid}/confirm", {"revision": 1})).status_code == 403
        # Nothing completes from submitted.
        r = await _post(client, buyer_token, f"/orders/{oid}/received")
        assert r.status_code == 409
        # Declining needs a reason the buyer will see.
        r = await _post(client, seller_token, f"/orders/{oid}/decline", {})
        assert r.status_code == 400 and r.json()["detail"]["code"] == "ORDER_REASON_REQUIRED"
        await _post(client, seller_token, f"/orders/{oid}/accept")
        await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        # A delivery order is dispatched, not made ready for pickup.
        r = await _post(client, seller_token, f"/orders/{oid}/ready")
        assert r.status_code == 409 and r.json()["detail"]["code"] == "ORDER_FULFILMENT_MISMATCH"
        await _post(client, seller_token, f"/orders/{oid}/preparing")
        # Once preparing, only the store may cancel - and must say why.
        assert (await _post(client, buyer_token, f"/orders/{oid}/cancel")).status_code == 409
        r = await _post(client, seller_token, f"/orders/{oid}/cancel", {})
        assert r.status_code == 400
        r = await _post(client, seller_token, f"/orders/{oid}/cancel", {"reason": "Item damaged in store"})
        assert r.status_code == 200 and r.json()["status"] == "cancelled"
        assert r.json()["cancelled_by"] == "seller"
        # An ended order takes no more actions.
        assert (await _post(client, seller_token, f"/orders/{oid}/dispatch")).status_code == 409

    @pytest.mark.asyncio
    async def test_the_buyer_cannot_complete_before_handover(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        order = await _order(client, buyer_token, store_id, lid, fulfilment="collection")
        oid = order["id"]
        await _post(client, seller_token, f"/orders/{oid}/accept")
        await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        r = await _post(client, buyer_token, f"/orders/{oid}/received")
        assert r.status_code == 409
        ready = await _post(client, seller_token, f"/orders/{oid}/ready", {"fulfilment_note": "Shop 12, Luthuli Ave"})
        assert ready.json()["status"] == "ready_for_pickup"
        assert ready.json()["fulfilment"]["note"] == "Shop 12, Luthuli Ave"
        done = await _post(client, buyer_token, f"/orders/{oid}/received")
        assert done.json()["status"] == "completed"

    @pytest.mark.asyncio
    async def test_a_problem_is_recorded_without_moving_the_order(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid))["id"]
        await _post(client, seller_token, f"/orders/{oid}/accept")
        await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        await _post(client, seller_token, f"/orders/{oid}/dispatch")
        r = await _post(client, buyer_token, f"/orders/{oid}/problem", {"note": "The box arrived crushed"})
        assert r.status_code == 200
        assert r.json()["status"] == "dispatched"
        assert r.json()["problem"]["note"] == "The box arrived crushed"


# ── 11-12: stock ────────────────────────────────────────────────────────────

class TestStock:
    @pytest.mark.asyncio
    async def test_tracked_stock_is_reserved_on_acceptance_and_deducted_at_handover(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=5)
        tracked = await _track(client, seller_token, store_id, lid, 5)
        assert tracked["available_quantity"] == 5
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid, quantity=2))["id"]
        # Submitting reserves nothing.
        assert tuple(await _listing_row(lid)) == (5, 0)
        await _post(client, seller_token, f"/orders/{oid}/accept")
        assert tuple(await _listing_row(lid)) == (5, 2)
        public = (await client.get(f"/listings/{lid}")).json()
        assert public["stock_tracked"] is True and public["available_quantity"] == 3
        await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        await _post(client, seller_token, f"/orders/{oid}/dispatch")
        assert tuple(await _listing_row(lid)) == (5, 2)
        await _post(client, seller_token, f"/orders/{oid}/delivered")
        assert tuple(await _listing_row(lid)) == (3, 0)
        # Completing does not take them a second time.
        await _post(client, buyer_token, f"/orders/{oid}/received")
        assert tuple(await _listing_row(lid)) == (3, 0)

    @pytest.mark.asyncio
    async def test_the_last_units_go_to_one_order_only(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=2)
        await _track(client, seller_token, store_id, lid, 2)
        _, b1 = await _buyer(client)
        _, b2 = await _buyer(client, name="Second Buyer")
        o1 = (await _order(client, b1, store_id, lid, quantity=2))["id"]
        o2 = (await _order(client, b2, store_id, lid, quantity=2))["id"]
        assert (await _post(client, seller_token, f"/orders/{o1}/accept")).status_code == 200
        r = await _post(client, seller_token, f"/orders/{o2}/accept")
        assert r.status_code == 409 and r.json()["detail"]["code"] == "ORDER_STOCK_SHORT"
        assert r.json()["detail"]["available"] == 0
        # The refused acceptance left the second order exactly as it was.
        assert (await client.get(f"/orders/{o2}", headers=_auth(b2))).json()["status"] == "submitted"
        assert tuple(await _listing_row(lid)) == (2, 2)
        # And a new request for it is told it's out of stock.
        _, b3 = await _buyer(client, name="Third Buyer")
        late = await _submit(client, b3, store_id, [{"listing_id": lid, "quantity": 1}])
        assert late.status_code == 409 and late.json()["detail"]["code"] == "ORDER_ITEM_OUT_OF_STOCK"

    @pytest.mark.asyncio
    async def test_concurrent_acceptances_cannot_over_reserve(self, client):
        """Two acceptances racing for the same last units: exactly one wins.
        Real row-level concurrency needs PostgreSQL (the CI job runs this
        suite there); SQLite serialises writers outright and the sequential
        test above covers the same rule there."""
        if db_module.engine.dialect.name != "postgresql":
            pytest.skip("needs PostgreSQL's concurrent writers")
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=3)
        await _track(client, seller_token, store_id, lid, 3)
        orders = []
        for i in range(4):
            _, b = await _buyer(client, name=f"Racer {i}")
            orders.append((await _order(client, b, store_id, lid, quantity=2))["id"])
        results = await asyncio.gather(*(
            _post(client, seller_token, f"/orders/{oid}/accept") for oid in orders))
        codes = sorted(r.status_code for r in results)
        assert codes.count(200) == 1, [r.text for r in results]
        assert all(c == 409 for c in codes if c != 200)
        assert tuple(await _listing_row(lid)) == (3, 2)

    @pytest.mark.asyncio
    async def test_cancelled_declined_and_rejected_orders_give_stock_back(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=4)
        await _track(client, seller_token, store_id, lid, 4)
        _, buyer_token = await _buyer(client)
        a = (await _order(client, buyer_token, store_id, lid, quantity=1))["id"]
        b = (await _order(client, buyer_token, store_id, lid, quantity=1))["id"]
        c = (await _order(client, buyer_token, store_id, lid, quantity=1))["id"]
        for oid in (a, b, c):
            await _post(client, seller_token, f"/orders/{oid}/accept")
        assert tuple(await _listing_row(lid)) == (4, 3)
        await _post(client, buyer_token, f"/orders/{a}/cancel", {"reason": "Changed my mind"})
        await _post(client, seller_token, f"/orders/{b}/decline", {"reason": "Reserved for someone else"})
        await _post(client, buyer_token, f"/orders/{c}/reject-proposal")
        assert tuple(await _listing_row(lid)) == (4, 0)

    @pytest.mark.asyncio
    async def test_an_expired_offer_releases_its_stock(self, client):
        from api.domains.store_orders import service
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=3)
        await _track(client, seller_token, store_id, lid, 3)
        _, buyer_token = await _buyer(client)
        swept = (await _order(client, buyer_token, store_id, lid, quantity=1))["id"]
        read = (await _order(client, buyer_token, store_id, lid, quantity=1))["id"]
        for oid in (swept, read):
            await _post(client, seller_token, f"/orders/{oid}/accept")
        assert tuple(await _listing_row(lid)) == (3, 2)
        async def lapse(order_id):
            async with db_module.AsyncSessionLocal() as db:
                await db.execute(update(StoreOrder).where(StoreOrder.id == order_id)
                                 .values(expires_at=datetime.utcnow() - timedelta(minutes=1)))
                await db.commit()

        # The sweep expires one...
        await lapse(swept)
        async with db_module.AsyncSessionLocal() as db:
            push_ids = await service.expire_due(db)
        assert push_ids
        swept_view = await client.get(f"/orders/{swept}", headers=_auth(buyer_token))
        assert swept_view.json()["status"] == "expired"
        assert tuple(await _listing_row(lid)) == (3, 1)
        # ...and opening the other after its deadline finds it lapsed, rather
        # than showing an offer that can no longer be confirmed.
        await lapse(read)
        seen = await client.get(f"/orders/{read}", headers=_auth(buyer_token))
        assert seen.json()["status"] == "expired"
        assert tuple(await _listing_row(lid)) == (3, 0)
        r = await _post(client, buyer_token, f"/orders/{read}/confirm", {"revision": 1})
        assert r.status_code == 409

    @pytest.mark.asyncio
    async def test_a_request_the_store_never_answers_expires(self, client):
        from api.domains.store_orders import service
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid))["id"]
        async with db_module.AsyncSessionLocal() as db:
            await db.execute(update(StoreOrder).where(StoreOrder.id == oid)
                             .values(expires_at=datetime.utcnow() - timedelta(seconds=5)))
            await db.commit()
        r = await _post(client, seller_token, f"/orders/{oid}/accept")
        assert r.status_code == 409 and r.json()["detail"]["code"] == "ORDER_EXPIRED"
        view = (await client.get(f"/orders/{oid}", headers=_auth(buyer_token))).json()
        assert view["status"] == "expired"
        assert view["events"][-1]["detail"]["stage"] == "seller_response"
        async with db_module.AsyncSessionLocal() as db:
            assert await service.expire_due(db) == []

    @pytest.mark.asyncio
    async def test_untracked_stock_is_never_zero(self, client):
        _, seller_token, store_id = await _seller(client)
        untracked = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        public = (await client.get(f"/listings/{untracked}")).json()
        assert public["stock_tracked"] is False and public["available_quantity"] is None
        oid = (await _order(client, buyer_token, store_id, untracked))["id"]
        accepted = await _post(client, seller_token, f"/orders/{oid}/accept")
        assert accepted.status_code == 200
        assert tuple(await _listing_row(untracked)) == (None, 0)
        # A product without a stated quantity reads as one, as the cart always did.
        r = await _submit(client, buyer_token, store_id, [{"listing_id": untracked, "quantity": 2}])
        assert r.status_code == 409 and r.json()["detail"]["code"] == "ORDER_ITEM_QUANTITY"

    @pytest.mark.asyncio
    async def test_stock_controls(self, client):
        _, seller_token, store_id = await _seller(client)
        _, other_token, other_store = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=3)
        _, buyer_token = await _buyer(client)
        path = f"/stores/{store_id}/manage/listings/{lid}/stock"
        # Owner only.
        assert (await client.patch(path, json={"stock_tracked": True}, headers=_auth(other_token))).status_code == 403
        assert (await client.patch(f"/stores/{other_store}/manage/listings/{lid}/stock",
                                   json={"stock_tracked": True}, headers=_auth(other_token))).status_code == 404
        # Tracking an existing quantity; then out of stock.
        assert (await client.patch(path, json={"stock_tracked": True}, headers=_auth(seller_token))).json()["quantity"] == 3
        zero = await client.patch(path, json={"quantity": 0}, headers=_auth(seller_token))
        assert zero.status_code == 200 and zero.json()["available_quantity"] == 0
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert r.json()["detail"]["code"] == "ORDER_ITEM_OUT_OF_STOCK"
        public = (await client.get(f"/listings/{lid}")).json()
        assert public["out_of_stock"] is True
        # Restocked, then paused: still listed, but not orderable.
        await client.patch(path, json={"quantity": 4, "temporarily_unavailable": True}, headers=_auth(seller_token))
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert r.json()["detail"]["code"] == "ORDER_ITEM_UNAVAILABLE"
        assert (await client.get(f"/listings/{lid}")).json()["temporarily_unavailable"] is True
        await client.patch(path, json={"temporarily_unavailable": False}, headers=_auth(seller_token))
        oid = (await _order(client, buyer_token, store_id, lid, quantity=3))["id"]
        await _post(client, seller_token, f"/orders/{oid}/accept")
        # On hand can't drop below what accepted orders hold.
        low = await client.patch(path, json={"quantity": 2}, headers=_auth(seller_token))
        assert low.status_code == 409 and low.json()["detail"]["code"] == "STOCK_BELOW_RESERVED"


# ── The store's own switches ────────────────────────────────────────────────

class TestStoreSettings:
    @pytest.mark.asyncio
    async def test_pausing_new_orders_keeps_the_store_open(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        open_order = (await _order(client, buyer_token, store_id, lid))["id"]
        r = await client.patch(f"/stores/{store_id}", json={
            "accepting_orders": False, "orders_pause_note": "Back on Monday"}, headers=_auth(seller_token))
        assert r.status_code == 200 and r.json()["accepting_orders"] is False
        public = (await client.get(f"/stores/{store_id}")).json()
        assert public["is_active"] is True
        assert public["accepting_orders"] is False and public["orders_pause_note"] == "Back on Monday"
        assert (await client.get(f"/stores/{store_id}/listings")).json()
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert r.status_code == 409 and r.json()["detail"]["code"] == "STORE_ORDERS_PAUSED"
        assert "Back on Monday" in r.json()["detail"]["message"]
        # An order already under way carries on.
        assert (await _post(client, seller_token, f"/orders/{open_order}/accept")).status_code == 200
        await client.patch(f"/stores/{store_id}", json={"accepting_orders": True}, headers=_auth(seller_token))
        assert (await _submit(client, buyer_token, store_id,
                              [{"listing_id": lid, "quantity": 1}])).status_code == 201

    @pytest.mark.asyncio
    async def test_open_orders_per_store_are_capped(self, client):
        from api.core.config import settings
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        for _ in range(settings.store_order_max_open_per_store):
            await _order(client, buyer_token, store_id, lid)
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert r.status_code == 429 and r.json()["detail"]["code"] == "ORDER_TOO_MANY_OPEN"


# ── 15-16: payment stays a report ──────────────────────────────────────────

class TestPaymentRecords:
    async def _confirmed(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid))["id"]
        await _post(client, seller_token, f"/orders/{oid}/accept")
        await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        return seller_token, buyer_token, oid

    @pytest.mark.asyncio
    async def test_payment_reports_remain_user_reported(self, client):
        seller_token, buyer_token, oid = await self._confirmed(client)
        chose = await _post(client, buyer_token, f"/orders/{oid}/payment-arrangement",
                            {"arrangement": "direct_to_seller"})
        assert chose.status_code == 200 and chose.json()["status"] == "confirmed"
        sent = await _post(client, buyer_token, f"/orders/{oid}/payment-reports",
                           {"kind": "buyer_reported_payment_sent", "reference": "SGT7H2K9LP"})
        assert sent.status_code == 201, sent.text
        pay = sent.json()["payment"]
        assert sent.json()["status"] == "confirmed"          # payment never moves the order
        assert pay["summary"]["label"] == "Buyer reported payment sent"
        assert pay["summary"]["awaiting_external_confirmation"] is True
        assert pay["summary"]["verified"] is False
        assert pay["reports"][0]["verified"] is False
        assert pay["reports"][0]["label"] == "Buyer reported payment sent"
        assert "does not receive, hold, verify or release" in pay["notice"]
        # The reference stays on the report, out of the shared history.
        assert "SGT7H2K9LP" not in str(sent.json()["events"])
        # Each side reports only its own part, once.
        assert (await _post(client, buyer_token, f"/orders/{oid}/payment-reports",
                            {"kind": "seller_confirmed_receipt"})).status_code == 403
        dup = await _post(client, buyer_token, f"/orders/{oid}/payment-reports",
                          {"kind": "buyer_reported_payment_sent"})
        assert dup.status_code == 409 and dup.json()["detail"]["code"] == "PAYMENT_ALREADY_REPORTED"
        got = await _post(client, seller_token, f"/orders/{oid}/payment-reports",
                          {"kind": "seller_confirmed_receipt"})
        assert got.json()["payment"]["summary"]["label"] == "Seller confirmed receipt"
        assert got.json()["payment"]["summary"]["verified"] is False
        # Once something is reported, how it is paid is fixed.
        r = await _post(client, buyer_token, f"/orders/{oid}/payment-arrangement",
                        {"arrangement": "independent_escrow", "provider_id": "lipasafe"})
        assert r.status_code == 409 and r.json()["detail"]["code"] == "PAYMENT_ARRANGEMENT_LOCKED"
        # The order still needs the store and the buyer to finish it.
        assert sent.json()["allowed_actions"] == ["cancel"]

    @pytest.mark.asyncio
    async def test_choosing_an_escrow_provider_is_not_paying(self, client):
        seller_token, buyer_token, oid = await self._confirmed(client)
        r = await _post(client, buyer_token, f"/orders/{oid}/payment-arrangement",
                        {"arrangement": "independent_escrow", "provider_id": "lipasafe"})
        assert r.status_code == 200, r.text
        o = r.json()
        assert o["status"] == "confirmed"
        provider = o["payment"]["provider"]
        assert provider["id"] == "lipasafe" and provider["independent"] is True
        assert provider["url"].startswith("https://") and provider["domain"] == "lipasafe.co.ke"
        assert "independent of BROKA" in provider["notice"]
        assert o["payment"]["reports"] == []
        assert o["payment"]["summary"]["label"].endswith("nothing reported yet")
        async with db_module.AsyncSessionLocal() as db:
            assert (await db.execute(select(StoreOrderPaymentReport.id).where(
                StoreOrderPaymentReport.order_id == oid))).all() == []
        # Only a listed provider, with nothing about it taken from the request.
        bad = await _post(client, buyer_token, f"/orders/{oid}/payment-arrangement",
                          {"arrangement": "independent_escrow", "provider_id": "escrowkenya"})
        assert bad.status_code == 400 and bad.json()["detail"]["code"] == "PAYMENT_PROVIDER_UNKNOWN"
        assert (await _post(client, seller_token, f"/orders/{oid}/payment-arrangement",
                            {"arrangement": "direct_to_seller"})).status_code == 403
        started = await _post(client, buyer_token, f"/orders/{oid}/payment-reports",
                              {"kind": "buyer_reported_escrow_initiated"})
        assert started.json()["payment"]["summary"]["label"] == "Buyer reported escrow initiated via Lipasafe"
        assert started.json()["status"] == "confirmed"

    @pytest.mark.asyncio
    async def test_nothing_is_reported_before_the_final_order(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid))["id"]
        await _post(client, buyer_token, f"/orders/{oid}/payment-arrangement", {"arrangement": "direct_to_seller"})
        r = await _post(client, buyer_token, f"/orders/{oid}/payment-reports",
                        {"kind": "buyer_reported_payment_sent"})
        assert r.status_code == 409 and r.json()["detail"]["code"] == "PAYMENT_REPORT_TOO_EARLY"


# ── 17: notifications ───────────────────────────────────────────────────────

class TestNotifications:
    @pytest.mark.asyncio
    async def test_a_push_failure_never_undoes_an_order(self, client, monkeypatch):
        from api.core import push_devices

        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        real = push_devices.push_user

        async def broken(user_id, **kwargs):
            if (kwargs.get("data") or {}).get("type") == "store_order":
                raise RuntimeError("FCM is down")
            return await real(user_id, **kwargs)

        monkeypatch.setattr(push_devices, "push_user", broken)
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert r.status_code == 201
        oid = r.json()["id"]
        assert (await client.get(f"/orders/{oid}", headers=_auth(buyer_token))).status_code == 200
        async with db_module.AsyncSessionLocal() as db:
            note = (await db.execute(select(StoreOrderNotification).where(
                StoreOrderNotification.order_id == oid))).scalar_one()
        # Kept for the sweep to retry, and already in the seller's feed.
        assert note.push_state == "pending" and note.push_attempts == 1
        feed = await client.get("/orders/notifications", headers=_auth(seller_token))
        assert feed.json()["items"][0]["order_id"] == oid

    @pytest.mark.asyncio
    async def test_each_update_is_pushed_once(self, client, monkeypatch):
        from api.core import push_devices
        from api.domains.store_orders import notify

        seller_id, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        buyer_id, buyer_token = await _buyer(client)
        calls = []
        real = push_devices.push_user

        async def accepted(user_id, **kwargs):
            data = kwargs.get("data") or {}
            if data.get("type") != "store_order":
                return await real(user_id, **kwargs)
            calls.append((user_id, data["event"], data["order_id"]))
            return 1

        def this_order():
            # Only this order's pushes. The sweep below also sends whatever
            # earlier tests in the session left pending - which is its job.
            return [(user, event) for user, event, order_id in calls if order_id == oid]

        monkeypatch.setattr(push_devices, "push_user", accepted)
        oid = (await _order(client, buyer_token, store_id, lid))["id"]
        await _post(client, seller_token, f"/orders/{oid}/accept")
        assert this_order() == [(seller_id, "submitted"), (buyer_id, "seller_accepted")]
        async with db_module.AsyncSessionLocal() as db:
            ids = (await db.execute(select(StoreOrderNotification.id).where(
                StoreOrderNotification.order_id == oid))).scalars().all()
        # A second delivery attempt and a sweep find nothing left to send.
        await notify.deliver(ids)
        await notify.retry_pending()
        assert len(this_order()) == 2
        async with db_module.AsyncSessionLocal() as db:
            states = (await db.execute(select(StoreOrderNotification.push_state).where(
                StoreOrderNotification.order_id == oid))).scalars().all()
        assert set(states) == {"sent"}

    @pytest.mark.asyncio
    async def test_the_feed_is_each_persons_own(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid))["id"]
        await _post(client, seller_token, f"/orders/{oid}/accept")
        buyer_feed = (await client.get("/orders/notifications", headers=_auth(buyer_token))).json()
        assert [n["kind"] for n in buyer_feed["items"]] == ["seller_accepted"]
        seller_feed = (await client.get("/orders/notifications", headers=_auth(seller_token))).json()
        # Marking someone else's notification read changes nothing.
        r = await _post(client, buyer_token, "/orders/notifications/read",
                        {"ids": [n["id"] for n in seller_feed["items"]]})
        assert r.json()["marked"] == 0
        r = await _post(client, buyer_token, "/orders/notifications/read", {"order_id": oid})
        assert r.json()["marked"] == 1 and r.json()["unread"] == 0


# ── 18: insights ────────────────────────────────────────────────────────────

class TestInsights:
    @pytest.mark.asyncio
    async def test_requests_are_not_completed_orders(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, price=2000, quantity=10)
        _, buyer_token = await _buyer(client)
        done = (await _order(client, buyer_token, store_id, lid, quantity=2))["id"]
        await _order(client, buyer_token, store_id, lid, quantity=1)   # still a request
        await _post(client, seller_token, f"/orders/{done}/accept")
        await _post(client, buyer_token, f"/orders/{done}/confirm", {"revision": 1})
        await _post(client, seller_token, f"/orders/{done}/dispatch")
        await _post(client, buyer_token, f"/orders/{done}/received")
        insights = await client.get(f"/stores/{store_id}/insights", headers=_auth(seller_token))
        assert insights.status_code == 200, insights.text
        orders = insights.json()["orders"]
        assert orders["kpis"]["requests"]["value"] == 2
        assert orders["kpis"]["accepted"]["value"] == 1
        assert orders["kpis"]["confirmed"]["value"] == 1
        assert orders["kpis"]["completed"]["value"] == 1
        # Only the completed order's agreed total, labelled as not revenue.
        assert orders["completed_value_minor"] == 400_000
        assert "not revenue" in orders["definitions"]["completed_value"]
        rates = {r["key"]: r for r in orders["rates"]}
        assert rates["completion_rate"]["numerator"] == 1 and rates["completion_rate"]["denominator"] == 2
        assert rates["completion_rate"]["percent"] == 50.0
        assert orders["pipeline"]["awaiting_store"] == 1
        assert orders["top_products"][0]["requests"] == 2
        assert orders["top_products"][0]["units_completed"] == 2
        assert sum(d["count"] for d in orders["series"]["requests"]) == 2
        assert sum(d["count"] for d in orders["series"]["completed"]) == 1
        # And the store's other advice is still there beside the order cards.
        assert {"positives", "negatives"} <= set(insights.json()["advice"])

    @pytest.mark.asyncio
    async def test_campaign_attribution_counts_orders_not_clicks(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        campaign = await client.post(f"/stores/{store_id}/marketing/campaigns", json={
            "title": "December offer", "product_ids": [lid], "platforms": ["whatsapp"], "generate": False,
        }, headers=_auth(seller_token))
        assert campaign.status_code == 201, campaign.text
        token = campaign.json()["link_token"]
        _, buyer_token = await _buyer(client)
        attributed = await _order(client, buyer_token, store_id, lid, via="wa", campaign=token)
        seen = await client.get(f"/orders/{attributed['id']}", headers=_auth(seller_token))
        assert seen.json()["attribution"]["source"] == "whatsapp"
        assert seen.json()["attribution"]["campaign"]["title"] == "December offer"
        # A token from another store's campaign is ignored, not credited.
        _, other_token, other_store = await _seller(client)
        olid = await _listing(client, other_token, other_store)
        stray = await _order(client, buyer_token, other_store, olid, campaign=token)
        assert (await client.get(f"/orders/{stray['id']}", headers=_auth(other_token))).json()["attribution"]["campaign"] is None
        detail = await client.get(f"/stores/{store_id}/marketing/campaigns/{campaign.json()['id']}",
                                  headers=_auth(seller_token))
        events = detail.json()["events"]
        assert events["orders"] == {"order_requests": 1, "confirmed_orders": 0, "completed_orders": 0}
        assert "sales" in events["not_measured"] and "revenue" in events["not_measured"]
        insights = (await client.get(f"/stores/{store_id}/insights", headers=_auth(seller_token))).json()
        assert insights["orders"]["by_campaign"][0]["requests"] == 1
        assert insights["orders"]["by_source"]["whatsapp"]["requests"] == 1

    @pytest.mark.asyncio
    async def test_cart_additions_are_interest_counted_once(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        body = {"listing_id": lid, "surface": "web", "visitor": "visitor-abc123",
                "via": "tiktok"}
        ua = {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"}
        first = await client.post(f"/stores/{store_id}/cart-events", json=body, headers=ua)
        again = await client.post(f"/stores/{store_id}/cart-events", json=body, headers=ua)
        assert first.json()["counted"] is True and again.json()["counted"] is False
        bot = await client.post(f"/stores/{store_id}/cart-events", json={**body, "visitor": "visitor-bot0001"},
                                headers={"User-Agent": "facebookexternalhit/1.1"})
        assert bot.json()["counted"] is False
        stray = await client.post(f"/stores/{store_id}/cart-events",
                                  json={**body, "listing_id": "not-in-this-store"}, headers=ua)
        assert stray.json()["counted"] is False
        orders = (await client.get(f"/stores/{store_id}/insights", headers=_auth(seller_token))).json()["orders"]
        assert orders["kpis"]["cart_additions"]["value"] == 1
        assert orders["kpis"]["requests"]["value"] == 0


# ── Lists, search and the seller's badges ──────────────────────────────────

class TestLists:
    @pytest.mark.asyncio
    async def test_seller_list_filters_searches_and_counts(self, client):
        _, seller_token, store_id = await _seller(client)
        phone = await _listing(client, seller_token, store_id, name="Tecno Spark 20")
        charger = await _listing(client, seller_token, store_id, name="Oraimo charger")
        _, buyer_token = await _buyer(client, name="Brian Otieno")
        a = await _order(client, buyer_token, store_id, phone)
        b = await _order(client, buyer_token, store_id, charger)
        await _post(client, seller_token, f"/orders/{b['id']}/accept")
        auth = _auth(seller_token)
        new = (await client.get(f"/stores/{store_id}/orders?group=new", headers=auth)).json()
        assert [o["id"] for o in new["items"]] == [a["id"]]
        assert new["items"][0]["needs_action"] is True and new["items"][0]["buyer_name"] == "Brian Otieno"
        waiting = (await client.get(f"/stores/{store_id}/orders?group=awaiting_buyer", headers=auth)).json()
        assert [o["id"] for o in waiting["items"]] == [b["id"]]
        assert waiting["counts"]["open"] == 2 and waiting["counts"]["new"] == 1
        found = (await client.get(f"/stores/{store_id}/orders?group=all&q=oraimo", headers=auth)).json()
        assert [o["id"] for o in found["items"]] == [b["id"]]
        by_ref = (await client.get(f"/stores/{store_id}/orders?group=all&q={a['reference'][-4:]}",
                                   headers=auth)).json()
        assert a["id"] in [o["id"] for o in by_ref["items"]]
        assert (await client.get(f"/stores/{store_id}/orders?group=bogus", headers=auth)).status_code == 400
        summary = (await client.get(f"/stores/{store_id}/orders/summary", headers=auth)).json()
        assert summary["pipeline"]["awaiting_store"] == 1 and summary["pipeline"]["awaiting_buyer"] == 1
        mine = (await client.get("/orders?scope=open", headers=_auth(buyer_token))).json()
        assert mine["total"] == 2


# ── Web sign-in and enquiries ───────────────────────────────────────────────

class TestWebSignIn:
    @pytest.mark.asyncio
    async def test_an_existing_account_signs_in_with_a_code(self, client):
        buyer_id, _ = await _buyer(client)
        async with db_module.AsyncSessionLocal() as db:
            phone = (await db.execute(text("SELECT phone FROM users WHERE id = :i"), {"i": buyer_id})).scalar_one()
        req = await client.post("/auth/otp/sign-in/request", json={"phone": phone})
        assert req.json()["account_exists"] is True
        wrong = await client.post("/auth/otp/sign-in/verify", json={"phone": phone, "code": "000000"})
        assert wrong.status_code == 400
        ok = await client.post("/auth/otp/sign-in/verify", json={"phone": phone, "code": req.json()["debug_code"]})
        assert ok.status_code == 200 and ok.json()["user_id"] == buyer_id
        assert ok.json()["access_token"] and ok.json()["refresh_token"]
        me = await client.get("/auth/me", headers=_auth(ok.json()["access_token"]))
        assert me.status_code == 200
        # A code is spent once.
        again = await client.post("/auth/otp/sign-in/verify",
                                  json={"phone": phone, "code": req.json()["debug_code"]})
        assert again.status_code == 400

    @pytest.mark.asyncio
    async def test_a_sign_in_code_cannot_reset_a_password(self, client):
        buyer_id, _ = await _buyer(client)
        async with db_module.AsyncSessionLocal() as db:
            phone = (await db.execute(text("SELECT phone FROM users WHERE id = :i"), {"i": buyer_id})).scalar_one()
        code = (await client.post("/auth/otp/sign-in/request", json={"phone": phone})).json()["debug_code"]
        r = await client.post("/auth/password/forgot/verify", json={"phone": phone, "code": code})
        assert r.status_code == 400

    @pytest.mark.asyncio
    async def test_a_new_account_needs_the_legal_declarations(self, client):
        phone = f"0733{next(_phones):06d}"
        req = await client.post("/auth/otp/sign-in/request", json={"phone": phone})
        verify = await client.post("/auth/otp/sign-in/verify",
                                   json={"phone": phone, "code": req.json()["debug_code"]})
        token = verify.json()["phone_verify_token"]
        refused = await client.post("/auth/otp/sign-in/register", json={
            "phone_verify_token": token, "name": "No Terms",
            "legal_acceptance": legal_payload(terms_accepted=False)})
        assert refused.status_code == 422
        legal = (await client.get("/auth/legal/current")).json()
        assert legal["terms"]["version"] == legal_payload()["terms_version"]
        made = await client.post("/auth/otp/sign-in/register", json={
            "phone_verify_token": token, "name": "Wanjiru Kamau", "legal_acceptance": legal_payload()})
        assert made.status_code == 201 and made.json()["account_type"] == "buyer"
        # No password anyone knows: password sign-in can't get in.
        login = await client.post("/auth/login", json={"phone": phone, "password": "anything123"})
        assert login.status_code == 401


class TestEnquiries:
    @pytest.mark.asyncio
    async def test_a_web_buyer_asks_the_store_and_reads_the_reply(self, client):
        seller_uid, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        buyer_id, buyer_token = await _buyer(client)
        asked = await client.post(f"/stores/{store_id}/enquiries", json={
            "content": "Do you deliver to Thika?", "client_msg_id": "web-msg-0001"}, headers=_auth(buyer_token))
        assert asked.status_code == 201, asked.text
        history = await client.get(f"/negotiate/store/{store_id}/history", headers=_auth(buyer_token))
        assert [m["content"] for m in history.json()] == ["Do you deliver to Thika?"]
        # The store answers in its own thread with this buyer.
        reply = await client.post("/negotiate/direct-message", json={
            "store_id": store_id, "sender_role": "seller", "sender_id": seller_uid,
            "content": "Yes, KES 300", "buyer_id": buyer_id}, headers=_auth(seller_token))
        assert reply.status_code == 200, reply.text
        history = await client.get(f"/negotiate/store/{store_id}/history", headers=_auth(buyer_token))
        assert [m["role"] for m in history.json()] == ["buyer", "seller"]
        product = await client.post(f"/stores/{store_id}/enquiries", json={
            "content": "Is it the 8GB version?", "listing_id": lid}, headers=_auth(buyer_token))
        assert product.status_code == 201
        thread = await client.get(f"/negotiate/{lid}/history", headers=_auth(buyer_token))
        assert "Is it the 8GB version?" in [m["content"] for m in thread.json()]

    @pytest.mark.asyncio
    async def test_enquiries_need_an_account_and_the_right_store(self, client):
        _, seller_token, store_id = await _seller(client)
        _, other_token, other_store = await _seller(client)
        theirs = await _listing(client, other_token, other_store)
        _, buyer_token = await _buyer(client)
        assert (await client.post(f"/stores/{store_id}/enquiries", json={"content": "hi there"})).status_code == 401
        r = await client.post(f"/stores/{store_id}/enquiries", json={
            "content": "Is this available?", "listing_id": theirs}, headers=_auth(buyer_token))
        assert r.status_code == 404
        r = await client.post(f"/stores/{store_id}/enquiries", json={"content": "Me?"}, headers=_auth(seller_token))
        assert r.status_code == 400
        r = await client.post(f"/stores/{store_id}/enquiries", json={"content": "   "}, headers=_auth(buyer_token))
        assert r.status_code == 400


# ── The schema change ───────────────────────────────────────────────────────

class TestSchema:
    @pytest.mark.asyncio
    async def test_the_release_records_the_store_orders_revision(self):
        from api.database import SCHEMA_VERSION, schema_status
        status = await schema_status()
        assert SCHEMA_VERSION >= 19
        assert any(v["version"] == 19 and v["name"] == "store_orders" for v in status["versions"])
        # A second run changes nothing and fails nothing.
        await init_db()
        assert (await schema_status())["current"] is True

    @pytest.mark.asyncio
    async def test_events_record_who_did_what(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id)
        buyer_id, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid))["id"]
        await _post(client, seller_token, f"/orders/{oid}/decline", {"reason": "Out of stock today"})
        async with db_module.AsyncSessionLocal() as db:
            rows = (await db.execute(select(StoreOrderEvent).where(StoreOrderEvent.order_id == oid)
                                     .order_by(StoreOrderEvent.created_at))).scalars().all()
        assert [(e.kind, e.actor_role, e.from_status, e.to_status) for e in rows] == [
            ("submitted", "buyer", None, "submitted"),
            ("seller_declined", "seller", "submitted", "declined"),
        ]
        assert rows[0].actor_id == buyer_id


# ── One count for both channels (listings/inventory.py) ─────────────────────
#
# A tracked product is sold two ways: chat deals (POST /deal/finalize) and
# store orders. finalize_deal used to count chat deals only, so a chat buyer
# could be sold units an accepted order was holding; and an order counted
# chat deals before it locked anything, so a deal agreed in that gap was
# missed. These pin the one count both channels now take units by.

async def _finalize(client, token: str, buyer_id: str, listing_id: str, quantity: int = 1,
                    price: float = 12500):
    """A chat deal: the buyer accepts the agreed price for `quantity` units."""
    return await client.post("/deal/finalize", json={
        "listing_id": listing_id, "buyer_id": buyer_id, "agreed_price": price, "quantity": quantity,
    }, headers=_auth(token))


async def _set_deal(deal_id: str, status: DealStatus) -> None:
    """Move a chat deal on, as its payout, refund or cancellation would."""
    async with db_module.AsyncSessionLocal() as db:
        deal = await db.get(Deal, deal_id)
        deal.status = status
        if status == DealStatus.released:
            deal.released_at = datetime.utcnow()
        await db.commit()


async def _deal_units(listing_id: str) -> int:
    """Units in chat deals on the listing that hold stock (payments on: all
    from agreement until refunded or cancelled)."""
    async with db_module.AsyncSessionLocal() as db:
        deals = (await db.execute(select(Deal).where(Deal.listing_id == listing_id))).scalars().all()
    return sum(int(d.quantity or 1) for d in deals
               if d.status not in (DealStatus.refunded, DealStatus.cancelled, DealStatus.negotiating))


async def _owner_product(client, token: str, store_id: str, listing_id: str) -> dict:
    page = (await client.get(f"/stores/{store_id}/manage/listings", headers=_auth(token))).json()
    return next(p for p in page["items"] if p["id"] == listing_id)


async def _sweep() -> None:
    from api.core.workers import task_sync_listing_stock
    await task_sync_listing_stock()


class TestCrossChannelStock:
    @pytest.mark.asyncio
    async def test_an_accepted_order_holds_its_units_against_chat_deals(self, client):
        # 1. A store order reserves the last units: a chat deal can't have them.
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=3)
        await _track(client, seller_token, store_id, lid, 3)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid, quantity=2))["id"]
        assert (await _post(client, seller_token, f"/orders/{oid}/accept")).status_code == 200

        chat_id, chat_token = await _buyer(client, name="Chat Buyer")
        r = await _finalize(client, chat_token, chat_id, lid, quantity=2)
        # It used to be allowed: finalize_deal counted chat deals only.
        assert r.status_code == 409 and r.json()["detail"] == "Only 1 left - this deal can be for 1 at most."
        assert (await _finalize(client, chat_token, chat_id, lid, quantity=1)).status_code == 201

        # The last unit is gone on both channels now.
        late_id, late_token = await _buyer(client, name="Late Chat Buyer")
        r = await _finalize(client, late_token, late_id, lid, quantity=1)
        assert r.status_code == 409 and r.json()["detail"] == "This listing is sold out."
        late = await _submit(client, late_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert late.status_code == 409 and late.json()["detail"]["code"] == "ORDER_ITEM_OUT_OF_STOCK"
        assert tuple(await _listing_row(lid)) == (3, 2)
        assert await _deal_units(lid) == 1
        # A counted product stays listed, saying it's out of stock.
        public = (await client.get(f"/listings/{lid}")).json()
        assert public["status"] == "active"
        assert (public["units_left"], public["available_quantity"], public["out_of_stock"],
                public["available"]) == (0, 0, True, False)

    @pytest.mark.asyncio
    async def test_a_chat_deal_holds_its_units_against_store_orders(self, client):
        # 2. A chat deal takes a unit first: the store can't accept it again.
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=2)
        await _track(client, seller_token, store_id, lid, 2)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid, quantity=2))["id"]
        chat_id, chat_token = await _buyer(client, name="Chat Buyer")
        assert (await _finalize(client, chat_token, chat_id, lid, quantity=1)).status_code == 201

        r = await _post(client, seller_token, f"/orders/{oid}/accept")
        assert r.status_code == 409 and r.json()["detail"]["code"] == "ORDER_STOCK_SHORT"
        assert r.json()["detail"]["available"] == 1
        assert tuple(await _listing_row(lid)) == (2, 0)
        # What is left can still be offered.
        item_id = (await client.get(f"/orders/{oid}", headers=_auth(seller_token))).json()["items"][0]["id"]
        offer = await _post(client, seller_token, f"/orders/{oid}/propose",
                            {"items": [{"item_id": item_id, "quantity": 1}]})
        assert offer.status_code == 200, offer.text
        assert tuple(await _listing_row(lid)) == (2, 1)
        _, third_token = await _buyer(client, name="Third Buyer")
        late = await _submit(client, third_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert late.json()["detail"]["code"] == "ORDER_ITEM_OUT_OF_STOCK"
        third_chat_id, third_chat_token = await _buyer(client, name="Third Chat Buyer")
        r = await _finalize(client, third_chat_token, third_chat_id, lid, quantity=1)
        assert r.status_code == 409 and r.json()["detail"] == "This listing is sold out."

    @pytest.mark.asyncio
    @pytest.mark.parametrize("first", ["store_order", "chat_deal"])
    async def test_two_channels_racing_for_the_last_unit_cannot_both_get_it(self, client, monkeypatch, first):
        """3. Each channel's request holds the listing's lock from before it
        counts until it commits, so the other waits and then counts again.
        The first is held mid-count - after reading the chat deals, before
        writing - to open exactly the window the old code had: there, the
        second sailed through and both took the unit."""
        if db_module.engine.dialect.name != "postgresql":
            pytest.skip("needs PostgreSQL's concurrent writers; SQLite serialises them outright")
        from api.domains.listings import stock as listing_stock

        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=1)
        await _track(client, seller_token, store_id, lid, 1)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid, quantity=1))["id"]
        chat_id, chat_token = await _buyer(client, name="Racing Chat Buyer")

        counting = asyncio.Event()
        go_on = asyncio.Event()
        held = {"once": False}
        real = listing_stock.units_taken

        async def held_mid_count(db, listing_id):
            result = await real(db, listing_id)
            if listing_id == lid and not held["once"]:
                held["once"] = True
                counting.set()
                await asyncio.wait_for(go_on.wait(), 30)
            return result

        monkeypatch.setattr(listing_stock, "units_taken", held_mid_count)
        # Where the chat path counted before the shared count existed.
        monkeypatch.setattr("api.domains.escrow.service.units_taken", held_mid_count, raising=False)

        async def store_order():
            return await _post(client, seller_token, f"/orders/{oid}/accept")

        async def chat_deal():
            return await _finalize(client, chat_token, chat_id, lid, quantity=1)

        one, other = (store_order, chat_deal) if first == "store_order" else (chat_deal, store_order)
        a = asyncio.create_task(one())
        await asyncio.wait_for(counting.wait(), 30)
        b = asyncio.create_task(other())
        await asyncio.sleep(0.5)
        # The other channel is waiting on the listing's lock, not counting.
        assert not b.done(), (await b).text
        go_on.set()
        ra, rb = await asyncio.wait_for(asyncio.gather(a, b), 30)
        assert ra.status_code in (200, 201), ra.text
        assert rb.status_code == 409, rb.text
        quantity, reserved = await _listing_row(lid)
        assert (quantity, reserved + await _deal_units(lid)) == (1, 1)

    @pytest.mark.asyncio
    async def test_cancelled_and_expired_orders_give_their_units_to_chat_deals(self, client):
        # 4. An order ending without a sale releases what it held - to
        # either channel.
        from api.domains.store_orders import service

        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=2)
        await _track(client, seller_token, store_id, lid, 2)
        _, buyer_token = await _buyer(client)
        cancelled = (await _order(client, buyer_token, store_id, lid, quantity=1))["id"]
        lapsing = (await _order(client, buyer_token, store_id, lid, quantity=1))["id"]
        for oid in (cancelled, lapsing):
            assert (await _post(client, seller_token, f"/orders/{oid}/accept")).status_code == 200
        first_id, first_token = await _buyer(client, name="First Chat Buyer")
        assert (await _finalize(client, first_token, first_id, lid)).status_code == 409

        await _post(client, buyer_token, f"/orders/{cancelled}/cancel", {"reason": "Found it nearby"})
        assert tuple(await _listing_row(lid)) == (2, 1)
        assert (await _finalize(client, first_token, first_id, lid)).status_code == 201

        async with db_module.AsyncSessionLocal() as db:
            await db.execute(update(StoreOrder).where(StoreOrder.id == lapsing)
                             .values(expires_at=datetime.utcnow() - timedelta(minutes=1)))
            await db.commit()
        second_id, second_token = await _buyer(client, name="Second Chat Buyer")
        assert (await _finalize(client, second_token, second_id, lid)).status_code == 409
        async with db_module.AsyncSessionLocal() as db:
            assert await service.expire_due(db)
        assert tuple(await _listing_row(lid)) == (2, 0)
        assert (await _finalize(client, second_token, second_id, lid)).status_code == 201
        assert await _deal_units(lid) == 2

    @pytest.mark.asyncio
    async def test_a_completed_order_and_a_paid_out_deal_each_take_their_units_once(self, client):
        # 5. Handover deducts an order's units from on hand once; a chat
        # deal's units leave on hand once when it is paid out.
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=5)
        await _track(client, seller_token, store_id, lid, 5)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid, quantity=2))["id"]
        await _post(client, seller_token, f"/orders/{oid}/accept")
        await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        await _post(client, seller_token, f"/orders/{oid}/dispatch")
        await _post(client, seller_token, f"/orders/{oid}/delivered")
        assert tuple(await _listing_row(lid)) == (3, 0)
        await _post(client, buyer_token, f"/orders/{oid}/received")
        assert tuple(await _listing_row(lid)) == (3, 0)

        chat_id, chat_token = await _buyer(client, name="Chat Buyer")
        deal = await _finalize(client, chat_token, chat_id, lid, quantity=1)
        assert deal.status_code == 201
        before = await _owner_product(client, seller_token, store_id, lid)
        assert (before["stock_on_hand"], before["stock_committed_to_deals"], before["available_quantity"]) == (3, 1, 2)
        await _set_deal(deal.json()["deal_id"], DealStatus.released)
        for _ in range(2):
            await _sweep()
            paid_out = await _owner_product(client, seller_token, store_id, lid)
            # Gone from on hand (sold), no longer "in a deal", and counted once.
            assert (paid_out["stock_on_hand"], paid_out["stock_committed_to_deals"],
                    paid_out["stock_sold_through_deals"], paid_out["available_quantity"]) == (2, 0, 1, 2)
        # quantity itself was never touched by the chat sale.
        assert tuple(await _listing_row(lid)) == (3, 0)
        r = await _finalize(client, chat_token, chat_id, lid, quantity=3)
        assert r.status_code == 409 and "Only 2 left" in r.json()["detail"]
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 3}])
        assert r.json()["detail"]["code"] == "ORDER_ITEM_QUANTITY" and r.json()["detail"]["available"] == 2

    @pytest.mark.asyncio
    async def test_refunded_and_cancelled_deals_give_their_units_back(self, client):
        # 6. As the chat rules always had it: a refunded or cancelled deal
        # holds nothing - for store orders as much as for other chats.
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=1)
        await _track(client, seller_token, store_id, lid, 1)
        chat_id, chat_token = await _buyer(client, name="Chat Buyer")
        deal = await _finalize(client, chat_token, chat_id, lid)
        assert deal.status_code == 201
        _, buyer_token = await _buyer(client)
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert r.json()["detail"]["code"] == "ORDER_ITEM_OUT_OF_STOCK"

        await _set_deal(deal.json()["deal_id"], DealStatus.refunded)
        assert (await client.get(f"/listings/{lid}")).json()["available_quantity"] == 1
        oid = (await _order(client, buyer_token, store_id, lid, quantity=1))["id"]
        assert (await _post(client, seller_token, f"/orders/{oid}/accept")).status_code == 200
        await _post(client, buyer_token, f"/orders/{oid}/cancel")

        second_id, second_token = await _buyer(client, name="Second Chat Buyer")
        again = await _finalize(client, second_token, second_id, lid)
        assert again.status_code == 201
        await _set_deal(again.json()["deal_id"], DealStatus.cancelled)
        assert (await client.get(f"/listings/{lid}")).json()["available_quantity"] == 1
        assert tuple(await _listing_row(lid)) == (1, 0)

    @pytest.mark.asyncio
    async def test_with_payments_off_only_paid_out_deals_hold_units(self, client, payments_off):
        # The established chat rule (listings/stock.deals_hold_stock): with
        # payments off an agreed deal is a price, not a sale; a paid-out one
        # holds its units - for store orders too.
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=1)
        await _track(client, seller_token, store_id, lid, 1)
        chat_id, chat_token = await _buyer(client, name="Chat Buyer")
        deal = await _finalize(client, chat_token, chat_id, lid)
        assert deal.status_code == 201
        assert (await client.get(f"/listings/{lid}")).json()["available_quantity"] == 1
        await _set_deal(deal.json()["deal_id"], DealStatus.released)
        _, buyer_token = await _buyer(client)
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 1}])
        assert r.json()["detail"]["code"] == "ORDER_ITEM_OUT_OF_STOCK"

    @pytest.mark.asyncio
    async def test_every_seller_figure_is_the_number_the_backend_decides_by(self, client):
        # P1: the stock controls, the product list, the order screen, the
        # public product and the store's catalogue all show the shared
        # count - and both channels are allowed exactly that many.
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=5)
        await _track(client, seller_token, store_id, lid, 5)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid, quantity=2))["id"]
        await _post(client, seller_token, f"/orders/{oid}/accept")
        chat_id, chat_token = await _buyer(client, name="Chat Buyer")
        assert (await _finalize(client, chat_token, chat_id, lid, quantity=1)).status_code == 201

        controls = (await client.patch(f"/stores/{store_id}/manage/listings/{lid}/stock",
                                       json={"temporarily_unavailable": False},
                                       headers=_auth(seller_token))).json()
        product = await _owner_product(client, seller_token, store_id, lid)
        line = (await client.get(f"/orders/{oid}", headers=_auth(seller_token))).json()["items"][0]
        public = (await client.get(f"/listings/{lid}")).json()
        card = next(c for c in (await client.get(f"/stores/{store_id}/listings")).json() if c["id"] == lid)

        assert (controls["stock_on_hand"], controls["stock_reserved"],
                controls["stock_committed_to_deals"], controls["available_quantity"]) == (5, 2, 1, 2)
        assert (product["stock_on_hand"], product["stock_reserved"],
                product["stock_committed_to_deals"], product["available_quantity"]) == (5, 2, 1, 2)
        assert (line["stock_on_hand"], line["stock_committed_to_deals"], line["stock_available"]) == (5, 1, 2)
        assert (public["available_quantity"], public["units_left"]) == (2, 2)
        assert card["available_quantity"] == 2

        # Exactly 2, on either channel.
        r = await _submit(client, buyer_token, store_id, [{"listing_id": lid, "quantity": 3}])
        assert r.json()["detail"]["code"] == "ORDER_ITEM_QUANTITY" and r.json()["detail"]["available"] == 2
        other_id, other_token = await _buyer(client, name="Other Chat Buyer")
        r = await _finalize(client, other_token, other_id, lid, quantity=3)
        assert r.status_code == 409 and "Only 2 left" in r.json()["detail"]
        second = (await _order(client, buyer_token, store_id, lid, quantity=2))["id"]
        assert (await _post(client, seller_token, f"/orders/{second}/accept")).status_code == 200
        after = await _owner_product(client, seller_token, store_id, lid)
        assert after["available_quantity"] == 0
        r = await _finalize(client, other_token, other_id, lid, quantity=1)
        assert r.status_code == 409 and r.json()["detail"] == "This listing is sold out."
        # On hand can't be counted below what is promised: 4 to orders, 1 to a chat.
        low = await client.patch(f"/stores/{store_id}/manage/listings/{lid}/stock",
                                 json={"quantity": 4}, headers=_auth(seller_token))
        assert low.status_code == 409 and low.json()["detail"]["code"] == "STOCK_BELOW_RESERVED"
        assert low.json()["detail"]["minimum"] == 5


class TestStockTrackingToggle:
    @pytest.mark.asyncio
    async def test_counting_cannot_stop_while_accepted_orders_hold_units(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=3)
        await _track(client, seller_token, store_id, lid, 3)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid, quantity=2))["id"]
        await _post(client, seller_token, f"/orders/{oid}/accept")
        path = f"/stores/{store_id}/manage/listings/{lid}/stock"

        r = await client.patch(path, json={"stock_tracked": False}, headers=_auth(seller_token))
        assert r.status_code == 409 and r.json()["detail"]["code"] == "STOCK_TRACKING_IN_USE"
        assert r.json()["detail"]["reserved"] == 2
        # Nothing changed: still counted, the reservation intact.
        assert tuple(await _listing_row(lid)) == (3, 2)
        assert (await client.get(f"/listings/{lid}")).json()["stock_tracked"] is True

        # Handed over, the units come off on hand - then counting can stop.
        await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        await _post(client, seller_token, f"/orders/{oid}/dispatch")
        await _post(client, seller_token, f"/orders/{oid}/delivered")
        assert tuple(await _listing_row(lid)) == (1, 0)
        stopped = await client.patch(path, json={"stock_tracked": False}, headers=_auth(seller_token))
        assert stopped.status_code == 200, stopped.text
        assert (stopped.json()["stock_tracked"], stopped.json()["quantity"]) == (False, 1)
        # Untracked, chat deals count from the same quantity as before.
        chat_id, chat_token = await _buyer(client, name="Chat Buyer")
        assert (await _finalize(client, chat_token, chat_id, lid)).status_code == 201
        other_id, other_token = await _buyer(client, name="Other Chat Buyer")
        r = await _finalize(client, other_token, other_id, lid)
        assert r.status_code == 409 and r.json()["detail"] == "This listing is sold out."

    @pytest.mark.asyncio
    async def test_counting_from_nothing_left_needs_a_number(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=2)
        await _track(client, seller_token, store_id, lid, 0)
        path = f"/stores/{store_id}/manage/listings/{lid}/stock"
        r = await client.patch(path, json={"stock_tracked": False}, headers=_auth(seller_token))
        # Untracked, 0 would read as one: say how many first.
        assert r.status_code == 400 and r.json()["detail"]["code"] == "STOCK_QUANTITY_REQUIRED"
        ok = await client.patch(path, json={"stock_tracked": False, "quantity": 2}, headers=_auth(seller_token))
        assert ok.status_code == 200 and ok.json()["quantity"] == 2

    @pytest.mark.asyncio
    async def test_counting_starts_with_orders_accepted_before_it_reserved(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=5)
        _, buyer_token = await _buyer(client)
        oid = (await _order(client, buyer_token, store_id, lid, quantity=2))["id"]
        assert (await _post(client, seller_token, f"/orders/{oid}/accept")).status_code == 200
        # Accepted while not counted: nothing reserved.
        assert tuple(await _listing_row(lid)) == (5, 0)
        path = f"/stores/{store_id}/manage/listings/{lid}/stock"

        short = await client.patch(path, json={"stock_tracked": True, "quantity": 1}, headers=_auth(seller_token))
        assert short.status_code == 409 and short.json()["detail"]["code"] == "STOCK_BELOW_RESERVED"
        assert short.json()["detail"]["reserved"] == 2
        assert tuple(await _listing_row(lid)) == (5, 0)

        started = await client.patch(path, json={"stock_tracked": True, "quantity": 4}, headers=_auth(seller_token))
        assert started.status_code == 200, started.text
        assert (started.json()["stock_reserved"], started.json()["available_quantity"]) == (2, 2)
        assert tuple(await _listing_row(lid)) == (4, 2)
        line = (await client.get(f"/orders/{oid}", headers=_auth(seller_token))).json()["items"][0]
        assert (line["reserved_quantity"], line["stock_state"]) == (2, "reserved")
        # A chat deal can't take the order's units...
        chat_id, chat_token = await _buyer(client, name="Chat Buyer")
        r = await _finalize(client, chat_token, chat_id, lid, quantity=3)
        assert r.status_code == 409 and "Only 2 left" in r.json()["detail"]
        # ...and handing the order over takes them off once.
        await _post(client, buyer_token, f"/orders/{oid}/confirm", {"revision": 1})
        await _post(client, seller_token, f"/orders/{oid}/dispatch")
        await _post(client, seller_token, f"/orders/{oid}/delivered")
        assert tuple(await _listing_row(lid)) == (2, 0)
        await _post(client, buyer_token, f"/orders/{oid}/received")
        assert tuple(await _listing_row(lid)) == (2, 0)

    @pytest.mark.asyncio
    async def test_switching_counting_keeps_what_chat_deals_hold_and_sold(self, client):
        _, seller_token, store_id = await _seller(client)
        lid = await _listing(client, seller_token, store_id, quantity=4)
        sold_id, sold_token = await _buyer(client, name="Paid Chat Buyer")
        sold = await _finalize(client, sold_token, sold_id, lid, quantity=1)
        await _set_deal(sold.json()["deal_id"], DealStatus.released)
        open_id, open_token = await _buyer(client, name="Open Chat Buyer")
        assert (await _finalize(client, open_token, open_id, lid, quantity=1)).status_code == 201
        # Untracked: 4 stated, 1 sold, 1 in a deal under way.
        assert (await client.get(f"/listings/{lid}")).json()["units_left"] == 2
        path = f"/stores/{store_id}/manage/listings/{lid}/stock"

        # Counting from the stated quantity: on hand is what wasn't sold.
        started = (await client.patch(path, json={"stock_tracked": True}, headers=_auth(seller_token))).json()
        assert (started["stock_on_hand"], started["stock_committed_to_deals"],
                started["available_quantity"]) == (3, 1, 2)
        # The seller's own count: on hand 3 is what they have, not 3 - 1 sold again.
        recount = (await client.patch(path, json={"quantity": 3}, headers=_auth(seller_token))).json()
        assert (recount["stock_on_hand"], recount["available_quantity"]) == (3, 2)
        low = await client.patch(path, json={"quantity": 0}, headers=_auth(seller_token))
        assert low.status_code == 409 and low.json()["detail"]["in_deals"] == 1
        # And stopping keeps the same units for chat deals.
        stopped = (await client.patch(path, json={"stock_tracked": False}, headers=_auth(seller_token))).json()
        assert stopped["stock_tracked"] is False
        assert (await client.get(f"/listings/{lid}")).json()["units_left"] == 2
        # Not counted, a quantity is the listing's stated one again: stored
        # as given, with the chat deals (1 sold, 1 under way) counted against it.
        restated = (await client.patch(path, json={"quantity": 6}, headers=_auth(seller_token))).json()
        assert (restated["stock_tracked"], restated["quantity"], restated["stock_on_hand"]) == (False, 6, None)
        assert (await client.get(f"/listings/{lid}")).json()["units_left"] == 4
