"""What a provider record is allowed to contain, and how it may change.

A record is a plain nested dict (see seed.py for four of them). It is
validated here, in one place, whoever wrote it - the seed, an admin's
edit, or a row read back from the database - because the provider list is
what tells a buyer which website to send money to.

THREE RULES THE VALIDATOR ENFORCES

  1. Every address in a record is on the provider's own canonical domain,
     and that domain is on the deployment's allowlist (links.py).
  2. A record cannot contradict itself about price: if its disclosure says
     "quote_required", "not_disclosed" or "under_review" it carries no
     fee figure at all - a fee shown beside "no fee published" is read as
     the fee.
  3. An edit cannot verify itself. The fields that say "BROKA checked this"
     (review statuses, verification dates, reviewer, the provider's status)
     are changed only by the review and status endpoints, never by the
     general edit, and a change to what was checked clears the check.
"""
from __future__ import annotations

import copy
import re
from typing import Any, Iterable, Optional

from . import fees
from .freshness import parse_date
from .links import domain_allowed, is_domain, official_url

# ── Vocabularies ─────────────────────────────────────────────────────────

STATUSES = ("draft", "under_review", "approved", "suspended", "rejected")
# Shown to people: draft, rejected and suspended providers are not.
LISTED_STATUSES = ("approved", "under_review")

IDENTITY_STATES = ("not_started", "pending", "verified", "failed")
REVIEW_STATES = ("not_started", "pending", "verified", "failed")
OPERATIONAL_STATES = ("not_started", "pending", "passed", "failed")

PAYMENT_METHODS = {
    "mpesa_stk_push": "M-Pesa STK Push",
    "mpesa": "M-Pesa",
    "mpesa_paybill": "M-Pesa Paybill",
    "mpesa_till": "M-Pesa Till",
    "bank_transfer": "Bank transfer",
    "card": "Card",
}
PAYOUT_METHODS = {
    "mpesa": "M-Pesa",
    "mpesa_phone": "M-Pesa (to a phone number)",
    "mpesa_till": "M-Pesa (to a till)",
    "bank_transfer": "Bank transfer",
}
CATEGORIES = {
    "goods": "Goods",
    "services": "Services",
    "vehicles": "Vehicles",
    "property": "Property and rent",
    "digital": "Digital goods",
    "freelance": "Freelance work",
}
BASES = ("seller_receives", "transaction_value", "not_stated")
COUNTRIES = ("KE", "UG", "TZ", "RW")

# Dotted paths an ordinary edit may not set: they record that BROKA checked
# something, and only the review/status endpoints may say so.
PROTECTED_PATHS = frozenset({
    "status",
    "trust.identity_verification", "trust.terms_review", "trust.pricing_review",
    "trust.operational_test", "trust.last_verified", "trust.next_review", "trust.reviewed_by",
    "pricing.last_verified",
})

_ID = re.compile(r"^[a-z][a-z0-9_]{1,39}$")
_EMAIL = re.compile(r"^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$")
_PHONE = re.compile(r"^\+?[0-9][0-9 ()-]{6,19}$")
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

MAX_TEXT = 1000
MAX_NOTES = 4000


# ── A blank record ───────────────────────────────────────────────────────

