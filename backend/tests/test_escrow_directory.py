"""The provider directory's rules (api/domains/escrow_directory/): which
links are official, what counts as current, what an admin edit may and may
not do, what a public reader may see, and when a comparison may rank.

Plain Python, no database: the rules that protect a buyer from a wrong
website, a stale fee or a false "cheapest" are tested directly. The HTTP
layer on top is in test_escrow_directory_api.py.
"""
import copy
import json

import pytest

from api.domains.escrow_directory import (
    catalogue, compare, disclosures, freshness, links, projection, schema, seed,
)

ALLOW = seed.DEFAULT_PROVIDER_DOMAINS
TODAY = "2026-11-16"


def rec(pid: str) -> dict:
    return next(r for r in seed.records() if r["id"] == pid)


def verified(record: dict, on: str = "2026-11-10") -> dict:
    """[record] as an administrator would leave it after a full review."""
    record["status"] = "approved"
    record["pricing"]["last_verified"] = on
    record["pricing"]["additional_fees_may_apply"] = False
    record["trust"].update(identity_verification="verified", terms_review="verified",
                           pricing_review="verified", operational_test="passed",
                           last_verified=on, next_review="2027-02-01", reviewed_by="admin-1")
    record["identity"].update(legal_entity_name=record["identity"]["legal_entity_name"] or "Example Ltd",
                              legal_entity_confirmed=True)
    return record


# ── Links ────────────────────────────────────────────────────────────────

class TestOfficialLinks:
    @pytest.mark.parametrize("url", [
        "https://kenyaescrow.com@evil.example/",          # user-info: the browser goes to evil.example
        "https://user@kenyaescrow.com/",                   # right host, but user-info is never legitimate
        "https://user:secret@kenyaescrow.com/pricing",     # ...nor credentials in a link we hand out
        "https://kenyaescrow.com.evil.example/",          # ends in a name it doesn't own
        "https://evilkenyaescrow.com/",                    # contains the name
        "https://notkenyaescrow.com",
        "http://kenyaescrow.com/",                         # not https
        "https://kenyaescrow.com:8443/x",                  # odd port
        "https://xn--kenyaescrw-8cf.com/",                 # punycode look-alike
        "https://kenyaescrow.com/\n", "https://kenya escrow.com/", "https://kenyaescrow.com/\"x",
        "javascript:alert(1)", "data:text/html,x", "//kenyaescrow.com/", "kenyaescrow.com",
        "https://escrowkenya.com/",                         # the other company
        "https://sub.kenyaescrow.com/",                    # only the apex and www
        "", None, 5, "https://" + "a" * 400 + ".com",
    ])
    def test_a_look_alike_or_unsafe_address_is_never_official(self, url):
        assert links.official_url(url, "kenyaescrow.com") is None
        assert links.is_official_url(url, "kenyaescrow.com") is False

    @pytest.mark.parametrize("url,clean", [
        ("https://kenyaescrow.com", "https://kenyaescrow.com/"),
        ("https://www.kenyaescrow.com/pricing", "https://www.kenyaescrow.com/pricing"),
        ("https://KenyaEscrow.com:443/faq?x=1#top", "https://kenyaescrow.com/faq?x=1"),
    ])
    def test_the_provider_own_pages_are_official(self, url, clean):
        assert links.official_url(url, "kenyaescrow.com") == clean

    def test_a_domain_must_be_plain_and_on_the_deployments_list(self):
        assert links.is_domain("kenyaescrow.com") and links.is_domain("econfirm.co.ke")
        for bad in ("www.kenyaescrow.com", "KenyaEscrow.com", "xn--abc.com", "kenyaescrow", "a.b",
                    "kenya escrow.com", "", None, "kenyaescrow.com/", "kenyaescrow.com:80"):
            assert not links.is_domain(bad), bad
        assert links.domain_allowed("kenyaescrow.com", ALLOW)
        assert not links.domain_allowed("kenyaescrow.co.ke", ALLOW)
        assert not links.domain_allowed("evil.example", ALLOW)


# ── The seed ─────────────────────────────────────────────────────────────

