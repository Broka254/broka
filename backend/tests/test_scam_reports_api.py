"""Scam reports, private evidence, protective restrictions and appeals, over
HTTP (domains/scam_reports). The rules are tested as plain functions in
test_scam_report_policy.py; this checks the wiring and - above all - that:

  * a report never changes anyone's standing: no restriction, no flag, no
    trust-score change comes from reports, however many;
  * evidence is private: only the reporter and an administrator can fetch it,
    everyone else gets a 404 that does not confirm it exists, and an
    administrator's view is written to the audit log;
  * a restriction is applied only by an administrator, ends on its own, tells
    the person what it is about, can be appealed, and when overturned lifts.

Setup follows test_feedback_admin_triage.py.
"""
import base64
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import func, select

from main import app
from api.database import AsyncSessionLocal, AuditLog, User, init_db, reset_engine
from api.models.admin_alert import AdminAlert
from api.models.scam_report import AccountRestriction
from api.security import create_access_token

PNG = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"\x00" * 64).decode()


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_scam_reports_api.db"
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


async def _user(admin=False, name="Person") -> User:
    tag = uuid.uuid4().hex
    u = User(name=name, phone=f"+2547{tag[:8]}", email=f"{tag[:10]}@example.test", password_hash="x", is_admin=admin)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u


def _auth(user) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


def _report(**over):
    body = {"reason_code": "deposit_to_reserve", "description": "He asked me to send 2,000 to reserve the phone.",
            "reported_account_ref": "0712 345 678", "provider_id": "kenyaescrow",
            "transaction_reference": "KE-1234", "amount_kes": 2000, "payment_sent": False}
    body.update(over)
    return body


async def _file(client, reporter, **over):
    r = await client.post("/scam-reports", headers=_auth(reporter), json=_report(**over))
    assert r.status_code == 201, r.text
    return r.json()


async def _standing(user_id):
    async with AsyncSessionLocal() as db:
        u = await db.get(User, user_id)
        restrictions = (await db.execute(select(func.count(AccountRestriction.id)).where(
            AccountRestriction.user_id == user_id))).scalar()
        return (u.trust_score, u.is_flagged, restrictions)


class TestFilingAReport:
    @pytest.mark.asyncio
    async def test_it_needs_sign_in(self, client):
        assert (await client.post("/scam-reports", json=_report())).status_code in (401, 403)

    @pytest.mark.asyncio
    async def test_a_report_is_a_complaint_the_existing_queue_can_see(self, client):
        reporter = await _user()
        out = await _file(client, reporter)
        assert out["duplicate"] is False
        assert "not a finding against anyone" in out["message"]
        assert "cannot promise to recover money" in out["message"]
        mine = (await client.get("/feedback", headers=_auth(reporter))).json()["items"]
        assert any(i["id"] == out["id"] and i["kind"] == "complaint" and i["category"] == "safety" for i in mine)
        assert any("police" in step for step in out["next_steps"])

    @pytest.mark.asyncio
    async def test_the_same_report_twice_in_a_day_is_one_report(self, client):
        reporter = await _user()
        first = await _file(client, reporter, reported_account_ref="fake-escrow.com")
        second = await _file(client, reporter, reported_account_ref="https://www.fake-escrow.com/pay")
        assert second["duplicate"] is True and second["id"] == first["id"]

    @pytest.mark.asyncio
    @pytest.mark.parametrize("over", [
        {"reason_code": "not_a_reason"}, {"description": "bad"},
        {"reported_account_ref": None}, {"amount_kes": -5},
    ])
    async def test_a_bad_report_is_refused_cleanly(self, client, over):
        r = await client.post("/scam-reports", headers=_auth(await _user()), json=_report(**over))
        assert r.status_code == 422

    @pytest.mark.asyncio
    async def test_a_refusal_is_a_message_a_person_can_read_not_a_bare_list(self, client):
        """The app shows `detail.message` (ApiClient reads a structured detail); a list
        of strings would be shown as "Request failed" and tell the person nothing."""
        r = await client.post("/scam-reports", headers=_auth(await _user()),
                              json=_report(description="bad", reported_account_ref=None))
        assert r.status_code == 422
        detail = r.json()["detail"]
        assert isinstance(detail, dict) and detail["code"] == "SCAM_REPORT_REFUSED"
        assert "description: say what happened" in detail["message"]
        assert "reported_account_ref: name the account" in detail["message"]
        assert isinstance(detail["problems"], list) and len(detail["problems"]) == 2

    @pytest.mark.asyncio
    async def test_you_cannot_report_yourself(self, client):
        me = await _user()
        r = await client.post("/scam-reports", headers=_auth(me),
                              json=_report(reported_user_id=me.id, reported_account_ref=None))
        assert r.status_code == 422 and "yourself" in r.text

    @pytest.mark.asyncio
    async def test_the_reporter_sees_only_their_own(self, client):
        a, b = await _user(), await _user()
        await _file(client, a, reported_account_ref="0700000001")
        assert len((await client.get("/scam-reports/mine", headers=_auth(a))).json()["items"]) >= 1
        assert (await client.get("/scam-reports/mine", headers=_auth(b))).json()["items"] == []