def blank_record(provider_id: str, display_name: str, canonical_domain: str) -> dict:
    """A draft with every field present and nothing claimed."""
    return {
        "id": provider_id,
        "display_name": display_name,
        "status": "draft",
        "tagline": None,
        "identity": {
            "legal_entity_name": None, "legal_entity_confirmed": False, "operator_note": None,
            "website_url": f"https://{canonical_domain}/", "canonical_domain": canonical_domain,
            "contact_email": None, "contact_phone": None, "terms_url": None, "privacy_url": None,
            "countries": ["KE"], "confusable_with": [], "logo_url": None,
        },
        "pricing": {
            "disclosure": "under_review", "currency": "KES", "basis": "not_stated",
            "commission": None, "processing_fees": [], "payout_fees": [],
            "absorbs_mpesa_fees": None, "additional_fees_may_apply": None,
            "source_url": None, "quote_url": None, "last_verified": None, "public_note": None,
        },
        "conditions": {
            "min_amount": None, "max_amount": None, "amount_basis": "not_stated",
            "payment_methods": None, "payout_methods": None, "registration_required": None,
            "kyc_required": None, "categories": None, "regions": None, "other": [],
        },
        "protection": {
            "how_funds_are_held": None, "when_funds_locked": None, "release_conditions": None,
            "auto_release": {"can_occur": None, "description": None}, "confirmation_window": None,
            "buyer_protection": None, "seller_protection": None, "dispute_initiation": None,
            "evidence_required": None, "dispute_timeframe": None, "refund_conditions": None,
            "cancellation_policy": None, "deposit_insurance": None, "notable_terms": [],
        },
        "trust": {
            "identity_verification": "not_started", "terms_review": "not_started",
            "pricing_review": "not_started", "operational_test": "not_started",
            "last_verified": None, "next_review": None, "sources": [],
            "internal_notes": None, "reviewed_by": None,
        },
        "public_notice": None,
    }


# ── Validation ───────────────────────────────────────────────────────────

def _text(value: Any, where: str, errors: list[str], *, limit: int = MAX_TEXT) -> None:
    if value is None:
        return
    if not isinstance(value, str):
        errors.append(f"{where}: must be text or null")
    elif len(value) > limit:
        errors.append(f"{where}: longer than {limit} characters")
    elif _CONTROL.search(value):
        errors.append(f"{where}: contains control characters")


def _tri(value: Any, where: str, errors: list[str]) -> None:
    if value is not None and not isinstance(value, bool):
        errors.append(f"{where}: must be true, false or null (null = not documented)")


def _url(value: Any, domain: str, where: str, errors: list[str], *, required: bool = False) -> None:
    if value is None:
        if required:
            errors.append(f"{where}: required")
        return
    if official_url(value, domain) is None:
        errors.append(f"{where}: must be an https address on {domain} (or www.{domain})")


def _subset(value: Any, allowed: Iterable[str], where: str, errors: list[str]) -> None:
    if value is None:
        return
    allowed = set(allowed)
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        errors.append(f"{where}: must be a list of codes, or null")
    elif not set(value) <= allowed:
        errors.append(f"{where}: unknown value(s) {sorted(set(value) - allowed)}")


def _body_errors(body: Any, where: str, errors: list[str]) -> None:
    """percent / fixed / tiers on a fee rule, or on one payout destination."""
    if not isinstance(body, dict):
        errors.append(f"{where}: must be an object")
        return
    if body.get("tiers") is not None:
        errors.extend(fees.validate_tiers(body["tiers"], where))
    if body.get("percent") is not None and fees.parse_decimal(body["percent"], high=fees.Decimal(100)) is None:
        errors.append(f"{where}: percent must be a number from 0 to 100")
    if body.get("fixed") is not None and fees.parse_decimal(
            body["fixed"], high=fees.Decimal(fees.MAX_AMOUNT_KES)) is None:
        errors.append(f"{where}: fixed must be a non-negative number of shillings")


def _rule_errors(rule: Any, where: str, errors: list[str]) -> None:
    if not isinstance(rule, dict):
        errors.append(f"{where}: must be an object")
        return
    _text(rule.get("label"), f"{where}.label", errors, limit=120)
    if not rule.get("label"):
        errors.append(f"{where}.label: required")
    if rule.get("payer", "not_stated") not in fees.PAYERS:
        errors.append(f"{where}.payer: must be one of {list(fees.PAYERS)}")
    by_destination = rule.get("by_destination")
    if by_destination is not None:
        if not isinstance(by_destination, dict) or not by_destination:
            errors.append(f"{where}.by_destination: must be an object keyed by payout destination")
            return
        for key, body in by_destination.items():
            if key not in fees.PAYOUT_DESTINATIONS:
                errors.append(f"{where}.by_destination: unknown destination {key!r}")
            elif body:
                _body_errors(body, f"{where}.by_destination.{key}", errors)
            elif rule.get("documented") is True:
                errors.append(f"{where}.by_destination.{key}: marked documented but has no figures")
        return
    if rule.get("documented") is False:
        return
    _body_errors(rule, where, errors)
    if not any(rule.get(k) is not None for k in ("percent", "fixed", "tiers")):
        errors.append(f"{where}: needs percent, fixed or tiers (or documented=false)")