class TestSeed:
    def test_every_seed_record_is_valid(self):
        for r in seed.records():
            assert schema.validate_record(r, ALLOW) == [], r["id"]

    def test_nothing_is_approved_or_verified_just_because_the_code_shipped(self):
        for r in seed.records():
            assert r["status"] in ("under_review", "suspended"), r["id"]
            assert r["pricing"]["last_verified"] is None and r["trust"]["last_verified"] is None
            assert r["trust"]["pricing_review"] != "verified" and r["trust"]["identity_verification"] != "verified"
            assert schema.approval_blockers(r), r["id"]       # none can be approved as shipped

    def test_the_four_providers_and_their_official_domains(self):
        got = {r["id"]: r["identity"]["canonical_domain"] for r in seed.records()}
        assert got == {"econfirm": "econfirm.co.ke", "kenyaescrow": "kenyaescrow.com",
                       "lipasafe": "lipasafe.co.ke", "shikilia": "shikilia.co.ke",
                       "escrowkenya": "escrowkenya.com"}
        urls = {r["id"]: r["identity"]["website_url"] for r in seed.records()}
        assert urls["kenyaescrow"] == "https://kenyaescrow.com/"           # the owner's exact URL
        assert urls["econfirm"] == "https://econfirm.co.ke/"
        assert urls["lipasafe"] == "https://lipasafe.co.ke/"
        assert urls["shikilia"] == "https://www.shikilia.co.ke/"

    def test_every_seed_domain_is_on_the_default_allowlist_and_the_setting_agrees(self):
        from api.core.config import settings
        assert {r["identity"]["canonical_domain"] for r in seed.records()} <= set(ALLOW)
        assert tuple(settings.escrow_provider_domains) == tuple(ALLOW)

    def test_escrow_kenya_is_suspended_and_never_listed_or_confused_with_kenya_escrow(self):
        suspended = rec("escrowkenya")
        assert suspended["status"] == "suspended"
        assert suspended["identity"]["canonical_domain"] == "escrowkenya.com"
        assert rec("kenyaescrow")["identity"]["canonical_domain"] == "kenyaescrow.com"
        listed_ids = [r["id"] for r in catalogue.listed(seed.records())]
        assert "escrowkenya" not in listed_ids
        confused = rec("kenyaescrow")["identity"]["confusable_with"]
        assert confused == [{"name": "Escrow Kenya", "domain": "escrowkenya.com", "note": confused[0]["note"]}]

    def test_the_owner_stated_facts_are_recorded_as_given(self):
        ke, ec, lp, sh = rec("kenyaescrow"), rec("econfirm"), rec("lipasafe"), rec("shikilia")
        assert (ke["conditions"]["min_amount"], ke["conditions"]["max_amount"]) == (50, 240000)
        assert ke["conditions"]["registration_required"] is False
        assert ke["pricing"]["absorbs_mpesa_fees"] is True
        assert ke["pricing"]["disclosure"] == "published_tiered"
        assert ec["pricing"]["commission"]["percent"] == "1"
        assert (ec["conditions"]["min_amount"], ec["conditions"]["max_amount"]) == (100, 500000)
        assert ec["identity"]["terms_url"] == "https://econfirm.co.ke/terms-and-conditions"
        assert ec["pricing"]["source_url"] == "https://econfirm.co.ke/tariffs"
        assert any("fully functional beta" in t for t in ec["protection"]["notable_terms"])
        assert lp["conditions"]["registration_required"] is True and lp["conditions"]["kyc_required"] is True
        assert lp["identity"]["legal_entity_name"] == "Holda Fintech Technologies Limited"
        assert lp["protection"]["auto_release"]["can_occur"] is True
        assert "not covered by deposit insurance" in lp["protection"]["deposit_insurance"]
        assert sh["conditions"]["min_amount"] == 10
        assert "24 to 48 hours" in sh["protection"]["dispute_timeframe"]
        assert "24-hour" in sh["protection"]["buyer_protection"]

    def test_unknowns_are_left_blank_not_filled_in(self):
        sh, lp, ec = rec("shikilia"), rec("lipasafe"), rec("econfirm")
        assert sh["pricing"]["commission"] is None and lp["pricing"]["commission"] is None
        assert sh["conditions"]["max_amount"] is None and lp["conditions"]["min_amount"] is None
        assert ec["conditions"]["registration_required"] is None and ec["conditions"]["kyc_required"] is None
        for r in seed.records():
            assert r["conditions"]["categories"] is None            # never documented in the research
            assert r["pricing"]["additional_fees_may_apply"] is None
            assert r["identity"]["contact_email"] is None and r["identity"]["contact_phone"] is None

    def test_econfirms_payout_reserve_is_declared_but_unloaded(self):
        reserve = rec("econfirm")["pricing"]["payout_fees"][0]
        assert reserve["estimated"] is True and reserve["documented"] is False
        assert set(reserve["by_destination"]) == {"phone", "till"}
        assert all(body == {} for body in reserve["by_destination"].values())

    def test_the_two_names_the_brief_gave_for_unresolved_entities_are_kept(self):
        assert "Confirm Delegence Solutions" in rec("econfirm")["identity"]["legal_entity_name"]
        note = rec("shikilia")["identity"]["operator_note"]
        for name in ("Jeno-tech Solutions", "Jo-Jo Mani Investment", "Travel Pay"):
            assert name in note
        assert rec("shikilia")["identity"]["legal_entity_name"] is None
        assert rec("kenyaescrow")["identity"]["legal_entity_name"] is None


# ── Validation ───────────────────────────────────────────────────────────

