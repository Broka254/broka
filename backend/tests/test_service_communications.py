"""Service Communications: durable publishing, audience and delivery contracts."""
from __future__ import annotations

import asyncio
import json
import logging
import uuid
from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, desc, inspect, select
from sqlalchemy.exc import IntegrityError

from api.core import push_devices
from api.core.config import settings
from api.database import (
    AccountType, AsyncSessionLocal, AuditLog, User, init_db, reset_engine,
)
from api.domains.service_communications import router as communication_router
from api.domains.service_communications import service as communication_service
from api.domains.service_communications.audience import count_audience
from api.models.service_communication import (
    ServiceCommunication,
    ServiceCommunicationDeviceDelivery,
    ServiceCommunicationRecipient,
    ServiceCommunicationVersion,
)
from api.models.store import Store
from api.routers import calls
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / f"test_service_communications_{uuid.uuid4().hex}.db"
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


@pytest.fixture(autouse=True)
def fcm_configured(monkeypatch):
    monkeypatch.setattr(calls, "_get_fcm", lambda: object())


@pytest_asyncio.fixture(autouse=True)
async def clean_communications():
    """Keep one test's due rows from publishing inside the next test's pass."""
    async with AsyncSessionLocal() as db:
        await db.execute(delete(ServiceCommunicationDeviceDelivery))
        await db.execute(delete(ServiceCommunicationRecipient))
        await db.execute(delete(ServiceCommunicationVersion))
        await db.execute(delete(ServiceCommunication))
        await db.execute(delete(AuditLog).where(
            AuditLog.resource_type == "service_communication",
        ))
        await db.commit()