def validate_record(record: Any, allowlist: Iterable[str]) -> list[str]:
    """Every reason [record] is not acceptable, or [] when it is."""
    errors: list[str] = []
    if not isinstance(record, dict):
        return ["record must be an object"]
    for section in ("identity", "pricing", "conditions", "protection", "trust"):
        if not isinstance(record.get(section), dict):
            errors.append(f"{section}: required object missing")
    if errors:
        return errors

    if not isinstance(record.get("id"), str) or not _ID.match(record["id"]):
        errors.append("id: lower-case letters, digits and underscores, starting with a letter")
    _text(record.get("display_name"), "display_name", errors, limit=60)
    if not record.get("display_name"):
        errors.append("display_name: required")
    if record.get("status") not in STATUSES:
        errors.append(f"status: must be one of {list(STATUSES)}")
    _text(record.get("tagline"), "tagline", errors, limit=100)
    _text(record.get("public_notice"), "public_notice", errors, limit=400)

    identity, pricing = record["identity"], record["pricing"]
    conditions, protection, trust = record["conditions"], record["protection"], record["trust"]

    # ── identity ──
    domain = identity.get("canonical_domain")
    allow = list(allowlist)
    if not is_domain(domain):
        errors.append("identity.canonical_domain: must be a plain lower-case domain such as example.co.ke")
        domain = ""
    elif not domain_allowed(domain, allow):
        errors.append(f"identity.canonical_domain: {domain} is not in this deployment's approved "
                      "provider domains (ESCROW_PROVIDER_DOMAINS)")
    _url(identity.get("website_url"), domain, "identity.website_url", errors, required=True)
    for key in ("terms_url", "privacy_url", "logo_url"):
        _url(identity.get(key), domain, f"identity.{key}", errors)
    _text(identity.get("legal_entity_name"), "identity.legal_entity_name", errors, limit=160)
    _text(identity.get("operator_note"), "identity.operator_note", errors)
    _tri(identity.get("legal_entity_confirmed"), "identity.legal_entity_confirmed", errors)
    if identity.get("legal_entity_confirmed") is True and not identity.get("legal_entity_name"):
        errors.append("identity.legal_entity_confirmed: cannot be true without a legal_entity_name")
    email = identity.get("contact_email")
    if email is not None and (not isinstance(email, str) or not _EMAIL.match(email)):
        errors.append("identity.contact_email: not a valid email address")
    phone = identity.get("contact_phone")
    if phone is not None and (not isinstance(phone, str) or not _PHONE.match(phone)):
        errors.append("identity.contact_phone: not a valid phone number")
    _subset(identity.get("countries"), COUNTRIES, "identity.countries", errors)
    confusable = identity.get("confusable_with") or []
    if not isinstance(confusable, list):
        errors.append("identity.confusable_with: must be a list")
    else:
        for i, item in enumerate(confusable, 1):
            ok = (isinstance(item, dict) and isinstance(item.get("name"), str) and item["name"]
                  and is_domain(item.get("domain")))
            if not ok:
                errors.append(f"identity.confusable_with[{i}]: needs a name and a plain domain")
                continue
            _text(item.get("name"), f"identity.confusable_with[{i}].name", errors, limit=60)
            _text(item.get("note"), f"identity.confusable_with[{i}].note", errors, limit=200)

    # ── pricing ──
    disclosure = pricing.get("disclosure")
    if disclosure not in fees.DISCLOSURES:
        errors.append(f"pricing.disclosure: must be one of {list(fees.DISCLOSURES)}")
    if pricing.get("currency") != "KES":
        errors.append("pricing.currency: only KES is supported")
    if pricing.get("basis") not in BASES:
        errors.append(f"pricing.basis: must be one of {list(BASES)}")
    _tri(pricing.get("absorbs_mpesa_fees"), "pricing.absorbs_mpesa_fees", errors)
    _tri(pricing.get("additional_fees_may_apply"), "pricing.additional_fees_may_apply", errors)
    for key in ("source_url", "quote_url"):
        _url(pricing.get(key), domain, f"pricing.{key}", errors)
    _text(pricing.get("public_note"), "pricing.public_note", errors)
    if pricing.get("last_verified") is not None and parse_date(pricing["last_verified"]) is None:
        errors.append("pricing.last_verified: must be a date such as 2026-11-16")

    commission = pricing.get("commission")
    if commission is not None:
        _rule_errors(commission, "pricing.commission", errors)
    for group in ("processing_fees", "payout_fees"):
        rules = pricing.get(group)
        if not isinstance(rules, list):
            errors.append(f"pricing.{group}: must be a list")
            continue
        for i, rule in enumerate(rules, 1):
            _rule_errors(rule, f"pricing.{group}[{i}]", errors)

    carries_figures = bool(commission) or bool(pricing.get("processing_fees")) or bool(pricing.get("payout_fees"))
    if disclosure in ("quote_required", "not_disclosed", "under_review") and carries_figures:
        errors.append(f"pricing: disclosure {disclosure!r} must not carry fee figures (a number beside "
                      "'no fee published' reads as the fee)")
    if disclosure in fees.CALCULABLE_DISCLOSURES:
        if not commission:
            errors.append(f"pricing.commission: required when disclosure is {disclosure!r}")
        elif disclosure == "published_tiered" and not commission.get("tiers"):
            errors.append("pricing.commission.tiers: required for published_tiered")
        elif disclosure == "published_percentage" and commission.get("percent") is None:
            errors.append("pricing.commission.percent: required for published_percentage")
        elif disclosure == "published_fixed" and commission.get("fixed") is None:
            errors.append("pricing.commission.fixed: required for published_fixed")
        if not pricing.get("source_url"):
            errors.append("pricing.source_url: a published fee needs the page it was read from")

    # ── conditions ──
    low, high = conditions.get("min_amount"), conditions.get("max_amount")
    for key, value in (("min_amount", low), ("max_amount", high)):
        if value is not None and not (isinstance(value, int) and not isinstance(value, bool) and value >= 0):
            errors.append(f"conditions.{key}: must be a whole number of shillings, or null")
    if isinstance(low, int) and isinstance(high, int) and low > high:
        errors.append("conditions: min_amount is above max_amount")
    if conditions.get("amount_basis") not in BASES:
        errors.append(f"conditions.amount_basis: must be one of {list(BASES)}")
    _subset(conditions.get("payment_methods"), PAYMENT_METHODS, "conditions.payment_methods", errors)
    _subset(conditions.get("payout_methods"), PAYOUT_METHODS, "conditions.payout_methods", errors)
    _subset(conditions.get("categories"), CATEGORIES, "conditions.categories", errors)
    _subset(conditions.get("regions"), COUNTRIES, "conditions.regions", errors)
    _tri(conditions.get("registration_required"), "conditions.registration_required", errors)
    _tri(conditions.get("kyc_required"), "conditions.kyc_required", errors)
    other = conditions.get("other")
    if not isinstance(other, list) or not all(isinstance(x, str) for x in other):
        errors.append("conditions.other: must be a list of text lines")
    else:
        for i, line in enumerate(other, 1):
            _text(line, f"conditions.other[{i}]", errors, limit=240)
    # The tier table must cover exactly the limits the record advertises.
    tiers = (commission or {}).get("tiers") if isinstance(commission, dict) else None
    if tiers and not fees.validate_tiers(tiers, "x"):
        if isinstance(low, int) and tiers[0]["min"] != low:
            errors.append(f"pricing.commission.tiers: first band starts at {tiers[0]['min']} but the "
                          f"minimum amount is {low}")
        if isinstance(high, int) and tiers[-1]["max"] != high:
            errors.append(f"pricing.commission.tiers: last band ends at {tiers[-1]['max']} but the "
                          f"maximum amount is {high}")

    # ── protection ──
    for key, value in protection.items():
        if key == "auto_release":
            if not isinstance(value, dict):
                errors.append("protection.auto_release: must be an object")
                continue
            _tri(value.get("can_occur"), "protection.auto_release.can_occur", errors)
            _text(value.get("description"), "protection.auto_release.description", errors)
        elif key == "notable_terms":
            if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
                errors.append("protection.notable_terms: must be a list of text lines")
            else:
                for i, line in enumerate(value, 1):
                    _text(line, f"protection.notable_terms[{i}]", errors, limit=240)
        else:
            _text(value, f"protection.{key}", errors)

    # ── trust ──
    for key, states in (("identity_verification", IDENTITY_STATES), ("terms_review", REVIEW_STATES),
                        ("pricing_review", REVIEW_STATES), ("operational_test", OPERATIONAL_STATES)):
        if trust.get(key) not in states:
            errors.append(f"trust.{key}: must be one of {list(states)}")
    for key in ("last_verified", "next_review"):
        if trust.get(key) is not None and parse_date(trust[key]) is None:
            errors.append(f"trust.{key}: must be a date such as 2026-11-16")
    _text(trust.get("internal_notes"), "trust.internal_notes", errors, limit=MAX_NOTES)
    _text(trust.get("reviewed_by"), "trust.reviewed_by", errors, limit=80)
    sources = trust.get("sources")
    if not isinstance(sources, list):
        errors.append("trust.sources: must be a list")
    else:
        for i, source in enumerate(sources, 1):
            if not isinstance(source, dict) or not source.get("label"):
                errors.append(f"trust.sources[{i}]: needs a label and a url")
                continue
            _text(source.get("label"), f"trust.sources[{i}].label", errors, limit=80)
            _url(source.get("url"), domain, f"trust.sources[{i}].url", errors, required=True)

    # The provider's own domain must not be the domain of one it is "confused with".
    for item in confusable if isinstance(confusable, list) else []:
        if isinstance(item, dict) and item.get("domain") == domain:
            errors.append("identity.confusable_with: a provider cannot be confused with itself")
    return errors


