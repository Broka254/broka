"""Announcement 30-day lifecycle, per-user delete, and feedback/complaints."""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, select

from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.models.feedback import UserFeedback
from api.models.service_communication import (
    ServiceCommunication, ServiceCommunicationRecipient,
)
from api.routers import calls
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / f"test_lifecycle_{uuid.uuid4().hex}.db"
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
async def clean():
    async with AsyncSessionLocal() as db:
        await db.execute(delete(ServiceCommunicationRecipient))
        await db.execute(delete(ServiceCommunication))
        await db.execute(delete(UserFeedback))
        await db.commit()


def _auth(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _user(*, admin: bool = False) -> User:
    tag = uuid.uuid4().hex[:12]
    user = User(
        name=f"User {tag}", phone=f"+2547{tag[:9]}",
        email=f"{tag}@lifecycle.test", password_hash="x", is_admin=admin,
        trust_score=100,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


async def _published(client: AsyncClient, admin: User, buyer: User, **overrides) -> dict:
    payload = {
        "title": "Maintenance tonight",
        "body": "Down from 2am to 3am EAT.",
        "communication_type": "maintenance",
        "severity": "high",
        "audience": {"kind": "user_ids", "user_ids": [buyer.id]},
        "channels": ["in_app"],
    }
    payload.update(overrides)
    created = await client.post("/admin/communications", headers=_auth(admin), json=payload)
    assert created.status_code == 201, created.text
    body = created.json()
    published = await client.post(
        f"/admin/communications/{body['id']}/publish", headers=_auth(admin))
    assert published.status_code == 202, published.text
    from api.domains.service_communications import service as svc

    class _Sender:
        async def __call__(self, **kwargs):
            return calls.FcmResult(True, message_id="m1")

    await svc.run_service_communications_pass(sender=_Sender())
    return body


# ── 30-day expiry ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_announcement_defaults_to_30_day_expiry(client):
    admin, buyer = await _user(admin=True), await _user()
    created = await _published(client, admin, buyer)
    feed = await client.get("/communications", headers=_auth(buyer))
    assert feed.status_code == 200
    item = feed.json()["items"][0]
    assert item["id"] == created["id"]
    assert item["published_at"] is not None and item["published_at"].endswith("Z")
    assert item["expires_at"] is not None
    published_at = datetime.fromisoformat(item["published_at"].replace("Z", ""))
    expires_at = datetime.fromisoformat(item["expires_at"].replace("Z", ""))
    assert timedelta(days=29) < (expires_at - published_at) <= timedelta(days=30)


@pytest.mark.asyncio
async def test_explicit_long_expiry_is_capped_at_30_days(client):
    admin, buyer = await _user(admin=True), await _user()
    far = (datetime.utcnow() + timedelta(days=90)).isoformat()
    created = await _published(client, admin, buyer, expires_at=far)
    detail = await client.get(f"/admin/communications/{created['id']}", headers=_auth(admin))
    expires_at = datetime.fromisoformat(
        detail.json()["communication"]["expires_at"].replace("Z", ""))
    assert expires_at <= datetime.utcnow() + timedelta(days=31)


@pytest.mark.asyncio
async def test_expired_announcement_leaves_the_feed(client):
    admin, buyer = await _user(admin=True), await _user()
    created = await _published(client, admin, buyer)
    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(ServiceCommunication).where(
            ServiceCommunication.id == created["id"]))).scalar_one()
        row.expires_at = datetime.utcnow() - timedelta(minutes=1)
        await db.commit()
    feed = await client.get("/communications", headers=_auth(buyer))
    assert feed.json()["total"] == 0


# ── Per-user delete ─────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_user_can_delete_announcement_for_themselves_only(client):
    admin, buyer, other = await _user(admin=True), await _user(), await _user()
    created = await _published(client, admin, buyer)
    # Another user cannot delete (or even see) it.
    stranger = await client.delete(f"/communications/{created['id']}", headers=_auth(other))
    assert stranger.status_code == 404
    deleted = await client.delete(f"/communications/{created['id']}", headers=_auth(buyer))
    assert deleted.status_code == 200, deleted.text
    assert deleted.json()["dismissed"] is True
    # Gone from feed and badge; delete is idempotent via the POST spelling.
    feed = await client.get("/communications", headers=_auth(buyer))
    assert feed.json()["total"] == 0
    count = await client.get("/communications/unread-count", headers=_auth(buyer))
    assert count.json()["unread_count"] == 0
    again = await client.post(f"/communications/{created['id']}/dismiss", headers=_auth(buyer))
    assert again.status_code == 200
    # The recipient row survives for admin delivery stats.
    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(select(ServiceCommunicationRecipient).where(
            ServiceCommunicationRecipient.communication_id == created["id"]))).scalar_one()
        assert recipient.dismissed_at is not None