def _auth(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _user(
    *, admin: bool = False, account_type: AccountType = AccountType.buyer,
    trust_score: int = 100, flagged: bool = False,
) -> User:
    tag = uuid.uuid4().hex[:12]
    user = User(
        name="Admin" if admin else f"User {tag}",
        phone=f"+2547{tag[:9]}",
        email=f"{tag}@service.test",
        password_hash="x",
        is_admin=admin,
        account_type=account_type,
        trust_score=trust_score,
        is_flagged=flagged,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


async def _store(owner: User) -> Store:
    tag = uuid.uuid4().hex[:10]
    store = Store(owner_id=owner.id, name=f"Store {tag}", slug=f"store-{tag}")
    async with AsyncSessionLocal() as db:
        db.add(store)
        await db.commit()
        await db.refresh(store)
    return store


async def _register_device(user: User, token: str) -> None:
    async with AsyncSessionLocal() as db:
        await push_devices.register(db, user.id, token)
        await db.commit()


async def _create(client: AsyncClient, admin: User, **overrides) -> dict:
    payload = {
        "title": "Scheduled maintenance",
        "body": "BROKA will be unavailable for a short period.",
        "communication_type": "maintenance",
        "severity": "high",
        "audience": {"kind": "all"},
        "channels": ["in_app"],
    }
    payload.update(overrides)
    response = await client.post("/admin/communications", headers=_auth(admin), json=payload)
    assert response.status_code == 201, response.text
    return response.json()


async def _publish(client: AsyncClient, admin: User, communication_id: str, key: str | None = None):
    headers = _auth(admin)
    if key:
        headers["X-Idempotency-Key"] = key
    return await client.post(
        f"/admin/communications/{communication_id}/publish", headers=headers,
    )


class RecordingSender:
    def __init__(self, outcome=None):
        self.calls: list[dict] = []
        self.outcome = outcome

    async def __call__(self, **kwargs):
        self.calls.append(kwargs)
        if callable(self.outcome):
            result = self.outcome(**kwargs)
            if asyncio.iscoroutine(result):
                return await result
            return result
        if self.outcome is not None:
            return self.outcome
        return calls.FcmResult(True, message_id=f"projects/test/messages/{len(self.calls)}")


async def _pass(sender: RecordingSender, *, now: datetime | None = None) -> service.PassResult:
    return await communication_service.run_service_communications_pass(
        sender=sender, now=now,
    )


# ── Schema and model constraints ─────────────────────────────────────────────

@pytest.mark.asyncio
async def test_new_tables_and_unique_recipient_constraint_are_real():
    async with AsyncSessionLocal() as db:
        def _tables(conn):
            return set(inspect(conn).get_table_names())

        connection = await db.connection()
        tables = await connection.run_sync(_tables)
    assert {
        "service_communications", "service_communication_versions",
        "service_communication_recipients", "service_communication_device_deliveries",
    } <= tables

    admin = await _user(admin=True)
    communication = await _create_type(admin)
    async with AsyncSessionLocal() as db:
        db.add_all([
            ServiceCommunicationRecipient(
                communication_id=communication.id, user_id=admin.id, status="queued",
            ),
            ServiceCommunicationRecipient(
                communication_id=communication.id, user_id=admin.id, status="queued",
            ),
        ])
        with pytest.raises(IntegrityError):
            await db.commit()
        await db.rollback()


async def _create_type(admin: User) -> ServiceCommunication:
    now = datetime.utcnow()
    communication = ServiceCommunication(
        title="Constraint check", body="Body", communication_type="announcement",
        severity="normal", status="draft", audience_json='{"kind":"all"}',
        channels_json='["in_app"]', created_by_id=admin.id, created_at=now,
        updated_at=now,
    )
    async with AsyncSessionLocal() as db:
        db.add(communication)
        await db.commit()
        await db.refresh(communication)
    return communication


# ── Authorization and draft lifecycle ────────────────────────────────────────

@pytest.mark.asyncio
async def test_management_routes_require_admin_and_customer_routes_require_user(client):
    ordinary = await _user()
    for method, path, body in (
        ("get", "/admin/communications", None),
        ("post", "/admin/communications/preview", {"audience": {"kind": "all"}}),
        ("get", "/admin/communications/diagnostics/worker", None),
        ("post", "/admin/communications", {
            "title": "Denied", "body": "Denied", "communication_type": "announcement",
            "audience": {"kind": "all"}, "channels": ["in_app"],
        }),
        ("patch", "/admin/communications/missing", {"title": "Denied"}),
        ("post", "/admin/communications/missing/schedule", {
            "scheduled_at": (datetime.utcnow() + timedelta(hours=1)).isoformat(),
        }),
        ("post", "/admin/communications/missing/publish", None),
        ("post", "/admin/communications/missing/cancel", {}),
        ("post", "/admin/communications/missing/complete", {}),
        ("get", "/admin/communications/missing/recipients", None),
        ("post", "/admin/communications/missing/recipients/retry", {}),
        ("get", "/admin/communications/missing/stats", None),
    ):
        kwargs = {"json": body} if body is not None else {}
        response = await getattr(client, method)(path, headers=_auth(ordinary), **kwargs)
        assert response.status_code == 403, response.text
    assert (await client.get("/communications")).status_code == 401


@pytest.mark.asyncio
async def test_draft_create_and_update_append_version_history(client):
    admin = await _user(admin=True)
    created = await _create(client, admin, audience={"kind": "all"})
    assert created["status"] == "draft"
    assert created["version"] == 1
    assert created["channels"] == ["in_app"]

    updated = await client.patch(
        f"/admin/communications/{created['id']}",
        headers=_auth(admin),
        json={
            "expected_version": 1,
            "title": "Updated maintenance",
            "body": "New plain-text body.",
            "audience": {"kind": "buyers"},
        },
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["version"] == 2
    assert updated.json()["title"] == "Updated maintenance"

    stale = await client.patch(
        f"/admin/communications/{created['id']}",
        headers=_auth(admin), json={"expected_version": 1, "title": "Stale edit"},
    )
    assert stale.status_code == 409

    async with AsyncSessionLocal() as db:
        versions = (await db.execute(
            select(ServiceCommunicationVersion.version).where(
                ServiceCommunicationVersion.communication_id == created["id"],
            ).order_by(ServiceCommunicationVersion.version)
        )).scalars().all()
    assert versions == [1, 2]

    null_title = await client.patch(
        f"/admin/communications/{created['id']}",
        headers=_auth(admin), json={"title": None},
    )
    assert null_title.status_code == 422


@pytest.mark.asyncio
async def test_edit_after_publication_starts_is_refused(client):
    admin = await _user(admin=True)
    created = await _create(client, admin)
    assert (await _publish(client, admin, created["id"], "edit-after-publish")).status_code == 202
    response = await client.patch(
        f"/admin/communications/{created['id']}",
        headers=_auth(admin), json={"title": "Too late"},
    )
    assert response.status_code == 409


# ── Audience validation and preview ─────────────────────────────────────────

@pytest.mark.asyncio
async def test_audience_preview_matches_database_and_excludes_ineligible_users(client):
    admin = await _user(admin=True)
    buyer = await _user(account_type=AccountType.buyer)
    seller = await _user(account_type=AccountType.buyer_seller)
    blocked = await _user(account_type=AccountType.buyer, trust_score=10)
    await _user(account_type=AccountType.buyer, flagged=True)
    await _store(seller)

    async with AsyncSessionLocal() as db:
        owners_before_inactive_store = await count_audience(
            db, {"kind": "store_owners"},
        )
    inactive_owner = await _user(account_type=AccountType.buyer_seller)
    inactive_store = await _store(inactive_owner)
    async with AsyncSessionLocal() as db:
        store = await db.get(Store, inactive_store.id)
        store.is_active = False
        await db.commit()

    async with AsyncSessionLocal() as db:
        buyers = await count_audience(db, {"kind": "buyers"})
        sellers = await count_audience(db, {"kind": "sellers"})
        owners = await count_audience(db, {"kind": "store_owners"})
        selected = await count_audience(db, {"kind": "user_ids", "user_ids": [buyer.id]})
        blocked_count = await count_audience(db, {"kind": "user_ids", "user_ids": [blocked.id]})
    assert owners == owners_before_inactive_store

    for audience, expected in (
        ({"kind": "buyers"}, buyers),
        ({"kind": "sellers"}, sellers),
        ({"kind": "store_owners"}, owners),
        ({"kind": "user_ids", "user_ids": [buyer.id]}, selected),
    ):
        response = await client.post(
            "/admin/communications/preview", headers=_auth(admin),
            json={"audience": audience},
        )
        assert response.status_code == 200, response.text
        assert response.json()["count"] == expected
    assert blocked_count == 0

    invalid = await client.post(
        "/admin/communications/preview", headers=_auth(admin),
        json={"audience": {"kind": "user_ids", "user_ids": [blocked.id]}},
    )
    assert invalid.status_code == 422


@pytest.mark.asyncio
async def test_unsupported_channels_and_unsafe_deep_links_are_refused(client):
    admin = await _user(admin=True)
    unsupported = await client.post(
        "/admin/communications", headers=_auth(admin),
        json={
            "title": "Email attempt", "body": "Must not silently succeed",
            "communication_type": "announcement", "audience": {"kind": "all"},
            "channels": ["in_app", "email"],
        },
    )
    assert unsupported.status_code == 422
    unsafe = await client.post(
        "/admin/communications", headers=_auth(admin),
        json={
            "title": "Unsafe", "body": "Body", "communication_type": "announcement",
            "audience": {"kind": "all"}, "channels": ["in_app"],
            "deep_link": "javascript:alert(1)",
        },
    )
    assert unsafe.status_code == 422
    too_large_for_push = await client.post(
        "/admin/communications", headers=_auth(admin),
        json={
            "title": "Large push", "body": "x" * 4_000,
            "communication_type": "announcement", "audience": {"kind": "all"},
            "channels": ["in_app", "push"],
        },
    )
    assert too_large_for_push.status_code == 422


@pytest.mark.asyncio
async def test_configured_explicit_recipient_limit_is_enforced(client):
    admin = await _user(admin=True)
    first = await _user()
    second = await _user()
    previous = settings.service_communication_max_explicit_recipients
    object.__setattr__(settings, "service_communication_max_explicit_recipients", 1)
    try:
        audience = {"kind": "user_ids", "user_ids": [first.id, second.id]}
        preview = await client.post(
            "/admin/communications/preview", headers=_auth(admin),
            json={"audience": audience},
        )
        assert preview.status_code == 422
        created = await client.post(
            "/admin/communications", headers=_auth(admin),
            json={
                "title": "Too many selected users", "body": "Body",
                "communication_type": "announcement", "audience": audience,
                "channels": ["in_app"],
            },
        )
        assert created.status_code == 422
    finally:
        object.__setattr__(settings, "service_communication_max_explicit_recipients", previous)


# ── Immediate/scheduled publication, expiry and idempotency ─────────────────

@pytest.mark.asyncio
async def test_immediate_publish_is_durable_idempotent_and_reaches_in_app(client):
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"immediate-{uuid.uuid4().hex}")
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )
    sender = RecordingSender()

    first = await _publish(client, admin, created["id"], "publish-once")
    assert first.status_code == 202, first.text
    assert first.json()["communication"]["status"] == "publishing"
    replay = await _publish(client, admin, created["id"], "publish-once")
    assert replay.status_code == 202
    assert replay.json()["communication"]["id"] == created["id"]
    assert (await _publish(client, admin, created["id"])).status_code == 409

    result = await _pass(sender)
    assert result.communications_published == 1
    assert result.recipients_resolved == 1
    assert len(sender.calls) == 1
    assert sender.calls[0]["data"]["communication_id"] == created["id"]
    # No explicit expiry: publication stamps the 30-day announcement
    # lifetime, so the push TTL follows it (capped at FCM's 28 days)
    # instead of living forever.
    assert sender.calls[0]["ttl_seconds"] == 28 * 24 * 60 * 60

    customer = await client.get("/communications", headers=_auth(buyer))
    assert customer.status_code == 200
    assert customer.json()["total"] == 1
    assert customer.json()["items"][0]["id"] == created["id"]


@pytest.mark.asyncio
async def test_push_ttl_follows_the_communication_expiry(client):
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"ttl-{uuid.uuid4().hex}")
    expires_at = datetime.utcnow() + timedelta(minutes=10)
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"], expires_at=expires_at.isoformat(),
    )
    sender = RecordingSender()
    await _publish(client, admin, created["id"], "push-ttl")
    await _pass(sender, now=datetime.utcnow())

    ttl = sender.calls[0]["ttl_seconds"]
    assert ttl is not None
    # FCM must stop trying after the in-app announcement expires instead of
    # using its four-week default for an already-finished maintenance notice.
    assert 590 <= ttl <= 600

    long_lived = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
        expires_at=(datetime.utcnow() + timedelta(days=60)).isoformat(),
    )
    long_sender = RecordingSender()
    await _publish(client, admin, long_lived["id"], "push-ttl-max")
    await _pass(long_sender, now=datetime.utcnow())
    assert long_sender.calls[0]["ttl_seconds"] == 28 * 24 * 60 * 60