# ── Approval gate ────────────────────────────────────────────────────────

def approval_blockers(record: dict) -> list[str]:
    """Why [record] cannot be made `approved` yet, or [] when it can.

    "Approved" is what lets BROKA say a provider has been reviewed, and be
    included in a ranking. It needs every check done and dated, and the
    provider's own statement of who it is. Nothing here can be waived."""
    trust, pricing, identity = record["trust"], record["pricing"], record["identity"]
    blockers: list[str] = []
    if trust.get("identity_verification") != "verified":
        blockers.append("identity has not been verified")
    if not identity.get("legal_entity_name") or identity.get("legal_entity_confirmed") is not True:
        blockers.append("the legal entity responsible for the escrow transaction is not confirmed")
    if trust.get("terms_review") != "verified":
        blockers.append("the provider's terms have not been reviewed")
    if trust.get("pricing_review") != "verified":
        blockers.append("pricing has not been reviewed")
    if parse_date(pricing.get("last_verified")) is None:
        blockers.append("pricing has no verification date")
    if trust.get("operational_test") != "passed":
        blockers.append("no operational test has passed")
    if parse_date(trust.get("last_verified")) is None:
        blockers.append("the record has no verification date")
    if parse_date(trust.get("next_review")) is None:
        blockers.append("no next review date is set")
    if not trust.get("sources"):
        blockers.append("no source references are recorded")
    if not identity.get("terms_url"):
        blockers.append("the provider's terms URL is missing")
    if not identity.get("privacy_url"):
        blockers.append("the provider's privacy policy URL is missing")
    return blockers


