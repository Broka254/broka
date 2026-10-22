"""Who a NegotiationMessage row is allowed to reach.

A listing keeps ONE thread per buyer, and Zeno writes a DIFFERENT reply to
each side of the same relay. `recipient_role` is the audience line: a row
addressed to the buyer must never become the seller's inbox preview, their
push notification, or their unread count.

This lives in core/ rather than in negotiate.py because the inbox, the
push builder and the delivery queries all read the same table. Three
surfaces each remembering the same `or_(...)` is how the leak that
prompted this module happened in the first place.

Three rules, deliberately separate:

  * `visible_to_role_clause` - NEWS for a viewer: the other person's
    direct messages and Zeno messages written TO this viewer. Pushes use
    this; your own message is not news to you.
  * `thread_visible_to_role_clause` - what may appear in a thread's
    preview, which includes the viewer's OWN direct messages. The newest
    row after you reply is your reply.
  * `addressed_to_role_clause` - only Zeno's private messages to this
    viewer, for the Zeno-room unread count.

Broker rows with no recipient_role are legacy shared replies; they are
not previewed, pushed or counted (the side that should see them is
unknowable), though /history still shows them for backward
compatibility. A party's own words to Zeno (via_ai=True) are private and
appear in none of these. Call cards are excluded from push separately.
"""
from __future__ import annotations

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