@pytest.mark.asyncio
async def test_concurrent_publish_requests_move_the_row_once(client):
    admin = await _user(admin=True)
    created = await _create(client, admin)
    first, second = await asyncio.gather(
        _publish(client, admin, created["id"]),
        _publish(client, admin, created["id"]),
    )
    assert sorted((first.status_code, second.status_code)) == [202, 409]
    winner = first if first.status_code == 202 else second
    assert winner.json()["communication"]["status"] == "publishing"


@pytest.mark.asyncio
async def test_delivery_waits_until_publication_is_committed(client):
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"pre-publish-{uuid.uuid4().hex}")
    created = await _create(
        client, admin,
        audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )
    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        # A publication worker has committed its recipient batch but has not
        # yet committed the final published state.
        communication.status = "publishing"
        communication.publish_claim_token = "still-expanding"
        communication.publish_claim_expires_at = now + timedelta(minutes=5)
        db.add(ServiceCommunicationRecipient(
            communication_id=communication.id,
            user_id=buyer.id,
            status="queued",
            next_attempt_at=now,
            created_at=now,
            updated_at=now,
        ))
        await db.commit()

    sender = RecordingSender()
    before_publish = await _pass(sender, now=now)
    assert before_publish.recipients_claimed == 0
    assert sender.calls == []

    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        communication.status = "published"
        communication.published_at = now
        communication.publish_claim_token = None
        communication.publish_claim_expires_at = None
        await db.commit()

    after_publish = await _pass(sender, now=now)
    assert after_publish.recipients_claimed == 1
    assert len(sender.calls) == 1