# Status moves an administrator may make. Never suspended -> approved: a
# provider that was taken off the list comes back through review, not by a
# single click.
_TRANSITIONS = {
    "draft": ("under_review", "rejected"),
    "under_review": ("approved", "rejected", "suspended"),
    "approved": ("under_review", "suspended"),
    "suspended": ("under_review", "rejected"),
    "rejected": ("under_review",),
}


def transition_error(current: str, target: str) -> Optional[str]:
    if target not in STATUSES:
        return f"unknown status {target!r}"
    if target == current:
        return f"already {current}"
    if target not in _TRANSITIONS.get(current, ()):
        return f"a provider cannot move from {current} to {target}"
    return None


# ── Changing a record ────────────────────────────────────────────────────

def merge_patch(base: dict, patch: dict) -> dict:
    """[base] with [patch] applied: objects merge key by key, anything else
    (a list, a number, text, null) replaces. Null clears a field."""
    out = copy.deepcopy(base)

    def apply(target: dict, changes: dict) -> None:
        for key, value in changes.items():
            if isinstance(value, dict) and isinstance(target.get(key), dict) and key not in (
                    "commission", "by_destination"):
                apply(target[key], value)
            else:
                target[key] = copy.deepcopy(value)
    apply(out, patch)
    return out


def _paths(value: Any, prefix: str = "") -> list[str]:
    paths: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            here = f"{prefix}.{key}" if prefix else key
            paths.append(here)
            paths.extend(_paths(child, here))
    return paths


