"""A record as each reader may see it.

Three readers, three views, and the difference matters:

  public_view   everyone, including a guest on the website. Everything a
                person deciding on a provider needs, with the words already
                written - "Fee not publicly specified - confirm before
                paying", "Not yet verified by BROKA" - so the app and the
                website show the same thing and neither has to decide how to
                phrase a missing fact. NEVER the reviewer, the internal
                notes, or a revision history.
  admin_view    an administrator editing and reviewing: the whole record,
                what is stale, what blocks approval.
  legacy_view   the shape older app builds read from
                GET /pricing/safe-payment (flat strings). Kept so a phone
                that has not updated still shows the live list instead of a
                broken screen - and so the list those phones show is the
                reviewed one, not a copy baked into an old release.

Blank is blank: a None in the record is shown as "Not documented", and the
UI is told which fields those are, so it never dresses a gap up as a fact.
"""
from __future__ import annotations

import copy
from typing import Optional

from . import disclosures, fees, freshness, schema

NOT_DOCUMENTED = "Not documented. Check the provider's own website."

# Fields that are internal in the record and must never reach a public view.
_INTERNAL_TRUST_KEYS = ("internal_notes", "reviewed_by")

REVIEW_LABELS = {
    "approved": "Reviewed by Broka",
    "under_review": "Under review: not yet verified by Broka",
    "suspended": "Not on Broka's list",
    "draft": "Draft",
    "rejected": "Not on Broka's list",
}

FEE_SUMMARY = {
    "quote_required": "Check live quotation in {name} before paying",
    "not_disclosed": "Fee not publicly specified – confirm before paying",
    "under_review": "Pricing under review – confirm before paying",
}


def _label(mapping: dict, codes: Optional[list]) -> Optional[list[str]]:
    return None if codes is None else [mapping.get(c, c) for c in codes]


def _kes(value: Optional[int]) -> Optional[str]:
    return None if value is None else f"KSh {value:,}"


def _yes_no(value: Optional[bool], yes: str, no: str) -> str:
    return yes if value is True else no if value is False else "Not documented"


def limits_summary(conditions: dict) -> str:
    low, high = conditions.get("min_amount"), conditions.get("max_amount")
    basis = conditions.get("amount_basis")
    what = {"seller_receives": "the amount the seller receives",
            "transaction_value": "the transaction value"}.get(basis, "")
    suffix = f" ({what})" if what else ""
    if low is not None and high is not None:
        return f"{_kes(low)} to {_kes(high)}{suffix}"
    if low is not None:
        return f"From {_kes(low)}; maximum not published{suffix}"
    if high is not None:
        return f"Up to {_kes(high)}; minimum not published{suffix}"
    return "Limits not published"


def fee_summary(record: dict) -> str:
    """One line for a card: what is published, and no more."""
    pricing = record["pricing"]
    disclosure = pricing["disclosure"]
    name = record["display_name"]
    if disclosure in FEE_SUMMARY:
        return FEE_SUMMARY[disclosure].format(name=name)
    commission = pricing.get("commission") or {}
    if disclosure == "published_tiered":
        # No percentages quoted here: the first and last band alone ("10%"
        # ... "0.3%") would suggest big amounts cost almost nothing, when
        # each band also carries a fixed charge. The calculator has the
        # whole table; a card says only what shape the fee has.
        tiers = commission.get("tiers") or []
        if tiers:
            return (f"Fee depends on the amount: a percentage plus a fixed charge, in "
                    f"{len(tiers)} published bands. Use the calculator for your amount.")
    if disclosure == "published_percentage":
        percent = fees.parse_decimal(commission.get("percent"))
        # Never let a lone percentage read as the whole fee: if the record
        # has a payout charge, say it is charged on top and separately.
        extra = " The M-Pesa payout reserve is charged separately." if pricing.get("payout_fees") else ""
        if percent is not None:
            return f"Platform commission {fees.plain(percent)}% (published).{extra}"
    if disclosure == "published_fixed":
        fixed = fees.parse_decimal(commission.get("fixed"))
        if fixed is not None:
            return f"Fixed fee KSh {fees.plain(fixed)} per transaction (published)."
    return FEE_SUMMARY["under_review"].format(name=name)


