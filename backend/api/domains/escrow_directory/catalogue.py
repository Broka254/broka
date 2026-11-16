"""The catalogue as the rest of the backend reads it.

THE RECORDS. The code ships a starting set (seed.py); an administrator's
edits live in the database (repository.py). A provider's database row, when
it exists, replaces the seed's record of the same id; a seed provider with
no row is served as shipped. So a reviewed record is never overwritten by a
release, and a provider added to the seed appears (as under review) with
the next deploy.

THE SNAPSHOT. Zeno's walkthrough is synchronous and so is the router's
"is this turn free?" check, so neither can await a database read. A
snapshot of the merged records is kept in the process and refreshed on a
short clock (SNAPSHOT_SECONDS); an admin's suspension refreshes the process
that handled it at once and every other replica within that clock. Until
the first refresh, and if the database cannot be read, the snapshot is the
seed - which carries no approval and no verification date, so a database
outage makes the list less trusted, never more.

NOTHING HERE FETCHES A PROVIDER'S WEBSITE. Fees change only when a named
administrator records a change with its source (repository.py); there is
no code path from the internet into a fee.
"""
from __future__ import annotations

import copy
import time
from datetime import date
from typing import Awaitable, Callable, Iterable, Optional

from . import compare, fees, freshness, projection, schema, seed

SNAPSHOT_SECONDS = 30

Loader = Callable[[], Awaitable[list[dict]]]

_state: dict = {"records": None, "loaded_at": 0.0}


def merge(seed_records: Iterable[dict], stored: Iterable[dict]) -> list[dict]:
    """Seed records, with any stored record of the same id replacing it,
    then stored records the seed does not have. Order: seed order first."""
    by_id = {r["id"]: r for r in stored}
    out = [copy.deepcopy(by_id.pop(r["id"], r)) for r in seed_records]
    out.extend(copy.deepcopy(r) for r in by_id.values())
    return out


def reset() -> None:
    """Forget the snapshot (tests, and after an admin change)."""
    _state["records"] = None
    _state["loaded_at"] = 0.0


def prime(records: list[dict]) -> None:
    """Install [records] as the snapshot now."""
    _state["records"] = copy.deepcopy(records)
    _state["loaded_at"] = time.monotonic()


def current_records() -> list[dict]:
    """The last known records, without waiting for anything. The seed until
    something has been loaded."""
    records = _state["records"]
    return copy.deepcopy(records if records is not None else seed.records())


async def refresh(loader: Optional[Loader], *, force: bool = False) -> list[dict]:
    """The snapshot, reloaded through [loader] when it is older than
    SNAPSHOT_SECONDS (or [force]). A loader that fails leaves the previous
    snapshot in place."""
    age = time.monotonic() - _state["loaded_at"]
    if loader is not None and (force or _state["records"] is None or age >= SNAPSHOT_SECONDS):
        try:
            prime(merge(seed.records(), await loader()))
        except Exception:  # noqa: BLE001 - serve the last good copy, never fail a user's turn
            if _state["records"] is None:
                prime(seed.records())
    return current_records()


# ── Who is shown to whom ─────────────────────────────────────────────────

def listed(records: Iterable[dict]) -> list[dict]:
    """Providers people may be shown: approved, or under review (labelled)."""
    return [r for r in records if r["status"] in schema.LISTED_STATUSES]


def unlisted_notices(records: Iterable[dict]) -> list[dict]:
    """Providers BROKA does not list that have a public notice to give
    (the name-confusion warning), and only those."""
    return [projection.notice_view(r) for r in records
            if r["status"] not in schema.LISTED_STATUSES and r.get("public_notice")]


def find_by_name_or_domain(records: Iterable[dict], text: str) -> Optional[dict]:
    """The record a user's words name, listed or not, by exact name or domain.
    Used so a suspended provider is recognised ("walk me through escrow
    kenya") and answered, not silently swapped for a similarly named one."""
    t = (text or "").strip().lower()
    for r in records:
        if t in (r["display_name"].lower(), r["identity"]["canonical_domain"], r["id"]):
            return r
    return None


# ── The public responses ─────────────────────────────────────────────────

def _today(now: object) -> date:
    return freshness.as_date(now)


def public_catalogue(records: list[dict], now: object, **ages) -> dict:
    """GET /escrow-providers."""
    shown = listed(records)
    return {
        "as_of": _today(now).isoformat(),
        "providers": [projection.public_view(r, now, **ages) for r in shown],
        "notices": unlisted_notices(records),
        "disclosures": projection.disclosures_view(),
    }


def build_criteria(*, amount: Optional[int] = None, payout: Optional[str] = None, **filters) -> dict:
    criteria = {k: v for k, v in filters.items() if v not in (None, False, "")}
    if amount is not None:
        criteria["amount"] = amount
    if payout is not None:
        criteria["payout"] = payout
    return criteria


def compare_providers(records: list[dict], now: object, *, amount: Optional[int] = None,
                      payout: Optional[str] = None, sort: str = "name", criteria: Optional[dict] = None,
                      **ages) -> dict:
    """GET /escrow-providers/compare: filters, estimates, ranking, one answer.

    [criteria] filters (compare.matches); [amount] is also the calculator's
    "seller should receive" and filters out providers that will not take it.
    """
    criteria = dict(criteria or {})
    if amount is not None:
        criteria["amount"] = amount
    shown = listed(records)
    kept, excluded = compare.filter_providers(shown, criteria)

    estimates: dict[str, dict] = {}
    entries = []
    if amount is not None:
        for r in kept:
            state = freshness.evaluate(r, now, **{k: v for k, v in ages.items()
                                                  if k in ("pricing_max_age_days", "record_max_age_days")})
            est = fees.estimate(r, amount, payout_destination=payout, freshness=state["pricing"])
            estimates[r["id"]] = est
            entries.append({"id": r["id"], "name": r["display_name"], "estimate": est,
                            "approved": r["status"] == "approved"})
    ranking = compare.rank_by_fee(entries) if amount is not None else None
    if sort not in compare.SORTS:
        sort = "name"
    ordered = compare.order(kept, sort, ranking)

    results = []
    for r in ordered:
        view = projection.public_view(r, now, **ages)
        if r["id"] in estimates:
            view["estimate"] = estimates[r["id"]]
        results.append(view)
    return {
        "as_of": _today(now).isoformat(),
        "query": {"amount": amount, "payout": payout, "sort": sort,
                  "filters": {k: v for k, v in criteria.items() if k != "amount"}},
        "results": results,
        "excluded": excluded,
        "ranking": ranking,
        "notices": unlisted_notices(records),
        "disclosures": projection.disclosures_view(),
        "estimate_note": ("Estimates assume the buyer pays every charge on top of the amount the "
                          "seller should receive. " + "The quotation on the provider's own checkout "
                          "is the amount you actually pay."),
    }
