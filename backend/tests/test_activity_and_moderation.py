"""Phase One: session tracking, activity metrics and enforced suspension.

These tests treat the numbers as claims to verify, not as decoration:

* a session's duration is the time the app was actually present, so a gap
  between beats must not become usage;
* a stale session is closed where it was last seen;
* an empty platform reports zero (and duration as unavailable), never a
  fabricated figure;
* a suspension blocks the login form, a live access token and a refresh
  token, and leaves an audit trail.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.core import activity, moderation
from api.database import (
    AccountType,
    AsyncSessionLocal,
    AuditLog,
    User,
    init_db,
    reset_engine,
)
from api.models.activity import UserModerationAction, UserSession
from api.security import create_access_token, hash_password
from main import app

PASSWORD = "Passw0rd!test"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / f"test_activity_{uuid.uuid4().hex}.db"
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


def _h(user_id: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user_id})}"}


async def _user(*, admin: bool = False, name: str | None = None) -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(
        name=name or f"User {tag}",
        phone=f"+2547{tag[:8]}",
        email=f"{tag}@activity.test",
        password_hash=hash_password(PASSWORD),
        is_admin=admin,
        account_type=AccountType.buyer,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


async def test_an_empty_platform_reports_zero_and_no_invented_duration(client):
    """Run before any session exists: every count is a real 0, and a duration
    that cannot be measured is reported as unavailable, not as 0 seconds."""
    async with AsyncSessionLocal() as db:
        overview = await activity.overview(db)

    assert overview["presence"]["active_users"] == 0
    assert overview["presence"]["active_sessions"] == 0
    assert overview["engagement"]["dau"] == 0
    assert overview["engagement"]["avg_session_seconds"] is None
    assert overview["engagement"]["median_session_seconds"] is None
    assert any(
        item["metric"] == "session_duration" for item in overview["unavailable"]
    )
    # With no registered accounts there is no denominator, so the percentage
    # is unavailable rather than a made-up 0% or 100%.
    assert overview["population"]["eligible_users"] == 0
    assert overview["population"]["active_user_pct"] is None


async def test_a_heartbeat_opens_a_session_and_the_next_beat_advances_it(client):
    user = await _user()

    response = await client.patch(
        "/auth/heartbeat",
        json={"device_id": "device-a", "platform": "android"},
        headers=_h(user.id),
    )
    assert response.status_code == 200, response.text
    assert response.json()["session_id"]

    # Historical timestamps are exercised through the service, so the test
    # controls the clock instead of sleeping. A separate device keeps these
    # beats from being folded into the HTTP-created session above.
    base = datetime(2026, 1, 1, 9, 0, 0)
    async with AsyncSessionLocal() as db:
        first = await activity.touch_session(
            db, user.id, device_id="device-b", now=base
        )
        await db.commit()
        second = await activity.touch_session(
            db, user.id, device_id="device-b", now=base + timedelta(seconds=60)
        )
        await db.commit()

        assert first["session_id"] == second["session_id"]
        assert second["foreground_seconds"] == 60

        live = (
            await db.execute(
                UserSession.__table__.select().where(
                    UserSession.user_id == user.id,
                    UserSession.ended_at.is_(None),
                    UserSession.device_id == "device-b",
                )
            )
        ).all()

    assert len(live) == 1


async def test_a_long_gap_closes_the_session_where_it_was_last_seen(client):
    """A phone that was away for an hour must not be credited with the hour."""
    user = await _user()
    base = datetime(2026, 2, 1, 8, 0, 0)

    async with AsyncSessionLocal() as db:
        await activity.touch_session(db, user.id, device_id="d", now=base)
        await activity.touch_session(
            db, user.id, device_id="d", now=base + timedelta(seconds=60)
        )
        # An hour later: the gap is not usage, so this starts a new session.
        later = await activity.touch_session(
            db, user.id, device_id="d", now=base + timedelta(hours=1)
        )
        await db.commit()

        rows = (
            await db.execute(
                UserSession.__table__.select()
                .where(UserSession.user_id == user.id)
                .order_by(UserSession.started_at)
            )
        ).all()

    assert len(rows) == 2
    assert rows[0].ended_at == base + timedelta(seconds=60)
    assert rows[0].end_reason == "inactivity"
    assert rows[0].foreground_seconds == 60
    assert rows[1].started_at == base + timedelta(hours=1)
    assert later["foreground_seconds"] == 0
    assert later["session_id"] != rows[0].id


async def test_the_sweep_closes_a_stale_session_and_retention_purges_it():
    user = await _user()
    base = datetime(2026, 3, 1, 7, 0, 0)
    async with AsyncSessionLocal() as db:
        await activity.touch_session(db, user.id, device_id="sweep", now=base)
        await db.commit()

        closed = await activity.close_stale_sessions(db, now=base + timedelta(minutes=30))
        await db.commit()
        assert closed >= 1

        session = (
            await db.execute(
                UserSession.__table__.select().where(UserSession.user_id == user.id)
            )
        ).first()
        assert session.ended_at == base
        assert session.end_reason == "inactivity"

        still_open = (
            await db.execute(
                UserSession.__table__.select().where(
                    UserSession.user_id == user.id,
                    UserSession.ended_at.is_(None),
                )
            )
        ).all()
        assert still_open == []

        purged = await activity.purge_old_sessions(
            db, now=base + timedelta(days=activity.SESSION_RETENTION_DAYS + 1)
        )
        await db.commit()
    assert purged >= 1


async def test_the_analytics_timeseries_carries_the_active_users_series(client):
    """The dashboard asked for `active_users` and received nothing; a missing
    series is not the same answer as a flat zero."""
    admin = await _user(admin=True)
    response = await client.get(
        "/admin/analytics/timeseries",
        params={"from": "2026-01-01", "to": "2026-01-08", "bucket": "day"},
        headers=_h(admin.id),
    )
    assert response.status_code == 200, response.text
    series = response.json()["series"]
    assert "active_users" in series
    assert len(series["active_users"]) == len(series["signups"])
    for point in series["active_users"]:
        assert set(point) == {"t", "v"}
        assert isinstance(point["v"], int)


async def test_suspension_blocks_login_live_access_and_refresh(client):
    user = await _user(name="Suspend Me")
    admin = await _user(admin=True)

    # Signed in and working before the decision.
    before = await client.patch("/auth/heartbeat", headers=_h(user.id))
    assert before.status_code == 200, before.text

    login = await client.post(
        "/auth/login", json={"phone": user.phone, "password": PASSWORD}
    )
    assert login.status_code == 200, login.text
    refresh_token = login.json()["refresh_token"]

    suspended = await client.post(
        f"/admin/users/{user.id}/suspend",
        json={
            "mode": "temporary",
            "duration_hours": 24,
            "reason": "Confirmed fraudulent listing",
            "notes": "Evidence in audit row.",
        },
        headers=_h(admin.id),
    )
    assert suspended.status_code == 200, suspended.text
    state = suspended.json()["moderation"]
    assert state["status"] == moderation.SUSPENDED
    assert state["blocked"] is True
    assert state["permanent"] is False

    # 1. The live access token stops working on the very next request.
    live = await client.patch("/auth/heartbeat", headers=_h(user.id))
    assert live.status_code == 403
    assert live.json()["code"] == "ACCOUNT_SUSPENDED"

    # 2. The login form refuses a correct password.
    refused = await client.post(
        "/auth/login", json={"phone": user.phone, "password": PASSWORD}
    )
    assert refused.status_code == 403

    # 3. The refresh token cannot mint a new access token.
    refreshed = await client.post(
        "/auth/token/refresh", json={"refresh_token": refresh_token}
    )
    assert refreshed.status_code in (401, 403)

    # The sessions the account held open were closed, not left running.
    async with AsyncSessionLocal() as db:
        open_rows = (
            await db.execute(
                UserSession.__table__.select().where(
                    UserSession.user_id == user.id,
                    UserSession.ended_at.is_(None),
                )
            )
        ).all()
    assert open_rows == []


async def test_reinstatement_allows_a_new_sign_in_but_not_the_old_token(client):
    user = await _user(name="Reinstate Me")
    admin = await _user(admin=True)
    old_token_headers = _h(user.id)

    suspended = await client.post(
        f"/admin/users/{user.id}/suspend",
        json={"mode": "permanent", "reason": "Chargeback abuse"},
        headers=_h(admin.id),
    )
    assert suspended.status_code == 200
    assert suspended.json()["moderation"]["permanent"] is True

    reinstated = await client.post(
        f"/admin/users/{user.id}/reinstate",
        json={"reason": "Appeal upheld", "notes": "Bank confirmed the chargeback was reversed."},
        headers=_h(admin.id),
    )
    assert reinstated.status_code == 200
    assert reinstated.json()["moderation"]["status"] == moderation.ACTIVE

    # The token issued before the suspension stays revoked: reinstatement
    # restores the account, not the old credential.
    stale = await client.patch("/auth/heartbeat", headers=old_token_headers)
    assert stale.status_code == 401
    assert stale.json()["code"] == "SESSION_REVOKED"

    fresh = await client.patch("/auth/heartbeat", headers=_h(user.id))
    assert fresh.status_code == 200

    # Signing in again works.
    login = await client.post(
        "/auth/login", json={"phone": user.phone, "password": PASSWORD}
    )
    assert login.status_code == 200


async def test_a_temporary_suspension_lapses_on_its_own():
    user = await _user(name="Expiring")
    user.account_status = moderation.SUSPENDED
    user.suspended_until = datetime.utcnow() - timedelta(minutes=1)
    assert moderation.is_blocked(user) is False
    assert moderation.effective_status(user) == moderation.ACTIVE
    moderation.invalidate_verdict(user.id)


async def test_a_non_admin_cannot_suspend_and_self_suspension_is_refused(client):
    member = await _user()
    other = await _user()
    admin = await _user(admin=True)

    forbidden = await client.post(
        f"/admin/users/{other.id}/suspend",
        json={"mode": "temporary", "duration_hours": 24, "reason": "not allowed"},
        headers=_h(member.id),
    )
    assert forbidden.status_code == 403

    self_suspend = await client.post(
        f"/admin/users/{admin.id}/suspend",
        json={"mode": "temporary", "duration_hours": 24, "reason": "self"},
        headers=_h(admin.id),
    )
    assert self_suspend.status_code == 409


async def test_suspension_and_reinstatement_leave_an_auditable_trail(client):
    user = await _user(name="Audited")
    admin = await _user(admin=True)

    await client.post(
        f"/admin/users/{user.id}/suspend",
        json={
            "mode": "temporary",
            "duration_hours": 168,
            "reason": "Repeated scam reports",
            "notes": "Three buyers, same pattern.",
        },
        headers=_h(admin.id),
    )
    await client.post(
        f"/admin/users/{user.id}/reinstate",
        json={"reason": "Investigation closed without evidence"},
        headers=_h(admin.id),
    )

    profile = await client.get(f"/admin/users/{user.id}/activity", headers=_h(admin.id))
    assert profile.status_code == 200, profile.text
    body = profile.json()
    history = body["moderation_history"]
    actions = [row["action"] for row in history]
    assert "suspend" in actions and "reinstate" in actions
    assert all(row["actor_id"] == admin.id for row in history)
    assert history[0]["reason"] == "Investigation closed without evidence"

    async with AsyncSessionLocal() as db:
        audit_actions = (
            await db.execute(
                AuditLog.__table__.select().where(
                    AuditLog.resource_id == user.id,
                    AuditLog.action.in_(("user_suspended", "user_reinstated")),
                )
            )
        ).all()
        moderation_rows = (
            await db.execute(
                UserModerationAction.__table__.select().where(
                    UserModerationAction.user_id == user.id
                )
            )
        ).all()
    assert {row.action for row in audit_actions} == {"user_suspended", "user_reinstated"}
    assert len(moderation_rows) == 2


async def test_the_activity_table_reports_presence_and_moderation_together(client):
    user = await _user(name="Table Row")
    admin = await _user(admin=True)
    await client.patch("/auth/heartbeat", headers=_h(user.id))

    response = await client.get(
        "/admin/activity/users",
        params={"q": "Table Row", "limit": 10},
        headers=_h(admin.id),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["total"] >= 1
    row = next(entry for entry in body["users"] if entry["id"] == user.id)
    assert row["is_online"] is True
    assert row["open_sessions"] == 1
    assert row["moderation"]["status"] == moderation.ACTIVE
