"""Who a NegotiationMessage row is allowed to reach.

A listing keeps ONE thread per buyer, and Zeno writes a DIFFERENT reply to
each side of the same relay. `recipient_role` is the audience line: a row
addressed to the buyer must never become the seller's inbox preview, their
push notification, or their unread count.

This lives in core/ rather than in negotiate.py because the inbox, the
push builder, the delivery queries, the thread itself and the model
context all read the same table. Each surface remembering its own
`or_(...)` is how the leak that prompted this module happened in the
first place.

Four rules, deliberately separate:

  * `visible_to_role_clause` - NEWS for a viewer: the other person's
    direct messages and Zeno messages written TO this viewer. Pushes use
    this; your own message is not news to you.
  * `thread_visible_to_role_clause` - what may appear in a thread's
    preview, which includes the viewer's OWN direct messages. The newest
    row after you reply is your reply.
  * `addressed_to_role_clause` - only Zeno's private messages to this
    viewer, for the Zeno-room unread count.
  * `broker_visible_to` - the same audience rule for the Python loops that
    build /history, Zeno's model context and arbitration, where rows are
    loaded and filtered after the fact.

**A broker row with no recipient_role has no audience.** It is not
previewed, pushed, counted, shown in /history, or fed to a model. Zeno
writes a different message to each side of a relay, so a row that names
nobody cannot be attributed to a side - and guessing "both" is how a
private note ends up in front of the party it was written about. (Rows
from before the audience column existed are silent rather than leaked;
the alternative fails open on exactly the content nobody can audit.)

A party's own words to Zeno (via_ai=True) are private and appear in none
of these. Call cards are excluded from push separately.
"""
from __future__ import annotations

from typing import Optional

from sqlalchemy import and_, or_

from api.database import NegotiationMessage

_ROLES = ("buyer", "seller")


def visible_to_role_clause(role: str):
    """Rows that are news/context for `role` in a thread.

    Direct messages (via_ai false/NULL) from the counterpart; Zeno messages
    explicitly addressed to `role`. `role` is the viewer, never the sender.
    """
    M = NegotiationMessage
    counterpart = "seller" if role == "buyer" else "buyer"
    return or_(
        and_(
            M.role == counterpart,
            or_(M.via_ai.is_(False), M.via_ai.is_(None)),
        ),
        and_(
            M.role == "broker",
            M.recipient_role == role,
        ),
    )


def thread_visible_to_role_clause(role: str):
    """Everything a viewer may see in the thread, including their OWN
    direct messages. The inbox previews the newest row like this: after
    you reply, your reply is the last thing in the conversation, not
    something to hide from yourself. Unlike `visible_to_role_clause`, this
    is not a "news for me" predicate - pushes must not announce your own
    message back to you.
    """
    M = NegotiationMessage
    return or_(
        and_(
            M.role.in_(_ROLES),
            or_(M.via_ai.is_(False), M.via_ai.is_(None)),
        ),
        and_(
            M.role == "broker",
            M.recipient_role == role,
        ),
    )


def addressed_to_role_clause(role: str):
    """Zeno's private messages to this viewer only."""
    M = NegotiationMessage
    return and_(M.role == "broker", M.recipient_role == role)


def broker_visible_to(recipient_role: Optional[str], viewer_role: str) -> bool:
    """The audience rule for one already-loaded broker row.

    For the loops (`get_history`, `_build_messages_for_party`,
    `_grounding_transcript`, arbitration) that select rows and filter in
    Python. Identical to `addressed_to_role_clause` - a NULL audience is
    visible to nobody - so a row cannot be shown on one surface and hidden
    on another, which is the mismatch that made a message appear in the
    inbox and then vanish when the thread opened.
    """
    return recipient_role is not None and recipient_role == viewer_role
