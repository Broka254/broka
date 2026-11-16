"""The provider directory over HTTP: GET /escrow-providers..., the admin
endpoints under /admin/escrow-providers, and what they do to Zeno and to the
older GET /pricing/safe-payment.

The rules themselves (fee maths, freshness, link safety, ranking) are tested
as plain functions in test_escrow_fees.py and test_escrow_directory.py; this
file checks the wiring: who may call what, what a public response contains,
that an administrator's suspension reaches every reader, and that nothing
here can move money.

Setup follows test_feedback_admin_triage.py: a module-scoped SQLite file and
users inserted directly (an admin is a row with is_admin=True).
"""
import json
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import AsyncSessionLocal, AuditLog, User, init_db, reset_engine
from api.domains.escrow_directory import catalogue
from api.security import create_access_token
from sqlalchemy import select


@pytest.fixture(autouse=True)
def _fresh_catalogue():
    catalogue.reset()
    yield
    catalogue.reset()


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_escrow_directory_api.db"
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


async def _user(admin: bool = False) -> User:
    tag = uuid.uuid4().hex
    u = User(name="Admin" if admin else "Buyer", phone=f"+2547{tag[:8]}", email=f"{tag[:10]}@example.test",
             password_hash="x", is_admin=admin)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u


def _auth(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


# ── Public reads ─────────────────────────────────────────────────────────

class TestPublicCatalogue:
    @pytest.mark.asyncio
    async def test_it_needs_no_sign_in_and_lists_the_four_providers_with_their_official_sites(self, client):
        r = await client.get("/escrow-providers")
        assert r.status_code == 200
        body = r.json()
        got = {p["id"]: p["website_url"] for p in body["providers"]}
        assert got == {"econfirm": "https://econfirm.co.ke/", "kenyaescrow": "https://kenyaescrow.com/",
                       "lipasafe": "https://lipasafe.co.ke/", "shikilia": "https://www.shikilia.co.ke/"}
        assert r.headers["cache-control"] == "public, max-age=60"

    @pytest.mark.asyncio
    async def test_the_suspended_provider_is_not_listed_but_its_notice_is_given(self, client):
        body = (await client.get("/escrow-providers")).json()
        assert "escrowkenya" not in [p["id"] for p in body["providers"]]
        assert [n["id"] for n in body["notices"]] == ["escrowkenya"]
        assert "different website from Kenya Escrow" in body["notices"][0]["public_notice"]

    @pytest.mark.asyncio
    async def test_every_response_carries_the_required_notice_verbatim(self, client):
        from tests.test_escrow_directory import TestDisclosures
        for path in ("/escrow-providers", "/escrow-providers/compare?amount=5000", "/escrow-providers/kenyaescrow"):
            body = (await client.get(path)).json()
            assert body["disclosures"]["main"] == TestDisclosures.OWNER_TEXT, path

    @pytest.mark.asyncio
    async def test_every_provider_says_how_current_it_is_and_nothing_starts_out_verified(self, client):
        providers = (await client.get("/escrow-providers")).json()["providers"]
        # Without this an empty list would pass the loop below having checked nothing.
        assert [p["id"] for p in providers] == ["econfirm", "kenyaescrow", "lipasafe", "shikilia"]
        for p in providers:
            assert p["status"] == "under_review" and p["recommendable"] is False
            assert p["freshness"]["pricing"]["state"] == "unverified"
            assert "not yet verified" in p["freshness"]["pricing"]["label"].lower()
            assert p["review_label"].startswith("Under review")

    @pytest.mark.asyncio
    async def test_no_internal_note_or_reviewer_is_ever_served(self, client):
        for path in ("/escrow-providers", "/escrow-providers/econfirm", "/escrow-providers/compare?amount=5000",
                     "/escrow-providers/escrowkenya", "/pricing/safe-payment"):
            text = (await client.get(path)).text
            for secret in ("internal_notes", "reviewed_by", "Research input only", "Continuity check",
                           "SUSPENDED per", "transcription slip"):
                assert secret not in text, (path, secret)

    @pytest.mark.asyncio
    async def test_one_provider_in_full_and_a_missing_one_is_404(self, client):
        r = await client.get("/escrow-providers/kenyaescrow")
        assert r.status_code == 200 and r.json()["provider"]["canonical_domain"] == "kenyaescrow.com"
        assert (await client.get("/escrow-providers/nonesuch")).status_code == 404

    @pytest.mark.asyncio
    async def test_a_suspended_provider_returns_only_its_notice(self, client):
        r = await client.get("/escrow-providers/escrowkenya")
        assert r.status_code == 200 and "provider" not in r.json()
        assert r.json()["notice"]["status"] == "suspended"
        assert "escrowkenya.com" in r.json()["notice"]["public_notice"]


class TestCompareOverHttp:
    @pytest.mark.asyncio
    async def test_the_calculator_gives_the_published_figures_and_withholds_what_it_cannot_know(self, client):
        out = (await client.get("/escrow-providers/compare?amount=5000")).json()
        by = {p["id"]: p["estimate"] for p in out["results"]}
        assert (by["kenyaescrow"]["commission"], by["kenyaescrow"]["fixed_charges"],
                by["kenyaescrow"]["total_buyer_payment"]) == (270, 46, 5316)
        assert by["econfirm"]["commission"] == 50 and by["econfirm"]["total_buyer_payment"] is None
        assert by["lipasafe"]["status"] == "unavailable" and by["shikilia"]["status"] == "unavailable"
        assert out["ranking"]["claim_allowed"] is False

    @pytest.mark.asyncio
    async def test_bad_input_is_a_clean_422_not_a_500(self, client):
        for query in ("amount=0", "amount=-5", "amount=abc", "amount=99999999999", "amount=5000&payout=cash",
                      "sort=cheapest", "kyc=maybe", "category=weapons", "payment_method=cheque"):
            assert (await client.get(f"/escrow-providers/compare?{query}")).status_code == 422, query

    @pytest.mark.asyncio
    async def test_filters_exclude_with_a_reason(self, client):
        out = (await client.get("/escrow-providers/compare?no_account=true")).json()
        assert [r["id"] for r in out["results"]] == ["kenyaescrow"]
        assert {e["id"] for e in out["excluded"]} == {"econfirm", "lipasafe", "shikilia"}

    @pytest.mark.asyncio
    async def test_an_amount_outside_a_providers_limits_excludes_it(self, client):
        out = (await client.get("/escrow-providers/compare?amount=300000")).json()
        assert "kenyaescrow" not in [r["id"] for r in out["results"]]
        assert any(e["id"] == "kenyaescrow" and "240,000" in e["reason"] for e in out["excluded"])


# ── Gates and money ──────────────────────────────────────────────────────

class TestNothingHereMovesMoney:
    def test_in_app_payments_stay_off_by_default(self):
        import os
        from api.core.config import Settings
        saved = os.environ.pop("IN_APP_PAYMENTS_ENABLED", None)
        try:
            assert Settings().in_app_payments_enabled is False
        finally:
            if saved is not None:
                os.environ["IN_APP_PAYMENTS_ENABLED"] = saved

    @pytest.mark.asyncio
    async def test_the_old_endpoint_still_refuses_payments_and_the_new_ones_offer_none(self, client, payments_off):
        r = await client.get("/pricing/safe-payment")
        assert r.json()["in_app_payments"] is False
        # From the OpenAPI schema, not app.routes: scanning route objects does not see
        # router-included routes reliably in this FastAPI version (tests/test_route_ordering.py).
        paths = {path for path in app.openapi()["paths"] if "escrow-providers" in path}
        assert paths  # the directory is mounted
        for path in paths:
            for word in ("pay", "payout", "release", "refund", "withdraw", "fund", "hold", "transfer"):
                assert word not in path.replace("escrow-providers", "").lower(), path

    @pytest.mark.asyncio
    async def test_no_directory_route_accepts_a_money_amount_or_credential(self, client):
        """No public or admin directory route takes a PIN, OTP, password, card, account or M-Pesa
        value. Read from the OpenAPI schema, and required to find routes: an earlier version
        looped over app.routes, found none, and passed without checking anything."""
        bad = ("pin", "otp", "password", "card", "account_number", "mpesa", "iban")
        schema = app.openapi()
        paths = {path: ops for path, ops in schema["paths"].items() if "escrow-providers" in path}
        assert len(paths) >= 5, sorted(paths)

        def properties(spec: dict) -> set[str]:
            """Property names of a schema, following one level of $ref."""
            if "$ref" in spec:
                spec = schema["components"]["schemas"][spec["$ref"].rsplit("/", 1)[-1]]
            return {name.lower() for name in spec.get("properties", {})}

        checked = 0
        for path, ops in paths.items():
            for method, op in ops.items():
                if method not in ("get", "post", "put", "patch", "delete"):
                    continue  # a path-level key such as "parameters", not an operation
                names = {param["name"].lower() for param in op.get("parameters", [])}
                body = op.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema")
                if body:
                    names |= properties(body)
                checked += 1
                assert not any(b in n for n in names for b in bad), (method, path, sorted(names))
        assert checked >= 5, checked

    @pytest.mark.asyncio
    async def test_the_legacy_payload_serves_the_catalogue_not_a_baked_in_list(self, client):
        body = (await client.get("/pricing/safe-payment")).json()
        assert [p["id"] for p in body["providers"]] == ["econfirm", "kenyaescrow", "lipasafe", "shikilia"]
        assert all(p["verified"] is False for p in body["providers"])
        assert body["disclaimer"].startswith("Broka does not operate these escrow services")


# ── Admin ────────────────────────────────────────────────────────────────

class TestAdminAccess:
    @pytest.mark.asyncio
    async def test_a_signed_out_or_ordinary_user_cannot_read_or_change_anything(self, client):
        user = await _user()
        for method, path, body in (("get", "/admin/escrow-providers", None),
                                   ("get", "/admin/escrow-providers/kenyaescrow", None),
                                   ("patch", "/admin/escrow-providers/kenyaescrow", {"patch": {"tagline": "x"}, "reason": "because"}),
                                   ("post", "/admin/escrow-providers/kenyaescrow/status", {"status": "suspended", "reason": "because"}),
                                   ("post", "/admin/escrow-providers/kenyaescrow/review",
                                    {"area": "pricing", "outcome": "verified", "reason": "because"})):
            anon = await getattr(client, method)(path, **({"json": body} if body else {}))
            assert anon.status_code in (401, 403), (path, anon.status_code)
            ordinary = await getattr(client, method)(path, headers=_auth(user), **({"json": body} if body else {}))
            assert ordinary.status_code == 403, (path, ordinary.status_code)

    @pytest.mark.asyncio
    async def test_an_admin_sees_internal_notes_the_public_never_does(self, client):
        admin = await _user(admin=True)
        r = await client.get("/admin/escrow-providers/econfirm", headers=_auth(admin))
        assert r.status_code == 200
        assert "Research input only" in json.dumps(r.json()["record"]["trust"])
        assert r.json()["can_be_approved"] is False and r.json()["approval_blockers"]


class TestAdminWorkflow:
    @pytest.mark.asyncio
    async def test_a_fee_change_needs_its_source_and_is_audited_and_resets_the_review(self, client):
        admin = await _user(admin=True)
        h = _auth(admin)
        patch = {"pricing": {"additional_fees_may_apply": False}}
        no_source = await client.patch("/admin/escrow-providers/kenyaescrow", headers=h,
                                       json={"patch": patch, "reason": "confirmed no other fees"})
        assert no_source.status_code == 422 and "source_url" in json.dumps(no_source.json())
        wrong_site = await client.patch("/admin/escrow-providers/kenyaescrow", headers=h, json={
            "patch": patch, "reason": "confirmed no other fees", "source_url": "https://evil.example/p",
            "source_note": "It says there are no other fees."})
        assert wrong_site.status_code == 422
        ok = await client.patch("/admin/escrow-providers/kenyaescrow", headers=h, json={
            "patch": patch, "reason": "confirmed no other fees", "source_url": "https://kenyaescrow.com/pricing",
            "source_note": "Its pricing page says there are no other fees."})
        assert ok.status_code == 200, ok.text
        assert ok.json()["record"]["pricing"]["additional_fees_may_apply"] is False
        async with AsyncSessionLocal() as db:
            rows = (await db.execute(select(AuditLog).where(
                AuditLog.action == "escrow_provider_edited", AuditLog.resource_id == "kenyaescrow"))).scalars().all()
        assert rows and rows[-1].actor_id == admin.id

    @pytest.mark.asyncio
    async def test_an_edit_cannot_verify_itself(self, client):
        admin = await _user(admin=True)
        r = await client.patch("/admin/escrow-providers/lipasafe", headers=_auth(admin), json={
            "patch": {"status": "approved", "trust": {"pricing_review": "verified"}}, "reason": "trying to skip review"})
        assert r.status_code == 422
        text = json.dumps(r.json())
        assert "status" in text and "trust.pricing_review" in text

    @pytest.mark.asyncio
    async def test_a_refusal_reads_as_a_message_not_a_bare_list(self, client):
        admin = await _user(admin=True)
        r = await client.patch("/admin/escrow-providers/lipasafe", headers=_auth(admin), json={
            "patch": {"status": "approved"}, "reason": "trying to skip review"})
        detail = r.json()["detail"]
        assert detail["code"] == "ESCROW_PROVIDER_REFUSED" and "status: cannot be set by an edit" in detail["message"]

    @pytest.mark.asyncio
    async def test_a_lookalike_domain_cannot_be_set(self, client):
        admin = await _user(admin=True)
        r = await client.patch("/admin/escrow-providers/shikilia", headers=_auth(admin), json={
            "patch": {"identity": {"website_url": "https://shikilia-pay.com/"}}, "reason": "a mistaken change"})
        assert r.status_code == 422
        assert (await client.get("/escrow-providers/shikilia")).json()["provider"]["website_url"] == \
            "https://www.shikilia.co.ke/"

    @pytest.mark.asyncio
    async def test_a_provider_cannot_be_approved_without_every_check(self, client):
        admin = await _user(admin=True)
        r = await client.post("/admin/escrow-providers/econfirm/status", headers=_auth(admin),
                              json={"status": "approved", "reason": "launch day, looks fine to me"})
        assert r.status_code == 422 and "cannot be approved yet" in json.dumps(r.json())

    @pytest.mark.asyncio
    async def test_suspending_removes_it_from_every_list_at_once_and_is_audited(self, client):
        admin = await _user(admin=True)
        r = await client.post("/admin/escrow-providers/lipasafe/status", headers=_auth(admin), json={
            "status": "suspended", "reason": "complaints being investigated",
            "public_notice": "Lipasafe is not on Broka's list for now."})
        assert r.status_code == 200 and r.json()["record"]["status"] == "suspended"
        catalogue.reset()
        body = (await client.get("/escrow-providers")).json()
        assert "lipasafe" not in [p["id"] for p in body["providers"]]
        assert "lipasafe" in [n["id"] for n in body["notices"]]
        legacy = (await client.get("/pricing/safe-payment")).json()
        assert "lipasafe" not in [p["id"] for p in legacy["providers"]]
        compare = (await client.get("/escrow-providers/compare?amount=5000&sort=lowest_fee")).json()
        assert "lipasafe" not in [p["id"] for p in compare["results"]]
        assert "lipasafe" not in [p["id"] for p in compare["ranking"]["ranked"]]
        async with AsyncSessionLocal() as db:
            audited = (await db.execute(select(AuditLog).where(
                AuditLog.action == "escrow_provider_suspended", AuditLog.resource_id == "lipasafe"))).scalars().all()
        assert audited
        # ...and it cannot jump straight back to approved.
        back = await client.post("/admin/escrow-providers/lipasafe/status", headers=_auth(admin),
                                 json={"status": "approved", "reason": "reinstating it quickly"})
        assert back.status_code == 409

    @pytest.mark.asyncio
    async def test_a_stale_edit_loses_to_a_newer_one(self, client):
        admin = await _user(admin=True)
        h = _auth(admin)
        # Two admins load the same version, then both save: the second loses.
        loaded = (await client.get("/admin/escrow-providers/econfirm", headers=h)).json()["version"]
        mine = await client.patch("/admin/escrow-providers/econfirm", headers=h, json={
            "patch": {"tagline": "Mine"}, "reason": "my edit lands first", "expected_version": loaded})
        assert mine.status_code == 200
        assert mine.json()["version"] == loaded + 1
        theirs = await client.patch("/admin/escrow-providers/econfirm", headers=h, json={
            "patch": {"tagline": "Theirs"}, "reason": "their edit, from a stale page", "expected_version": loaded})
        assert theirs.status_code == 409 and "changed since you loaded it" in json.dumps(theirs.json())
        # Nothing of the losing edit was kept.
        assert (await client.get("/escrow-providers/econfirm")).json()["provider"]["tagline"] == "Mine"

    @pytest.mark.asyncio
    async def test_outdated_pricing_shows_the_warning_publicly(self, client, monkeypatch):
        """Pricing verified long ago is shown as outdated, not as current."""
        from api.domains.escrow_directory import router as dir_router
        from datetime import date
        admin = await _user(admin=True)
        h = _auth(admin)
        r = await client.post("/admin/escrow-providers/kenyaescrow/review", headers=h, json={
            "area": "pricing", "outcome": "verified", "reason": "checked against its pricing page",
            "verified_on": "2026-01-02", "source_url": "https://kenyaescrow.com/pricing",
            "source_note": "All eleven bands match the page."})
        assert r.status_code == 200, r.text
        monkeypatch.setattr(dir_router, "_today", lambda: date(2026, 11, 16))
        catalogue.reset()
        p = (await client.get("/escrow-providers/kenyaescrow")).json()["provider"]
        assert p["freshness"]["pricing"]["state"] == "expired"
        assert p["freshness"]["pricing"]["label"].startswith("Outdated")
        assert any("Fees may have changed" in w for w in p["freshness"]["warnings"])
        monkeypatch.setattr(dir_router, "_today", lambda: date(2026, 1, 20))
        assert (await client.get("/escrow-providers/kenyaescrow")).json()["provider"][
            "freshness"]["pricing"]["state"] == "current"

    @pytest.mark.asyncio
    async def test_a_new_provider_starts_as_a_draft_and_is_not_listed(self, client):
        from api.domains.escrow_directory import schema
        admin = await _user(admin=True)
        record = schema.blank_record("econfirm2", "eConfirm Two", "econfirm.co.ke")
        record["status"], record["trust"]["pricing_review"] = "approved", "verified"
        r = await client.post("/admin/escrow-providers", headers=_auth(admin),
                              json={"record": record, "reason": "adding a second econfirm record"})
        assert r.status_code == 201, r.text
        assert r.json()["record"]["status"] == "draft" and r.json()["record"]["trust"]["pricing_review"] == "not_started"
        catalogue.reset()
        assert "econfirm2" not in [p["id"] for p in (await client.get("/escrow-providers")).json()["providers"]]
        evil = schema.blank_record("evilco", "Evil", "evil.example")
        assert (await client.post("/admin/escrow-providers", headers=_auth(admin),
                                  json={"record": evil, "reason": "a phishing domain add"})).status_code == 422


class TestFeatureGates:
    @pytest.mark.asyncio
    async def test_zeno_does_not_open_the_comparison_screen_while_the_gate_is_off(self, payments_hidden):
        from api.domains.zeno_assistant import intents
        assert "escrow_services" not in intents.destinations()
        assert intents.clean_action({"type": "NAVIGATE", "destination": "escrow_services"}) == {"type": "NONE"}

    def test_zeno_can_open_it_when_the_gate_is_on(self):
        from api.domains.zeno_assistant import intents
        assert intents.clean_action({"type": "NAVIGATE", "destination": "escrow_services"}) == {
            "type": "NAVIGATE", "destination": "escrow_services"}

    @pytest.mark.asyncio
    async def test_the_scam_guidance_works_whatever_the_gate_says(self, client, payments_hidden, monkeypatch):
        """The gate controls pushing escrow at people, not warning them off a scam."""
        from api.domains.zeno_assistant import service
        assert service.is_free_turn("the seller asked for my OTP", []) is True