@pytest.mark.asyncio
async def test_read_all_marks_only_own_visible_announcements(client):
    admin, buyer = await _user(admin=True), await _user()
    await _published(client, admin, buyer)
    result = await client.post("/communications/read-all", headers=_auth(buyer))
    assert result.status_code == 200, result.text
    assert result.json()["marked_read"] == 1
    count = await client.get("/communications/unread-count", headers=_auth(buyer))
    assert count.json()["unread_count"] == 0


# ── Feedback & complaints ───────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_user_files_feedback_and_complaint_and_reads_them_back(client):
    user = await _user()
    feedback = await client.post("/feedback", headers=_auth(user), json={
        "kind": "feedback", "category": "suggestion", "severity": "normal",
        "subject": "Dark mode schedule", "body": "Please dim at night.",
    })
    assert feedback.status_code == 201, feedback.text
    complaint = await client.post("/feedback", headers=_auth(user), json={
        "kind": "complaint", "category": "seller_conduct", "severity": "high",
        "subject": "Seller was abusive", "body": "Insults in chat.",
    })
    assert complaint.status_code == 201, complaint.text
    assert complaint.json()["status"] == "open"
    mine = await client.get("/feedback", headers=_auth(user))
    assert mine.json()["total"] == 2
    complaints = await client.get("/feedback?kind=complaint", headers=_auth(user))
    assert complaints.json()["total"] == 1
    one = await client.get(f"/feedback/{complaint.json()['id']}", headers=_auth(user))
    assert one.status_code == 200
    # Another user cannot read it.
    other = await _user()
    hidden = await client.get(f"/feedback/{complaint.json()['id']}", headers=_auth(other))
    assert hidden.status_code == 404


@pytest.mark.asyncio
async def test_feedback_validation_rejects_blank_and_bad_category(client):
    user = await _user()
    blank = await client.post("/feedback", headers=_auth(user), json={
        "kind": "feedback", "category": "general", "subject": "  ", "body": "x"})
    assert blank.status_code == 422
    bad = await client.post("/feedback", headers=_auth(user), json={
        "kind": "feedback", "category": "nonsense", "subject": "Hi", "body": "x"})
    assert bad.status_code == 422
    self_report = await client.post("/feedback", headers=_auth(user), json={
        "kind": "complaint", "category": "other", "subject": "Me",
        "body": "x", "related_user_id": user.id})
    assert self_report.status_code == 422


@pytest.mark.asyncio
async def test_admin_triages_feedback_and_user_sees_reply(client):
    admin, user = await _user(admin=True), await _user()
    filed = await client.post("/feedback", headers=_auth(user), json={
        "kind": "complaint", "category": "payments", "severity": "urgent",
        "subject": "Charged twice", "body": "Two debits for one listing fee."})
    fid = filed.json()["id"]
    # Non-admins cannot triage.
    denied = await client.patch(f"/admin/feedback/{fid}", headers=_auth(user),
                                json={"status": "resolved"})
    assert denied.status_code == 403
    triaged = await client.patch(f"/admin/feedback/{fid}", headers=_auth(admin), json={
        "admin_response": "Refund issued, sorry for the trouble."})
    assert triaged.status_code == 200, triaged.text
    assert triaged.json()["status"] == "acknowledged"
    assert triaged.json()["responded_at"] is not None
    resolved = await client.patch(f"/admin/feedback/{fid}", headers=_auth(admin),
                                  json={"status": "resolved"})
    assert resolved.json()["resolved_at"] is not None
    stats = await client.get("/admin/feedback/stats", headers=_auth(admin))
    assert stats.status_code == 200
    assert stats.json()["by_kind"]["complaint"] == 1
    seen = await client.get(f"/feedback/{fid}", headers=_auth(user))
    assert seen.json()["admin_response"].startswith("Refund issued")
    assert seen.json()["status"] == "resolved"