@pytest.mark.asyncio
async def test_scheduled_publication_waits_for_due_time_and_uses_utc(client):
    admin = await _user(admin=True)
    buyer = await _user()
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
    )
    due_utc = datetime.now(timezone.utc).replace(microsecond=0) + timedelta(hours=2)
    response = await client.post(
        f"/admin/communications/{created['id']}/schedule",
        headers=_auth(admin), json={"scheduled_at": due_utc.isoformat()},
    )
    assert response.status_code == 200, response.text
    stored = datetime.fromisoformat(response.json()["scheduled_at"].replace("Z", "+00:00"))
    assert abs((stored - due_utc).total_seconds()) < 1

    sender = RecordingSender()
    early = await _pass(sender, now=due_utc.replace(tzinfo=None) - timedelta(minutes=1))
    assert early.communications_published == 0
    assert sender.calls == []

    on_time = await _pass(sender, now=due_utc.replace(tzinfo=None))
    assert on_time.communications_published == 1


@pytest.mark.asyncio
async def test_expired_communication_cannot_publish(client):
    admin = await _user(admin=True)
    created = await _create(client, admin)
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        communication.expires_at = datetime.utcnow() - timedelta(minutes=1)
        await db.commit()
    response = await _publish(client, admin, created["id"])
    assert response.status_code == 409


@pytest.mark.asyncio
async def test_expired_queued_recipient_is_not_pushed(client):
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"expired-before-send-{uuid.uuid4().hex}")
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )
    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        communication.status = "published"
        communication.published_at = now - timedelta(hours=1)
        communication.expires_at = now - timedelta(minutes=1)
        communication.audience_count = 1
        db.add(ServiceCommunicationRecipient(
            communication_id=communication.id,
            user_id=buyer.id,
            status="queued",
            next_attempt_at=now,
            created_at=now,
            updated_at=now,
        ))
        await db.commit()

    sender = RecordingSender()
    result = await _pass(sender, now=now)
    assert sender.calls == []
    assert result.failures == 1
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
    assert recipient.status == "failed"
    assert recipient.failure_category == "communication_expired"
    assert recipient.retry_eligible is False


@pytest.mark.asyncio
async def test_corrupt_stored_audience_fails_instead_of_publishing_empty(client):
    admin = await _user(admin=True)
    created = await _create(client, admin)
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        communication.audience_json = "{not-json"
        communication.status = "scheduled"
        communication.scheduled_at = datetime.utcnow() - timedelta(seconds=1)
        await db.commit()

    result = await _pass(RecordingSender())
    assert result.communications_published == 0
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        recipients = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalars().all()
    assert communication.status == "failed"
    assert recipients == []


@pytest.mark.asyncio
async def test_cancel_only_works_before_publication_starts(client):
    admin = await _user(admin=True)
    draft = await _create(client, admin)
    cancelled = await client.post(
        f"/admin/communications/{draft['id']}/cancel",
        headers=_auth(admin), json={"reason": "No longer needed"},
    )
    assert cancelled.status_code == 200
    assert cancelled.json()["status"] == "cancelled"

    live = await _create(client, admin)
    await _publish(client, admin, live["id"], "cancel-live")
    refused = await client.post(
        f"/admin/communications/{live['id']}/cancel",
        headers=_auth(admin), json={},
    )
    assert refused.status_code == 409


@pytest.mark.asyncio
async def test_complete_requires_settled_delivery_and_is_idempotent(client):
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"complete-{uuid.uuid4().hex}")
    scheduled = await _create(client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]})
    assert (await client.post(
        f"/admin/communications/{scheduled['id']}/schedule",
        headers=_auth(admin),
        json={"scheduled_at": (datetime.utcnow() + timedelta(hours=1)).isoformat()},
    )).status_code == 200
    assert (await client.post(
        f"/admin/communications/{scheduled['id']}/cancel",
        headers=_auth(admin), json={},
    )).json()["status"] == "cancelled"

    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )
    await _publish(client, admin, created["id"], "complete-pending")
    await _pass(RecordingSender(calls.FcmResult(
        False, failure_category="provider_transient", retryable=True,
    )))
    pending = await client.post(
        f"/admin/communications/{created['id']}/complete",
        headers=_auth(admin), json={},
    )
    assert pending.status_code == 409

    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
        recipient.status = "failed"
        recipient.retry_eligible = False
        recipient.next_attempt_at = None
        await db.commit()
    resolved = await client.post(
        f"/admin/communications/{created['id']}/complete",
        headers=_auth(admin), json={},
    )
    assert resolved.status_code == 200
    assert resolved.json()["status"] == "completed"
    again = await client.post(
        f"/admin/communications/{created['id']}/complete",
        headers=_auth(admin), json={},
    )
    assert again.status_code == 200
    assert again.json()["status"] == "completed"


# ── Multi-device and provider outcomes ──────────────────────────────────────

