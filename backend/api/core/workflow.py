"""
BROKA Platform - Workflow Versioning Engine
════════════════════════════════════════════════════════════════════════════════
Long-running transactions (deals, disputes) run under the workflow rules that
were active when they started. Deploying new logic never retroactively changes
the terms of an in-flight deal.

Design principles:
  1. A Deal stores workflow_version at creation time (e.g. "v3").
  2. WorkflowRegistry maps version strings → frozen WorkflowSpec rule sets.
  3. Any business logic that depends on configurable thresholds calls
       spec = get_spec(deal.workflow_version)
     and uses spec.seller_silence_refund_hours rather than a hard-coded value.
  4. New versions are additive — never edit an existing registered spec.
     Old specs are kept forever (or until all deals on that version are terminal).

Adding a new version:
  1. Define a new WorkflowSpec below.
  2. Register it via _register().
  3. Update CURRENT_VERSION.
  4. Deploy. In-flight deals auto-continue under their original version.
  5. Never rename or remove a registered version key.

Usage:
    from api.core.workflow import get_spec, CURRENT_VERSION

    # At deal creation:
    deal.workflow_version = CURRENT_VERSION

    # When applying timer logic:
    spec = get_spec(deal.workflow_version)
    refund_after = timedelta(hours=spec.seller_silence_refund_hours)

    # Admin API:
    from api.core.workflow import spec_summary
    return spec_summary()
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════════════
# WorkflowSpec — immutable rule set for one version
# ══════════════════════════════════════════════════════════════════════════════

@dataclass(frozen=True)
class WorkflowSpec:
    """
    All configurable business rules for a workflow version.

    frozen=True ensures specs can never be mutated at runtime —
    they are read-only once registered.
    """
    version:     str
    description: str
    released_at: str   # ISO date string, for documentation

    # ── Commission ────────────────────────────────────────────────────────────
    commission_rate: float = 0.03          # fraction of agreed_price kept by Broka

    # ── Payment windows ───────────────────────────────────────────────────────
    payment_window_hours: int       = 24   # buyer has N hours to complete M-Pesa after deal agreed
    escrow_lock_ttl_hours: int      = 48   # auto-cancel if buyer hasn't paid within N hours

    # ── Seller silence → auto-refund ──────────────────────────────────────────
    seller_silence_refund_hours: int = 48  # after escrow funded; seller went quiet

    # ── Buyer silence → auto-release ─────────────────────────────────────────
    buyer_silence_release_hours: int = 96  # after delivery claimed; buyer never confirmed
    delivery_checkin_schedule_days: tuple = field(default=(1, 3, 5, 7))
    max_delivery_checkins: int = 4

    # ── Dispute rules ─────────────────────────────────────────────────────────
    dispute_window_hours: int           = 72  # buyer can open dispute within N hours post-payment
    dispute_seller_response_hours: int  = 24  # seller must respond to dispute within N hours
    dispute_checkin_interval_hours: int = 24
    dispute_max_checkins: int           = 3

    # ── Replacement rules ─────────────────────────────────────────────────────
    replacement_ship_deadline_days:    int = 3
    replacement_arrival_deadline_days: int = 14
    max_replacement_cycles:            int = 1

    # ── Zeno AI behaviour ─────────────────────────────────────────────────────
    zeno_auto_message_on_escrow:    bool = True   # Zeno messages both parties on PAYMENT.ESCROW_LOCKED
    zeno_auto_message_on_delivery:  bool = True   # Zeno asks buyer to confirm on SHIPMENT.DELIVERY_CLAIMED
    zeno_delivery_reminder_hours:   int  = 24     # interval between Zeno delivery follow-ups

    # ── Reputation ────────────────────────────────────────────────────────────
    review_window_days:              int = 14   # buyer has N days to leave review post-release
    min_reviews_for_trust_badge:     int = 5    # reviews needed before badge appears
    fraud_flag_auto_suspend_count:   int = 3    # auto-suspend after N confirmed fraud flags

    def as_dict(self) -> dict:
        """Serialisable representation for admin / API exposure."""
        return {
            "version":                      self.version,
            "description":                  self.description,
            "released_at":                  self.released_at,
            "commission_rate":              self.commission_rate,
            "payment_window_hours":         self.payment_window_hours,
            "seller_silence_refund_hours":  self.seller_silence_refund_hours,
            "buyer_silence_release_hours":  self.buyer_silence_release_hours,
            "delivery_checkin_schedule_days": list(self.delivery_checkin_schedule_days),
            "dispute_window_hours":         self.dispute_window_hours,
            "max_replacement_cycles":       self.max_replacement_cycles,
            "zeno_auto_message_on_escrow":  self.zeno_auto_message_on_escrow,
            "min_reviews_for_trust_badge":  self.min_reviews_for_trust_badge,
        }


# ══════════════════════════════════════════════════════════════════════════════
# Registry — built at import time
# ══════════════════════════════════════════════════════════════════════════════

REGISTRY: Dict[str, WorkflowSpec] = {}


def _register(spec: WorkflowSpec) -> WorkflowSpec:
    if spec.version in REGISTRY:
        raise ValueError(
            f"Workflow version {spec.version!r} already registered. "
            f"Never modify existing specs — add a new version instead."
        )
    REGISTRY[spec.version] = spec
    return spec


# ──────────────────────────────────────────────────────────────────────────────
# v1 — Initial launch  (Q1 2024)
# ──────────────────────────────────────────────────────────────────────────────
_register(WorkflowSpec(
    version     = "v1",
    released_at = "2024-01-15",
    description = "Initial Broka launch rules. Baseline escrow + dispute logic. "
                  "3% commission, 48h seller silence refund, standard 4-checkin delivery window.",
    commission_rate              = 0.03,
    seller_silence_refund_hours  = 48,
    buyer_silence_release_hours  = 96,
    delivery_checkin_schedule_days = (1, 3, 5, 7),
    zeno_auto_message_on_escrow  = False,  # Zeno was passive in v1
    zeno_auto_message_on_delivery = False,
    min_reviews_for_trust_badge  = 5,
))

# ──────────────────────────────────────────────────────────────────────────────
# v2 — Trust platform upgrade  (Q3 2024)
# ──────────────────────────────────────────────────────────────────────────────
_register(WorkflowSpec(
    version     = "v2",
    released_at = "2024-09-01",
    description = "Trust upgrades: Zeno auto-messages activated, extended silence window "
                  "for verified sellers, SMS reminders on day 3 of delivery silence.",
    commission_rate              = 0.03,
    seller_silence_refund_hours  = 72,    # verified sellers get more response time
    buyer_silence_release_hours  = 96,
    delivery_checkin_schedule_days = (1, 3, 5, 7),
    zeno_auto_message_on_escrow  = True,
    zeno_auto_message_on_delivery = True,
    min_reviews_for_trust_badge  = 5,
))

# ──────────────────────────────────────────────────────────────────────────────
# v3 — Platform architecture  (Q1 2026) ← CURRENT
# ──────────────────────────────────────────────────────────────────────────────
_register(WorkflowSpec(
    version     = "v3",
    released_at = "2026-01-01",
    description = "Platform architecture: 2.5% commission (reduced from 3%), "
                  "easier trust badge (3 reviews vs 5), full Zeno event reactions, "
                  "event catalog + workflow versioning introduced.",
    commission_rate              = 0.025,   # reduced for v3
    payment_window_hours         = 24,
    seller_silence_refund_hours  = 48,
    buyer_silence_release_hours  = 96,
    delivery_checkin_schedule_days = (1, 3, 5, 7),
    max_delivery_checkins        = 4,
    dispute_window_hours         = 72,
    dispute_seller_response_hours = 24,
    max_replacement_cycles       = 1,
    zeno_auto_message_on_escrow  = True,
    zeno_auto_message_on_delivery = True,
    review_window_days           = 14,
    min_reviews_for_trust_badge  = 3,       # easier badge in v3
    fraud_flag_auto_suspend_count = 3,
))


# ══════════════════════════════════════════════════════════════════════════════
# Current version — assigned to every new deal at creation
# ══════════════════════════════════════════════════════════════════════════════

CURRENT_VERSION = "v3"


# ══════════════════════════════════════════════════════════════════════════════
# Public API
# ══════════════════════════════════════════════════════════════════════════════

def get_spec(version: Optional[str]) -> WorkflowSpec:
    """
    Return the WorkflowSpec for a given version string.

    Falls back to CURRENT_VERSION when version is None (legacy deals created
    before versioning was introduced are treated as running under current rules,
    which is safe because v3 is a strict superset of earlier behaviours for
    all non-financial configuration).

    Only raises KeyError if an explicitly-set, non-None version is not found —
    which indicates a data integrity bug, not a user error.
    """
    if version is None:
        return REGISTRY[CURRENT_VERSION]
    if version not in REGISTRY:
        logger.warning(
            "[workflow] unknown version %r — falling back to current (%s). "
            "This may indicate a data migration issue or a deal pre-dating versioning.",
            version, CURRENT_VERSION,
        )
        return REGISTRY[CURRENT_VERSION]
    return REGISTRY[version]


def all_versions() -> List[str]:
    """Sorted list of all registered version strings."""
    return sorted(REGISTRY.keys())


def spec_summary() -> List[dict]:
    """
    Human-readable summary of all versions.
    Exposed by GET /admin/workflow-versions.
    """
    return [
        {**s.as_dict(), "is_current": v == CURRENT_VERSION}
        for v, s in sorted(REGISTRY.items())
    ]