def protected_paths_in(patch: dict) -> list[str]:
    """The protected fields [patch] tries to set."""
    return sorted(p for p in _paths(patch) if p in PROTECTED_PATHS)


_COSMETIC = {"display_name", "tagline", "public_notice"}


def changed_areas(before: dict, after: dict) -> set[str]:
    """Which kinds of fact differ: "pricing", "identity", "terms" (limits,
    conditions, protection, sources, contacts) or "cosmetic". What changed
    decides which earlier check no longer stands."""
    areas: set[str] = set()

    def differs(a: Any, b: Any) -> bool:
        return a != b

    pricing_keys = {k for k in set(before["pricing"]) | set(after["pricing"])
                    if k not in ("public_note", "last_verified")}
    if any(differs(before["pricing"].get(k), after["pricing"].get(k)) for k in pricing_keys):
        areas.add("pricing")
    identity_keys = {"legal_entity_name", "legal_entity_confirmed", "canonical_domain", "website_url"}
    if any(differs(before["identity"].get(k), after["identity"].get(k)) for k in identity_keys):
        areas.add("identity")
    other_identity = set(before["identity"]) | set(after["identity"])
    if any(differs(before["identity"].get(k), after["identity"].get(k))
           for k in other_identity - identity_keys):
        areas.add("terms")
    if differs(before["conditions"], after["conditions"]) or differs(before["protection"], after["protection"]):
        areas.add("terms")
    if differs(before["trust"].get("sources"), after["trust"].get("sources")):
        areas.add("terms")
    if any(differs(before.get(k), after.get(k)) for k in _COSMETIC):
        areas.add("cosmetic")
    return areas


def apply_edit_consequences(before: dict, after: dict) -> tuple[dict, list[str]]:
    """[after], with the checks that no longer stand cleared, and what was cleared.

    Changed pricing clears the pricing check and its date; changed identity
    clears the identity check; changed terms/conditions/protection clears
    the terms check; any of these clears the record's verification date and
    drops an `approved` provider back to `under_review`. A provider is
    never shown as verified for text nobody verified."""
    out = copy.deepcopy(after)
    areas = changed_areas(before, after)
    cleared: list[str] = []
    if "pricing" in areas:
        out["pricing"]["last_verified"] = None
        out["trust"]["pricing_review"] = "pending"
        cleared.append("pricing review")
    if "identity" in areas:
        out["trust"]["identity_verification"] = "pending"
        cleared.append("identity verification")
    if "terms" in areas:
        out["trust"]["terms_review"] = "pending"
        cleared.append("terms review")
    if areas & {"pricing", "identity", "terms"}:
        out["trust"]["last_verified"] = None
        if out["status"] == "approved":
            out["status"] = "under_review"
            cleared.append("approval (back to under review)")
    return out, cleared
