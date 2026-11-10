"""Complaint triage for the admin dashboard.

What the admin queue needs and the customer routes never showed: who filed
it and what it is about, its first-reply deadline, the triage history, an
Alert Centre page for urgent ones (closed again with the complaint), and a
push to the person who filed it when the team answers.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, select

from api.core import push_devices
from api.database import AsyncSessionLocal, Deal, DealStatus, Listing, User, init_db, reset_engine
from api.models.admin_alert import AdminAlert
from api.models.feedback import UserFeedback
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / f"test_feedback_triage_{uuid.uuid4().hex}.db"
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


@pytest_asyncio.fixture(autouse=True)
async def clean():
    async with AsyncSessionLocal() as db:
        await db.execute(delete(UserFeedback))
        await db.execute(delete(AdminAlert))
        await db.commit()
    yield


@pytest.fixture(autouse=True)
def pushes(monkeypatch):
    """Every push the triage tries to send, instead of FCM."""
    sent: list[dict] = []

    async def fake_push_user(user_id, *, title, body, data, **kwargs):
        sent.append({"user_id": user_id, "title": title, "body": body, "data": data})
        return 1

    monkeypatch.setattr(push_devices, "push_user", fake_push_user)
    return sent


async def _user(*, admin=False, name=None) -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(name=name or f"User {tag}", phone=f"+2547{tag[:8]}", email=f"{tag}@triage.test",
                password_hash="x", is_admin=admin)
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


def _auth(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _file(client, user, **fields) -> dict:
    body = {"kind": "complaint", "category": "seller_conduct", "severity": "normal",
            "subject": "Seller problem", "body": "Details of what happened."}
    body.update(fields)
    r = await client.post("/feedback", headers=_auth(user), json=body)
    assert r.status_code == 201, r.text
    return r.json()


async def _alerts() -> list[AdminAlert]:
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(AdminAlert).where(AdminAlert.kind == "complaint_filed")
            .execution_options(populate_existing=True))).scalars().all()


@pytest.mark.asyncio
async def test_an_urgent_complaint_pages_the_alert_centre_without_its_text(client):
    user = await _user()
    filed = await _file(client, user, severity="urgent", category="payments",
                        subject="Charged twice SECRET-SUBJECT", body="SECRET-BODY")
    await _file(client, user, severity="normal", subject="Minor thing")
    await _file(client, user, kind="feedback", severity="urgent", category="suggestion",
                subject="Idea")
    [alert] = await _alerts()
    assert alert.severity == "critical"
    assert alert.meta == {"feedback_id": filed["id"]}
    assert alert.href == f"/complaints?id={filed['id']}"
    assert "SECRET" not in (alert.title + (alert.body or ""))


@pytest.mark.asyncio
async def test_a_safety_complaint_pages_even_at_normal_severity(client):
    user = await _user()
    await _file(client, user, category="safety", severity="normal")
    [alert] = await _alerts()
    assert alert.severity == "critical"


@pytest.mark.asyncio
async def test_the_queue_shows_who_filed_it_and_sorts_by_priority(client):
    admin, reporter = await _user(admin=True), await _user(name="Wanjiru Reporter")
    low = await _file(client, reporter, severity="low", subject="Low one")
    urgent = await _file(client, reporter, severity="urgent", subject="Urgent one")
    r = await client.get("/admin/feedback?sort=priority", headers=_auth(admin))
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    assert [i["id"] for i in items] == [urgent["id"], low["id"]]
    assert items[0]["user_id"] == reporter.id
    assert items[0]["reporter"]["name"] == "Wanjiru Reporter"
    assert items[0]["sla_hours"] == 4 and items[0]["sla_breached"] is False

    found = await client.get("/admin/feedback?search=urgent", headers=_auth(admin))
    assert [i["id"] for i in found.json()["items"]] == [urgent["id"]]
    assert (await client.get("/admin/feedback?queue=nope", headers=_auth(admin))).status_code == 422


@pytest.mark.asyncio
async def test_overdue_queue_and_stats_count_missed_deadlines(client):
    admin, reporter, target = await _user(admin=True), await _user(), await _user(name="Repeat Trader")
    old = await _file(client, reporter, severity="urgent", related_user_id=target.id)
    await _file(client, reporter, severity="normal", related_user_id=target.id)
    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(UserFeedback).where(UserFeedback.id == old["id"]))).scalar_one()
        row.created_at = datetime.utcnow() - timedelta(hours=10)  # past the 4h urgent deadline
        await db.commit()
    overdue = await client.get("/admin/feedback?queue=overdue", headers=_auth(admin))
    assert [i["id"] for i in overdue.json()["items"]] == [old["id"]]
    assert overdue.json()["items"][0]["sla_breached"] is True

    stats = (await client.get("/admin/feedback/stats", headers=_auth(admin))).json()
    assert stats["sla_breached"] == 1 and stats["sla_breached_urgent"] == 1
    assert stats["unanswered"] == 2
    assert stats["open_by_severity"] == {"urgent": 1, "normal": 1}
    assert stats["repeat_reported_users"] == [
        {"user_id": target.id, "name": "Repeat Trader", "complaints_90d": 2}]
    assert stats["by_kind"]["complaint"] == 2  # the original keys are still there


@pytest.mark.asyncio
async def test_detail_brings_the_listing_user_deal_and_history(client):
    admin, reporter, seller = await _user(admin=True), await _user(), await _user(name="Kip Seller")
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller.id, name="Used phone", category="Electronics",
                          price=5000.0, lat=-1.29, lng=36.82)
        db.add(listing)
        await db.flush()
        deal = Deal(listing_id=listing.id, seller_id=seller.id, buyer_id=reporter.id,
                    agreed_price=5000.0, commission=0.0, status=DealStatus.agreed)
        db.add(deal)
        await db.commit()
        listing_id, deal_id = listing.id, deal.id
    filed = await _file(client, reporter, related_listing_id=listing_id,
                        related_deal_id=deal_id, related_user_id=seller.id)
    await client.patch(f"/admin/feedback/{filed['id']}", headers=_auth(admin),
                       json={"status": "in_progress"})

    r = await client.get(f"/admin/feedback/{filed['id']}", headers=_auth(admin))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["related_listing"]["name"] == "Used phone"
    assert body["related_deal"]["status"] == "agreed"
    assert body["related_user"]["name"] == "Kip Seller"
    assert body["related_user"]["complaints_against_open"] == 1
    assert body["reporter_history"] == {"submissions": 1, "complaints": 1}
    assert [(t["action"], t["status"]) for t in body["timeline"]] == [
        ("user_feedback_triaged", "in_progress")]
    assert body["timeline"][0]["actor_id"] == admin.id

    assert (await client.get("/admin/feedback/missing", headers=_auth(admin))).status_code == 404
    assert (await client.get(f"/admin/feedback/{filed['id']}", headers=_auth(reporter))).status_code == 403


@pytest.mark.asyncio
async def test_a_reply_reaches_the_person_who_filed_it(client, pushes):
    admin, reporter = await _user(admin=True), await _user()
    filed = await _file(client, reporter)
    r = await client.patch(f"/admin/feedback/{filed['id']}", headers=_auth(admin),
                           json={"admin_response": "We have spoken to the seller."})
    assert r.status_code == 200, r.text
    assert r.json()["notified_devices"] == 1
    [push] = pushes
    assert push["user_id"] == reporter.id
    assert push["title"] == "BROKA replied to your complaint"
    assert push["body"] == "We have spoken to the seller."
    assert push["data"] == {"type": "feedback_update", "feedbackId": filed["id"], "status": "acknowledged"}

    # A status that tells the user nothing new sends nothing.
    pushes.clear()
    quiet = await client.patch(f"/admin/feedback/{filed['id']}", headers=_auth(admin),
                               json={"status": "acknowledged"})
    assert quiet.json()["notified_devices"] is None and pushes == []


@pytest.mark.asyncio
async def test_an_explicit_status_is_kept_when_replying(client):
    admin, reporter = await _user(admin=True), await _user()
    filed = await _file(client, reporter)
    r = await client.patch(f"/admin/feedback/{filed['id']}", headers=_auth(admin),
                           json={"status": "open", "admin_response": "Still looking."})
    # It used to come back "acknowledged": the auto-acknowledge for a reply
    # overrode the status the administrator had just chosen.
    assert r.json()["status"] == "open"


@pytest.mark.asyncio
async def test_resolving_a_complaint_closes_its_alert_and_tells_the_user(client, pushes):
    admin, reporter = await _user(admin=True), await _user()
    filed = await _file(client, reporter, severity="urgent")
    [alert] = await _alerts()
    assert alert.status == "open"
    r = await client.patch(f"/admin/feedback/{filed['id']}", headers=_auth(admin),
                           json={"status": "resolved"})
    assert r.status_code == 200
    [alert] = await _alerts()
    assert alert.status == "resolved"
    assert pushes[-1]["title"] == "Your complaint has been resolved"


@pytest.mark.asyncio
async def test_search_finds_the_reference_the_app_shows_and_treats_wildcards_literally(client):
    admin, reporter = await _user(admin=True), await _user()
    target = await _file(client, reporter, subject="Phone never arrived")
    percent = await _file(client, reporter, subject="Refund of 100% promised")
    # The app shows the reporter "#" + the first six hex digits, upper case.
    reference = "#" + target["id"].replace("-", "")[:6].upper()

    r = await client.get("/admin/feedback", params={"search": reference}, headers=_auth(admin))
    assert r.status_code == 200, r.text
    assert [i["id"] for i in r.json()["items"]] == [target["id"]]
    r = await client.get("/admin/feedback", params={"search": reference[1:].lower()}, headers=_auth(admin))
    assert [i["id"] for i in r.json()["items"]] == [target["id"]]

    # "%" is a character to find, not "match everything".
    r = await client.get("/admin/feedback", params={"search": "%"}, headers=_auth(admin))
    assert [i["id"] for i in r.json()["items"]] == [percent["id"]]