@pytest.mark.asyncio
async def test_every_device_is_attempted_and_partial_failure_is_visible(client):
    admin = await _user(admin=True)
    buyer = await _user()
    token_ok = f"ok-{uuid.uuid4().hex}"
    token_bad = f"bad-{uuid.uuid4().hex}"
    await _register_device(buyer, token_ok)
    await _register_device(buyer, token_bad)
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )

    async def outcome(**kwargs):
        if kwargs["token"] == token_ok:
            return calls.FcmResult(True, message_id="provider-message-1")
        return calls.FcmResult(
            False, failure_category="provider_transient", retryable=True,
        )

    sender = RecordingSender(outcome)
    await _publish(client, admin, created["id"], "partial")
    await _pass(sender)
    assert {call["token"] for call in sender.calls} == {token_ok, token_bad}

    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
        devices = (await db.execute(
            select(ServiceCommunicationDeviceDelivery).where(
                ServiceCommunicationDeviceDelivery.recipient_id == recipient.id,
            )
        )).scalars().all()
    assert recipient.status == "provider_accepted"
    assert recipient.provider_message_id == "provider-message-1"
    assert recipient.failure_category == "partial_failure"
    assert recipient.retry_eligible is False
    assert sorted(device.status for device in devices) == ["failed", "provider_accepted"]


@pytest.mark.asyncio
async def test_provider_timeout_is_bounded_and_retryable(client):
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"timeout-{uuid.uuid4().hex}")
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )

    class HangingSender:
        async def __call__(self, **kwargs):
            await asyncio.sleep(1)
            raise AssertionError("the timeout should have cancelled this call")

    previous = settings.service_communication_provider_timeout_seconds
    object.__setattr__(settings, "service_communication_provider_timeout_seconds", 0.05)
    try:
        await _publish(client, admin, created["id"], "timeout")
        result = await _pass(HangingSender())
    finally:
        object.__setattr__(settings, "service_communication_provider_timeout_seconds", previous)

    assert result.retries_scheduled == 1
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
        device = (await db.execute(
            select(ServiceCommunicationDeviceDelivery).where(
                ServiceCommunicationDeviceDelivery.recipient_id == recipient.id,
            )
        )).scalar_one()
    assert recipient.status == "retry_scheduled"
    assert recipient.failure_category == "provider_timeout"
    assert device.status == "retry_scheduled"
    assert device.failure_category == "provider_timeout"


@pytest.mark.asyncio
async def test_provider_failure_logs_do_not_expose_tokens_or_error_text(client, caplog):
    admin = await _user(admin=True)
    buyer = await _user()
    token = f"secret-device-{uuid.uuid4().hex}"
    await _register_device(buyer, token)
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )

    class LeakyFailureSender:
        async def __call__(self, **kwargs):
            raise RuntimeError(f"provider payload token={kwargs['token']}")

    await _publish(client, admin, created["id"], "sanitized-log")
    with caplog.at_level(logging.WARNING):
        result = await _pass(LeakyFailureSender())

    assert result.retries_scheduled == 1
    assert token not in caplog.text
    assert "provider payload" not in caplog.text
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
    assert recipient.failure_category == "provider_exception"


@pytest.mark.asyncio
async def test_dead_token_is_not_retried_and_is_forgotten(client):
    admin = await _user(admin=True)
    buyer = await _user()
    token = f"dead-{uuid.uuid4().hex}"
    await _register_device(buyer, token)
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )
    sender = RecordingSender(calls.FcmResult(False, unregistered=True))
    await _publish(client, admin, created["id"], "dead-token")
    await _pass(sender)
    again = await _pass(sender, now=datetime.utcnow() + timedelta(days=1))
    assert len(sender.calls) == 1
    assert again.recipients_claimed == 0
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
        tokens = await push_devices.tokens_for(db, buyer.id)
    assert recipient.status == "failed"
    assert recipient.failure_category == "invalid_token"
    assert recipient.retry_eligible is False
    assert tokens == []


@pytest.mark.asyncio
async def test_retry_backoff_exhaustion_and_duplicate_prevention(client):
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"retry-{uuid.uuid4().hex}")
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )
    sender = RecordingSender(calls.FcmResult(
        False, failure_category="provider_transient", retryable=True,
    ))
    await _publish(client, admin, created["id"], "retry-exhaust")

    now = datetime.utcnow()
    for expected_attempt in range(1, settings.service_communication_max_attempts + 1):
        result = await _pass(sender, now=now)
        assert len(sender.calls) == expected_attempt
        async with AsyncSessionLocal() as db:
            recipient = (await db.execute(
                select(ServiceCommunicationRecipient).where(
                    ServiceCommunicationRecipient.communication_id == created["id"],
                )
            )).scalar_one()
            assert recipient.attempt_count == expected_attempt
            if expected_attempt < settings.service_communication_max_attempts:
                assert recipient.status == "retry_scheduled"
                assert recipient.retry_eligible is True
                now = recipient.next_attempt_at + timedelta(microseconds=1)
            else:
                assert recipient.status == "failed"
                assert recipient.failure_category == "retry_exhausted"
                assert recipient.retry_eligible is False
                now = now + timedelta(days=1)

    await _pass(sender, now=datetime.utcnow() + timedelta(days=10))
    assert len(sender.calls) == settings.service_communication_max_attempts