class TestValidation:
    def errors(self, **patch):
        r = rec("kenyaescrow")
        r = schema.merge_patch(r, patch)
        return schema.validate_record(r, ALLOW)

    def test_a_domain_outside_the_allowlist_is_refused(self):
        errs = self.errors(identity={"canonical_domain": "evil.example",
                                     "website_url": "https://evil.example/"})
        assert any("approved provider domains" in e for e in errs)

    @pytest.mark.parametrize("key", ["website_url", "terms_url", "privacy_url", "logo_url"])
    def test_every_identity_url_must_be_on_the_providers_domain(self, key):
        errs = self.errors(identity={key: "https://evil.example/kenyaescrow"})
        assert any(f"identity.{key}" in e for e in errs)

    def test_pricing_and_source_urls_must_be_on_the_providers_domain(self):
        assert any("pricing.source_url" in e for e in self.errors(pricing={"source_url": "https://evil.example/p"}))
        assert any("pricing.quote_url" in e for e in self.errors(pricing={"quote_url": "http://kenyaescrow.com/"}))
        errs = self.errors(trust={"sources": [{"label": "x", "url": "https://evil.example/"}]})
        assert any("trust.sources[1].url" in e for e in errs)

    def test_a_fee_cannot_sit_beside_no_fee_published(self):
        for disclosure in ("quote_required", "not_disclosed", "under_review"):
            errs = self.errors(pricing={"disclosure": disclosure})
            assert any("must not carry fee figures" in e for e in errs), disclosure

    def test_a_published_fee_needs_its_formula_and_its_source(self):
        lp = schema.merge_patch(rec("lipasafe"), {"pricing": {"disclosure": "published_percentage"}})
        assert any("commission" in e for e in schema.validate_record(lp, ALLOW))
        ke = rec("kenyaescrow")
        ke["pricing"]["source_url"] = None
        assert any("needs the page it was read from" in e for e in schema.validate_record(ke, ALLOW))

    def test_the_band_table_must_match_the_advertised_limits(self):
        errs = self.errors(conditions={"max_amount": 250000})
        assert any("last band ends at 240000" in e for e in errs)
        errs = self.errors(conditions={"min_amount": 10})
        assert any("first band starts at 50" in e for e in errs)

    @pytest.mark.parametrize("patch,expect", [
        ({"status": "live"}, "status"),
        ({"display_name": ""}, "display_name"),
        ({"id": "Bad Id"}, "id"),
        ({"pricing": {"disclosure": "free"}}, "pricing.disclosure"),
        ({"pricing": {"currency": "USD"}}, "currency"),
        ({"conditions": {"min_amount": -1}}, "min_amount"),
        ({"conditions": {"payment_methods": ["bitcoin"]}}, "payment_methods"),
        ({"conditions": {"registration_required": "yes"}}, "registration_required"),
        ({"trust": {"pricing_review": "great"}}, "trust.pricing_review"),
        ({"trust": {"last_verified": "yesterday"}}, "last_verified"),
        ({"identity": {"contact_email": "not an email"}}, "contact_email"),
        ({"identity": {"legal_entity_confirmed": True, "legal_entity_name": None}}, "legal_entity_confirmed"),
        ({"identity": {"confusable_with": [{"name": "X", "domain": "kenyaescrow.com"}]}}, "itself"),
        ({"tagline": "x" * 200}, "tagline"),
        ({"protection": {"how_funds_are_held": "bad\x00text"}}, "control characters"),
    ])
    def test_malformed_fields_are_refused(self, patch, expect):
        assert any(expect in e for e in self.errors(**patch)), patch

    def test_garbage_is_refused_not_crashed_on(self):
        for bad in (None, [], "x", 5, {}, {"identity": {}}):
            assert schema.validate_record(bad, ALLOW)

    def test_a_blank_draft_is_valid(self):
        draft = schema.blank_record("newco", "NewCo", "econfirm.co.ke")
        draft["id"] = "newco"
        assert schema.validate_record(draft, ALLOW) == []


# ── What an edit may do ──────────────────────────────────────────────────

