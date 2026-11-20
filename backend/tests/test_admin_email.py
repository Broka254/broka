"""Admin Email Reply: POST /admin/email/send.

What these pin down:

* only an administrator holding the capability can send - a missing token,
  a customer and an admin without the flag are all refused before the
  provider is touched;
* the recipient, subject and message are validated, and a request can name no
  sender, Reply-To or HTML of its own;
* a good request reaches Resend once, from the fixed address, with replies
  directed to it, as HTML and plain text, and the answer carries Resend's id;
* every provider failure is reported in fixed words, audited and logged
  without the recipient, subject or message - even when the provider's own
  error body echoes them;
* none of it touches the verification-code path (its circuit breaker, its
  sender, its Reply-To).

Resend itself is replaced at the module's own seam (`_admin_http_client`), so
no test needs a network.
"""
from __future__ import annotations

import json
import logging
import uuid
from dataclasses import replace

import httpx
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

import api.core.email as email_mod
import api.core.permissions as permissions
from api.core.circuit_breaker import CircuitState
from api.core.config import settings
from api.core.idempotency import IdempotencyResult, idempotency_guard
from api.core.permissions import Permission
from api.core.rate_limit import RateLimiter
from api.database import AsyncSessionLocal, AuditLog, User, init_db, reset_engine
from api.domains.admin_email import router as admin_email_router
from api.security import create_access_token
from main import app

SEND = "/admin/email/send"

# Values that must never appear in a log line or an error response.
RECIPIENT = "wanjiru.reporter@example.com"
SUBJECT = "Re: your complaint SUBJECT-MARKER-7"
MESSAGE = "Hello <b>Wanjiru</b> & team,\n\nBODY-MARKER-9 \"quoted\"\nSecond line"
LEAK_MARKERS = (RECIPIENT, "wanjiru", "SUBJECT-MARKER-7", "BODY-MARKER-9", "re_test_key")


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / f"test_admin_email_{uuid.uuid4().hex}.db"
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