@pytest.mark.asyncio
async def test_admin_retry_requeues_only_eligible_failures_and_audits(client):
    admin = await _user(admin=True)
    first_buyer = await _user()
    second_buyer = await _user()
    first_token = f"admin-retry-{uuid.uuid4().hex}"
    second_token = f"permanent-failure-{uuid.uuid4().hex}"
    await _register_device(first_buyer, first_token)
    await _register_device(second_buyer, second_token)
    created = await _create(
        client, admin,
        audience={
            "kind": "user_ids", "user_ids": [first_buyer.id, second_buyer.id],
        },
        channels=["in_app", "push"],
    )
    failing = RecordingSender(calls.FcmResult(
        False, failure_category="provider_transient", retryable=True,
    ))
    await _publish(client, admin, created["id"], "admin-retry")
    await _pass(failing)
    assert {call["token"] for call in failing.calls} == {first_token, second_token}

    async with AsyncSessionLocal() as db:
        recipients = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalars().all()
        by_user = {recipient.user_id: recipient for recipient in recipients}
        by_user[first_buyer.id].status = "failed"
        by_user[first_buyer.id].failure_category = "provider_error"
        by_user[first_buyer.id].retry_eligible = True
        by_user[first_buyer.id].next_attempt_at = None
        by_user[second_buyer.id].status = "failed"
        by_user[second_buyer.id].failure_category = "invalid_message"
        by_user[second_buyer.id].retry_eligible = False
        by_user[second_buyer.id].next_attempt_at = None
        communication = await db.get(ServiceCommunication, created["id"])
        communication.status = "completed"
        communication.completed_at = datetime.utcnow()
        await db.commit()

    retried = await client.post(
        f"/admin/communications/{created['id']}/recipients/retry",
        headers=_auth(admin), json={},
    )
    assert retried.status_code == 200, retried.text
    assert retried.json()["retried"] == 1
    async with AsyncSessionLocal() as db:
        recipients = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalars().all()
        by_user = {recipient.user_id: recipient for recipient in recipients}
        communication = await db.get(ServiceCommunication, created["id"])
        audit = (await db.execute(
            select(AuditLog).where(
                AuditLog.resource_type == "service_communication",
                AuditLog.resource_id == created["id"],
                AuditLog.action == "service_communication_retry_requested",
            ).order_by(desc(AuditLog.created_at))
        )).scalars().first()
    assert by_user[first_buyer.id].status == "queued"
    assert by_user[second_buyer.id].status == "failed"
    assert by_user[second_buyer.id].failure_category == "invalid_message"
    assert communication.status == "published"
    assert audit is not None
    assert json.loads(audit.detail)["retried"] == 1

    succeeding = RecordingSender()
    await _pass(succeeding)
    assert {call["token"] for call in succeeding.calls} == {first_token}


@pytest.mark.asyncio
async def test_empty_retry_selection_is_rejected_instead_of_retrying_everyone(client):
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"empty-retry-{uuid.uuid4().hex}")
    created = await _create(
        client, admin,
        audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )
    await _publish(client, admin, created["id"], "empty-retry")
    await _pass(RecordingSender(calls.FcmResult(
        False, failure_category="provider_transient", retryable=True,
    )))

    response = await client.post(
        f"/admin/communications/{created['id']}/recipients/retry",
        headers=_auth(admin),
        json={"recipient_ids": []},
    )
    assert response.status_code == 422
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
    assert recipient.status == "retry_scheduled"
    assert recipient.attempt_count == 1


@pytest.mark.asyncio
async def test_worker_recovers_an_abandoned_sending_claim(client):
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"recover-{uuid.uuid4().hex}")
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )
    await _publish(client, admin, created["id"], "recover")
    async with AsyncSessionLocal() as db:
        # First pass publishes and leaves a recipient row; this test models
        # a process dying after it claimed that row.
        await _pass(RecordingSender(calls.FcmResult(
            False, failure_category="provider_transient", retryable=True,
        )))
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
        recipient.status = "sending"
        recipient.claim_token = "abandoned"
        recipient.claim_expires_at = datetime.utcnow() - timedelta(seconds=1)
        recipient.next_attempt_at = None
        await db.commit()
    sender = RecordingSender()
    await _pass(sender, now=datetime.utcnow())
    assert len(sender.calls) == 1
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
    assert recipient.status == "provider_accepted"


@pytest.mark.asyncio
async def test_publication_recovers_after_a_recipient_insert_rollback(
    client, monkeypatch,
):
    admin = await _user(admin=True)
    buyer = await _user()
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
    )
    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        communication.status = "publishing"
        communication.publish_claim_token = "insert-conflict"
        communication.publish_claim_expires_at = now + timedelta(minutes=5)
        communication.expires_at = now + timedelta(hours=1)
        db.add(ServiceCommunicationRecipient(
            communication_id=communication.id,
            user_id=buyer.id,
            status="queued",
            next_attempt_at=now,
            created_at=now,
            updated_at=now,
        ))
        await db.commit()

    calls = 0

    async def conflicting_batch(db, communication_id, audience, limit):
        nonlocal calls
        calls += 1
        # Force the unique constraint to reject the first insert, then show
        # the recovery pass that the winner's recipient row is now present.
        return [buyer.id] if calls == 1 else []

    monkeypatch.setattr(
        communication_service, "missing_user_ids", conflicting_batch,
    )
    inserted = await communication_service.publish_claimed(
        created["id"], "insert-conflict", now=now,
    )

    assert inserted == 1
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        recipients = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalars().all()
    assert communication.status == "published"
    assert communication.audience_count == 1
    assert len(recipients) == 1