class TestEditing:
    def test_an_edit_cannot_set_its_own_verification(self):
        sneaky = {"status": "approved", "trust": {"pricing_review": "verified", "last_verified": "2026-11-16"},
                  "pricing": {"last_verified": "2026-11-16"}}
        assert schema.protected_paths_in(sneaky) == [
            "pricing.last_verified", "status", "trust.last_verified", "trust.pricing_review"]
        assert schema.protected_paths_in({"tagline": "x", "pricing": {"public_note": "y"}}) == []
        assert schema.protected_paths_in({"trust": {"internal_notes": "n"}}) == []

    def test_changing_a_fee_clears_the_pricing_check_and_unapproves(self):
        before = verified(rec("kenyaescrow"))
        after = schema.merge_patch(before, {"pricing": {"additional_fees_may_apply": True}})
        out, cleared = schema.apply_edit_consequences(before, after)
        assert out["pricing"]["last_verified"] is None
        assert out["trust"]["pricing_review"] == "pending" and out["trust"]["last_verified"] is None
        assert out["status"] == "under_review"
        assert "pricing review" in cleared and any("approval" in c for c in cleared)
        assert freshness.pricing_freshness(out, TODAY)["state"] == freshness.UNVERIFIED

    def test_changing_a_band_is_a_fee_change(self):
        before = verified(rec("kenyaescrow"))
        tiers = copy.deepcopy(before["pricing"]["commission"]["tiers"])
        tiers[0]["fixed"] = "11"
        after = schema.merge_patch(before, {"pricing": {"commission": {"tiers": tiers}}})
        out, cleared = schema.apply_edit_consequences(before, after)
        assert "pricing" in schema.changed_areas(before, after) and "pricing review" in cleared
        assert out["pricing"]["commission"]["tiers"][0]["fixed"] == "11"

    def test_changing_limits_or_protection_clears_the_terms_check(self):
        before = verified(rec("kenyaescrow"))
        for patch in ({"conditions": {"registration_required": True}},
                      {"protection": {"refund_conditions": "Within 24 hours."}},
                      {"identity": {"terms_url": "https://kenyaescrow.com/terms"}}):
            after = schema.merge_patch(before, patch)
            out, cleared = schema.apply_edit_consequences(before, after)
            assert out["trust"]["terms_review"] == "pending" and out["status"] == "under_review", patch

    def test_changing_the_legal_entity_clears_the_identity_check(self):
        before = verified(rec("lipasafe"))
        after = schema.merge_patch(before, {"identity": {"legal_entity_name": "Other Ltd"}})
        out, cleared = schema.apply_edit_consequences(before, after)
        assert out["trust"]["identity_verification"] == "pending" and "identity verification" in cleared

    def test_a_wording_only_edit_leaves_the_review_standing(self):
        before = verified(rec("kenyaescrow"))
        after = schema.merge_patch(before, {"tagline": "New tagline", "public_notice": "Note",
                                            "pricing": {"public_note": "New note"},
                                            "trust": {"internal_notes": "Checked again."}})
        out, cleared = schema.apply_edit_consequences(before, after)
        assert cleared == [] and out["status"] == "approved" and out["pricing"]["last_verified"] == "2026-11-10"

    def test_merge_patch_merges_objects_replaces_lists_and_null_clears(self):
        base = rec("kenyaescrow")
        out = schema.merge_patch(base, {"conditions": {"payment_methods": ["mpesa"], "other": []},
                                        "identity": {"contact_email": None}})
        assert out["conditions"]["payment_methods"] == ["mpesa"] and out["conditions"]["other"] == []
        assert out["conditions"]["max_amount"] == 240000                    # untouched sibling
        assert base["conditions"]["payment_methods"] == ["mpesa_stk_push"]   # the base is not modified

    def test_commission_is_replaced_whole_not_merged(self):
        """Merging two fee rules key by key would leave a percent from one and
        tiers from the other: a formula nobody published."""
        base = rec("kenyaescrow")
        out = schema.merge_patch(base, {"pricing": {"commission": {"label": "Fee", "percent": "2"}}})
        assert out["pricing"]["commission"] == {"label": "Fee", "percent": "2"}


class TestApprovalAndTransitions:
    def test_a_fully_reviewed_record_can_be_approved(self):
        r = verified(rec("kenyaescrow"))
        r["status"] = "under_review"
        r["identity"].update(terms_url="https://kenyaescrow.com/terms", privacy_url="https://kenyaescrow.com/privacy")
        assert schema.approval_blockers(r) == []

    @pytest.mark.parametrize("mutate,expect", [
        (lambda r: r["trust"].update(identity_verification="pending"), "identity has not been verified"),
        (lambda r: r["identity"].update(legal_entity_confirmed=False), "legal entity"),
        (lambda r: r["identity"].update(legal_entity_name=None), "legal entity"),
        (lambda r: r["trust"].update(terms_review="pending"), "terms have not been reviewed"),
        (lambda r: r["trust"].update(pricing_review="failed"), "pricing has not been reviewed"),
        (lambda r: r["pricing"].update(last_verified=None), "pricing has no verification date"),
        (lambda r: r["trust"].update(operational_test="pending"), "no operational test"),
        (lambda r: r["trust"].update(last_verified=None), "no verification date"),
        (lambda r: r["trust"].update(next_review=None), "no next review date"),
        (lambda r: r["trust"].update(sources=[]), "no source references"),
        (lambda r: r["identity"].update(terms_url=None), "terms URL is missing"),
        (lambda r: r["identity"].update(privacy_url=None), "privacy policy URL is missing"),
    ])
    def test_each_missing_check_blocks_approval(self, mutate, expect):
        r = verified(rec("kenyaescrow"))
        r["identity"].update(terms_url="https://kenyaescrow.com/terms", privacy_url="https://kenyaescrow.com/privacy")
        mutate(r)
        assert any(expect in b for b in schema.approval_blockers(r)), schema.approval_blockers(r)

    @pytest.mark.parametrize("current,target,ok", [
        ("draft", "under_review", True), ("under_review", "approved", True),
        ("under_review", "suspended", True), ("approved", "suspended", True),
        ("approved", "under_review", True), ("suspended", "under_review", True),
        ("rejected", "under_review", True),
        ("suspended", "approved", False),       # back through review, never in one click
        ("rejected", "approved", False), ("draft", "approved", False), ("draft", "suspended", False),
        ("approved", "approved", False), ("under_review", "bogus", False),
    ])
    def test_status_moves(self, current, target, ok):
        assert (schema.transition_error(current, target) is None) is ok


# ── Freshness ────────────────────────────────────────────────────────────

