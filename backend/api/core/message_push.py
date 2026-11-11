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

from sqlalchemy import and_, event, func, or_, select
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
# (listing_id, buyer_id, role) -> the id of the message last announced and
# the phones it reached, so the same newest message is never announced twice
# - and so a phone that registered afterwards is told about it without the
# phones that already were buzzing again. Bounded.
_last_pushed: "OrderedDict[tuple, tuple]" = OrderedDict()
_LAST_PUSHED_MAX = 20000
# (listing_id, buyer_id) -> how many times the thread was scheduled. Every
# schedule() bumps it, so a send built from an older read can tell a newer
# message re-armed the thread while it was being built - and stand down
# instead of delivering stale text after the fresh push (the re-arm's own
# task sends the fresh state).
_generations: dict = {}
# (listing_id, buyer_id, role) -> asyncio.Lock serialising the guard-and-send
# for one thread's notification. Without it two tasks (a debounce run and a
# register-time re-push, or two re-pushes) both pass the _last_pushed guard
# and both send: the await on the FCM send yields between the check and the
# record. Locks are never removed; the key space is bounded by active
# threads and one small lock per thread is cheaper than a janitor.
_send_locks: dict = {}


def thread_tag(listing_id: str, buyer_id: str) -> str:
    """The Android notification tag for one conversation. The app posts its
    own message notifications under the same tag (NotificationService), so
    a push and the app's notification for one thread are one notification."""
    return f"thread_{listing_id}_{buyer_id}"


def store_tag(store_id: str, buyer_id: str) -> str:
    # Same canonical thread id the app uses for a store ("store:<id>"), so
    # the server push and the app's own notification replace one another.
    return thread_tag(f"store:{store_id}", buyer_id)


def recipients_of(role: str, recipient_role: Optional[str], via_ai: Optional[bool],
                  msg_type: Optional[str]) -> set:
    """Which side(s) of the thread a new message is news for - /history's
    rules (negotiate.get_history):

      * Zeno's message to one side is for that side. A broker row with no
        recipient_role is a legacy shared reply: nobody knows which side
        it was written to, so it is not news for either - the old "both"
        rule pushed private relay copies of one side to the other.
      * A buyer's or seller's DIRECT message (via_ai false) is for the
        other side. Their words to Zeno (via_ai true) are private.
      * A call card is not a message: calls send their own missed-call push.
    """
    if role == "broker":
        if recipient_role in _ROLES:
            return {recipient_role}
        return set()
    if role in _ROLES and not via_ai and (msg_type or "text") != "call":
        return {"seller" if role == "buyer" else "buyer"}
    return set()


def preview_of(msg_type: Optional[str], content: Optional[str],
               file_name: Optional[str] = None) -> str:
    """One line for the notification. Non-text rows carry a placeholder or a
    URL as their content, neither of which belongs in it. A document is
    announced by its name ("📄 Invoice.pdf"), its caption being only a note
    on it."""
    kind = msg_type or "text"
    if kind == "image":
        return "\U0001F4F7 Photo"
    if kind == "voice":
        return "\U0001F3A4 Voice message"
    if kind == "video":
        return "\U0001F3AC Video"
    if kind == "file":
        name = " ".join((file_name or "").split()) or "Document"
        return "\U0001F4C4 " + (name if len(name) <= 120 else name[:117] + "...")
    text = " ".join((content or "").split())
    return text if len(text) <= 160 else text[:157] + "..."


def album_preview(photos: int) -> str:
    """Several photos sent together (NegotiationMessage.album_id) are one
    piece of news, as the chat shows them in one frame: "📷 3 photos", not
    "3 new messages · 📷 Photo"."""
    return "\U0001F4F7 " + (f"{photos} photos" if photos > 1 else "Photo")


def _notification_body(count: int, preview: str, album_photos: int) -> str:
    # An album that is all of the news reads as the album alone.
    if album_photos > 1 and count <= album_photos:
        return preview
    return preview if count == 1 else f"{count} new messages · {preview}"