class TestAReportIsNotAVerdict:
    @pytest.mark.asyncio
    async def test_many_reports_change_nothing_about_the_person_reported_but_ask_a_human_to_look(self, client):
        accused = await _user(name="Accused")
        before = await _standing(accused.id)
        for _ in range(6):                                  # six DIFFERENT people
            reporter = await _user()
            await _file(client, reporter, reported_user_id=accused.id, reported_account_ref=None,
                        description="Took my deposit for a phone and stopped replying to me.")
        assert await _standing(accused.id) == before         # score, flag, restrictions: all untouched
        async with AsyncSessionLocal() as db:
            alerts = (await db.execute(select(AdminAlert).where(
                AdminAlert.kind == "scam_reports_repeated"))).scalars().all()
        assert any((a.meta or {}).get("user_id") == accused.id for a in alerts)
        # No text a reporter wrote is in the alert; it says it is not a finding.
        mine = [a for a in alerts if (a.meta or {}).get("user_id") == accused.id][0]
        assert "not a finding" in mine.body and "phone and stopped replying" not in (mine.body or "")

    @pytest.mark.asyncio
    async def test_one_person_reporting_many_times_does_not_trigger_the_alert(self, client):
        accused = await _user(name="Accused Two")
        angry = await _user()
        for i in range(5):
            await _file(client, angry, reported_user_id=accused.id, reported_account_ref=None,
                        reason_code=["bypass_escrow", "fake_escrow_link", "non_delivery",
                                     "fake_payment_proof", "other"][i],
                        description=f"Complaint number {i} about the same account, again.")
        async with AsyncSessionLocal() as db:
            alerts = (await db.execute(select(AdminAlert).where(AdminAlert.kind == "scam_reports_repeated"))).scalars().all()
        assert not any((a.meta or {}).get("user_id") == accused.id for a in alerts)