class TestFreshness:
    def test_a_record_nobody_has_checked_is_unverified(self):
        state = freshness.pricing_freshness(rec("kenyaescrow"), TODAY)
        assert state["state"] == freshness.UNVERIFIED and state["verified_on"] is None
        assert "not yet verified" in state["warning"].lower()

    def test_a_dated_check_without_the_review_marked_verified_still_is_not_current(self):
        r = rec("kenyaescrow")
        r["pricing"]["last_verified"] = "2026-11-10"          # a date alone verifies nothing
        assert freshness.pricing_freshness(r, TODAY)["state"] == freshness.UNVERIFIED

    def test_current_then_expired_at_exactly_the_boundary(self):
        r = verified(rec("kenyaescrow"), "2026-11-01")
        r["trust"]["next_review"] = None
        assert freshness.pricing_freshness(r, "2026-11-16")["state"] == freshness.CURRENT
        assert freshness.pricing_freshness(r, "2026-12-01")["state"] == freshness.CURRENT   # day 30
        late = freshness.pricing_freshness(r, "2026-12-02")                                  # day 31
        assert late["state"] == freshness.EXPIRED
        assert "1 Nov 2026" in late["warning"] and "30 days" in late["warning"]
        assert late["label"].startswith("Outdated")

    def test_the_age_limit_is_a_parameter(self):
        r = verified(rec("kenyaescrow"), "2026-11-01")
        r["trust"]["next_review"] = None
        assert freshness.pricing_freshness(r, "2026-11-16", max_age_days=10)["state"] == freshness.EXPIRED
        assert freshness.pricing_freshness(r, "2026-11-16", max_age_days=60)["state"] == freshness.CURRENT

    def test_an_overdue_next_review_expires_pricing_early(self):
        r = verified(rec("kenyaescrow"), "2026-11-01")
        r["trust"]["next_review"] = "2026-11-08"
        state = freshness.pricing_freshness(r, "2026-11-09")
        assert state["state"] == freshness.EXPIRED and "was due on 8 Nov 2026" in state["warning"]

    def test_a_date_in_the_future_is_never_current(self):
        r = verified(rec("kenyaescrow"), "2027-01-01")
        assert freshness.pricing_freshness(r, TODAY)["state"] == freshness.UNVERIFIED

    @pytest.mark.parametrize("bad", ["2026-13-01", "16/11/2026", "2026-11-16T10:00:00", "", 20261116, None, "tomorrow"])
    def test_a_malformed_date_is_unverified(self, bad):
        r = verified(rec("kenyaescrow"))
        r["pricing"]["last_verified"] = bad
        assert freshness.pricing_freshness(r, TODAY)["state"] == freshness.UNVERIFIED

    def test_a_record_is_only_as_current_as_its_least_current_part(self):
        r = verified(rec("kenyaescrow"), "2026-11-10")
        assert freshness.evaluate(r, TODAY)["state"] == freshness.CURRENT
        r["trust"]["last_verified"] = None
        out = freshness.evaluate(r, TODAY)
        assert out["state"] == freshness.UNVERIFIED and out["needs_review"] is True
        assert out["pricing"]["state"] == freshness.CURRENT and out["record"]["state"] == freshness.UNVERIFIED


# ── What a public reader may see ─────────────────────────────────────────

class TestPublicView:
    SECRETS = ("internal_notes", "reviewed_by", "Research input only", "Continuity check",
               "SUSPENDED per", "transcription slip", "approval_blockers")

    def test_no_internal_note_or_reviewer_reaches_a_public_response(self):
        records = [verified(r) if r["id"] == "kenyaescrow" else r for r in seed.records()]
        records[1]["trust"]["internal_notes"] = "SECRET-NOTE-123: call the founder"
        records[1]["trust"]["reviewed_by"] = "admin-uuid-9"
        payloads = [catalogue.public_catalogue(records, TODAY),
                    catalogue.compare_providers(records, TODAY, amount=5000, sort="lowest_fee")]
        payloads += [projection.public_view(r, TODAY) for r in records]
        payloads += [projection.notice_view(r) for r in records] + [projection.legacy_view(r) for r in records]
        for payload in payloads:
            text = json.dumps(payload)
            for secret in self.SECRETS + ("SECRET-NOTE-123", "admin-uuid-9"):
                assert secret not in text, secret

    def test_the_admin_view_does_carry_them(self):
        r = rec("econfirm")
        assert "Research input only" in json.dumps(projection.admin_view(r, TODAY))

    def test_suspended_and_rejected_and_draft_providers_are_not_listed(self):
        records = seed.records()
        for status in ("suspended", "rejected", "draft"):
            records[0]["status"] = status
            ids = [p["id"] for p in catalogue.public_catalogue(records, TODAY)["providers"]]
            assert "econfirm" not in ids, status
        records[0]["status"] = "approved"
        assert "econfirm" in [p["id"] for p in catalogue.public_catalogue(records, TODAY)["providers"]]

    def test_a_notice_is_given_only_for_an_unlisted_provider_that_has_one(self):
        out = catalogue.public_catalogue(seed.records(), TODAY)
        assert [n["id"] for n in out["notices"]] == ["escrowkenya"]
        assert "different website from Kenya Escrow" in out["notices"][0]["public_notice"]
        assert "fraud" not in out["notices"][0]["public_notice"].lower()      # no accusation without evidence
        records = seed.records()
        records[-1]["public_notice"] = None
        assert catalogue.public_catalogue(records, TODAY)["notices"] == []

    def test_a_provider_is_called_reviewed_only_if_approved_and_current(self):
        r = verified(rec("kenyaescrow"))
        assert projection.public_view(r, TODAY)["recommendable"] is True
        assert projection.public_view(r, TODAY)["review_label"] == "Reviewed by Broka"
        assert projection.public_view(r, "2027-03-01")["recommendable"] is False        # expired
        r["status"] = "under_review"
        assert projection.public_view(r, TODAY)["recommendable"] is False
        assert "not yet verified" in projection.public_view(r, TODAY)["review_label"]

    def test_expired_pricing_carries_the_outdated_warning(self):
        r = verified(rec("kenyaescrow"), "2026-09-01")
        view = projection.public_view(r, TODAY)
        assert view["freshness"]["pricing"]["state"] == "expired"
        assert any("Fees may have changed" in w for w in view["freshness"]["warnings"])

    def test_every_visible_provider_says_how_current_it_is(self):
        for p in catalogue.public_catalogue(seed.records(), TODAY)["providers"]:
            assert p["freshness"]["pricing"]["label"] and p["freshness"]["record"]["label"]
            assert p["freshness"]["pricing"]["state"] in ("current", "expired", "unverified")

    def test_a_legal_entity_that_is_not_confirmed_is_labelled_as_unconfirmed(self):
        view = projection.public_view(rec("lipasafe"), TODAY)
        assert view["identity"]["legal_entity_label"].startswith("Operator named by the provider")
        assert "not yet verified" in view["identity"]["legal_entity_label"]
        assert "not yet confirmed" in projection.public_view(rec("kenyaescrow"), TODAY)["identity"]["legal_entity_label"]

    def test_undocumented_facts_are_listed_for_the_ui(self):
        gaps = projection.public_view(rec("shikilia"), TODAY)["undocumented"]
        for gap in ("maximum_amount", "registration", "kyc", "refund_conditions", "additional_fees"):
            assert gap in gaps
        assert "minimum_amount" not in gaps


