"""The inbox's figures for every conversation, in a fixed number of queries.

GET /negotiate/inbox/{user_id} describes each conversation a user is in: its
newest row, how much of it they haven't read, what Zeno has told them since
they were last in the Zeno room, and the newest unread message and missed
call the last row can hide. It asked the database for each of those one
conversation at a time - five to eight round trips per thread, so a seller
with fifty threads made three to four hundred queries on every poll and held
one of the process's five connections for all of them.

Here each figure is ONE grouped query over a group of conversations that
share a kind and the viewer's side (`ThreadGroup`): a buyer's product
threads, a seller's, a buyer's store threads, a store owner's. The number of
queries follows the number of groups - at most four - not the number of
conversations.

The rules are those of the per-thread helpers in routers/negotiate.py
(`_thread_unread_and_seen`, `_zeno_unread`), which still answer
read-status and the push builder one thread at a time;
tests/test_inbox_batched.py holds the inbox to the same answers:

  * a thread's preview is its newest row the caller's
    `thread_visible_to_role_clause(role)` admits - never Zeno's words to the
    other side, never either side's private words to Zeno;
  * unread: the other side's direct messages after this side's read
    watermark - not their via_ai messages to Zeno (a phantom badge, and a
    meter on a private conversation), not an unsent tombstone;
  * zeno_unread: Zeno's messages to this side after its Zeno-room watermark,
    or its direct-chat one when it has never opened the Zeno room;
  * whatever was sent up to the moment this user deleted the chat
    (thread_clears) counts for none of them.

Watermarks and deletions are joined in SQL, not passed in, so no query
carries a parameter per conversation. Only window functions and grouped
counts are used - SQLite (tests, development) has both since 3.25.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, NamedTuple, Optional

from sqlalchemy import and_, case, func, literal_column, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from api.core.message_visibility import addressed_to_role_clause
from api.database import Listing, NegotiationMessage, ThreadReadState
from api.models.thread_clear import ThreadClear

# (listing_id or store_id, buyer_id): one conversation.
ThreadKey = tuple

# A missed call, and a call the caller gave up on before it was answered:
# both are calls this side never took (see unread_by_kind).
MISSED_CALL_OUTCOMES = ("missed", "cancelled")


def zeno_read_role(role: str) -> str:
    """The ThreadReadState role of one side's Zeno-room watermark - the rule
    negotiate._zeno_read_role documents, and must stay equal to."""
    return f"zeno_{role}"


@dataclass(frozen=True)
class ThreadGroup:
    """Conversations of one kind, seen from one side.

    `kind` is "listing" (a product thread) or "store" (a store-general one);
    `role` is the viewer's side in all of them; `user_id` is the viewer. A
    buyer's group is every thread they wrote in as the buyer; a seller's is
    every buyer thread on their listings, or on their stores that are not
    deleted.
    """
    kind: str
    role: str
    user_id: str

    @property
    def counterpart(self) -> str:
        return "seller" if self.role == "buyer" else "buyer"

    def thread_of(self, entity):
        """The column naming the conversation on a message, a watermark or a
        deletion - or, given a loaded row, its value."""
        return entity.listing_id if self.kind == "listing" else entity.store_id

    def scope(self) -> list:
        """The messages of every conversation in the group.

        A seller's scope also takes in (listing, buyer) pairs with no buyer
        message, which are not inbox threads; callers look figures up by the
        threads they listed, so those are never read back.
        """
        M = NegotiationMessage
        if self.role == "buyer":
            return [M.buyer_id == self.user_id, self.thread_of(M).isnot(None)]
        if self.kind == "listing":
            owned = select(Listing.id).where(Listing.seller_id == self.user_id)
            return [M.listing_id.in_(owned), M.buyer_id.isnot(None)]
        from api.models.store import Store
        owned = select(Store.id).where(Store.owner_id == self.user_id,
                                       Store.deleted_at.is_(None))
        return [M.store_id.in_(owned), M.buyer_id.isnot(None)]

    def mark_on(self, mark, role: str):
        """Join one side's watermark row (ThreadReadState, unique per thread,
        buyer and role) to each message."""
        M = NegotiationMessage
        return and_(self.thread_of(mark) == self.thread_of(M),
                    mark.buyer_id == M.buyer_id, mark.role == role)

    def clear_on(self, clear):
        """Join this user's deletion of the conversation (unique per user,
        thread and buyer) to each message."""
        M = NegotiationMessage
        on = [clear.user_id == self.user_id, clear.buyer_id == M.buyer_id,
              self.thread_of(clear) == self.thread_of(M)]
        if self.kind == "store":
            # thread_clears.clears_for files a deletion naming a listing
            # under that listing, whatever else it names.
            on.append(clear.listing_id.is_(None))
        return and_(*on)

    @staticmethod
    def after(at):
        """Sent after `at`, a joined watermark or deletion - or anything, when
        the join found none."""
        return or_(at.is_(None), NegotiationMessage.created_at > at)

    def counterpart_direct(self) -> list:
        """The other side's direct messages that still have something to
        read: not their private words to Zeno, not a message they unsent."""
        M = NegotiationMessage
        return [
            M.role == self.counterpart,
            or_(M.via_ai.is_(False), M.via_ai.is_(None)),
            M.deleted_at.is_(None),
        ]


class LatestRow(NamedTuple):
    message: NegotiationMessage
    their_read_at: object        # the other side's read watermark, or None
    their_delivered_at: object   # ... and delivery watermark, or None


@dataclass
class ThreadFigures:
    """What the inbox says about one conversation, for one side of it."""
    last: NegotiationMessage
    unread: int
    seen: bool
    delivered: bool
    zeno_unread: int
    unread_message: Optional[dict]
    unread_missed_call: Optional[dict]


async def latest_messages(db: AsyncSession, group: ThreadGroup, visible) -> dict:
    """Each conversation's newest row that `visible` lets this side see, sent
    after this user deleted the chat, with the other side's watermarks - its
    seen and delivered ticks are measured against them.

    `visible` is the caller's `thread_visible_to_role_clause(group.role)`:
    the audience rule stays at the call site, where the privacy review of the
    inbox looks for it.
    """
    M = NegotiationMessage
    clear = aliased(ThreadClear)
    theirs = aliased(ThreadReadState)
    thread = group.thread_of(M)
    # Newest first; equal timestamps fall back to the id so the same rows
    # always give the same preview (and the same ETag).
    rank = func.row_number().over(
        partition_by=(thread, M.buyer_id),
        order_by=(M.created_at.desc(), M.id.desc()),
    )
    # visibility-ok: `visible` is the caller's thread_visible_to_role_clause - recipient_role and via_ai audience rules
    ranked = (
        select(M.id.label("id"), rank.label("rank"))
        .outerjoin(clear, group.clear_on(clear))
        .where(*group.scope(), visible, group.after(clear.cleared_at))
        .subquery()
    )
    # visibility-ok: only rows the ranked subquery above admitted through `visible`
    rows = (await db.execute(
        select(M, theirs.last_read_at, theirs.last_delivered_at)
        .join(ranked, ranked.c.id == M.id)
        .outerjoin(theirs, group.mark_on(theirs, group.counterpart))
        .where(ranked.c.rank == 1)
    )).all()
    return {
        (group.thread_of(m), m.buyer_id): LatestRow(m, read_at, delivered_at)
        for m, read_at, delivered_at in rows
    }


async def unread_counts(db: AsyncSession, group: ThreadGroup) -> dict:
    """The other side's unread direct messages per conversation - what
    negotiate._thread_unread_and_seen counts for one. Call cards count, as
    the inbox badge always has."""
    M = NegotiationMessage
    mine = aliased(ThreadReadState)
    clear = aliased(ThreadClear)
    thread = group.thread_of(M)
    # visibility-ok: counts the other side's direct messages (via_ai excluded), no content reaches the response
    rows = (await db.execute(
        select(thread, M.buyer_id, func.count(M.id))
        .outerjoin(mine, group.mark_on(mine, group.role))
        .outerjoin(clear, group.clear_on(clear))
        .where(*group.scope(), *group.counterpart_direct(),
               group.after(mine.last_read_at), group.after(clear.cleared_at))
        .group_by(thread, M.buyer_id)
    )).all()
    return {(thread_id, buyer_id): int(n) for thread_id, buyer_id, n in rows}


async def zeno_unread_counts(db: AsyncSession, group: ThreadGroup) -> dict:
    """Zeno's messages to this side per product conversation since its
    Zeno-room watermark, or its direct-chat watermark when it has never
    marked one - negotiate._zeno_unread for one thread. A store thread has
    no Zeno room."""
    M = NegotiationMessage
    zeno = aliased(ThreadReadState)
    mine = aliased(ThreadReadState)
    clear = aliased(ThreadClear)
    since = func.coalesce(zeno.last_read_at, mine.last_read_at)
    # visibility-ok: addressed_to_role_clause keeps only Zeno's rows to this viewer, and only their count leaves
    rows = (await db.execute(
        select(M.listing_id, M.buyer_id, func.count(M.id))
        .outerjoin(zeno, group.mark_on(zeno, zeno_read_role(group.role)))
        .outerjoin(mine, group.mark_on(mine, group.role))
        .outerjoin(clear, group.clear_on(clear))
        .where(*group.scope(), addressed_to_role_clause(group.role),
               group.after(since), group.after(clear.cleared_at))
        .group_by(M.listing_id, M.buyer_id)
    )).all()
    return {(listing_id, buyer_id): int(n) for listing_id, buyer_id, n in rows}


async def unread_by_kind(db: AsyncSession, group: ThreadGroup) -> dict:
    """Per conversation, the other side's newest unread message and their
    newest unread missed call: (message, call), either None.

    The inbox describes a thread by its last row, and the app's sweep
    announces that row. So a text followed by a missed call announced only
    the missed call - reported from phones (2026-10-07): "only missed call
    was displayed despite there being an unread text message" - and a
    missed call followed by a text, only the text. These are the two a last
    row can hide; the app announces whichever it has not yet.

    Unread by the same watermark as `unread_counts`, so a thread read on
    another phone has nothing here. "cancelled" is a missed call too: the
    caller hung up before it was answered.
    """
    M = NegotiationMessage
    mine = aliased(ThreadReadState)
    clear = aliased(ThreadClear)
    thread = group.thread_of(M)
    # Constants, not bound values: a parameter as a CASE result has no type
    # PostgreSQL can infer inside the window's PARTITION BY.
    kind = case((M.msg_type == "call", literal_column("'call'")),
                else_=literal_column("'message'"))
    rank = func.row_number().over(
        partition_by=(thread, M.buyer_id, kind),
        order_by=(M.created_at.desc(), M.id.desc()),
    )
    # visibility-ok: the other side's direct messages only - via_ai excluded, recipient_role must be this viewer or none
    ranked = (
        select(thread.label("thread_id"), M.buyer_id.label("buyer_id"),
               M.id.label("id"), M.content.label("content"),
               M.msg_type.label("msg_type"), M.call_type.label("call_type"),
               M.deleted_at.label("deleted_at"), kind.label("kind"),
               rank.label("rank"))
        .outerjoin(mine, group.mark_on(mine, group.role))
        .outerjoin(clear, group.clear_on(clear))
        .where(*group.scope(), *group.counterpart_direct(),
               or_(M.recipient_role.is_(None), M.recipient_role == group.role),
               group.after(mine.last_read_at), group.after(clear.cleared_at),
               # Any message, but of the calls only those nobody answered.
               or_(M.msg_type.is_(None), M.msg_type != "call",
                   M.content.in_(MISSED_CALL_OUTCOMES)))
        .subquery()
    )
    rows = (await db.execute(select(ranked).where(ranked.c.rank == 1))).all()
    out: dict = {}
    for row in rows:
        key = (row.thread_id, row.buyer_id)
        message, call = out.get(key, (None, None))
        if row.kind == "call":
            call = {"id": row.id, "call_type": row.call_type}
        else:
            message = {
                "id": row.id,
                "content": ("Message deleted" if row.deleted_at
                            else (row.content or "[media]"))[:80],
                "msg_type": row.msg_type or "text",
            }
        out[key] = (message, call)
    return out


async def figures(
    db: AsyncSession, group: ThreadGroup, visible, keys: Iterable[ThreadKey],
    *, zeno: bool,
) -> dict:
    """Everything the inbox says about the conversations `keys` of `group`,
    by key; a conversation with nothing this side may see has no entry.

    Three or four queries whatever the number of conversations: the newest
    rows with the other side's watermarks, the unread counts, Zeno's (for
    product threads, `zeno`) and - only when something is unread - the
    newest unread message and missed call.
    """
    wanted = set(keys)
    if not wanted:
        return {}
    latest = {k: v for k, v in (await latest_messages(db, group, visible)).items()
              if k in wanted}
    if not latest:
        return {}
    unread = await unread_counts(db, group)
    zeno_counts = await zeno_unread_counts(db, group) if zeno else {}
    by_kind = (await unread_by_kind(db, group)
               if any(unread.get(k) for k in latest) else {})
    out: dict = {}
    for key, row in latest.items():
        last = row.message
        count = unread.get(key, 0)
        # The ticks describe this side's own last message only.
        mine_last = last.role == group.role and last.created_at is not None
        message, call = by_kind.get(key, (None, None)) if count else (None, None)
        out[key] = ThreadFigures(
            last=last,
            unread=count,
            seen=bool(mine_last and row.their_read_at
                      and row.their_read_at >= last.created_at),
            delivered=bool(mine_last and row.their_delivered_at
                           and row.their_delivered_at >= last.created_at),
            zeno_unread=zeno_counts.get(key, 0) if zeno else 0,
            unread_message=message,
            unread_missed_call=call,
        )
    return out


async def buyers_by_thread(db: AsyncSession, group: ThreadGroup) -> dict:
    """For a seller's group, the buyers who have written in each of their
    listings (or stores), each thread's in the order the database gave them:
    one query where the inbox used to ask once per listing and per store."""
    M = NegotiationMessage
    thread = group.thread_of(M)
    # visibility-ok: selects thread and buyer ids only, no message content
    rows = (await db.execute(
        select(thread, M.buyer_id)
        .where(*group.scope(), M.role == "buyer")
        .distinct()
    )).all()
    out: dict = {}
    for thread_id, buyer_id in rows:
        # The store loop always skipped an empty id; the listing loop's
        # IS NOT NULL is the scope's.
        if buyer_id or group.kind == "listing":
            out.setdefault(thread_id, []).append(buyer_id)
    return out