def release_summary(record: dict) -> str:
    p = record["protection"]
    parts = []
    if p.get("release_conditions"):
        parts.append(p["release_conditions"])
    auto = p.get("auto_release") or {}
    if auto.get("can_occur") is True:
        parts.append(auto.get("description") or "Funds can be released automatically.")
    elif auto.get("can_occur") is False:
        parts.append("It says funds are not released automatically.")
    return " ".join(parts) if parts else NOT_DOCUMENTED


def dispute_summary(record: dict) -> str:
    p = record["protection"]
    parts = [p[k] for k in ("dispute_initiation", "dispute_timeframe") if p.get(k)]
    return " ".join(parts) if parts else NOT_DOCUMENTED


def _requirements(conditions: dict) -> str:
    reg = conditions.get("registration_required")
    kyc = conditions.get("kyc_required")
    if reg is False and kyc is None:
        return "No account required. ID checks not documented."
    return (f"{_yes_no(reg, 'Account required', 'No account required')}; "
            f"{_yes_no(kyc, 'ID checks (KYC) required', 'No ID checks required')}")


def _undocumented(record: dict) -> list[str]:
    """Which facts the record does not have - for the UI to say so."""
    c, p, pr = record["conditions"], record["protection"], record["pricing"]
    gaps = []
    if c.get("min_amount") is None:
        gaps.append("minimum_amount")
    if c.get("max_amount") is None:
        gaps.append("maximum_amount")
    if c.get("registration_required") is None:
        gaps.append("registration")
    if c.get("kyc_required") is None:
        gaps.append("kyc")
    if c.get("categories") is None:
        gaps.append("categories")
    if c.get("payout_methods") is None:
        gaps.append("payout_methods")
    for key in ("how_funds_are_held", "release_conditions", "dispute_initiation", "dispute_timeframe",
                "refund_conditions", "cancellation_policy", "seller_protection", "buyer_protection",
                "evidence_required", "confirmation_window"):
        if not p.get(key):
            gaps.append(key)
    if pr.get("additional_fees_may_apply") is None:
        gaps.append("additional_fees")
    return gaps


def _identity_public(identity: dict) -> dict:
    out = copy.deepcopy(identity)
    if not identity.get("legal_entity_confirmed"):
        # Show what its terms say, labelled; never as confirmed fact.
        out["legal_entity_label"] = ("Operator named by the provider (not yet verified by Broka)"
                                     if identity.get("legal_entity_name") else
                                     "Legal operator not yet confirmed")
    else:
        out["legal_entity_label"] = "Operator confirmed by Broka"
    return out


def public_view(record: dict, now: object, *, pricing_max_age_days: int = freshness.PRICING_MAX_AGE_DAYS,
                record_max_age_days: int = freshness.RECORD_MAX_AGE_DAYS) -> dict:
    """[record] for any reader. Internal notes and the reviewer never appear."""
    state = freshness.evaluate(record, now, pricing_max_age_days=pricing_max_age_days,
                               record_max_age_days=record_max_age_days)
    conditions, pricing, protection = record["conditions"], record["pricing"], record["protection"]
    trust = {k: v for k, v in record["trust"].items() if k not in _INTERNAL_TRUST_KEYS}
    summary = fee_summary(record)
    return {
        "id": record["id"],
        "name": record["display_name"],
        "tagline": record.get("tagline"),
        "status": record["status"],
        "review_label": REVIEW_LABELS[record["status"]],
        "recommendable": record["status"] == "approved" and state["state"] == freshness.CURRENT,
        "website_url": record["identity"]["website_url"],
        "canonical_domain": record["identity"]["canonical_domain"],
        "identity": _identity_public(record["identity"]),
        "freshness": state,
        "fee_summary": summary,
        "fee_disclosure": pricing["disclosure"],
        "pricing": {k: pricing[k] for k in (
            "disclosure", "currency", "basis", "commission", "processing_fees", "payout_fees",
            "absorbs_mpesa_fees", "additional_fees_may_apply", "source_url", "quote_url",
            "last_verified", "public_note")},
        "conditions": {
            **conditions,
            "payment_method_labels": _label(schema.PAYMENT_METHODS, conditions.get("payment_methods")),
            "payout_method_labels": _label(schema.PAYOUT_METHODS, conditions.get("payout_methods")),
            "category_labels": _label(schema.CATEGORIES, conditions.get("categories")),
            "limits_summary": limits_summary(conditions),
            "requirements_summary": _requirements(conditions),
        },
        "protection": copy.deepcopy(protection),
        "summaries": {
            "fees": summary,
            "limits": limits_summary(conditions),
            "payment_methods": ", ".join(_label(schema.PAYMENT_METHODS, conditions.get("payment_methods")) or [])
            or "Not documented",
            "requirements": _requirements(conditions),
            "release": release_summary(record),
            "disputes": dispute_summary(record),
        },
        "undocumented": _undocumented(record),
        "trust": trust,
        "sources": copy.deepcopy(record["trust"].get("sources") or []),
        "not_to_be_confused_with": copy.deepcopy(record["identity"].get("confusable_with") or []),
        "public_notice": record.get("public_notice"),
    }