async def _user(*, admin: bool) -> User:
    tag = uuid.uuid4().hex[:12]
    user = User(
        name="Admin" if admin else f"Customer {tag}",
        phone=f"+2547{tag[:9]}",
        email=f"{tag}@admin-email.test",
        password_hash="x",
        is_admin=admin,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


def _auth(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


@pytest_asyncio.fixture
async def admin() -> User:
    return await _user(admin=True)


class FakeResend:
    """Stands in for the provider: records what was posted, answers as told."""

    def __init__(self):
        self.calls: list[dict] = []
        # (status, body), or an exception to raise. A new Response is built
        # for every request: one object must not be handed out twice.
        self.answer: tuple[int, dict] | BaseException = (200, {"id": "re_msg_0001"})

    def respond(self, status: int, body: dict | None = None) -> None:
        self.answer = (status, body if body is not None else {})

    def handler(self, request: httpx.Request) -> httpx.Response:
        if isinstance(self.answer, BaseException):
            raise self.answer
        self.calls.append({
            "url": str(request.url),
            "headers": dict(request.headers),
            "json": json.loads(request.content),
        })
        status, body = self.answer
        return httpx.Response(status, json=body)


@pytest.fixture
def resend(monkeypatch):
    """A configured provider (key set, default sender) that answers 200."""
    fake = FakeResend()
    monkeypatch.setattr(email_mod, "settings", replace(settings, resend_api_key="re_test_key"))
    monkeypatch.setattr(
        email_mod, "_admin_http_client",
        lambda: httpx.AsyncClient(transport=httpx.MockTransport(fake.handler)),
    )
    recorded: list[dict] = []

    async def record_usage(**kwargs):
        recorded.append(kwargs)

    monkeypatch.setattr("api.domains.service_costs.service.record_usage", record_usage)
    fake.usage = recorded
    return fake


def _body(**overrides) -> dict:
    body = {"to": RECIPIENT, "subject": SUBJECT, "message": MESSAGE}
    body.update(overrides)
    return body


async def _post(client, user, body=None, key: str | None = None):
    headers = _auth(user) if user is not None else {}
    if key:
        headers["X-Idempotency-Key"] = key
    return await client.post(SEND, headers=headers, json=body if body is not None else _body())


async def _audit_rows(admin: User) -> list[AuditLog]:
    async with AsyncSessionLocal() as db:
        rows = await db.execute(
            select(AuditLog)
            .where(AuditLog.actor_id == admin.id, AuditLog.resource_type == "admin_email")
            .order_by(AuditLog.created_at)
        )
        return list(rows.scalars().all())


def _assert_no_leak(text: str) -> None:
    for marker in LEAK_MARKERS:
        assert marker not in text, f"{marker!r} leaked into: {text[:300]!r}"


# ── Who may send ─────────────────────────────────────────────────────────────

class TestAuthorization:
    async def test_no_token_is_refused(self, client, resend):
        r = await _post(client, None)
        assert r.status_code == 401
        assert resend.calls == []

    async def test_a_garbage_token_is_refused(self, client, resend):
        r = await client.post(SEND, headers={"Authorization": "Bearer not-a-token"}, json=_body())
        assert r.status_code == 401
        assert resend.calls == []

    async def test_a_customer_is_refused(self, client, resend):
        customer = await _user(admin=False)
        r = await _post(client, customer)
        assert r.status_code == 403
        assert resend.calls == []

    async def test_an_admin_without_the_capability_is_refused(self, client, resend, admin, monkeypatch):
        """The route names its capability; it does not merely check is_admin."""
        monkeypatch.setattr(
            permissions, "_ADMIN_PERMISSIONS",
            permissions._ADMIN_PERMISSIONS - {Permission.SEND_ADMIN_EMAIL},
        )
        r = await _post(client, admin)
        assert r.status_code == 403
        assert Permission.SEND_ADMIN_EMAIL.value in r.json()["detail"]
        assert resend.calls == []

    async def test_an_unauthenticated_caller_gets_401_even_for_an_invalid_body(self, client, resend):
        # Authorization is checked before the body's rules, so a caller who
        # may not send learns nothing about them.
        r = await _post(client, None, {"to": "nope"})
        assert r.status_code == 401
        assert resend.calls == []

    def test_the_capability_belongs_to_administrators_only(self):
        assert Permission.SEND_ADMIN_EMAIL in permissions._ADMIN_PERMISSIONS
        assert Permission.SEND_ADMIN_EMAIL not in permissions._USER_PERMISSIONS


# ── What may be sent ─────────────────────────────────────────────────────────

class TestValidation:
    @pytest.mark.parametrize("field,value", [
        ("to", "not-an-email"),
        ("to", "a@b"),
        ("to", "a@b.com,c@d.com"),
        ("to", "Name <a@b.com>"),
        ("to", "a@b.com\r\nBcc: x@y.com"),
        ("to", ""),
        ("to", "x" * 300 + "@example.com"),
        ("subject", ""),
        ("subject", "   "),
        ("subject", "line one\nBcc: x@y.com"),
        ("subject", "x" * 201),
        ("message", ""),
        ("message", " \n\t "),
        ("message", "x" * 10_001),
        ("message", "bad \x00 byte"),
    ])
    async def test_a_bad_field_is_a_422_and_nothing_is_sent(self, client, resend, admin, field, value):
        r = await _post(client, admin, _body(**{field: value}))
        assert r.status_code == 422
        assert resend.calls == []
        assert await _audit_rows(admin) == []

    @pytest.mark.parametrize("field", ["to", "subject", "message"])
    async def test_a_missing_field_is_a_422(self, client, resend, admin, field):
        body = _body()
        del body[field]
        r = await _post(client, admin, body)
        assert r.status_code == 422
        assert resend.calls == []

    @pytest.mark.parametrize("extra", [
        {"from": "ceo@broka.co.ke"},
        {"sender": "ceo@broka.co.ke"},
        {"reply_to": "attacker@example.com"},
        {"html": "<script>alert(1)</script>"},
        {"cc": "x@y.com"},
        {"bcc": "x@y.com"},
        {"headers": {"X-Evil": "1"}},
    ])
    async def test_a_request_cannot_name_a_sender_or_extra_recipients(self, client, resend, admin, extra):
        r = await _post(client, admin, _body(**extra))
        assert r.status_code == 422
        assert resend.calls == []

    async def test_surrounding_whitespace_is_trimmed(self, client, resend, admin):
        r = await _post(client, admin, _body(to=f"  {RECIPIENT}\n", subject="  Hi  "))
        assert r.status_code == 200
        sent = resend.calls[0]["json"]
        assert sent["to"] == [RECIPIENT] and sent["subject"] == "Hi"

    async def test_a_validation_failure_does_not_spend_the_hourly_limit(self, client, resend, admin, monkeypatch):
        tight = RateLimiter("t", 1, 60)
        monkeypatch.setattr(admin_email_router, "admin_email_send_limiter", tight)
        for _ in range(3):
            assert (await _post(client, admin, _body(to="nope"))).status_code == 422
        assert (await _post(client, admin)).status_code == 200


# ── A good send ──────────────────────────────────────────────────────────────

class TestDelivery:
    async def test_it_reaches_resend_once_from_the_fixed_address(self, client, resend, admin):
        r = await _post(client, admin)
        assert r.status_code == 200, r.text
        assert r.json() == {
            "status": "sent",
            "message_id": "re_msg_0001",
            "sender": "Broka Admin <admin@broka.co.ke>",
            "reply_to": "admin@broka.co.ke",
        }
        assert len(resend.calls) == 1
        call = resend.calls[0]
        assert call["url"] == "https://api.resend.com/emails"
        assert call["headers"]["authorization"] == "Bearer re_test_key"

        sent = call["json"]
        assert sent["from"] == "Broka Admin <admin@broka.co.ke>"
        assert sent["reply_to"] == "admin@broka.co.ke"
        assert sent["to"] == [RECIPIENT]
        assert sent["subject"] == SUBJECT
        # Exactly these keys: no cc, bcc or custom headers.
        assert set(sent) == {"from", "to", "reply_to", "subject", "html", "text"}

    async def test_it_sends_both_html_and_plain_text_and_escapes_the_html(self, client, resend, admin):
        await _post(client, admin)
        sent = resend.calls[0]["json"]
        assert sent["text"].startswith("Hello <b>Wanjiru</b> & team,")
        assert "BODY-MARKER-9" in sent["text"]
        assert "<b>" not in sent["html"]
        assert "&lt;b&gt;Wanjiru&lt;/b&gt; &amp; team," in sent["html"]
        assert "BODY-MARKER-9" in sent["html"] and "<br>" in sent["html"]

    async def test_the_sender_is_not_the_verification_code_sender(self, client, resend, admin, monkeypatch):
        monkeypatch.setattr(email_mod, "settings", replace(
            email_mod.settings, resend_from="BROKA <noreply@broka.app>", resend_reply_to="otp@broka.app",
        ))
        await _post(client, admin)
        sent = resend.calls[0]["json"]
        assert sent["from"] == "Broka Admin <admin@broka.co.ke>"
        assert sent["reply_to"] == "admin@broka.co.ke"

    async def test_the_sender_comes_from_the_setting(self, client, resend, admin, monkeypatch):
        monkeypatch.setattr(email_mod, "settings", replace(
            email_mod.settings, broka_admin_email_from="BROKA Support <support@broka.co.ke>",
        ))
        r = await _post(client, admin)
        assert r.json()["sender"] == "BROKA Support <support@broka.co.ke>"
        assert resend.calls[0]["json"]["reply_to"] == "support@broka.co.ke"

    async def test_the_attempt_is_audited_without_its_contents(self, client, resend, admin):
        r = await _post(client, admin)
        assert r.status_code == 200
        (row,) = await _audit_rows(admin)
        assert row.action == "admin_email_sent"
        assert row.resource_id == "re_msg_0001"
        detail = json.loads(row.detail)
        assert detail["status"] == "sent" and detail["message_id"] == "re_msg_0001"
        assert detail["to_domain"] == "example.com"
        assert detail["subject_chars"] == len(SUBJECT) and detail["message_chars"] == len(MESSAGE)
        _assert_no_leak(row.detail)

    async def test_usage_is_counted_under_its_own_category(self, client, resend, admin):
        await _post(client, admin)
        (usage,) = resend.usage
        assert usage["service_key"] == "email.resend" and usage["status"] == "success"
        assert usage["metadata"] == {"category": "admin_email"}
        assert usage["provider_reference"] == "re_msg_0001"

    async def test_nothing_sensitive_is_logged(self, client, resend, admin, caplog):
        caplog.set_level(logging.DEBUG)
        r = await _post(client, admin)
        assert r.status_code == 200
        for record in caplog.records:
            _assert_no_leak(record.getMessage())

    async def test_the_idempotency_key_reaches_the_provider_scoped_and_hashed(self, client, resend, admin):
        await _post(client, admin, key="client-key-123456")
        header = resend.calls[0]["headers"]["idempotency-key"]
        assert header == email_mod.admin_email_provider_key(admin.id, "client-key-123456")
        assert "client-key" not in header
        other = await _user(admin=True)
        await _post(client, other, key="client-key-123456")
        assert resend.calls[1]["headers"]["idempotency-key"] != header

    async def test_no_key_means_no_provider_key(self, client, resend, admin):
        await _post(client, admin)
        assert "idempotency-key" not in resend.calls[0]["headers"]

    async def test_a_replayed_request_returns_the_first_answer_and_sends_nothing(self, client, resend, admin):
        first = {"status": "sent", "message_id": "re_first", "sender": "S", "reply_to": "R"}

        async def replay():
            return IdempotencyResult(key="k", cached=True, response=first)

        app.dependency_overrides[idempotency_guard] = replay
        try:
            r = await _post(client, admin, key="client-key-123456")
        finally:
            app.dependency_overrides.pop(idempotency_guard, None)
        assert r.status_code == 200 and r.json() == first
        assert resend.calls == []
        assert await _audit_rows(admin) == []


# ── Provider failures ────────────────────────────────────────────────────────

ECHO = {
    "name": "validation_error",
    "message": f"Invalid `to` {RECIPIENT}; subject {SUBJECT}; BODY-MARKER-9",
}


class TestProviderFailures:
    @pytest.mark.parametrize("provider_status,http_status,code", [
        (422, 422, "email_rejected"),
        (400, 422, "email_rejected"),
        (403, 502, "email_sender_refused"),
        (401, 502, "email_sender_refused"),
        (409, 409, "email_duplicate_request"),
        (429, 429, "email_provider_limit"),
        (500, 502, "email_provider_unavailable"),
        (503, 502, "email_provider_unavailable"),
        (404, 502, "email_provider_unavailable"),
    ])
    async def test_each_failure_has_its_own_status_and_code(
        self, client, resend, admin, provider_status, http_status, code,
    ):
        resend.respond(provider_status, ECHO)
        r = await _post(client, admin)
        assert r.status_code == http_status, r.text
        assert r.json()["code"] == code
        # Never 401/403: the dashboard's proxy treats a 401 as "signed out".
        assert r.status_code not in (401, 403)

    async def test_a_provider_error_body_is_never_repeated(self, client, resend, admin):
        resend.respond(422, ECHO)
        r = await _post(client, admin)
        _assert_no_leak(r.text)
        assert set(r.json()) == {"detail", "code"}

    async def test_a_failure_is_audited_without_its_contents(self, client, resend, admin):
        resend.respond(422, ECHO)
        await _post(client, admin)
        (row,) = await _audit_rows(admin)
        assert row.action == "admin_email_failed"
        detail = json.loads(row.detail)
        assert detail["status"] == "failed" and detail["failure"] == "rejected"
        assert detail["provider_status"] == 422 and "message_id" not in detail
        _assert_no_leak(row.detail)
        assert row.resource_id == detail["request_id"]

    async def test_a_failure_is_logged_without_its_contents(self, client, resend, admin, caplog):
        caplog.set_level(logging.DEBUG)
        resend.respond(500, ECHO)
        await _post(client, admin)
        assert caplog.records
        for record in caplog.records:
            _assert_no_leak(record.getMessage())

    async def test_a_failed_attempt_is_counted_unpriced(self, client, resend, admin):
        resend.respond(500, ECHO)
        await _post(client, admin)
        (usage,) = resend.usage
        assert usage["status"] == "failed" and usage["apply_pricing"] is False
        assert usage["metadata"] == {"category": "admin_email", "failure": "provider_unavailable"}

    @pytest.mark.parametrize("error", [
        httpx.ReadTimeout("slow"), httpx.ConnectError("down"), httpx.ConnectTimeout("slow"),
    ])
    async def test_no_answer_is_a_502_that_says_retrying_is_safe(self, client, resend, admin, error):
        resend.answer = error
        r = await _post(client, admin)
        assert r.status_code == 502 and r.json()["code"] == "email_provider_unavailable"
        assert "Retrying is safe" in r.json()["detail"]

    async def test_an_answer_without_a_message_id_is_a_failure(self, client, resend, admin):
        resend.respond(200, {})
        r = await _post(client, admin)
        assert r.status_code == 502
        (row,) = await _audit_rows(admin)
        assert row.action == "admin_email_failed"
        assert json.loads(row.detail)["failure"] == "no_message_id"

    async def test_an_unconfigured_server_refuses_without_calling_the_provider(self, client, resend, admin, monkeypatch):
        monkeypatch.setattr(email_mod, "settings", replace(email_mod.settings, resend_api_key=""))
        r = await _post(client, admin)
        assert r.status_code == 503 and r.json()["code"] == "email_not_configured"
        assert resend.calls == [] and resend.usage == []

    async def test_an_unusable_sender_setting_refuses_without_calling_the_provider(self, client, resend, admin, monkeypatch):
        monkeypatch.setattr(email_mod, "settings", replace(
            email_mod.settings, broka_admin_email_from="a@b.com, c@d.com",
        ))
        r = await _post(client, admin)
        assert r.status_code == 503 and r.json()["code"] == "email_not_configured"
        assert resend.calls == []

    async def test_a_failed_send_leaves_the_key_free_to_retry(self, client, resend, admin):
        resend.respond(500, ECHO)
        assert (await _post(client, admin, key="client-key-123456")).status_code == 502
        resend.respond(200, {"id": "re_second"})
        r = await _post(client, admin, key="client-key-123456")
        assert r.status_code == 200 and r.json()["message_id"] == "re_second"


# ── The hourly limit ─────────────────────────────────────────────────────────

class TestRateLimit:
    async def test_the_limit_is_per_administrator(self, client, resend, admin, monkeypatch):
        monkeypatch.setattr(admin_email_router, "admin_email_send_limiter", RateLimiter("t", 2, 60))
        assert (await _post(client, admin)).status_code == 200
        assert (await _post(client, admin)).status_code == 200
        r = await _post(client, admin)
        assert r.status_code == 429 and "Retry-After" in r.headers
        assert len(resend.calls) == 2
        # Another administrator has their own allowance.
        assert (await _post(client, await _user(admin=True))).status_code == 200

    async def test_production_allows_a_person_answering_mail_but_not_a_script(self):
        from api.core import rate_limit
        assert rate_limit.admin_email_send_limiter.window == 3600
        # Test mode widens the limit (as for every other limiter); the real
        # value is the 30-an-hour set where it is defined.
        assert rate_limit.admin_email_send_limiter.limit == (1000 if settings.is_test else 30)


# ── The verification-code path is untouched ──────────────────────────────────

class TestVerificationCodesAreUnaffected:
    async def test_a_run_of_failed_admin_sends_cannot_trip_the_code_breaker(self, client, resend, admin):
        # The breaker is process-wide: compare with what it held before, not
        # with zero, so another test's earlier use cannot fail this one.
        breaker = email_mod._resend_breaker
        before = (breaker.state, breaker.stats()["failure_count"])
        resend.respond(422, ECHO)
        for _ in range(8):
            assert (await _post(client, admin)).status_code == 422
        resend.answer = httpx.ReadTimeout("slow")
        for _ in range(8):
            assert (await _post(client, admin)).status_code == 502
        # More than the breaker's threshold of 5, yet nothing was counted.
        assert (breaker.state, breaker.stats()["failure_count"]) == before
        assert breaker.state != CircuitState.OPEN

    async def test_the_verification_mail_still_goes_out_from_its_own_sender(self, monkeypatch):
        posted: list[dict] = []

        def handler(request: httpx.Request) -> httpx.Response:
            posted.append(json.loads(request.content))
            return httpx.Response(200, json={"id": "re_otp_1"})

        real_client = httpx.AsyncClient

        def make(**kwargs):
            return real_client(transport=httpx.MockTransport(handler), **kwargs)

        monkeypatch.setattr(email_mod, "settings", replace(
            settings, resend_api_key="re_test_key", resend_from="BROKA <noreply@broka.app>",
            resend_reply_to="",
        ))
        monkeypatch.setattr(email_mod.httpx, "AsyncClient", make)

        async def record_usage(**kwargs):
            return None

        monkeypatch.setattr("api.domains.service_costs.service.record_usage", record_usage)
        subject, html, text = email_mod.build_otp_email("482913", 5)
        assert await email_mod.get_email_provider().send("someone@example.com", subject, html, text) is True
        (sent,) = posted
        assert sent["from"] == "BROKA <noreply@broka.app>"
        assert "reply_to" not in sent
        assert sent["to"] == ["someone@example.com"] and "482913" in sent["text"]


# ── The pure rules, without the app ──────────────────────────────────────────

class TestRules:
    @pytest.mark.parametrize("value", [
        "a@b.co", "first.last@example.com", "o'brien@example.co.ke",
        "user+tag@sub.example.org", "  padded@example.com  ",
    ])
    def test_ordinary_addresses_are_accepted(self, value):
        assert email_mod.normalize_admin_recipient(value)

    @pytest.mark.parametrize("value", [
        "", "no-at", "a@b", "a@b.c", "a b@c.com", "a@b.com,c@d.com", "Name <a@b.com>",
        "a@b.com\r\nBcc: x@y.com", ".a@b.com", "a..b@c.com", "a@-b.com", "a@localhost",
        "a%b@c.com", "a@[127.0.0.1]", "x" * 65 + "@example.com",
    ])
    def test_anything_that_is_not_one_plain_address_is_refused(self, value):
        with pytest.raises(ValueError):
            email_mod.normalize_admin_recipient(value)

    def test_the_domain_is_lowercased_and_the_local_part_kept(self):
        assert email_mod.normalize_admin_recipient("Ann.Lee@Example.COM") == "Ann.Lee@example.com"

    def test_the_default_sender_replies_to_itself(self):
        assert settings.broka_admin_email_from == "Broka Admin <admin@broka.co.ke>"
        assert email_mod.admin_email_sender() == (
            "Broka Admin <admin@broka.co.ke>", "admin@broka.co.ke",
        )

    @pytest.mark.parametrize("value", [
        "", "Name", "A <a@b.com>, <c@d.com>", "a@b.com, c@d.com", "Evil\r\nBcc: x@y.com <a@b.com>",
    ])
    def test_a_sender_that_is_not_one_address_is_unusable(self, value, monkeypatch):
        monkeypatch.setattr(email_mod, "settings", replace(settings, broka_admin_email_from=value))
        assert email_mod.admin_email_sender() is None

    def test_the_html_is_the_text_escaped_in_paragraphs(self):
        html, text = email_mod.build_admin_email("a <b> & c\n\n\nsecond\nline")
        assert text == "a <b> & c\n\n\nsecond\nline"
        assert html.count("<p ") == 2
        assert "a &lt;b&gt; &amp; c" in html and "second<br>line" in html
        assert "<b>" not in html