def per_phone_data(data: dict, *, user_id: str, role: str, buyer_id: str,
                   listing_id: Optional[str] = None,
                   store_id: Optional[str] = None):
    """Each phone's copy of a message push (push_devices.push_user's
    data_for_token): the push's data plus the token its notification's
    Reply and Mark as read, and its delivered receipt, are sent with -
    bound to that phone (api/security.py create_thread_token)."""
    from api.core.push_devices import token_fingerprint
    from api.security import create_thread_token

    def build(token: str) -> dict:
        return {**data, "threadToken": create_thread_token(
            user_id, role, buyer_id, listing_id=listing_id, store_id=store_id,
            device=token_fingerprint(token),
        )}
    return build


# ── Session hook ─────────────────────────────────────────────────────────────

@event.listens_for(Session, "after_flush")
def _collect(session, flush_context) -> None:
    for obj in session.new:
        if isinstance(obj, NegotiationMessage) and obj.buyer_id:
            roles = recipients_of(obj.role, obj.recipient_role, obj.via_ai, obj.msg_type)
            if not roles:
                continue
            if getattr(obj, "store_id", None) and not obj.listing_id:
                session.info.setdefault(_SESSION_KEY + "_store", []).append(
                    (obj.store_id, obj.buyer_id, frozenset(roles)))
            elif obj.listing_id:
                session.info.setdefault(_SESSION_KEY, []).append(
                    (obj.listing_id, obj.buyer_id, frozenset(roles)))


@event.listens_for(Session, "after_rollback")
def _discard(session) -> None:
    session.info.pop(_SESSION_KEY, None)
    session.info.pop(_SESSION_KEY + "_store", None)


@event.listens_for(Session, "after_commit")
def _dispatch(session) -> None:
    batch = session.info.pop(_SESSION_KEY, None)
    store_batch = session.info.pop(_SESSION_KEY + "_store", None)
    if (not batch and not store_batch) or not push_enabled():
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return  # committed outside an event loop (a script): nothing to push from
    for listing_id, buyer_id, roles in (batch or []):
        schedule(loop, listing_id, buyer_id, roles)
    for store_id, buyer_id, roles in (store_batch or []):
        schedule_store(loop, store_id, buyer_id, roles)


def push_enabled() -> bool:
    try:
        from api.routers import calls
        return calls._get_fcm() is not None
    except Exception:
        return False


