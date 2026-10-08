"""Push every chat message to the person it is for, app open or not.

There was no such push. A message reached the other person only through the
thread's WebSocket (open only while they had that very chat on screen) or
the app's own seven-second inbox sweep (alive only while the app was). A
message sent to someone whose app was closed produced nothing on their phone
until they happened to open BROKA - and Zeno relaying a buyer's question to
the seller, the moment a marketplace exists for, was as silent as the rest.

How it works:

  * Every NegotiationMessage committed, from any of the twenty-odd places
    that write one, is noticed by a session hook (after_flush collects,
    after_commit dispatches, a rollback discards) - so a new message path
    is covered without anyone remembering to call this.
  * Who it is for follows /history's visibility rules exactly
    (recipients_of): the other side's direct messages, and Zeno's to that
    side. A buyer's private words to Zeno are never pushed to the seller,
    and a call card is not a message (calls push their own missed-call
    notification).
  * Pushes are per thread and debounced (PUSH_DEBOUNCE_SECONDS): three
    quick messages are one notification saying "3 new messages", not three
    buzzes. The text is built when it is sent, from the database - the
    recipient's real unread count by the inbox's own rules, the newest
    message they may see - so it is never stale, and nothing is sent once
    they have read it.
  * It is a visible notification, tagged per thread (thread_<listing>_<buyer>,
    the tag the app's own notification uses), so Android shows it with the
    app closed and each conversation is one notification that updates.
    Messages are not given a TTL: a phone that was off gets them when it
    comes back, which is the point.
"""
from __future__ import annotations

import asyncio
import contextvars
import logging
from collections import OrderedDict
from typing import Optional

from sqlalchemy import and_, event, or_, select
from sqlalchemy.orm import Session

from api.database import AsyncSessionLocal, Listing, NegotiationMessage, User

logger = logging.getLogger(__name__)

PUSH_DEBOUNCE_SECONDS = 1.0
MESSAGES_CHANNEL_ID = "broka_messages"

_SESSION_KEY = "broka_new_messages"
_ROLES = ("buyer", "seller")

# (listing_id, buyer_id) -> the roles with something new, and the task
# that will push to them.
_pending_roles: dict = {}
_pending_tasks: dict = {}
# Every push task until it has finished sending. The loop holds tasks only
# weakly; this also keeps them alive.
_inflight: set = set()
# (listing_id, buyer_id, role) -> id of the message last announced, so the
# same newest message is never announced twice. Bounded.
_last_pushed: "OrderedDict[tuple, str]" = OrderedDict()
_LAST_PUSHED_MAX = 20000


def thread_tag(listing_id: str, buyer_id: str) -> str:
    """The Android notification tag for one conversation. The app posts its
    own message notifications under the same tag (NotificationService), so
    a push and the app's notification for one thread are one notification."""
    return f"thread_{listing_id}_{buyer_id}"


def recipients_of(role: str, recipient_role: Optional[str], via_ai: Optional[bool],
                  msg_type: Optional[str]) -> set:
    """Which side(s) of the thread a new message is news for - /history's
    rules (negotiate.get_history):

      * Zeno's message to one side is for that side; one with no
        recipient_role is shown to both.
      * A buyer's or seller's DIRECT message (via_ai false) is for the
        other side. Their words to Zeno (via_ai true) are private.
      * A call card is not a message: calls send their own missed-call push.
    """
    if role == "broker":
        if recipient_role in _ROLES:
            return {recipient_role}
        return set(_ROLES)
    if role in _ROLES and not via_ai and (msg_type or "text") != "call":
        return {"seller" if role == "buyer" else "buyer"}
    return set()


def preview_of(msg_type: Optional[str], content: Optional[str]) -> str:
    """One line for the notification. Non-text rows carry a placeholder or a
    URL as their content, neither of which belongs in it."""
    kind = msg_type or "text"
    if kind == "image":
        return "\U0001F4F7 Photo"
    if kind == "voice":
        return "\U0001F3A4 Voice message"
    if kind == "video":
        return "\U0001F3AC Video"
    text = " ".join((content or "").split())
    return text if len(text) <= 160 else text[:157] + "..."


# ── Session hook ─────────────────────────────────────────────────────────────

@event.listens_for(Session, "after_flush")
def _collect(session, flush_context) -> None:
    for obj in session.new:
        if isinstance(obj, NegotiationMessage) and obj.buyer_id and obj.listing_id:
            roles = recipients_of(obj.role, obj.recipient_role, obj.via_ai, obj.msg_type)
            if roles:
                session.info.setdefault(_SESSION_KEY, []).append(
                    (obj.listing_id, obj.buyer_id, frozenset(roles)))


@event.listens_for(Session, "after_rollback")
def _discard(session) -> None:
    session.info.pop(_SESSION_KEY, None)


@event.listens_for(Session, "after_commit")
def _dispatch(session) -> None:
    batch = session.info.pop(_SESSION_KEY, None)
    if not batch or not push_enabled():
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return  # committed outside an event loop (a script): nothing to push from
    for listing_id, buyer_id, roles in batch:
        schedule(loop, listing_id, buyer_id, roles)


def push_enabled() -> bool:
    try:
        from api.routers import calls
        return calls._get_fcm() is not None
    except Exception:
        return False


def schedule(loop, listing_id: str, buyer_id: str, roles) -> None:
    key = (listing_id, buyer_id)
    _pending_roles.setdefault(key, set()).update(roles)
    task = _pending_tasks.get(key)
    if task is not None and not task.done():
        return  # it reads the thread when it fires, so it will include this one
    # A fresh context, not the request's: Starlette's HTTP middleware runs
    # each request in an anyio task group and cancels what is left of it
    # once the response is sent - which, for a task inheriting the
    # request's context, was this push, cancelled before it was sent.
    task = loop.create_task(_push_after_debounce(key), context=contextvars.Context())
    _pending_tasks[key] = task
    _inflight.add(task)
    task.add_done_callback(_inflight.discard)