class TestEvidenceIsPrivate:
    async def _with_evidence(self, client):
        reporter = await _user()
        report = await _file(client, reporter)
        up = await client.post(f"/scam-reports/{report['id']}/evidence", headers=_auth(reporter),
                               json={"file_name": "../../chat.png", "content_base64": PNG})
        assert up.status_code == 201, up.text
        return reporter, report["id"], up.json()["id"]

    @pytest.mark.asyncio
    async def test_the_reporter_can_attach_and_fetch_their_own_image(self, client):
        reporter, rid, eid = await self._with_evidence(client)
        got = await client.get(f"/scam-reports/evidence/{rid}/{eid}", headers=_auth(reporter))
        assert got.status_code == 200 and got.headers["content-type"] == "image/png"
        assert got.headers["cache-control"] == "private, no-store"
        assert got.headers["x-content-type-options"] == "nosniff"
        assert got.headers["content-security-policy"] == "sandbox"
        assert got.headers["content-disposition"].startswith("attachment") and "/" not in got.headers["content-disposition"]

    @pytest.mark.asyncio
    async def test_anyone_else_gets_a_404_that_does_not_confirm_it_exists(self, client):
        reporter, rid, eid = await self._with_evidence(client)
        stranger = await _user()
        real = await client.get(f"/scam-reports/evidence/{rid}/{eid}", headers=_auth(stranger))
        fake = await client.get(f"/scam-reports/evidence/{uuid.uuid4()}/{uuid.uuid4()}", headers=_auth(stranger))
        assert real.status_code == fake.status_code == 404
        assert real.json() == fake.json()
        assert (await client.get(f"/scam-reports/evidence/{rid}/{eid}")).status_code in (401, 403)

    @pytest.mark.asyncio
    async def test_your_own_report_does_not_unlock_someone_elses_evidence(self, client):
        """The ownership check is on the REPORT in the path, so the evidence id
        has to be tied to that same report as well: a person's own report id
        paired with another person's evidence id must find nothing, on both
        routes. An id is hard to guess, not a secret - it travels in logs and
        screenshots - so the lookup, not the id, is what keeps it private."""
        victim, _, victims_evidence = await self._with_evidence(client)
        mine = await _user()
        my_report = await _file(client, mine, reported_account_ref="0700000009")
        mine_path = f"/scam-reports/evidence/{my_report['id']}/{victims_evidence}"
        assert (await client.get(mine_path, headers=_auth(mine))).status_code == 404
        # An administrator may open evidence, but only the evidence of the
        # report named in the path.
        admin = await _user(admin=True)
        admin_path = f"/admin/scam-reports/{my_report['id']}/evidence/{victims_evidence}"
        assert (await client.get(admin_path, headers=_auth(admin))).status_code == 404
        # Nothing was shown, so nothing is recorded as viewed.
        async with AsyncSessionLocal() as db:
            viewed = (await db.execute(select(AuditLog).where(
                AuditLog.action == "scam_evidence_viewed", AuditLog.resource_id == victims_evidence))).scalars().all()
        assert viewed == []

    @pytest.mark.asyncio
    async def test_nobody_but_the_reporter_can_attach_to_a_report(self, client):
        reporter, rid, _ = await self._with_evidence(client)
        other = await _user()
        r = await client.post(f"/scam-reports/{rid}/evidence", headers=_auth(other),
                              json={"content_base64": PNG})
        assert r.status_code == 404

    @pytest.mark.asyncio
    @pytest.mark.parametrize("payload,status", [
        (base64.b64encode(b"<html><script>alert(1)</script>").decode(), 415),
        (base64.b64encode(b"%PDF-1.7 stuff").decode(), 415),
        ("not base64 !!!", 422),
        # One byte over the 1,500,000-byte limit. Built from a byte count, not by cutting
        # encoded text: the first version sliced the base64 and landed exactly ON the limit,
        # which is (correctly) accepted, so it tested nothing.
        (base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"\x00" * (1_500_000 + 1 - 8)).decode(), 413),
    ])
    async def test_only_real_images_within_the_size_limit_are_stored(self, client, payload, status):
        reporter = await _user()
        report = await _file(client, reporter, reported_account_ref="0700000002")
        r = await client.post(f"/scam-reports/{report['id']}/evidence", headers=_auth(reporter),
                              json={"content_base64": payload})
        assert r.status_code == status, r.text

    @pytest.mark.asyncio
    async def test_a_file_exactly_at_the_size_limit_is_kept(self, client):
        """The limit is "more than 1,500,000 bytes is refused": a file of exactly that is kept."""
        reporter = await _user()
        report = await _file(client, reporter, reported_account_ref="0700000008")
        exactly = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"\x00" * (1_500_000 - 8)).decode()
        r = await client.post(f"/scam-reports/{report['id']}/evidence", headers=_auth(reporter),
                              json={"content_base64": exactly})
        assert r.status_code == 201 and r.json()["size_bytes"] == 1_500_000, r.text

    @pytest.mark.asyncio
    async def test_a_report_holds_at_most_three_files(self, client):
        reporter = await _user()
        report = await _file(client, reporter, reported_account_ref="0700000003")
        codes = [(await client.post(f"/scam-reports/{report['id']}/evidence", headers=_auth(reporter),
                                    json={"content_base64": PNG})).status_code for _ in range(4)]
        assert codes == [201, 201, 201, 409]

    @pytest.mark.asyncio
    async def test_an_ordinary_user_cannot_use_the_admin_evidence_route_and_an_admin_is_audited(self, client):
        reporter, rid, eid = await self._with_evidence(client)
        ordinary = await _user()
        assert (await client.get(f"/admin/scam-reports/{rid}/evidence/{eid}", headers=_auth(ordinary))).status_code == 403
        admin = await _user(admin=True)
        got = await client.get(f"/admin/scam-reports/{rid}/evidence/{eid}", headers=_auth(admin))
        assert got.status_code == 200 and got.headers["cache-control"] == "private, no-store"
        async with AsyncSessionLocal() as db:
            viewed = (await db.execute(select(AuditLog).where(
                AuditLog.action == "scam_evidence_viewed", AuditLog.resource_id == eid))).scalars().all()
        assert len(viewed) == 1 and viewed[0].actor_id == admin.id

    @pytest.mark.asyncio
    async def test_evidence_is_never_in_a_listing_the_public_can_reach(self, client):
        reporter, rid, eid = await self._with_evidence(client)
        for path in (f"/feedback/{rid}", "/scam-reports/mine"):
            assert PNG not in (await client.get(path, headers=_auth(reporter))).text