class TestWhatIsSaidAboutFees:
    def test_the_two_phrases_the_owner_specified_are_used_verbatim(self):
        assert projection.fee_summary(rec("lipasafe")) == "Check live quotation in Lipasafe before paying"
        assert projection.fee_summary(rec("shikilia")) == "Fee not publicly specified – confirm before paying"

    def test_the_one_percent_is_never_presented_as_the_total(self):
        summary = projection.fee_summary(rec("econfirm"))
        assert "commission" in summary and "1%" in summary
        assert "payout reserve is charged separately" in summary
        assert "total" not in summary.lower()
        assert "not the total fee" in rec("econfirm")["pricing"]["public_note"]

    def test_a_tiered_summary_does_not_cherry_pick_a_band(self):
        summary = projection.fee_summary(rec("kenyaescrow"))
        assert "11 published bands" in summary and "calculator" in summary
        assert "0.3%" not in summary and "10%" not in summary

    def test_limits_read_plainly(self):
        assert projection.limits_summary(rec("kenyaescrow")["conditions"]) == \
            "KSh 50 to KSh 240,000 (the amount the seller receives)"
        assert projection.limits_summary(rec("shikilia")["conditions"]).startswith("From KSh 10; maximum not published")
        assert projection.limits_summary(rec("lipasafe")["conditions"]) == "Limits not published"

    def test_requirements_do_not_guess(self):
        def req(pid):
            return projection.public_view(rec(pid), TODAY)["summaries"]["requirements"]
        # A documented "no account" does not imply "no ID checks".
        assert req("kenyaescrow") == "No account required. ID checks not documented."
        assert req("lipasafe") == "Account required; ID checks (KYC) required"
        # Neither documented: said so, not assumed either way.
        assert req("econfirm") == "Not documented; Not documented"

    def test_missing_protection_facts_say_not_documented(self):
        assert projection.release_summary(rec("econfirm")) == projection.NOT_DOCUMENTED
        assert projection.dispute_summary(rec("kenyaescrow")) != projection.NOT_DOCUMENTED   # it has one
        blank = rec("kenyaescrow")
        blank["protection"]["dispute_initiation"] = None
        assert projection.dispute_summary(blank) == projection.NOT_DOCUMENTED


class TestLegacyShape:
    KEYS = {"id", "name", "url", "note", "tagline", "best_for", "pay", "fees", "limits", "start",
            "release", "payout", "dispute", "company"}

    def test_older_app_builds_still_get_every_key_they_read_as_text(self):
        for r in seed.records():
            legacy = projection.legacy_view(r)
            assert self.KEYS <= set(legacy)
            assert all(isinstance(legacy[k], str) for k in self.KEYS)
            assert legacy["url"].startswith("https://")

    def test_no_provider_fee_or_limit_is_invented_for_them(self):
        legacy = {r["id"]: projection.legacy_view(r) for r in seed.records()}
        assert legacy["lipasafe"]["fees"] == "Check live quotation in Lipasafe before paying"
        assert legacy["shikilia"]["fees"] == "Fee not publicly specified – confirm before paying"
        assert legacy["shikilia"]["limits"].startswith("From KSh 10")
        assert "Not the same company as Escrow Kenya (escrowkenya.com)" in legacy["kenyaescrow"]["note"]

    def test_a_provider_is_not_called_verified_in_the_legacy_shape_unless_approved(self):
        assert all(projection.legacy_view(r)["verified"] is False for r in seed.records())
        assert projection.legacy_view(verified(rec("kenyaescrow")))["verified"] is True