def notice_view(record: dict) -> dict:
    """What is said about a provider that is not on the list."""
    return {
        "id": record["id"],
        "name": record["display_name"],
        "status": record["status"],
        "review_label": REVIEW_LABELS[record["status"]],
        "canonical_domain": record["identity"]["canonical_domain"],
        "public_notice": record.get("public_notice"),
    }


def admin_view(record: dict, now: object, *, pricing_max_age_days: int = freshness.PRICING_MAX_AGE_DAYS,
               record_max_age_days: int = freshness.RECORD_MAX_AGE_DAYS) -> dict:
    """The whole record, plus what an administrator needs to act on it."""
    state = freshness.evaluate(record, now, pricing_max_age_days=pricing_max_age_days,
                               record_max_age_days=record_max_age_days)
    return {
        "record": copy.deepcopy(record),
        "freshness": state,
        "approval_blockers": schema.approval_blockers(record),
        "can_be_approved": not schema.approval_blockers(record),
        "listed_publicly": record["status"] in schema.LISTED_STATUSES,
    }


# ── The flat shape older app builds read ─────────────────────────────────

def _sentence(text: Optional[str], fallback: str) -> str:
    text = (text or "").strip()
    return text if text else fallback


def legacy_view(record: dict) -> dict:
    """The keys GET /pricing/safe-payment has always had per provider. Built
    from the structured record, with a plain "check on its site" wherever
    the record has nothing - never from text that was not verified."""
    site = record["identity"]["canonical_domain"]
    c, p = record["conditions"], record["protection"]
    methods = ", ".join(_label(schema.PAYMENT_METHODS, c.get("payment_methods")) or []) or "its own checkout"
    confusable = record["identity"].get("confusable_with") or []
    note_bits = [record.get("tagline") or f"Independent escrow service at {site}."]
    note_bits += [f"Not the same company as {x['name']} ({x['domain']})." for x in confusable]
    check = f"Follow {site}'s own instructions."
    return {
        "id": record["id"],
        "name": record["display_name"],
        "url": record["identity"]["website_url"],
        "note": " ".join(note_bits),
        "tagline": _sentence(record.get("tagline"), f"Independent escrow service at {site}"),
        "best_for": limits_summary(c) if c.get("min_amount") is not None or c.get("max_amount") is not None
        else "See the provider's site for what it handles.",
        "pay": methods,
        "fees": fee_summary(record),
        "limits": limits_summary(c),
        "start": check,
        "release": _sentence(p.get("release_conditions"),
                             f"{site} has its own release step: check how it works on its site."),
        "payout": f"according to {site}'s own rules.",
        "dispute": _sentence(p.get("dispute_initiation"),
                             f"Open a dispute on {site} before any confirmation window ends."),
        "company": record["identity"].get("legal_entity_name") or "",
        "status": record["status"],
        "review_label": REVIEW_LABELS[record["status"]],
        "verified": record["status"] == "approved",
    }


def disclosures_view() -> dict:
    return disclosures.as_dict()