@pytest.mark.asyncio
async def test_concurrent_claims_do_not_duplicate_a_recipient(client):
    admin = await _user(admin=True)
    buyer = await _user()
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
    )
    await _publish(client, admin, created["id"], "claim-once")
    await _pass(RecordingSender())
    # Put the one recipient back in a due state to exercise the claim.
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
        recipient.status = "queued"
        recipient.attempt_count = 0
        recipient.next_attempt_at = datetime.utcnow() - timedelta(seconds=1)
        communication = await db.get(ServiceCommunication, created["id"])
        communication.status = "published"
        communication.completed_at = None
        await db.commit()

    async def claim():
        async with AsyncSessionLocal() as db:
            return await communication_service.claim_recipients(
                db, now=datetime.utcnow(),
            )

    first, second = await asyncio.gather(claim(), claim())
    claimed = set(first[1]) | set(second[1])
    assert len(claimed) == 1
    assert len(first[1]) + len(second[1]) == 1


@pytest.mark.asyncio
async def test_concurrent_workers_claim_a_due_campaign_once(client):
    admin = await _user(admin=True)
    created = await _create(client, admin)
    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        communication.status = "scheduled"
        communication.scheduled_at = now - timedelta(seconds=1)
        await db.commit()

    async def claim():
        async with AsyncSessionLocal() as db:
            return await communication_service.claim_publishing(db, now=now)

    first, second = await asyncio.gather(claim(), claim())
    claimed = set(first[1]) | set(second[1])
    assert claimed == {created["id"]}
    assert len(first[1]) + len(second[1]) == 1


# ── Push configuration failure, in-app persistence, isolation and read state ─

@pytest.mark.asyncio
async def test_push_configuration_failure_preserves_in_app_announcement(
    client, monkeypatch,
):
    monkeypatch.setattr(calls, "_get_fcm", lambda: None)
    admin = await _user(admin=True)
    buyer = await _user()
    await _register_device(buyer, f"unconfigured-{uuid.uuid4().hex}")
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
        channels=["in_app", "push"],
    )
    assert created["push_available"] is False
    assert created["warnings"]
    published = await _publish(client, admin, created["id"], "push-off")
    assert published.status_code == 202
    await _pass(RecordingSender())

    customer = await client.get("/communications", headers=_auth(buyer))
    assert customer.status_code == 200
    assert customer.json()["total"] == 1
    stats = await client.get(
        f"/admin/communications/{created['id']}/stats", headers=_auth(admin),
    )
    assert stats.json()["delivery"]["failed"] == 1
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
    assert recipient.failure_category == "push_not_configured"


@pytest.mark.asyncio
async def test_customer_isolation_and_read_state(client):
    admin = await _user(admin=True)
    first = await _user()
    second = await _user()
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [first.id]},
    )
    await _publish(client, admin, created["id"], "isolated")
    await _pass(RecordingSender())

    assert (await client.get("/communications", headers=_auth(first))).json()["total"] == 1
    assert (await client.get("/communications", headers=_auth(second))).json()["total"] == 0
    forbidden = await client.post(
        f"/communications/{created['id']}/read", headers=_auth(second),
    )
    assert forbidden.status_code == 404
    read = await client.post(
        f"/communications/{created['id']}/read", headers=_auth(first),
    )
    assert read.status_code == 200
    assert read.json()["is_read"] is True
    again = await client.post(
        f"/communications/{created['id']}/read", headers=_auth(first),
    )
    assert again.status_code == 200
    body = (await client.get("/communications", headers=_auth(first))).json()
    assert body["items"][0]["is_read"] is True
    assert body["items"][0]["read_at"]


@pytest.mark.asyncio
async def test_expired_announcement_disappears_and_cannot_be_read(client):
    admin = await _user(admin=True)
    buyer = await _user()
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
    )
    await _publish(client, admin, created["id"], "expiry-feed")
    await _pass(RecordingSender())
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, created["id"])
        communication.expires_at = datetime.utcnow() - timedelta(minutes=1)
        await db.commit()

    feed = await client.get("/communications", headers=_auth(buyer))
    assert feed.status_code == 200
    assert feed.json()["total"] == 0
    read = await client.post(
        f"/communications/{created['id']}/read", headers=_auth(buyer),
    )
    assert read.status_code == 404


@pytest.mark.asyncio
async def test_unread_count_tracks_reads_and_stays_per_user(client):
    """GET /communications/unread-count backs the app's badge: the whole
    feed's unread total for exactly this user, dropping as reads land."""
    admin = await _user(admin=True)
    first = await _user()
    second = await _user()
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [first.id]},
    )
    await _publish(client, admin, created["id"], "unread-count-reads")
    await _pass(RecordingSender())
    count = await client.get("/communications/unread-count", headers=_auth(first))
    assert count.status_code == 200
    assert count.json() == {"unread_count": 1}
    # Another user's audience, another count: no cross-user leakage.
    other = await client.get("/communications/unread-count", headers=_auth(second))
    assert other.json() == {"unread_count": 0}
    # Reading drops this user's count; repeats stay idempotent at zero.
    assert (await client.post(
        f"/communications/{created['id']}/read", headers=_auth(first),
    )).status_code == 200
    assert (await client.get(
        "/communications/unread-count", headers=_auth(first),
    )).json() == {"unread_count": 0}
    assert (await client.post(
        f"/communications/{created['id']}/read", headers=_auth(first),
    )).status_code == 200
    assert (await client.get(
        "/communications/unread-count", headers=_auth(first),
    )).json() == {"unread_count": 0}