# ── Comparing ────────────────────────────────────────────────────────────

class TestCompareAndRank:
    def reviewed_pair(self):
        records = seed.records()
        verified(next(r for r in records if r["id"] == "kenyaescrow"))
        ec = verified(next(r for r in records if r["id"] == "econfirm"))
        ec["pricing"]["payout_fees"][0].update(documented=True, by_destination={
            "phone": {"tiers": [{"min": 100, "max": 500000, "fixed": "10"}]},       # SYNTHETIC test figures
            "till": {"tiers": [{"min": 100, "max": 500000, "fixed": "5"}]}})
        return records

    def test_the_seed_as_shipped_claims_nothing_about_who_is_cheapest(self):
        out = catalogue.compare_providers(seed.records(), TODAY, amount=5000, sort="lowest_fee")
        assert out["ranking"]["claim_allowed"] is False and out["ranking"]["ranked"] == []
        assert "Not enough comparable" in out["ranking"]["headline"]
        reasons = {n["id"]: n["reason"] for n in out["ranking"]["not_ranked"]}
        assert set(reasons) == {"econfirm", "kenyaescrow", "lipasafe", "shikilia"}
        assert all(reasons.values())

    def test_an_undisclosed_fee_is_never_ranked_above_or_below_a_published_one(self):
        records = self.reviewed_pair()
        out = catalogue.compare_providers(records, TODAY, amount=5000, payout="phone", sort="lowest_fee")
        ranked = [r["id"] for r in out["ranking"]["ranked"]]
        assert "lipasafe" not in ranked and "shikilia" not in ranked
        assert set(ranked) == {"econfirm", "kenyaescrow"}
        not_ranked = {n["id"] for n in out["ranking"]["not_ranked"]}
        assert {"lipasafe", "shikilia"} <= not_ranked

    def test_with_two_comparable_estimates_the_cheaper_is_named_and_ranked_first(self):
        out = catalogue.compare_providers(self.reviewed_pair(), TODAY, amount=5000, payout="phone", sort="lowest_fee")
        assert out["ranking"]["claim_allowed"] is True
        assert [r["id"] for r in out["ranking"]["ranked"]] == ["econfirm", "kenyaescrow"]
        assert [p["id"] for p in out["results"]][:2] == ["econfirm", "kenyaescrow"]
        assert out["ranking"]["ranked"][0]["total_buyer_payment"] == 5000 + 50 + 10
        assert "eConfirm" in out["ranking"]["headline"]

    def test_one_comparable_provider_is_not_a_comparison(self):
        records = self.reviewed_pair()
        out = catalogue.compare_providers(records, TODAY, amount=5000, sort="lowest_fee")   # no payout: eConfirm partial
        assert out["ranking"]["claim_allowed"] is False

    def test_a_provider_that_is_not_approved_is_never_ranked_even_with_a_complete_estimate(self):
        records = self.reviewed_pair()
        next(r for r in records if r["id"] == "kenyaescrow")["status"] = "under_review"
        out = catalogue.compare_providers(records, TODAY, amount=5000, payout="phone", sort="lowest_fee")
        assert out["ranking"]["claim_allowed"] is False
        assert any("completed BROKA's review" in n["reason"] for n in out["ranking"]["not_ranked"])

    def test_out_of_date_pricing_drops_out_of_the_ranking(self):
        records = self.reviewed_pair()
        out = catalogue.compare_providers(records, "2027-03-01", amount=5000, payout="phone", sort="lowest_fee")
        assert out["ranking"]["claim_allowed"] is False
        assert all("out of date" in n["reason"] for n in out["ranking"]["not_ranked"]
                   if n["id"] in ("econfirm", "kenyaescrow"))

    def test_ties_share_a_position_and_neither_is_called_cheaper(self):
        entries = [{"id": i, "name": i.title(), "approved": True,
                    "estimate": {"comparable": True, "total_buyer_payment": 5316, "total_fees": 316}}
                   for i in ("a", "b")]
        ranking = compare.rank_by_fee(entries)
        assert [r["position"] for r in ranking["ranked"]] == [1, 1]
        assert "A and B" in ranking["headline"]

    def test_the_amount_filters_out_providers_that_will_not_take_it(self):
        out = catalogue.compare_providers(seed.records(), TODAY, amount=300000)
        assert {e["id"] for e in out["excluded"]} == {"kenyaescrow"}
        assert [r["id"] for r in out["results"]] == ["econfirm", "lipasafe", "shikilia"]
        assert "KSh 240,000" in out["excluded"][0]["reason"]

    def test_order_by_highest_limit_lists_unknown_limits_after_the_known_ones(self):
        out = catalogue.compare_providers(seed.records(), TODAY, sort="highest_limit")
        assert [r["id"] for r in out["results"]] == ["econfirm", "kenyaescrow", "lipasafe", "shikilia"]
        assert [r["conditions"]["max_amount"] for r in out["results"]] == [500000, 240000, None, None]

    def test_lowest_fee_ordering_does_not_imply_a_ranking_when_none_is_allowed(self):
        out = catalogue.compare_providers(seed.records(), TODAY, amount=5000, sort="lowest_fee")
        assert [r["id"] for r in out["results"]] == ["econfirm", "kenyaescrow", "lipasafe", "shikilia"]  # alphabetical
        assert out["ranking"]["claim_allowed"] is False

    def test_no_amount_means_no_estimates_and_no_ranking(self):
        out = catalogue.compare_providers(seed.records(), TODAY)
        assert out["ranking"] is None and all("estimate" not in r for r in out["results"])


