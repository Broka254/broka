"""
BROKA - Reconciliation alerts
─────────────────────────────────────────────────────────────────────────────
Money in a state the code will not resolve on its own: a payment that landed
on a cancelled deal, an E-Confirm deal a chat button or timer was not allowed
to settle, a provider answer nobody can interpret. Each of those sites writes
its own durable record (an audit row, an ExternalEscrow status) - this module
is how a PERSON finds out, by raising a Sentry event.

WHY NOT JUST logger.error
=========================
Sentry's default logging integration already turned those ERROR lines into
events, but grouped by message template - so every "RECONCILIATION_REQUIRED
deal=%s" from every site landed in ONE issue. The first ever notified
someone; every later one, for a different deal and different money, was an
extra count on an issue already marked seen. Here each (kind, deal) pair is
its own issue, so a new deal needing attention is a new alert, while the
same deal re-detected by a sweep every few minutes stays one issue.

WHY NOT AN EVENT SUBSCRIBER
===========================
The alert is raised where the condition is detected, in that process, rather
than from a subscriber to EConfirmReconciliationRequired. Some of these
conditions are not E-Confirm events at all (a legacy M-Pesa payment), and a
subscriber would depend on event-bus delivery - the legacy bus only runs
in-process handlers without Redis, and a fan-out consumer on several web
instances would report each alert once per instance. Call sites that
already publish EConfirmReconciliationRequired keep doing so for any other
consumer.

REPEATS
=======
A stuck condition is re-detected on every reconciliation pass (the sweep,
plus every payment-status poll from the app). Each (kind, deal) is sent to
Sentry at most once per REPEAT_COOLDOWN_SECONDS per process: the issue stays
open and keeps getting a periodic reminder, without spending the event quota
on one deal every few minutes. The log line is written every time.

LEVELS
======
  error    a person must act - nothing in the system will fix this
  warning  expected to self-resolve through reconciliation (an ambiguous
           provider timeout, say); surfaced so a stuck one gets noticed

Without SENTRY_DSN, sentry_sdk is uninitialised and capture is a no-op; the
log line below is then the alert, as it always was.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Any, Optional

# A dedicated logger that Sentry's logging integration ignores (below), so
# every alert reaches Sentry exactly once - as the structured event built in
# report_reconciliation - instead of also as a generic ERROR-log event
# grouped with unrelated errors. The line still goes to normal log output.
ALERT_LOGGER_NAME = "broka.reconciliation"
alert_logger = logging.getLogger(ALERT_LOGGER_NAME)

try:  # pragma: no cover - exercised whenever sentry-sdk is installed
    from sentry_sdk.integrations.logging import ignore_logger as _ignore_logger
    _ignore_logger(ALERT_LOGGER_NAME)
except ImportError:  # pragma: no cover
    pass

_LEVELS = {"error": logging.ERROR, "warning": logging.WARNING}

REPEAT_COOLDOWN_SECONDS = 3600
_MAX_TRACKED = 10_000
_last_sent: dict[tuple[str, str], float] = {}
_last_sent_lock = threading.Lock()


def _should_send(kind: str, deal_id: Optional[str]) -> bool:
    """True unless this (kind, deal) reached Sentry within the cooldown."""
    key = (kind, deal_id or "")
    now = time.monotonic()
    with _last_sent_lock:
        last = _last_sent.get(key)
        if last is not None and now - last < REPEAT_COOLDOWN_SECONDS:
            return False
        if len(_last_sent) >= _MAX_TRACKED:
            # Forget everything past its cooldown; if that is still too many,
            # start over - an occasional extra event beats unbounded memory.
            for k in [k for k, t in _last_sent.items() if now - t >= REPEAT_COOLDOWN_SECONDS]:
                del _last_sent[k]
            if len(_last_sent) >= _MAX_TRACKED:
                _last_sent.clear()
        _last_sent[key] = now
        return True


def report_reconciliation(
    kind: str,
    *,
    deal_id: Optional[str],
    reason: str,
    level: str = "error",
    provider_transaction_id: Optional[str] = None,
    **context: Any,
) -> None:
    """Tell a person that a deal's money needs manual reconciliation.

    `kind` is a stable machine name (it becomes the Sentry grouping key and
    a searchable tag), e.g. "econfirm_funded_on_inactive_deal". `reason` is
    the human sentence. Extra keyword arguments are attached as context -
    never pass a phone number, email or other personal data here.

    Never raises: an alerting failure must not break the money path that
    detected the problem, which has already recorded it durably.
    """
    if level not in _LEVELS:
        level = "error"

    alert_logger.log(
        _LEVELS[level],
        "[reconciliation] %s deal=%s tx=%s: %s",
        kind, deal_id, provider_transaction_id or "-", reason,
    )

    if not _should_send(kind, deal_id):
        return

    try:
        import sentry_sdk
    except ImportError:  # pragma: no cover
        return

    try:
        with sentry_sdk.new_scope() as scope:
            scope.set_level(level)
            scope.set_tag("alert", "reconciliation")
            scope.set_tag("reconciliation.kind", kind)
            if deal_id:
                scope.set_tag("deal_id", deal_id)
            if provider_transaction_id:
                scope.set_tag("provider_transaction_id", provider_transaction_id)
            scope.set_context("reconciliation", {
                "kind": kind,
                "deal_id": deal_id,
                "provider_transaction_id": provider_transaction_id,
                "reason": reason,
                **context,
            })
            # One issue per (kind, deal): each new deal needing a person is a
            # new alert; the same deal re-detected by a sweep is not.
            scope.fingerprint = ["reconciliation", kind, deal_id or "no-deal"]
            sentry_sdk.capture_message(f"Reconciliation required: {kind}", level=level)
    except Exception:
        alert_logger.exception("[reconciliation] failed to report %s to Sentry", kind)