@pytest.mark.asyncio
async def test_unread_count_ignores_expired_and_unpublished_rows(client):
    """The badge counts what the feed shows: published and unexpired only.
    Drafts, scheduled and expired rows never inflate it."""
    admin = await _user(admin=True)
    buyer = await _user()
    live = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
    )
    await _publish(client, admin, live["id"], "unread-count-live")
    await _pass(RecordingSender())
    # A draft and a scheduled campaign exist but publish nothing yet.
    await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
    )
    scheduled = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
    )
    schedule = await client.post(
        f"/admin/communications/{scheduled['id']}/schedule",
        headers=_auth(admin),
        json={"scheduled_at": (datetime.utcnow() + timedelta(hours=1)).isoformat()},
    )
    assert schedule.status_code == 200
    count = await client.get("/communications/unread-count", headers=_auth(buyer))
    assert count.json() == {"unread_count": 1}
    # Expiring the live row removes it from the count, like the feed.
    async with AsyncSessionLocal() as db:
        communication = await db.get(ServiceCommunication, live["id"])
        communication.expires_at = datetime.utcnow() - timedelta(minutes=1)
        await db.commit()
    expired = await client.get("/communications/unread-count", headers=_auth(buyer))
    assert expired.json() == {"unread_count": 0}


@pytest.mark.asyncio
async def test_unread_count_requires_authentication(client):
    assert (await client.get("/communications/unread-count")).status_code == 401


# ── Audit, pagination and response contracts ─────────────────────────────────

@pytest.mark.asyncio
async def test_admin_mutations_write_sanitized_audit_events_with_request_id(client):
    admin = await _user(admin=True)
    created = await _create(client, admin)
    await client.patch(
        f"/admin/communications/{created['id']}",
        headers=_auth(admin), json={"title": "Audited update"},
    )
    await _publish(client, admin, created["id"], "audit-publish")
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(
            select(AuditLog).where(
                AuditLog.resource_type == "service_communication",
                AuditLog.resource_id == created["id"],
            ).order_by(AuditLog.created_at)
        )).scalars().all()
    actions = {row.action for row in rows}
    assert {
        "service_communication_created",
        "service_communication_updated",
        "service_communication_publish_requested",
    } <= actions
    assert all(row.actor_id == admin.id for row in rows)
    assert all(json.loads(row.detail)["request_id"] for row in rows)
    # Body/title content is deliberately absent from audit metadata.
    assert all("Audited update" not in (row.detail or "") for row in rows)


@pytest.mark.asyncio
async def test_retry_mutation_rolls_back_when_its_audit_fails(client, monkeypatch):
    admin = await _user(admin=True)
    buyer = await _user()
    created = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
    )
    await _publish(client, admin, created["id"], "retry-audit-rollback")
    await _pass(RecordingSender(calls.FcmResult(
        False, failure_category="provider_exception", retryable=True,
    )))
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
        recipient.status = "failed"
        recipient.retry_eligible = False
        recipient.next_attempt_at = None
        communication = await db.get(ServiceCommunication, created["id"])
        communication.status = "completed"
        communication.completed_at = datetime.utcnow()
        await db.commit()

    async def failed_audit(*args, **kwargs):
        raise RuntimeError("audit unavailable")

    monkeypatch.setattr(communication_router, "_audit", failed_audit)
    # ASGITransport re-raises after the app's 500 handler has run, so the
    # test can assert both the failure and the transaction's final state.
    with pytest.raises(RuntimeError, match="audit unavailable"):
        await client.post(
            f"/admin/communications/{created['id']}/recipients/retry",
            headers=_auth(admin), json={},
        )

    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.communication_id == created["id"],
            )
        )).scalar_one()
        communication = await db.get(ServiceCommunication, created["id"])
    assert recipient.status == "failed"
    assert communication.status == "completed"


@pytest.mark.asyncio
async def test_list_pagination_and_recipient_page_contracts(client):
    admin = await _user(admin=True)
    created = [await _create(client, admin) for _ in range(3)]
    response = await client.get(
        "/admin/communications?limit=2&offset=0", headers=_auth(admin),
    )
    assert response.status_code == 200
    body = response.json()
    assert body["limit"] == 2 and body["offset"] == 0
    assert body["total"] >= 3
    assert len(body["items"]) == 2
    assert response.headers["x-total-count"] == str(body["total"])
    assert {
        "id", "title", "body", "communication_type", "severity", "status",
        "audience", "channels", "version", "warnings", "push_available",
    } <= set(body["items"][0])

    buyer = await _user()
    selected = await _create(
        client, admin, audience={"kind": "user_ids", "user_ids": [buyer.id]},
    )
    await _publish(client, admin, selected["id"], "recipient-page")
    await _pass(RecordingSender())
    recipients = await client.get(
        f"/admin/communications/{selected['id']}/recipients?limit=1&offset=0",
        headers=_auth(admin),
    )
    assert recipients.status_code == 200
    assert recipients.json()["total"] == 1
    assert "user_id" in recipients.json()["items"][0]
    assert "token" not in json.dumps(recipients.json()).lower()


@pytest.mark.asyncio
async def test_worker_diagnostics_reports_backlog_without_secrets(client):
    admin = await _user(admin=True)
    response = await client.get(
        "/admin/communications/diagnostics/worker", headers=_auth(admin),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert "worker" in body and "backlog" in body
    assert "pending_recipients" in body["backlog"]
    assert "token" not in json.dumps(body).lower()
