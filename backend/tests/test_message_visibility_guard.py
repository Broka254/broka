"""Structural guard: no NegotiationMessage read may leak across the audience line.

WHY THIS FILE EXISTS
====================
`NegotiationMessage.recipient_role` decides who is allowed to see a row.
Zeno writes a DIFFERENT message to each side of the same relay, and one
party's copy is private to them - including coaching about what to
counter-offer and how much room the other side probably has.

Enforcing that required every read surface to remember the filter. Over the
project's life there have been at least five such surfaces, and the ones
that forgot were not found by review or by the existing tests:

  * `get_inbox` (both branches) returned whichever copy sorted newest, so a
    SELLER's inbox preview displayed a message Zeno wrote to the BUYER,
    attributed to the buyer by name. It also suppressed the seller's own
    notification, because the row never changed to their copy.
  * `disputes.py` loaded EVERY message on the listing - all buyers, both
    audiences - and fed it to the arbitration model whose written verdict
    both parties read.

`get_history` had the filter from the beginning, and `test_thread_privacy`
covered the AI-context path. Neither helped, because a per-surface test only
protects the surfaces someone thought to write a test for. The failure mode
is not "the filter is wrong", it is "a new query was added and nobody
remembered". That is a structural problem and it needs a structural check.

HOW IT WORKS
============
Every `select(...)` naming NegotiationMessage must do ONE of:

  1. constrain `recipient_role` in the same statement, or
  2. carry an inline `# visibility-ok: <reason>` marker.

A marker is required to state a reason, which is the point: it forces the
author to articulate why this read cannot leak, and leaves that reasoning
next to the code for the next reader. Markers are matched by proximity to
the statement rather than by file:line, so they survive refactors.

Deliberately a static check, not a runtime one. A runtime assertion only
fires on a path someone exercises; this fails at CI on a query nobody has
called yet.
"""
import ast
import pathlib

import pytest

API_ROOT = pathlib.Path(__file__).resolve().parent.parent / "api"
MARKER = "# visibility-ok:"


def _enclosing_statement(tree: ast.AST, target: ast.AST) -> ast.stmt | None:
    """The innermost statement containing `target`.

    Must be the STATEMENT, not the `select(...)` call node. A query reads
    `select(NegotiationMessage).where(...)`, and the `.where()` carrying the
    filter is a separate call wrapping the select - so a window around the
    select node alone sees the table name and none of the constraints, and
    reports every correctly-filtered query as a violation.
    """
    best = None
    for node in ast.walk(tree):
        if not isinstance(node, ast.stmt):
            continue
        lo = node.lineno
        hi = getattr(node, "end_lineno", node.lineno)
        if lo <= target.lineno and getattr(target, "end_lineno", target.lineno) <= hi:
            if best is None or (node.lineno, -(getattr(node, "end_lineno", 0))) >= (
                best.lineno, -(getattr(best, "end_lineno", 0))
            ):
                best = node
    return best


def _statement_source(src_lines: list[str], tree: ast.AST, node: ast.AST) -> str:
    """Whole enclosing statement, plus the two lines above it for a marker."""
    stmt = _enclosing_statement(tree, node) or node
    lo = max(0, stmt.lineno - 3)
    hi = min(len(src_lines), getattr(stmt, "end_lineno", stmt.lineno))
    return "\n".join(src_lines[lo:hi])


def _message_selects() -> list[tuple[pathlib.Path, int, str]]:
    found = []
    for path in sorted(API_ROOT.rglob("*.py")):
        src = path.read_text()
        if "NegotiationMessage" not in src:
            continue
        lines = src.split("\n")
        tree = ast.parse(src)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            fname = getattr(node.func, "attr", getattr(node.func, "id", ""))
            if fname != "select":
                continue
            seg = ast.get_source_segment(src, node) or ""
            if "NegotiationMessage" not in seg:
                continue
            found.append((path, node.lineno, _statement_source(lines, tree, node)))
    return found


def test_message_queries_are_audience_scoped():
    """Every NegotiationMessage read filters recipient_role or says why not."""
    selects = _message_selects()
    assert selects, (
        "found no NegotiationMessage queries at all - the scanner is broken, "
        "not the codebase, and a broken scanner passes silently forever"
    )

    offenders = []
    for path, line, stmt in selects:
        if "recipient_role" in stmt:
            continue
        if MARKER in stmt:
            continue
        offenders.append(f"{path.relative_to(API_ROOT.parent)}:{line}")

    assert not offenders, (
        "These NegotiationMessage queries neither constrain recipient_role nor "
        "carry a justification marker:\n\n  "
        + "\n  ".join(offenders)
        + "\n\nA row's recipient_role decides who may see it. If this query can "
          "reach a user, filter it:\n"
          "    or_(NegotiationMessage.recipient_role.is_(None),\n"
          "        NegotiationMessage.recipient_role == viewer_role)\n\n"
          "If it genuinely cannot leak - it counts rows, reads only ids, or "
          "feeds analytics no user reads - mark it and say why:\n"
          f"    {MARKER} counts only, no content reaches a response\n\n"
          "Do not add the marker to silence this test. The two leaks that "
          "prompted it (get_inbox, dispute arbitration) both looked harmless "
          "at a glance."
    )


def test_visibility_markers_state_a_reason():
    """A marker with no reason after it is just a mute button."""
    bare = []
    for path in sorted(API_ROOT.rglob("*.py")):
        for i, line in enumerate(path.read_text().split("\n"), 1):
            if MARKER not in line:
                continue
            reason = line.split(MARKER, 1)[1].strip()
            if len(reason) < 15:
                bare.append(f"{path.relative_to(API_ROOT.parent)}:{i}")
    assert not bare, (
        "visibility-ok markers must explain why the query cannot leak:\n  "
        + "\n  ".join(bare)
    )


@pytest.mark.parametrize("surface,needle", [
    ("inbox buyer branch",  'NegotiationMessage.recipient_role == "buyer"'),
    ("inbox seller branch", 'NegotiationMessage.recipient_role == "seller"'),
])
def test_inbox_keeps_its_audience_filter(surface, needle):
    """Pins the specific fix, so a refactor cannot quietly drop it.

    The structural test above would still catch its removal, but this names
    the surface that actually leaked and fails with a message that says so.
    """
    src = (API_ROOT / "routers" / "negotiate.py").read_text()
    assert needle in src, (
        f"get_inbox lost its {surface} recipient filter. This is the exact "
        f"query that showed a seller a message Zeno had written to the buyer."
    )


def test_dispute_arbitration_is_scoped_to_one_buyer():
    """The arbitration context must not span buyers.

    A listing keeps one thread per interested buyer. Loading all of them
    put unrelated buyers' negotiations into a verdict both parties read.
    """
    src = (API_ROOT / "routers" / "disputes.py").read_text()
    assert "NegotiationMessage.buyer_id == deal.buyer_id" in src, (
        "dispute arbitration no longer scopes chat history to the deal's own "
        "buyer - other buyers' threads are being fed to the arbitrator"
    )
