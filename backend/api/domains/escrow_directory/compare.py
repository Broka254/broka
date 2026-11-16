"""Filtering and ordering providers - and the cases where BROKA will not.

THE RULE: nothing is ranked on a fact that is missing, unverified or old.

  * A provider whose fee is "not disclosed" is not cheaper than one with a
    published fee, and not dearer either: it is not in the ranking. The
    easy bug is `sort by fee, None last` - it puts an unknown fee in a
    position, and a position reads as a verdict.
  * A "lowest total fee" is claimed only when at least two providers have a
    COMPARABLE estimate: every charge calculated (including payout charges),
    the provider's own statement that no other fees apply, pricing verified
    by BROKA and not out of date, and the provider approved. With fewer, the
    answer is "not enough comparable information", with the reason for each.
  * "Highest permitted amount" orders only providers that publish a maximum;
    the rest are listed after, marked "limit not published".
  * A filter on a fact the record does not have EXCLUDES the provider and
    says why ("requirement not documented"). An unknown is not a yes.

Pure functions over records and estimates; the router only supplies them.
"""
from __future__ import annotations

from typing import Optional

SORTS = ("name", "lowest_fee", "highest_limit")

# Filter codes -> what the record must say. Tri-state fields: True / False
# match; None (not documented) never matches.
NO_ACCOUNT = "no_account"
KYC_REQUIRED = "kyc_required"
KYC_NOT_REQUIRED = "kyc_not_required"
DOCUMENTED_DISPUTES = "documented_disputes"
DOCUMENTED_REFUNDS = "documented_refunds"


def _supports_amount(record: dict, amount: Optional[int]) -> tuple[bool, str]:
    if amount is None:
        return True, ""
    c = record["conditions"]
    low, high = c.get("min_amount"), c.get("max_amount")
    if isinstance(low, int) and amount < low:
        return False, f"takes amounts from KSh {low:,}"
    if isinstance(high, int) and amount > high:
        return False, f"takes amounts up to KSh {high:,}"
    if low is None and high is None:
        return True, "limits not published"
    return True, ""


def matches(record: dict, criteria: dict) -> tuple[bool, str]:
    """Whether [record] meets [criteria]; if not, the plain reason."""
    c, p = record["conditions"], record["protection"]
    amount = criteria.get("amount")
    ok, why = _supports_amount(record, amount)
    if not ok:
        return False, why

    if criteria.get(NO_ACCOUNT):
        if c.get("registration_required") is None:
            return False, "whether an account is needed is not documented"
        if c["registration_required"] is True:
            return False, "needs an account"
    kyc = criteria.get("kyc")
    if kyc in ("required", "not_required"):
        if c.get("kyc_required") is None:
            return False, "ID-check requirement is not documented"
        if (kyc == "required") != c["kyc_required"]:
            return False, "has the opposite ID-check requirement"
    method = criteria.get("payment_method")
    if method:
        methods = c.get("payment_methods")
        if methods is None:
            return False, "payment methods are not documented"
        accepted = {m for m in methods}
        if method == "mpesa":
            accepted = {m for m in accepted if m.startswith("mpesa")}
        elif method not in accepted:
            accepted = set()
        if not accepted:
            return False, f"does not list {method} as a payment method"
    category = criteria.get("category")
    if category:
        categories = c.get("categories")
        if categories is None:
            return False, "supported transaction types are not documented"
        if category not in categories:
            return False, "does not list this type of transaction"
    if criteria.get(DOCUMENTED_DISPUTES) and not (p.get("dispute_initiation") or p.get("dispute_timeframe")):
        return False, "dispute process is not documented"
    if criteria.get(DOCUMENTED_REFUNDS) and not p.get("refund_conditions"):
        return False, "refund conditions are not documented"
    return True, ""


def filter_providers(records: list[dict], criteria: dict) -> tuple[list[dict], list[dict]]:
    """(matching records, [{id, name, reason}] for the rest). Order kept."""
    kept: list[dict] = []
    excluded: list[dict] = []
    for record in records:
        ok, reason = matches(record, criteria)
        if ok:
            kept.append(record)
        else:
            excluded.append({"id": record["id"], "name": record["display_name"], "reason": reason})
    return kept, excluded


def rank_by_fee(entries: list[dict]) -> dict:
    """Order [entries] ({"id", "name", "estimate", "approved"}) by total fee.

    Returns {"claim_allowed", "ranked", "not_ranked", "headline"}. Ranked
    only when two or more are comparable; ties keep their order and share a
    position (cheaper by KSh 0 is not cheaper)."""
    eligible, rest = [], []
    for entry in entries:
        est = entry["estimate"]
        reason = est.get("not_comparable_reason")
        if est.get("comparable") and entry.get("approved"):
            eligible.append(entry)
        else:
            if est.get("comparable") and not entry.get("approved"):
                reason = "the provider has not completed BROKA's review"
            rest.append({"id": entry["id"], "name": entry["name"],
                         "reason": reason or "no comparable estimate"})
    eligible.sort(key=lambda e: (e["estimate"]["total_buyer_payment"], e["name"].lower()))
    if len(eligible) < 2:
        return {"claim_allowed": False, "ranked": [], "not_ranked": rest + [
            {"id": e["id"], "name": e["name"], "reason": "no other provider has a comparable estimate"}
            for e in eligible],
            "headline": ("Not enough comparable, verified pricing to say which provider costs least. "
                         "Each provider's own figures are shown below.")}
    ranked, position, previous = [], 0, None
    for index, entry in enumerate(eligible, 1):
        total = entry["estimate"]["total_buyer_payment"]
        if total != previous:
            position, previous = index, total
        ranked.append({"id": entry["id"], "name": entry["name"], "position": position,
                       "total_buyer_payment": total, "total_fees": entry["estimate"]["total_fees"]})
    top = [r for r in ranked if r["position"] == 1]
    names = " and ".join(r["name"] for r in top)
    headline = (f"Lowest estimated total among providers with verified, complete pricing: {names}. "
                "Other providers are not ranked because their fees are unpublished, incomplete or "
                "unverified.") if rest else (
        f"Lowest estimated total: {names}.")
    return {"claim_allowed": True, "ranked": ranked, "not_ranked": rest, "headline": headline}


def order_by_limit(records: list[dict]) -> list[dict]:
    """Highest published maximum first; providers with none follow, in order."""
    with_max = [r for r in records if isinstance(r["conditions"].get("max_amount"), int)]
    without = [r for r in records if not isinstance(r["conditions"].get("max_amount"), int)]
    with_max.sort(key=lambda r: (-r["conditions"]["max_amount"], r["display_name"].lower()))
    return with_max + sorted(without, key=lambda r: r["display_name"].lower())


def order(records: list[dict], sort: str, ranking: Optional[dict]) -> list[dict]:
    """[records] in the order a screen shows them.

    "lowest_fee" puts ranked providers first in their ranked order and the
    unranked after, alphabetical - and the response says they are unranked;
    the list order alone must never imply a verdict, so the screen reads
    `ranking`, not the position."""
    if sort == "highest_limit":
        return order_by_limit(records)
    if sort == "lowest_fee" and ranking and ranking.get("claim_allowed"):
        position = {r["id"]: r["position"] for r in ranking["ranked"]}
        ranked = sorted((r for r in records if r["id"] in position),
                        key=lambda r: (position[r["id"]], r["display_name"].lower()))
        rest = sorted((r for r in records if r["id"] not in position),
                      key=lambda r: r["display_name"].lower())
        return ranked + rest
    return sorted(records, key=lambda r: r["display_name"].lower())