class TestAdminReview:
    @pytest.mark.asyncio
    async def test_the_admin_queue_needs_the_permission_and_shows_linked_reports(self, client):
        accused = await _user(name="Linked")
        reporters = [await _user() for _ in range(3)]
        ids = [(await _file(client, r, reported_user_id=accused.id, reported_account_ref=None,
                            description="Never delivered after I paid a deposit."))["id"] for r in reporters]
        assert (await client.get("/admin/scam-reports", headers=_auth(await _user()))).status_code == 403
        admin = await _user(admin=True)
        listed = (await client.get("/admin/scam-reports?limit=100", headers=_auth(admin))).json()["items"]
        mine = [i for i in listed if i["reported_user_id"] == accused.id]
        assert len(mine) == 3 and all(i["different_reporters_30d"] == 3 and i["needs_attention"] for i in mine)
        detail = (await client.get(f"/admin/scam-reports/{ids[0]}", headers=_auth(admin))).json()
        assert len(detail["other_reports"]) == 2 and detail["reported_user_id"] == accused.id


class TestRestrictionsAndAppeals:
    async def _restricted(self, client):
        admin, person = await _user(admin=True), await _user(name="Restricted")
        r = await client.post("/admin/scam-reports/restrictions", headers=_auth(admin), json={
            "user_id": person.id, "scopes": ["create_listing"], "days": 7,
            "internal_reason": "Four reports of the same fake escrow link in a week.",
            "public_reason": "Posting new listings is paused while we review reports."})
        assert r.status_code == 201, r.text
        return admin, person, r.json()["id"]

    @pytest.mark.asyncio
    async def test_only_an_administrator_can_restrict_and_it_has_a_hard_end(self, client):
        person = await _user()
        body = {"user_id": person.id, "scopes": ["create_listing"], "days": 7,
                "internal_reason": "Reports are being reviewed here.", "public_reason": "Paused while we review."}
        assert (await client.post("/admin/scam-reports/restrictions", headers=_auth(await _user()), json=body)).status_code == 403
        admin = await _user(admin=True)
        for bad in ({"days": 0}, {"days": 15}, {"days": 365}, {"scopes": ["delete_account"]}, {"scopes": []},
                    {"internal_reason": "x"}, {"public_reason": "x"}):
            assert (await client.post("/admin/scam-reports/restrictions", headers=_auth(admin),
                                      json={**body, **bad})).status_code == 422, bad
        assert (await client.post("/admin/scam-reports/restrictions", headers=_auth(admin),
                                  json={**body, "user_id": admin.id})).status_code == 422     # not yourself
        assert (await client.post("/admin/scam-reports/restrictions", headers=_auth(admin),
                                  json={**body, "user_id": str(uuid.uuid4())})).status_code == 404

    @pytest.mark.asyncio
    async def test_it_does_not_touch_the_trust_score_or_flag_and_is_audited(self, client):
        before_user = await _user(name="Untouched")
        before = await _standing(before_user.id)
        admin = await _user(admin=True)
        await client.post("/admin/scam-reports/restrictions", headers=_auth(admin), json={
            "user_id": before_user.id, "scopes": ["create_listing"], "days": 3,
            "internal_reason": "Investigating a repeated report.", "public_reason": "Paused while we review a report."})
        after = await _standing(before_user.id)
        assert after[:2] == before[:2] and after[2] == before[2] + 1
        async with AsyncSessionLocal() as db:
            applied = (await db.execute(select(AuditLog).where(
                AuditLog.action == "restriction_applied", AuditLog.resource_id == before_user.id))).scalars().all()
        assert applied and applied[-1].actor_id == admin.id

    @pytest.mark.asyncio
    async def test_the_person_is_told_what_why_and_until_when_but_never_the_teams_notes(self, client):
        admin, person, rid = await self._restricted(client)
        mine = (await client.get("/scam-reports/restrictions/mine", headers=_auth(person))).json()["items"]
        assert len(mine) == 1 and mine[0]["status"] == "active" and mine[0]["can_appeal"] is True
        assert mine[0]["reason"] == "Posting new listings is paused while we review reports."
        assert mine[0]["scopes"] == ["Post new listings"] and mine[0]["ends"]
        assert "not a finding that you did anything wrong" in mine[0]["notice"]
        assert "fake escrow link" not in str(mine)                   # the internal reason

    @pytest.mark.asyncio
    async def test_a_restricted_user_cannot_post_a_listing_and_is_told_why(self, client):
        """The restriction is checked first thing in ListingService.create_listing,
        before anything about the listing is read, so this exercises exactly that
        line without having to build a full valid listing body."""
        from fastapi import HTTPException
        from api.domains.listings.service import ListingService
        admin, person, rid = await self._restricted(client)
        async with AsyncSessionLocal() as db:
            with pytest.raises(HTTPException) as caught:
                await ListingService(db).create_listing(person.id, {"name": "Phone"})
        assert caught.value.status_code == 403
        detail = caught.value.detail
        assert detail["code"] == "ACCOUNT_RESTRICTED" and detail["restriction_id"] == rid
        assert "paused while we review" in detail["message"] and "appeal" in detail["message"]
        assert "not a finding that you did anything wrong" in detail["message"]

    @pytest.mark.asyncio
    async def test_an_unrestricted_user_is_not_stopped_by_it(self, client):
        from fastapi import HTTPException
        from api.domains.listings.service import ListingService
        person = await _user(name="Free")
        async with AsyncSessionLocal() as db:
            try:
                await ListingService(db).create_listing(person.id, {"name": "Phone"})
            except HTTPException as exc:      # refused for the listing's own reasons, never ACCOUNT_RESTRICTED
                assert not (isinstance(exc.detail, dict) and exc.detail.get("code") == "ACCOUNT_RESTRICTED")
            except Exception:
                pass                           # an incomplete body failing later is fine: it got past the check

    @pytest.mark.asyncio
    async def test_a_restriction_ends_by_itself(self, client):
        admin, person, rid = await self._restricted(client)
        async with AsyncSessionLocal() as db:
            row = await db.get(AccountRestriction, rid)
            row.expires_at = datetime.utcnow() - timedelta(minutes=1)
            await db.commit()
        mine = (await client.get("/scam-reports/restrictions/mine", headers=_auth(person))).json()["items"]
        assert mine[0]["status"] == "expired" and mine[0]["can_appeal"] is False
        from api.domains.scam_reports import service
        async with AsyncSessionLocal() as db:
            assert await service.is_restricted(db, person.id, "create_listing") is None

    @pytest.mark.asyncio
    async def test_an_appeal_can_be_filed_once_at_a_time_and_only_by_the_person(self, client):
        admin, person, rid = await self._restricted(client)
        other = await _user()
        assert (await client.post(f"/scam-reports/restrictions/{rid}/appeal", headers=_auth(other),
                                  json={"statement": "I am not the person restricted here."})).status_code == 404
        assert (await client.post(f"/scam-reports/restrictions/{rid}/appeal", headers=_auth(person),
                                  json={"statement": ""})).status_code == 422
        first = await client.post(f"/scam-reports/restrictions/{rid}/appeal", headers=_auth(person),
                                  json={"statement": "These reports are from a buyer I refused to refund."})
        assert first.status_code == 201, first.text
        again = await client.post(f"/scam-reports/restrictions/{rid}/appeal", headers=_auth(person),
                                  json={"statement": "Please look at this again, I sent photos."})
        assert again.status_code == 409 and "already have an appeal" in again.text

    @pytest.mark.asyncio
    async def test_an_overturned_appeal_lifts_the_restriction_and_the_person_is_told(self, client):
        admin, person, rid = await self._restricted(client)
        appeal = (await client.post(f"/scam-reports/restrictions/{rid}/appeal", headers=_auth(person),
                                    json={"statement": "These reports are from a buyer I refused to refund."})).json()
        queue = (await client.get("/admin/scam-reports/appeals", headers=_auth(admin))).json()["items"]
        assert any(a["id"] == appeal["id"] for a in queue)
        assert (await client.post(f"/admin/scam-reports/appeals/{appeal['id']}/decide", headers=_auth(await _user()),
                                  json={"outcome": "overturned", "note": "A long enough note."})).status_code == 403
        done = await client.post(f"/admin/scam-reports/appeals/{appeal['id']}/decide", headers=_auth(admin),
                                 json={"outcome": "overturned", "note": "The reports did not hold up; restriction removed."})
        assert done.status_code == 200 and done.json()["status"] == "overturned"
        mine = (await client.get("/scam-reports/restrictions/mine", headers=_auth(person))).json()["items"][0]
        assert mine["status"] == "lifted" and mine["appeals"][0]["decision"].startswith("The reports did not hold up")
        from api.domains.scam_reports import service
        async with AsyncSessionLocal() as db:
            assert await service.is_restricted(db, person.id, "create_listing") is None
        assert (await client.post(f"/admin/scam-reports/appeals/{appeal['id']}/decide", headers=_auth(admin),
                                  json={"outcome": "upheld", "note": "Changing my mind later on."})).status_code == 409

    @pytest.mark.asyncio
    async def test_an_upheld_appeal_leaves_it_to_run_out_and_every_step_is_audited(self, client):
        admin, person, rid = await self._restricted(client)
        appeal = (await client.post(f"/scam-reports/restrictions/{rid}/appeal", headers=_auth(person),
                                    json={"statement": "I would like this looked at again please."})).json()
        await client.post(f"/admin/scam-reports/appeals/{appeal['id']}/decide", headers=_auth(admin),
                          json={"outcome": "upheld", "note": "The evidence still stands; it ends on its date."})
        mine = (await client.get("/scam-reports/restrictions/mine", headers=_auth(person))).json()["items"][0]
        assert mine["status"] == "active"
        async with AsyncSessionLocal() as db:
            actions = {a.action for a in (await db.execute(select(AuditLog).where(
                AuditLog.resource_id.in_([rid, person.id])))).scalars().all()}
        assert {"restriction_applied", "restriction_appeal_filed", "restriction_appeal_decided"} <= actions

    @pytest.mark.asyncio
    async def test_an_administrator_can_lift_one_with_a_reason(self, client):
        admin, person, rid = await self._restricted(client)
        assert (await client.post(f"/admin/scam-reports/restrictions/{rid}/lift", headers=_auth(admin),
                                  json={"note": "x"})).status_code == 422
        ok = await client.post(f"/admin/scam-reports/restrictions/{rid}/lift", headers=_auth(admin),
                               json={"note": "Reports were withdrawn by the reporter."})
        assert ok.status_code == 200 and ok.json()["status"] == "lifted"