class TestFilters:
    def run(self, **criteria):
        kept, excluded = compare.filter_providers(catalogue.listed(seed.records()), criteria)
        return [r["id"] for r in kept], {e["id"]: e["reason"] for e in excluded}

    def test_no_account_matches_only_a_documented_no(self):
        kept, why = self.run(no_account=True)
        assert kept == ["kenyaescrow"]
        assert "not documented" in why["econfirm"] and "not documented" in why["shikilia"]
        assert why["lipasafe"] == "needs an account"

    def test_kyc_filters_say_unknown_is_not_a_yes(self):
        assert self.run(kyc="required")[0] == ["lipasafe"]
        assert self.run(kyc="not_required")[0] == []

    def test_mpesa_support_matches_every_mpesa_method(self):
        assert self.run(payment_method="mpesa")[0] == ["econfirm", "kenyaescrow", "lipasafe", "shikilia"]
        assert self.run(payment_method="bank_transfer")[0] == []

    def test_a_category_nobody_documented_matches_nobody(self):
        kept, why = self.run(category="goods")
        assert kept == [] and all("not documented" in r for r in why.values())
        records = catalogue.listed(seed.records())
        records[1]["conditions"]["categories"] = ["goods", "services"]
        assert [r["id"] for r in compare.filter_providers(records, {"category": "goods"})[0]] == ["kenyaescrow"]
        assert compare.filter_providers(records, {"category": "vehicles"})[0] == []

    def test_dispute_and_refund_filters_need_the_fact_to_be_written_down(self):
        assert self.run(documented_disputes=True)[0] == ["econfirm", "kenyaescrow", "lipasafe", "shikilia"]
        assert self.run(documented_refunds=True)[0] == []

    def test_filters_combine(self):
        assert self.run(no_account=True, payment_method="mpesa")[0] == ["kenyaescrow"]
        assert self.run(no_account=True, kyc="required")[0] == []


# ── Disclosures ──────────────────────────────────────────────────────────

class TestDisclosures:
    OWNER_TEXT = (
        "Broka does not operate these escrow services and does not hold, receive or release your "
        "money. The services are provided independently by their respective operators. Broka does "
        "not guarantee their performance or independently control their funds. Review the "
        "provider's current fees, conditions, refund policy and dispute procedures before paying.")

    def test_the_required_notice_is_the_owners_wording_exactly(self):
        assert disclosures.MAIN == self.OWNER_TEXT

    def test_every_public_response_carries_it(self):
        assert catalogue.public_catalogue(seed.records(), TODAY)["disclosures"]["main"] == self.OWNER_TEXT
        assert catalogue.compare_providers(seed.records(), TODAY)["disclosures"]["main"] == self.OWNER_TEXT

    def test_the_other_required_explanations_are_there(self):
        text = " ".join(disclosures.POINTS)
        for phrase in ("own terms and privacy policy", "separate agreement", "provider's own rules",
                       "cannot guarantee that a dispute will end in a refund",
                       "official website yourself", "exact approved https"):
            assert phrase in text, phrase

    def test_the_relationship_section_says_broka_is_an_independent_referrer(self):
        text = " ".join(disclosures.RELATIONSHIP)
        assert "not a party" in text and "cannot recover money" in text and "not a recommendation" in text

    def test_the_incident_advice_does_not_promise_recovery(self):
        assert "cannot promise to recover money" in disclosures.INCIDENT_LIMIT
        assert not any("recover your" in s.lower() for s in disclosures.INCIDENT_STEPS)


# ── Words BROKA must not use without a documented process ────────────────

BANNED = (r"\bguaranteed\b", r"\bfully safe\b", r"\b100% safe\b", r"\bbroka[- ]approved\b",
          r"\brisk[- ]free\b", r"\bcompletely safe\b", r"\bsafest\b")


def test_no_user_facing_text_uses_a_claim_broka_has_not_earned():
    import re
    texts = [json.dumps(catalogue.public_catalogue(seed.records(), TODAY)),
             json.dumps(catalogue.compare_providers(seed.records(), TODAY, amount=5000)),
             json.dumps([projection.legacy_view(r) for r in seed.records()]),
             json.dumps(disclosures.as_dict())]
    for text in texts:
        for pattern in BANNED:
            assert not re.search(pattern, text, re.I), pattern