async def _push_after_debounce(key: tuple) -> None:
    try:
        if PUSH_DEBOUNCE_SECONDS > 0:
            await asyncio.sleep(PUSH_DEBOUNCE_SECONDS)
    finally:
        _pending_tasks.pop(key, None)
        roles = _pending_roles.pop(key, set())
    listing_id, buyer_id = key
    for role in sorted(roles):
        try:
            await push_thread(listing_id, buyer_id, role)
        except Exception as exc:
            logger.warning("[message_push] thread %s:%s role=%s failed: %s",
                           listing_id, buyer_id, role, exc)


async def drain() -> None:
    """Wait for every scheduled push to be sent. For tests."""
    while _inflight:
        await asyncio.gather(*list(_inflight), return_exceptions=True)


# ── Building and sending one thread's notification ───────────────────────────

def _visible_to(role: str, listing_id: str, buyer_id: str):
    """Messages in this thread that are news for `role`: the other side's
    direct messages, and Zeno's to this side."""
    counterpart = "seller" if role == "buyer" else "buyer"
    M = NegotiationMessage
    return and_(
        M.listing_id == listing_id,
        M.buyer_id == buyer_id,
        or_(
            and_(
                M.role == counterpart,
                or_(M.via_ai.is_(False), M.via_ai.is_(None)),
                or_(M.msg_type.is_(None), M.msg_type != "call"),
            ),
            and_(
                M.role == "broker",
                or_(M.recipient_role.is_(None), M.recipient_role == role),
            ),
        ),
    )


async def build_notification(db, listing_id: str, buyer_id: str, role: str) -> Optional[dict]:
    """The notification `role` should see for this thread right now, or None
    when there is nothing unread for them. Pure read; sends nothing."""
    # The inbox's own unread rules - one definition of "unread" for the
    # badge and the notification.
    from api.routers.negotiate import _thread_unread_and_seen, _zeno_unread

    listing = (await db.execute(
        select(Listing).where(Listing.id == listing_id)
    )).scalar_one_or_none()
    if listing is None:
        return None
    recipient_id = buyer_id if role == "buyer" else listing.seller_id
    if not recipient_id or recipient_id == (listing.seller_id if role == "buyer" else buyer_id):
        return None  # a seller "buying" from themselves has no one to tell

    # visibility-ok: _visible_to applies /history's audience rules - recipient_role on Zeno's rows, via_ai on the other side's
    newest = (await db.execute(
        select(NegotiationMessage)
        .where(_visible_to(role, listing_id, buyer_id))
        .order_by(NegotiationMessage.created_at.desc())
        .limit(1)
    )).scalar_one_or_none()
    if newest is None:
        return None

    # Call cards left out: "2 new messages" for one text and one missed
    # call announced a message that does not exist (the call has its own).
    direct_unread, _ = await _thread_unread_and_seen(
        db, listing_id, buyer_id, role, None, messages_only=True)
    zeno_unread = await _zeno_unread(db, listing_id, buyer_id, role)
    count = int(direct_unread or 0) + int(zeno_unread or 0)
    if count <= 0:
        return None  # read already - the chat was open, or they were quick

    from_zeno = newest.role == "broker"
    if from_zeno:
        sender_name = "Zeno"
    else:
        other_id = listing.seller_id if role == "buyer" else buyer_id
        sender_name = (await db.execute(
            select(User.name).where(User.id == other_id)
        )).scalar_one_or_none() or ("Seller" if role == "buyer" else "Buyer")
    listing_name = (listing.name or "").strip()
    short_listing = listing_name if len(listing_name) <= 40 else listing_name[:37] + "..."
    title = f"{sender_name} · {short_listing}" if short_listing else sender_name
    preview = preview_of(newest.msg_type, newest.content)
    body = preview if count == 1 else f"{count} new messages · {preview}"

    return {
        "user_id": recipient_id,
        "message_id": newest.id,
        "title": title,
        "body": body,
        "data": {
            "type":        "new_message",
            "listingId":   listing_id,
            "buyerId":     buyer_id,
            "myRole":      role,
            "messageId":   newest.id,
            # Zeno's messages are read in Zeno's room, the rest in the chat.
            "screen":      "zeno" if from_zeno else "chat",
            "senderName":  sender_name,
            "listingName": listing_name,
            "count":       count,
            "preview":     preview,
        },
    }


async def push_thread(listing_id: str, buyer_id: str, role: str) -> int:
    """Send `role` this thread's notification if there is news for them.
    Returns how many phones accepted it."""
    from api.core import push_devices

    async with AsyncSessionLocal() as db:
        note = await build_notification(db, listing_id, buyer_id, role)
    if note is None:
        return 0
    dedupe_key = (listing_id, buyer_id, role)
    if _last_pushed.get(dedupe_key) == note["message_id"]:
        return 0
    _last_pushed[dedupe_key] = note["message_id"]
    _last_pushed.move_to_end(dedupe_key)
    while len(_last_pushed) > _LAST_PUSHED_MAX:
        _last_pushed.popitem(last=False)

    tag = thread_tag(listing_id, buyer_id)
    sent = await push_devices.push_user(
        note["user_id"], title=note["title"], body=note["body"], data=note["data"],
        android_tag=tag, android_channel_id=MESSAGES_CHANNEL_ID,
        apns_thread_id=tag,
    )
    logger.info("[message_push] MESSAGE_PUSHED thread=%s:%s role=%s phones=%d",
                listing_id, buyer_id, role, sent)
    return sent