def schedule(loop, listing_id: str, buyer_id: str, roles) -> None:
    key = (listing_id, buyer_id)
    _generations[key] = _generations.get(key, 0) + 1
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
    # What this run may send: anything scheduled after this point re-arms
    # the thread and gets its own task, which sends the fresh state.
    generation = _generations.get(key, 0)
    listing_id, buyer_id = key
    for role in sorted(roles):
        try:
            await push_thread(listing_id, buyer_id, role, generation=generation)
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
    direct messages, and Zeno's to this side. The audience rule itself is
    shared with the inbox (api.core.message_visibility) so the preview and
    the push can never disagree about a private Zeno reply."""
    from api.core.message_visibility import visible_to_role_clause

    M = NegotiationMessage
    return and_(
        M.listing_id == listing_id,
        M.buyer_id == buyer_id,
        visible_to_role_clause(role),
        or_(M.msg_type.is_(None), M.msg_type != "call"),
        # An unsent message is not news either: pushing "Message deleted"
        # would buzz a phone about words that no longer exist.
        M.deleted_at.is_(None),
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
    direct_unread, _, _ = await _thread_unread_and_seen(
        db, listing_id, buyer_id, role, None, messages_only=True)
    zeno_unread = await _zeno_unread(db, listing_id, buyer_id, role)
    count = int(direct_unread or 0) + int(zeno_unread or 0)
    if count <= 0:
        return None  # read already - the chat was open, or they were quick

    from_zeno = newest.role == "broker"
    sender_photo = None
    if from_zeno:
        sender_name = "Zeno"
    else:
        other_id = listing.seller_id if role == "buyer" else buyer_id
        sender_name = (await db.execute(
            select(User.name).where(User.id == other_id)
        )).scalar_one_or_none() or ("Seller" if role == "buyer" else "Buyer")
        # Their face on the notification, which the app draws in when the
        # push arrives (NotificationService). A URL: the picture itself
        # would not fit in a push.
        from api.domains.media.service import avatar_url
        try:
            sender_photo = await avatar_url(db, other_id)
        except Exception as exc:
            # Cosmetic: the message is pushed without a face.
            logger.warning("[message_push] no photo for user=%s: %s", other_id, exc)
    listing_name = (listing.name or "").strip()
    short_listing = listing_name if len(listing_name) <= 40 else listing_name[:37] + "..."
    title = f"{sender_name} · {short_listing}" if short_listing else sender_name
    preview = preview_of(newest.msg_type, newest.content, getattr(newest, "file_name", None))
    album_photos = 0
    album_id = getattr(newest, "album_id", None)
    if (newest.msg_type or "") == "image" and album_id:
        # visibility-ok: _visible_to applies /history's audience rules - recipient_role on Zeno's rows, via_ai on the other side's
        album_photos = int((await db.execute(
            select(func.count(NegotiationMessage.id)).where(
                _visible_to(role, listing_id, buyer_id),
                NegotiationMessage.album_id == album_id,
                NegotiationMessage.msg_type == "image",
            )
        )).scalar() or 0)
        if album_photos > 1:
            preview = album_preview(album_photos)
    body = _notification_body(count, preview, album_photos)

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
            # The other person's messages among them. A push whose newest
            # message is Zeno's still delivers these to the phone, and the
            # phone says so (the sender's delivered tick) only on this.
            "directUnread": int(direct_unread or 0),
            "preview":     preview,
            **({"senderPhoto": sender_photo} if sender_photo else {}),
        },
    }


async def push_thread(
    listing_id: str, buyer_id: str, role: str,
    generation: Optional[int] = None, force: bool = False,
) -> int:
    """Send `role` this thread's notification if there is news for them.
    Returns how many phones accepted it.

    `generation` is the schedule count `_push_after_debounce` saw when this
    run fired. When a newer message re-armed the thread while the note was
    being built, the run stands down without sending: its note is stale,
    and the re-arm's own task sends the fresh state. That keeps a slow
    first send from landing after - and overwriting, by tag - the fresh
    notification.

    `force` re-checks a thread whose newest message was already announced,
    for phones that were not told: a phone that has just registered has not
    seen this thread's news even when another phone of the same account was
    pushed to earlier (see push_unread_for_user). The phones already told
    about that same message are left out: the register-time re-push and the
    message's own debounced push race for the same thread, and both
    announcing it buzzed the phone twice (CI, Backend Tests PostgreSQL 16:
    test_a_photo_is_announced_as_a_photo found two pushes for one photo).

    The guard-and-send below runs under a per-thread lock: checking
    _last_pushed, sending, and recording are one atomic step, so two
    tasks racing on the same thread cannot both send. The notification
    itself is built before the lock (pure read, no shared state), so the
    lock is held only across the cheap guard and the FCM send.
    """
    from api.core import push_devices

    async with AsyncSessionLocal() as db:
        note = await build_notification(db, listing_id, buyer_id, role)
    if note is None:
        return 0
    dedupe_key = (listing_id, buyer_id, role)
    lock = _send_locks.setdefault(dedupe_key, asyncio.Lock())
    async with lock:
        if generation is not None and _generations.get((listing_id, buyer_id), 0) != generation:
            return 0
        announced = _last_pushed.get(dedupe_key)
        repeat = announced is not None and announced[0] == note["message_id"]
        if repeat and not force:
            return 0
        told = frozenset()
        phones = await _phones_for(note["user_id"])
        if repeat:
            told = announced[1]
            phones = [phone for phone in phones if phone not in told]
            if not phones:
                return 0  # every phone that could be reached was already told
        # Exactly the phones being told, so the record below is the truth.
        # None when the account has no phone registered: push_user resolves
        # the phones itself then, as it always has.
        tokens = phones or None

        tag = thread_tag(listing_id, buyer_id)
        sent = await push_devices.push_user(
            note["user_id"], title=note["title"], body=note["body"], data=note["data"],
            tokens=tokens,
            data_for_token=per_phone_data(
                note["data"], user_id=note["user_id"], role=role,
                buyer_id=buyer_id, listing_id=listing_id),
            android_tag=tag, android_channel_id=MESSAGES_CHANNEL_ID,
            apns_thread_id=tag,
        )
        if sent > 0:
            # Only a push a phone actually accepted counts as announced. This
            # used to be recorded before the send, so a message that reached
            # no phone at all - recipient offline, token not registered yet,
            # a transient FCM failure - was marked pushed and could never be
            # announced again for that thread, however long it stayed unread.
            _last_pushed[dedupe_key] = (note["message_id"], told | frozenset(tokens or ()))
            _last_pushed.move_to_end(dedupe_key)
            while len(_last_pushed) > _LAST_PUSHED_MAX:
                _last_pushed.popitem(last=False)
        logger.info("[message_push] MESSAGE_PUSHED thread=%s:%s role=%s phones=%d",
                    listing_id, buyer_id, role, sent)
        return sent


# ── Store-general threads ──────────────────────────────────────────────────
# Same debounce/dedupe discipline as listing threads, keyed by
# ("store", store_id, buyer_id) so the two namespaces never collide.

_store_pending_roles: dict = {}
_store_pending_tasks: dict = {}
_store_generations: dict = {}


def schedule_store(loop, store_id: str, buyer_id: str, roles) -> None:
    key = ("store", store_id, buyer_id)
    _store_generations[key] = _store_generations.get(key, 0) + 1
    _store_pending_roles.setdefault(key, set()).update(roles)
    task = _store_pending_tasks.get(key)
    if task is not None and not task.done():
        return
    task = loop.create_task(_push_store_after_debounce(key), context=contextvars.Context())
    _store_pending_tasks[key] = task
    _inflight.add(task)
    task.add_done_callback(_inflight.discard)


async def _push_store_after_debounce(key: tuple) -> None:
    try:
        if PUSH_DEBOUNCE_SECONDS > 0:
            await asyncio.sleep(PUSH_DEBOUNCE_SECONDS)
    finally:
        _store_pending_tasks.pop(key, None)
        roles = _store_pending_roles.pop(key, set())
    generation = _store_generations.get(key, 0)
    _, store_id, buyer_id = key
    for role in sorted(roles):
        try:
            await push_store_thread(store_id, buyer_id, role, generation=generation)
        except Exception as exc:
            logger.warning("[message_push] store thread %s:%s role=%s failed: %s",
                           store_id, buyer_id, role, exc)


async def build_store_notification(db, store_id: str, buyer_id: str, role: str) -> Optional[dict]:
    from api.models.store import Store
    from api.routers.negotiate import _thread_unread_and_seen
    store = (await db.execute(
        select(Store).where(Store.id == store_id, Store.deleted_at.is_(None))
    )).scalar_one_or_none()
    if store is None:
        return None
    recipient_id = buyer_id if role == "buyer" else store.owner_id
    if not recipient_id:
        return None
    from api.core.message_visibility import visible_to_role_clause
    M = NegotiationMessage
    # visibility-ok: visible_to_role_clause applies /history audience rules
    newest = (await db.execute(
        select(NegotiationMessage)
        .where(M.store_id == store_id, M.buyer_id == buyer_id,
               visible_to_role_clause(role),
               or_(M.msg_type.is_(None), M.msg_type != "call"),
               M.deleted_at.is_(None))
        .order_by(NegotiationMessage.created_at.desc()).limit(1)
    )).scalar_one_or_none()
    if newest is None:
        return None
    unread, _, _ = await _thread_unread_and_seen(
        db, None, buyer_id, role, None, messages_only=True, store_id=store_id)
    count = int(unread or 0)
    if count <= 0:
        return None
    other_id = store.owner_id if role == "buyer" else buyer_id
    sender_name = (await db.execute(
        select(User.name).where(User.id == other_id)
    )).scalar_one_or_none() or ("Seller" if role == "buyer" else "Buyer")
    if role == "buyer":
        sender_name = store.name
    sender_photo = None
    try:
        from api.domains.media.service import avatar_url
        sender_photo = await avatar_url(db, other_id)
    except Exception as exc:
        logger.warning("[message_push] no photo for user=%s: %s", other_id, exc)
    preview = preview_of(newest.msg_type, newest.content, getattr(newest, "file_name", None))
    album_photos = 0
    album_id = getattr(newest, "album_id", None)
    if (newest.msg_type or "") == "image" and album_id:
        # visibility-ok: visible_to_role_clause applies /history audience rules
        album_photos = int((await db.execute(
            select(func.count(NegotiationMessage.id)).where(
                M.store_id == store_id, M.buyer_id == buyer_id,
                visible_to_role_clause(role),
                M.deleted_at.is_(None),
                M.album_id == album_id,
                M.msg_type == "image",
            )
        )).scalar() or 0)
        if album_photos > 1:
            preview = album_preview(album_photos)
    body = _notification_body(count, preview, album_photos)
    return {
        "user_id": recipient_id,
        "message_id": newest.id,
        "title": f"{sender_name} · {store.name}" if role == "seller" else store.name,
        "body": body,
        "data": {
            "type": "new_message", "storeId": store_id, "buyerId": buyer_id,
            "myRole": role, "messageId": newest.id, "screen": "chat",
            "senderName": sender_name, "listingName": store.name,
            "count": count, "directUnread": count, "preview": preview,
            **({"senderPhoto": sender_photo} if sender_photo else {}),
        },
    }


async def push_store_thread(store_id: str, buyer_id: str, role: str,
                            generation: Optional[int] = None, force: bool = False) -> int:
    from api.core import push_devices
    async with AsyncSessionLocal() as db:
        note = await build_store_notification(db, store_id, buyer_id, role)
    if note is None:
        return 0
    dedupe_key = ("store", store_id, buyer_id, role)
    lock = _send_locks.setdefault(dedupe_key, asyncio.Lock())
    async with lock:
        if generation is not None and _store_generations.get(("store", store_id, buyer_id), 0) != generation:
            return 0
        announced = _last_pushed.get(dedupe_key)
        repeat = announced is not None and announced[0] == note["message_id"]
        if repeat and not force:
            return 0
        told = frozenset()
        phones = await _phones_for(note["user_id"])
        if repeat:
            told = announced[1]
            phones = [p for p in phones if p not in told]
            if not phones:
                return 0
        tokens = phones or None
        tag = store_tag(store_id, buyer_id)
        sent = await push_devices.push_user(
            note["user_id"], title=note["title"], body=note["body"], data=note["data"],
            tokens=tokens,
            data_for_token=per_phone_data(
                note["data"], user_id=note["user_id"], role=role,
                buyer_id=buyer_id, store_id=store_id),
            android_tag=tag, android_channel_id=MESSAGES_CHANNEL_ID,
            apns_thread_id=tag,
        )
        if sent > 0:
            _last_pushed[dedupe_key] = (note["message_id"], told | frozenset(tokens or ()))
            _last_pushed.move_to_end(dedupe_key)
            while len(_last_pushed) > _LAST_PUSHED_MAX:
                _last_pushed.popitem(last=False)
        logger.info("[message_push] STORE_PUSHED thread=%s:%s role=%s phones=%d",
                    store_id, buyer_id, role, sent)
        return sent


async def _phones_for(user_id: str) -> list:
    """Every phone `user_id` is signed in on, so a send can skip the ones
    already told about this message. Empty on a lookup failure: push_user
    then tries the lookup itself, and nothing is lost but the skip."""
    from api.core import push_devices

    try:
        async with AsyncSessionLocal() as db:
            return await push_devices.tokens_for(db, user_id)
    except Exception as exc:
        # The type only: the message itself never belongs in a push log line.
        logger.warning("[message_push] no phones for user=%s: %s",
                       user_id, type(exc).__name__)
        return []


async def push_unread_for_user(user_id: str) -> int:
    """Announce everything already unread for `user_id`, thread by thread.

    Called when a phone registers (see routers/calls.py): a message sent
    while that phone was offline, uninstalled or simply not registered
    yet produced a push to no phone, and nothing re-announced it when
    the phone became reachable - it waited for a *newer* message in the
    same thread. `build_notification` returns None for threads with
    nothing unread for the user, so read history stays silent. Returns
    how many phones accepted a push.
    """
    pairs: set = set()
    async with AsyncSessionLocal() as db:
        # visibility-ok: thread ids only, no content - the notification is
        # built per role by build_notification under the audience clause.
        buyer_rows = (await db.execute(
            select(NegotiationMessage.listing_id, NegotiationMessage.buyer_id)
            .where(NegotiationMessage.buyer_id == user_id)
            .distinct()
        )).all()
        pairs.update((lid, bid, "buyer") for lid, bid in buyer_rows)
        # visibility-ok: selects thread ids only, no message content - see above
        seller_rows = (await db.execute(
            select(NegotiationMessage.listing_id, NegotiationMessage.buyer_id)
            .join(Listing, Listing.id == NegotiationMessage.listing_id)
            .where(Listing.seller_id == user_id,
                   NegotiationMessage.buyer_id.isnot(None))
            .distinct()
        )).all()
        pairs.update((lid, bid, "seller") for lid, bid in seller_rows)
    sent = 0
    for listing_id, buyer_id, role in sorted(pairs, key=lambda p: (str(p[0]), str(p[1]), p[2])):
        if listing_id is None:
            continue
        try:
            sent += await push_thread(listing_id, buyer_id, role, force=True)
        except Exception as exc:
            logger.warning("[message_push] unread re-push thread %s:%s role=%s failed: %s",
                           listing_id, buyer_id, role, exc)
    # Store-general threads unread for this user.
    try:
        from api.models.store import Store
        store_pairs: set = set()
        async with AsyncSessionLocal() as db:
            # visibility-ok: thread ids only, no content
            sbuyer = (await db.execute(
                select(NegotiationMessage.store_id, NegotiationMessage.buyer_id)
                .where(NegotiationMessage.buyer_id == user_id,
                       NegotiationMessage.store_id.isnot(None))
                .distinct()
            )).all()
            store_pairs.update((sid, bid, "buyer") for sid, bid in sbuyer if sid)
            # visibility-ok: thread ids only, no content
            sseller = (await db.execute(
                select(NegotiationMessage.store_id, NegotiationMessage.buyer_id)
                .join(Store, Store.id == NegotiationMessage.store_id)
                .where(Store.owner_id == user_id,
                       NegotiationMessage.buyer_id.isnot(None))
                .distinct()
            )).all()
            store_pairs.update((sid, bid, "seller") for sid, bid in sseller if sid)
        for store_id, sbuyer_id, srole in sorted(store_pairs):
            try:
                sent += await push_store_thread(store_id, sbuyer_id, srole, force=True)
            except Exception as exc:
                logger.warning("[message_push] unread re-push store %s:%s role=%s failed: %s",
                               store_id, sbuyer_id, srole, exc)
    except Exception as exc:
        logger.warning("[message_push] unread re-push stores failed: %s", exc)
    return sent


def schedule_unread_for_user(loop, user_id: str) -> None:
    """Fire `push_unread_for_user` off the request's task group, the same
    way `schedule` keeps a message push alive past its response."""
    task = loop.create_task(push_unread_for_user(user_id),
                            context=contextvars.Context())
    _inflight.add(task)
    task.add_done_callback(_inflight.discard)
