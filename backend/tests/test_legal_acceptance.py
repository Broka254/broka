"""Registration is refused unless the caller makes the three declarations.

The app's own checkbox gate is not the enforcement point: these tests post
straight to `/auth/register`, because a request that skips the UI must fail
the same way. Evidence is checked in the database afterwards - the point of
the feature is the row, not the 201.
"""
from __future__ import annotations

import itertools
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.legal_documents import (
    AGE_ACCEPTANCE_TYPE, AGE_DECLARATION_VERSION, AGE_DOCUMENT_ID, PRIVACY, TERMS,
)
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.models.legal import LegalAcceptance
from api.security import hash_password_async
from main import app
from tests.legal_payload import SIGNUP_LEGAL, legal_payload

_n = itertools.count(1)


def _phone() -> str:
    return f"+254733{next(_n):06d}"


def _body(phone: str | None = None, **legal) -> dict:
    return {
        "phone": phone or _phone(),
        "name": "Legal Test",
        "password": "SecurePass123!",
        "lat": -1.286389,
        "lng": 36.817223,
        "legal_acceptance": legal_payload(**legal),
    }


async def _rows(phone: str) -> list[LegalAcceptance]:
    async with AsyncSessionLocal() as db:
        user = (await db.execute(select(User).where(User.phone == phone))).scalar_one_or_none()
        if user is None:
            return []
        return list((await db.execute(
            select(LegalAcceptance).where(LegalAcceptance.user_id == user.id)
        )).scalars().all())


async def _users(phone: str) -> int:
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(func.count(User.id)).where(User.phone == phone)
        )).scalar_one()


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_legal.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    mp.setenv("ENV", "test")
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test",
    ) as ac:
        yield ac


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


class TestValidRegistration:
    @pytest.mark.asyncio
    async def test_the_three_declarations_are_recorded_with_server_time(self, client):
        phone = _phone()
        before = datetime.utcnow() - timedelta(seconds=1)
        resp = await client.post("/auth/register", json=_body(phone))
        after = datetime.utcnow() + timedelta(seconds=1)
        assert resp.status_code == 201, resp.text

        rows = await _rows(phone)
        assert len(rows) == 3
        by_type = {row.acceptance_type: row for row in rows}
        assert set(by_type) == {
            AGE_ACCEPTANCE_TYPE, TERMS.acceptance_type, PRIVACY.acceptance_type,
        }

        terms = by_type[TERMS.acceptance_type]
        assert (terms.document_id, terms.document_version, terms.document_digest) == (
            TERMS.document_id, TERMS.version, TERMS.digest,
        )
        privacy = by_type[PRIVACY.acceptance_type]
        assert (privacy.document_id, privacy.document_version) == (
            PRIVACY.document_id, PRIVACY.version,
        )
        # The eligibility declaration is its own record, not a document
        # acceptance and not proof of age.
        age = by_type[AGE_ACCEPTANCE_TYPE]
        assert (age.document_id, age.document_version) == (
            AGE_DOCUMENT_ID, AGE_DECLARATION_VERSION,
        )
        assert age.document_digest is None

        # One server-generated instant for all three, inside the request
        # window, and naive UTC like every other DateTime column.
        stamps = {row.accepted_at for row in rows}
        assert len(stamps) == 1
        stamp = stamps.pop()
        assert stamp.tzinfo is None
        assert before <= stamp <= after

    @pytest.mark.asyncio
    async def test_a_client_timestamp_outside_the_legal_block_is_ignored(self, client):
        phone = _phone()
        body = _body(phone)
        body["accepted_at"] = "2000-01-01T00:00:00Z"
        resp = await client.post("/auth/register", json=body)
        assert resp.status_code == 201, resp.text
        rows = await _rows(phone)
        assert all(row.accepted_at.year >= datetime.utcnow().year for row in rows)

    @pytest.mark.asyncio
    async def test_login_and_recovery_still_work_after_acceptance(self, client):
        phone = _phone()
        assert (await client.post("/auth/register", json=_body(phone))).status_code == 201
        login = await client.post(
            "/auth/login", json={"phone": phone, "password": "SecurePass123!"},
        )
        assert login.status_code == 200, login.text
        forgot = await client.post("/auth/password/forgot", json={"phone": phone})
        assert forgot.status_code == 200, forgot.text
        assert forgot.json().get("debug_code")


class TestRefusedRegistrations:
    @pytest.mark.asyncio
    async def test_missing_legal_block_is_rejected(self, client):
        phone = _phone()
        body = _body(phone)
        del body["legal_acceptance"]
        resp = await client.post("/auth/register", json=body)
        assert resp.status_code == 422
        assert await _users(phone) == 0

    @pytest.mark.asyncio
    @pytest.mark.parametrize("field", list(SIGNUP_LEGAL))
    async def test_every_declaration_and_version_is_required(self, client, field):
        phone = _phone()
        body = _body(phone)
        del body["legal_acceptance"][field]
        resp = await client.post("/auth/register", json=body)
        assert resp.status_code == 422, (field, resp.text)
        assert await _users(phone) == 0

    @pytest.mark.asyncio
    @pytest.mark.parametrize("field, message", [
        ("age_confirmed", "18"),
        ("terms_accepted", "Terms of Use and Service"),
        ("privacy_acknowledged", "Privacy Policy"),
    ])
    async def test_a_false_declaration_is_a_refusal_not_a_default(self, client, field, message):
        phone = _phone()
        resp = await client.post("/auth/register", json=_body(phone, **{field: False}))
        assert resp.status_code == 422
        assert message in resp.json()["detail"]
        assert await _users(phone) == 0

    @pytest.mark.asyncio
    @pytest.mark.parametrize("field", ["age_confirmed", "terms_accepted", "privacy_acknowledged"])
    async def test_non_boolean_confirmations_are_rejected(self, client, field):
        """`1` and `"true"` are not a person ticking a box."""
        phone = _phone()
        for malformed in (1, "true"):
            resp = await client.post(
                "/auth/register", json=_body(phone, **{field: malformed}),
            )
            assert resp.status_code == 422, (field, malformed, resp.text)
        assert await _users(phone) == 0

    @pytest.mark.asyncio
    @pytest.mark.parametrize("field, stale", [
        ("terms_version", "2020-01-01"),
        ("terms_version", "1.0"),
        ("privacy_version", "1.0"),
        ("privacy_version", ""),
    ])
    async def test_outdated_or_unknown_versions_are_rejected(self, client, field, stale):
        phone = _phone()
        resp = await client.post("/auth/register", json=_body(phone, **{field: stale}))
        assert resp.status_code == 422, resp.text
        assert "updated" in resp.json()["detail"]
        assert await _users(phone) == 0

    @pytest.mark.asyncio
    async def test_a_timestamp_inside_the_legal_block_is_malformed(self, client):
        """`extra="forbid"`: the client does not get to say when."""
        phone = _phone()
        resp = await client.post(
            "/auth/register",
            json=_body(phone, accepted_at="2000-01-01T00:00:00Z"),
        )
        assert resp.status_code == 422
        assert await _users(phone) == 0


class TestAcceptanceEvidence:
    @pytest.mark.asyncio
    async def test_duplicate_registration_creates_one_account_and_three_rows(self, client):
        phone = _phone()
        body = _body(phone)
        assert (await client.post("/auth/register", json=body)).status_code == 201
        second = await client.post("/auth/register", json=body)
        assert second.status_code in (400, 409), second.text
        assert await _users(phone) == 1
        assert len(await _rows(phone)) == 3

    @pytest.mark.asyncio
    async def test_a_failed_acceptance_write_rolls_back_the_account(self, client, monkeypatch):
        phone = _phone()
        real_commit = AsyncSession.commit

        async def refuse(self):
            raise RuntimeError("simulated acceptance write failure")

        monkeypatch.setattr(AsyncSession, "commit", refuse)
        # The app's handler turns the failure into a 500; without this the
        # transport re-raises it instead of returning the response.
        async with AsyncClient(
            transport=ASGITransport(app=app, raise_app_exceptions=False),
            base_url="http://test",
        ) as failing:
            resp = await failing.post("/auth/register", json=_body(phone))
        monkeypatch.setattr(AsyncSession, "commit", real_commit)

        assert resp.status_code == 500
        # The user insert was flushed before the acceptance rows were staged,
        # so this is the assertion that proves the flush was rolled back too.
        assert await _users(phone) == 0
        assert await _rows(phone) == []

    @pytest.mark.asyncio
    async def test_an_existing_user_gets_no_fabricated_history(self, client):
        """Accounts that predate this feature have no row, and that is not
        backfilled during a migration or a startup."""
        phone = _phone()
        async with AsyncSessionLocal() as db:
            db.add(User(
                name="Existing Trader", phone=phone,
                password_hash=await hash_password_async("SecurePass123!"),
            ))
            await db.commit()

        assert await _rows(phone) == []
        assert (await client.post(
            "/auth/login", json={"phone": phone, "password": "SecurePass123!"},
        )).status_code == 200
