"""What happened to every chat message, per recipient - and the log of it.

Before this, the server knew a message was saved and, for a moment, that a
push "reached N phones". Nothing about a push was stored: a push that failed
(recipient offline, no phone registered yet, FCM unavailable) was never tried
again, a restart lost the push still waiting out its debounce, and the API
log could not say whether a given message had reached anyone. Firebase
accepting a push was the only evidence there was, and it is not delivery.

Now every message a person should receive gets a MessageDelivery row
(api/models/message_delivery.py) in the same transaction as the message:

  SAVED          the message is committed - written here, by the session hook
  PUSH_PENDING   a push for it is being sent (claimed by one attempt)
  PUSH_ACCEPTED  FCM accepted that push for at least one of their phones
  PUSH_FAILED    no phone accepted it; retried with backoff when transient
  DELIVERED      the recipient's app says it has the message: the offline
                 sync stored it, the open chat holds it, or the push handler
                 ran for it (push receipt)
  READ           they read it, by the chat's read receipts

A row only moves up that ladder (STATUS_RANK); the one way back is a failed
push being tried again. The rows are also the queue the push retry sweep
works from (retry_due_pushes, run by workers.py), and what the app's offline
sync asks for (GET /negotiate/sync): a message stays undelivered, and so
keeps being handed out, until the app acknowledges it - whatever happened
to its push.

Every step is logged on one line, event name first, ids only - never a
message's words, a push token or a credential:

  MESSAGE_SAVED message_id=... conversation_id=listing:<id>:<buyer> sender_id=...
      recipient_id=... recipient_role=seller delivery_status=SAVED attempt=0 timestamp=...

so `message_id=<id>` in the Render log shows one message's whole life.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Iterable, Optional

from sqlalchemy import and_, func, insert, or_, select, update

from api.database import AsyncSessionLocal, Listing, NegotiationMessage
from api.models.message_delivery import (
    DELIVERED, PUSH_ACCEPTED, PUSH_FAILED, PUSH_PENDING, READ, SAVED,
    STATUS_RANK, UNDELIVERED, MessageDelivery,
)

logger = logging.getLogger(__name__)

# The debounced push (message_push) normally handles a new message within a
# second or two. A row it never got to - the process restarted during the
# debounce, or push_thread raised - is the retry sweep's after this long.
FAST_PATH_GRACE_SECONDS = 20
# A claimed attempt that never reported back (the process died mid-send) is
# tried again after this. Longer than any FCM round trip.
PUSH_CLAIM_SECONDS = 120
# Five tries in all: 30s, 1m, 2m, 4m apart. Past that the push is given up -
# the message is not: the app's sync still delivers it whenever it next runs.
MAX_PUSH_ATTEMPTS = 5
RETRY_BASE_SECONDS = 30
RETRY_MAX_SECONDS = 900
# One retry sweep pass handles at most this many conversations; the rest
# wait for the next pass.
RETRY_BATCH_THREADS = 50
# A retry for one conversation that has not finished by then is abandoned;
# its rows are claimed and come back after PUSH_CLAIM_SECONDS.
RETRY_PUSH_TIMEOUT_SECONDS = 45
# Rows are kept this long, then pruned: long enough to answer "what happened
# to that message last month?", short enough that the table stays small.
RETENTION_DAYS = 60

_SAVED_KEY = "broka_delivery_saved"

# FCM's own words for why a push was refused, from firebase_admin's
# exception classes (calls._send_fcm). The Render log says UNAVAILABLE, not
# "UnavailableError".
FCM_ERROR_CODES = {
    "UnregisteredError": "UNREGISTERED",
    "SenderIdMismatchError": "SENDER_ID_MISMATCH",
    "QuotaExceededError": "QUOTA_EXCEEDED",
    "ThirdPartyAuthError": "THIRD_PARTY_AUTH_ERROR",
    "UnavailableError": "UNAVAILABLE",
    "InternalError": "INTERNAL",
    "InvalidArgumentError": "INVALID_ARGUMENT",
    "DeadlineExceededError": "DEADLINE_EXCEEDED",
    "ResourceExhaustedError": "RESOURCE_EXHAUSTED",
    "AbortedError": "ABORTED",
    "UnauthenticatedError": "UNAUTHENTICATED",
    "PermissionDeniedError": "PERMISSION_DENIED",
    "NotFoundError": "NOT_FOUND",
}


def _now() -> datetime:
    return datetime.utcnow()


def _iso(dt: Optional[datetime]) -> Optional[str]:
    return dt.isoformat() + "Z" if dt else None


def conversation_id(listing_id: Optional[str], store_id: Optional[str], buyer_id: Optional[str]) -> str:
    """One name for a conversation in every log line: listing:<id>:<buyer>
    or store:<id>:<buyer>."""
    if store_id and not listing_id:
        return f"store:{store_id}:{buyer_id or '-'}"
    return f"listing:{listing_id or '-'}:{buyer_id or '-'}"


def _fmt(value) -> str:
    if value is None or value == "":
        return "-"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, datetime):
        return _iso(value)
    # Values are ids and codes; a space would split one field into two.
    return "_".join(str(value).split()) or "-"


def log_event(event: str, **fields) -> None:
    """One lifecycle line: EVENT key=value ... with a UTC timestamp."""
    fields.setdefault("timestamp", _now())
    logger.info("%s %s", event, " ".join(f"{k}={_fmt(v)}" for k, v in fields.items()))


def _row_fields(row, *, status: Optional[str] = None, attempt=None) -> dict:
    """The identifying fields every event about one row carries, in order."""
    get = row.get if isinstance(row, dict) else (lambda k, d=None: getattr(row, k, d))
    return {
        "message_id": get("message_id"),
        "conversation_id": conversation_id(get("listing_id"), get("store_id"), get("buyer_id")),
        "sender_id": get("sender_id"),
        "recipient_id": get("recipient_id"),
        "recipient_role": get("recipient_role"),
        "delivery_status": status or get("status"),
        "attempt": get("push_attempts", 0) if attempt is None else attempt,
    }


def retry_delay_seconds(attempt: int) -> int:
    """Wait before the try after `attempt` (1-based): 30s, 1m, 2m, 4m..."""
    return int(min(RETRY_BASE_SECONDS * (2 ** max(attempt - 1, 0)), RETRY_MAX_SECONDS))


def _thread_clause(listing_id: Optional[str], store_id: Optional[str], buyer_id: str):
    MD = MessageDelivery
    if store_id and not listing_id:
        return and_(MD.store_id == store_id, MD.buyer_id == buyer_id)
    return and_(MD.listing_id == listing_id, MD.buyer_id == buyer_id)


# ── Written with the message (the session hook in message_push) ─────────────

def record_new_messages(session, messages: list) -> None:
    """Add a SAVED row for each recipient of each new message, inside the
    flush that wrote them - so the message and its tracking commit, or roll
    back, together.

    `messages` is (NegotiationMessage, roles) pairs, the roles from
    message_push.recipients_of. Synchronous: it runs in the after_flush hook
    on the flush's own connection.

    A failure here is logged and swallowed: on PostgreSQL the INSERT runs in
    a savepoint, so the message still commits. Tracking a message must never
    be what loses it.
    """
    try:
        conn = session.connection()
        if conn.dialect.name == "postgresql":
            # Both statements in the savepoint: on PostgreSQL a failed
            # statement aborts the whole transaction - the message's too.
            with conn.begin_nested():
                summaries = _write_rows(conn, messages)
        else:
            summaries = _write_rows(conn, messages)
    except Exception as exc:
        logger.error("MESSAGE_TRACKING_FAILED stage=record messages=%d error=%s",
                     len(messages), type(exc).__name__)
        summaries = [{
            "message_id": m.id, "listing_id": None if (m.store_id and not m.listing_id) else m.listing_id,
            "store_id": m.store_id if (m.store_id and not m.listing_id) else None,
            "buyer_id": m.buyer_id, "sender_id": m.sender_id, "recipient_id": None,
            "recipient_role": ",".join(sorted(roles)), "push_attempts": 0,
            "from_zeno": m.role == "broker", "kind": m.msg_type or "text", "untracked": True,
        } for m, roles in messages]
    session.info.setdefault(_SAVED_KEY, []).extend(summaries)


def _write_rows(conn, messages: list) -> list[dict]:
    """record_new_messages' two statements: who the recipients are, and
    their rows. Returns what MESSAGE_SAVED will say about each."""
    # The seller of every conversation involved, not only those with a
    # message for the seller: a seller writing in a thread on their own
    # listing (buyer_id == seller) has nobody to deliver to either way.
    sellers: dict = {}
    listing_ids = {m.listing_id for m, _ in messages if m.listing_id}
    store_ids = {m.store_id for m, _ in messages if m.store_id and not m.listing_id}
    if listing_ids:
        for lid, seller in conn.execute(
            select(Listing.id, Listing.seller_id).where(Listing.id.in_(listing_ids))
        ):
            sellers[("listing", lid)] = seller
    if store_ids:
        from api.models.store import Store
        for sid, owner in conn.execute(
            select(Store.id, Store.owner_id).where(Store.id.in_(store_ids))
        ):
            sellers[("store", sid)] = owner

    now = _now()
    rows = []
    summaries = []
    for m, roles in messages:
        is_store = bool(m.store_id) and not m.listing_id
        seller_id = sellers.get(("store", m.store_id) if is_store else ("listing", m.listing_id))
        for role in sorted(roles):
            recipient = m.buyer_id if role == "buyer" else seller_id
            if not recipient or recipient == m.sender_id:
                continue
            # A seller "buying" from themselves has no one to deliver to
            # (message_push.build_notification says the same).
            if seller_id and m.buyer_id == seller_id:
                continue
            created = m.created_at or now
            row = {
                "id": _new_id(),
                "message_id": m.id,
                "listing_id": None if is_store else m.listing_id,
                "store_id": m.store_id if is_store else None,
                "buyer_id": m.buyer_id,
                "sender_id": m.sender_id,
                "recipient_id": recipient,
                "recipient_role": role,
                "from_zeno": m.role == "broker",
                "message_created_at": created,
                "status": SAVED,
                "push_attempts": 0,
                "next_push_at": created + timedelta(seconds=FAST_PATH_GRACE_SECONDS),
                "created_at": now,
                "updated_at": now,
            }
            rows.append(row)
            summaries.append({**row, "kind": m.msg_type or "text"})
    if rows:
        conn.execute(insert(MessageDelivery.__table__), rows)
    return summaries


def _new_id() -> str:
    import uuid
    return str(uuid.uuid4())


def committed(session) -> None:
    """after_commit: the messages recorded in this transaction are saved."""
    for row in session.info.pop(_SAVED_KEY, None) or ():
        fields = _row_fields(row, status=SAVED, attempt=0)
        fields["kind"] = row.get("kind")
        fields["from_zeno"] = row.get("from_zeno")
        if row.get("untracked"):
            fields["tracked"] = False
        log_event("MESSAGE_SAVED", **fields)


def rolled_back(session) -> None:
    session.info.pop(_SAVED_KEY, None)


# ── Pushes ───────────────────────────────────────────────────────────────────

async def claim_for_push(*, listing_id: Optional[str], store_id: Optional[str],
                         buyer_id: str, role: str, up_to: datetime,
                         trigger: str, device_count: int) -> list[dict]:
    """Take this side's not-yet-pushed rows in the conversation, up to the
    message a push is about to announce, for one attempt.

    The push says "N new messages", so it covers every undelivered message
    up to `up_to`, not only the newest. A row another attempt holds
    (PUSH_PENDING whose claim has not expired) is left to that attempt; one
    already accepted, delivered or read is not pushed again.
    """
    MD = MessageDelivery
    now = _now()
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(
            select(MD).where(
                _thread_clause(listing_id, store_id, buyer_id),
                MD.recipient_role == role,
                MD.message_created_at <= up_to,
                or_(
                    MD.status.in_((SAVED, PUSH_FAILED)),
                    and_(MD.status == PUSH_PENDING,
                         or_(MD.next_push_at.is_(None), MD.next_push_at <= now)),
                ),
            ).order_by(MD.message_created_at, MD.message_id)
        )).scalars().all()
        if not rows:
            return []
        claimed = [{
            "id": r.id, "message_id": r.message_id, "listing_id": r.listing_id,
            "store_id": r.store_id, "buyer_id": r.buyer_id, "sender_id": r.sender_id,
            "recipient_id": r.recipient_id, "recipient_role": r.recipient_role,
            "attempt": int(r.push_attempts or 0) + 1,
            "previous_status": r.status, "previous_error": r.push_error,
        } for r in rows]
        await db.execute(
            update(MD).where(
                MD.id.in_([c["id"] for c in claimed]),
                MD.status.in_((SAVED, PUSH_FAILED, PUSH_PENDING)),
            ).values(
                status=PUSH_PENDING,
                push_attempts=MD.push_attempts + 1,
                next_push_at=now + timedelta(seconds=PUSH_CLAIM_SECONDS),
                updated_at=now,
            ).execution_options(synchronize_session=False)
        )
        await db.commit()
    for c in claimed:
        fields = _row_fields(c, status=PUSH_PENDING, attempt=c["attempt"])
        if trigger == "retry" or c["previous_status"] in (PUSH_FAILED, PUSH_PENDING):
            log_event("MESSAGE_DELIVERY_RETRY", **fields, trigger=trigger,
                      previous_status=c["previous_status"], previous_error=c["previous_error"])
        log_event("MESSAGE_PUSH_STARTED", **fields, device_count=device_count, trigger=trigger)
    return claimed


async def record_push_result(claimed: list[dict], *, sent: int, outcome, trigger: str) -> None:
    """Write what the attempt claimed for `claimed` did.

    Accepted by at least one phone: PUSH_ACCEPTED - not delivered; that is
    for the phone to say. Accepted by none: PUSH_FAILED, with the next try
    scheduled when the failure is one a retry can fix (FCM unavailable, a
    timeout) and attempts remain, and nothing scheduled when it cannot (no
    phone registered, a dead token, a misconfigured server). A row the
    recipient's app acknowledged while the push was in flight keeps its
    DELIVERED or READ: only rows still PUSH_PENDING are written.
    """
    if not claimed:
        return
    MD = MessageDelivery
    now = _now()
    device_count = getattr(outcome, "device_count", None)
    error = getattr(outcome, "error", None) or "NOT_ACCEPTED"
    retryable = bool(getattr(outcome, "retryable", False))
    ids = [c["id"] for c in claimed]
    try:
        async with AsyncSessionLocal() as db:
            if sent > 0:
                written = set((await db.execute(
                    update(MD).where(MD.id.in_(ids), MD.status == PUSH_PENDING).values(
                        status=PUSH_ACCEPTED, push_accepted_at=now, next_push_at=None,
                        push_error=None, updated_at=now,
                    ).returning(MD.id).execution_options(synchronize_session=False)
                )).scalars().all())
            else:
                written = set()
                for c in claimed:
                    again = retryable and c["attempt"] < MAX_PUSH_ATTEMPTS
                    c["next_retry_in_s"] = retry_delay_seconds(c["attempt"]) if again else None
                    written.update((await db.execute(
                        update(MD).where(MD.id == c["id"], MD.status == PUSH_PENDING).values(
                            status=PUSH_FAILED, push_error=error[:64],
                            next_push_at=(now + timedelta(seconds=c["next_retry_in_s"])
                                          if again else None),
                            updated_at=now,
                        ).returning(MD.id).execution_options(synchronize_session=False)
                    )).scalars().all())
            # A row the recipient's app acknowledged while the push was in
            # flight kept its DELIVERED or READ; the log says which.
            current = {}
            if len(written) < len(ids):
                current = dict((await db.execute(
                    select(MD.id, MD.status).where(MD.id.in_([i for i in ids if i not in written]))
                )).all())
            await db.commit()
    except Exception as exc:
        # The rows stay claimed and come back to the sweep once the claim
        # expires: a lost result costs a repeated push, never a lost message.
        logger.error("MESSAGE_TRACKING_FAILED stage=push_result messages=%d error=%s",
                     len(claimed), type(exc).__name__)
        return
    for c in claimed:
        if sent > 0:
            status = PUSH_ACCEPTED if c["id"] in written else current.get(c["id"])
            log_event("MESSAGE_PUSH_ACCEPTED",
                      **_row_fields(c, status=status, attempt=c["attempt"]),
                      device_count=device_count, accepted=sent, trigger=trigger)
        else:
            status = PUSH_FAILED if c["id"] in written else current.get(c["id"])
            log_event("MESSAGE_PUSH_FAILED",
                      **_row_fields(c, status=status, attempt=c["attempt"]),
                      device_count=device_count, error=error, retryable=retryable,
                      next_retry_in_s=c.get("next_retry_in_s"),
                      final=c.get("next_retry_in_s") is None, trigger=trigger)


async def skip_push(*, listing_id: Optional[str], store_id: Optional[str],
                    buyer_id: str, role: str, reason: str) -> int:
    """Nothing will be pushed for this side's waiting rows in the
    conversation - it has read everything, the conversation is gone - so
    the retry sweep stops coming back for them. Their status is untouched:
    an unpushed message is still undelivered, and the app's sync still
    delivers it."""
    MD = MessageDelivery
    now = _now()
    try:
        async with AsyncSessionLocal() as db:
            rows = (await db.execute(
                select(MD).where(
                    _thread_clause(listing_id, store_id, buyer_id),
                    MD.recipient_role == role,
                    MD.status.in_((SAVED, PUSH_FAILED, PUSH_PENDING)),
                    MD.next_push_at.isnot(None),
                    or_(MD.status != PUSH_PENDING, MD.next_push_at <= now),
                )
            )).scalars().all()
            if not rows:
                return 0
            await db.execute(
                update(MD).where(MD.id.in_([r.id for r in rows])).values(
                    next_push_at=None, push_error=reason[:64], updated_at=now,
                ).execution_options(synchronize_session=False)
            )
            await db.commit()
    except Exception as exc:
        logger.error("MESSAGE_TRACKING_FAILED stage=skip_push error=%s", type(exc).__name__)
        return 0
    for r in rows:
        log_event("MESSAGE_PUSH_SKIPPED", **_row_fields(r), reason=reason)
    return len(rows)


# ── Delivered and read ───────────────────────────────────────────────────────

async def mark_delivered(db, *, recipient_id: str, message_ids: Iterable[str], source: str,
                         sync_id: Optional[str] = None) -> dict:
    """The recipient's app has these messages: DELIVERED, once.

    Only `recipient_id`'s own rows are touched - an id that is someone
    else's message, or not a message at all, is "unknown" and changes
    nothing. Idempotent: a repeated or late acknowledgement leaves a
    DELIVERED or READ row as it is.

    Returns {"delivered": [...], "already": [...], "unknown": [...],
    "threads": {(listing_id, store_id, buyer_id, role): newest created_at}},
    the last for moving the direct chat's delivery watermark (the sender's
    double tick) up to what was acknowledged - Zeno's messages have no
    sender waiting on a tick.
    """
    MD = MessageDelivery
    ids = list(dict.fromkeys(i for i in message_ids if i))
    result = {"delivered": [], "already": [], "unknown": [], "threads": {}}
    if not ids:
        return result
    rows = (await db.execute(
        select(MD).where(MD.recipient_id == recipient_id, MD.message_id.in_(ids))
        .execution_options(populate_existing=True)
    )).scalars().all()
    by_id = {r.message_id: r for r in rows}
    now = _now()
    waiting = [r.id for r in rows if r.status in UNDELIVERED]
    changed: set = set()
    if waiting:
        changed = set((await db.execute(
            update(MD).where(MD.id.in_(waiting), MD.status.in_(UNDELIVERED)).values(
                status=DELIVERED, delivered_at=now, delivered_via=source[:24],
                next_push_at=None, updated_at=now,
            ).returning(MD.message_id).execution_options(synchronize_session=False)
        )).scalars().all())
    snapshot = [{
        "message_id": r.message_id, "listing_id": r.listing_id, "store_id": r.store_id,
        "buyer_id": r.buyer_id, "sender_id": r.sender_id, "recipient_id": r.recipient_id,
        "recipient_role": r.recipient_role, "status": r.status,
        "push_attempts": r.push_attempts, "from_zeno": bool(r.from_zeno),
        "message_created_at": r.message_created_at,
    } for r in rows]
    await db.commit()
    for s in snapshot:
        if not s["from_zeno"]:
            key = (s["listing_id"], s["store_id"], s["buyer_id"], s["recipient_role"])
            newest = result["threads"].get(key)
            if newest is None or s["message_created_at"] > newest:
                result["threads"][key] = s["message_created_at"]
    for mid in ids:
        s = next((x for x in snapshot if x["message_id"] == mid), None)
        if s is None:
            result["unknown"].append(mid)
            log_event("MESSAGE_DELIVERY_ACK_RECEIVED", message_id=mid, recipient_id=recipient_id,
                      delivery_status="-", source=source, sync_id=sync_id, result="unknown")
            continue
        if mid in changed:
            result["delivered"].append(mid)
            outcome = "delivered"
        else:
            result["already"].append(mid)
            outcome = "already_read" if by_id[mid].status == READ else "already_delivered"
        log_event("MESSAGE_DELIVERY_ACK_RECEIVED", **_row_fields(s), source=source,
                  sync_id=sync_id, result=outcome)
        if mid in changed:
            since = int((now - s["message_created_at"]).total_seconds() * 1000)
            log_event("MESSAGE_DELIVERED", **_row_fields(s, status=DELIVERED),
                      delivered_via=source, since_saved_ms=since)
    return result


async def mark_read_in_thread(db, *, listing_id: Optional[str], store_id: Optional[str],
                              buyer_id: str, role: str, read_at: datetime) -> list[dict]:
    """The read receipt for one side of one conversation: everything it was
    sent up to `read_at` is READ. Runs in the caller's transaction (the
    watermark's, negotiate._move_watermark); log the result with log_read
    once that commits.

    `role` is the watermark's: "buyer"/"seller" for the direct chat, which
    reads the other person's messages; "zeno_buyer"/"zeno_seller" for Zeno's
    room, which reads Zeno's. A push or a delivery never comes through here.
    """
    MD = MessageDelivery
    from_zeno = role.startswith("zeno_")
    side = role[len("zeno_"):] if from_zeno else role
    if side not in ("buyer", "seller"):
        return []
    rows = (await db.execute(
        select(MD).where(
            _thread_clause(listing_id, store_id, buyer_id),
            MD.recipient_role == side,
            MD.from_zeno.is_(from_zeno),
            MD.status != READ,
            MD.message_created_at <= read_at,
        ).execution_options(populate_existing=True)
    )).scalars().all()
    if not rows:
        return []
    snapshot = [{
        "id": r.id, "message_id": r.message_id, "listing_id": r.listing_id,
        "store_id": r.store_id, "buyer_id": r.buyer_id, "sender_id": r.sender_id,
        "recipient_id": r.recipient_id, "recipient_role": r.recipient_role,
        "push_attempts": r.push_attempts, "previous_status": r.status,
        "message_created_at": r.message_created_at,
    } for r in rows]
    now = _now()
    changed = set((await db.execute(
        update(MD).where(MD.id.in_([s["id"] for s in snapshot]), MD.status != READ).values(
            status=READ, read_at=read_at,
            delivered_at=func.coalesce(MD.delivered_at, read_at),
            delivered_via=func.coalesce(MD.delivered_via, "read"),
            next_push_at=None, updated_at=now,
        ).returning(MD.id).execution_options(synchronize_session=False)
    )).scalars().all())
    return [s for s in snapshot if s["id"] in changed]


def log_read(rows: list[dict], *, source: str) -> None:
    """After the read receipt committed. A message read before any delivery
    receipt is logged as delivered too - reading it proves the phone had
    it - so every READ follows a DELIVERED in the log."""
    for s in rows:
        if STATUS_RANK.get(s["previous_status"], 0) < STATUS_RANK[DELIVERED]:
            since = int((_now() - s["message_created_at"]).total_seconds() * 1000)
            log_event("MESSAGE_DELIVERED", **_row_fields(s, status=DELIVERED),
                      delivered_via="read", since_saved_ms=since)
        log_event("MESSAGE_READ", **_row_fields(s, status=READ), source=source)


# ── The app's offline sync ───────────────────────────────────────────────────

def parse_cursor(cursor: Optional[str]) -> Optional[tuple[datetime, str]]:
    """`<created_at ISO>|<message id>` - the last message of the previous
    page. None for the first page; ValueError for anything malformed."""
    if not cursor:
        return None
    from api.core.timeutil import parse_iso_to_naive_utc
    at, sep, mid = cursor.partition("|")
    if not sep or not mid or len(mid) > 64:
        raise ValueError("bad cursor")
    return parse_iso_to_naive_utc(at), mid


def make_cursor(created_at: datetime, message_id: str) -> str:
    return f"{created_at.isoformat()}Z|{message_id}"


async def pending_page(db, *, recipient_id: str, after: Optional[tuple[datetime, str]],
                       limit: int) -> tuple[list, bool]:
    """One page of `recipient_id`'s undelivered messages, oldest first, with
    whether more follow. Ordered by (sent time, id) so a page boundary never
    splits or repeats a message, however many share a timestamp.

    "Undelivered" is the server's own record, not a cursor the phone keeps:
    a message stays in these pages until the app acknowledges it, so a
    message that committed late, a sync cut off half way and a phone that
    lost what it was sent are all covered by asking again.
    """
    from api.core.message_visibility import visible_to_role_clause

    MD = MessageDelivery
    M = NegotiationMessage
    q = (
        # visibility-ok: rows exist only for a message's own audience (recipients_of), and each must also pass visible_to_role_clause for its side
        select(MD, M).join(M, M.id == MD.message_id).where(
            MD.recipient_id == recipient_id,
            MD.status.in_(UNDELIVERED),
            M.buyer_id == MD.buyer_id,
            or_(
                and_(MD.recipient_role == "buyer", visible_to_role_clause("buyer")),
                and_(MD.recipient_role == "seller", visible_to_role_clause("seller")),
            ),
        )
    )
    if after is not None:
        at, mid = after
        q = q.where(or_(MD.message_created_at > at,
                        and_(MD.message_created_at == at, MD.message_id > mid)))
    rows = (await db.execute(
        q.order_by(MD.message_created_at, MD.message_id).limit(limit + 1)
    )).all()
    return rows[:limit], len(rows) > limit


async def mark_synced(db, rows: list, *, sync_id: Optional[str], page: int) -> None:
    """The sync handed these out. Not delivered: the app has not said it
    stored them yet."""
    if not rows:
        return
    MD = MessageDelivery
    now = _now()
    await db.execute(
        update(MD).where(MD.id.in_([d.id for d, _ in rows])).values(synced_at=now)
        .execution_options(synchronize_session=False)
    )
    await db.commit()
    for d, _ in rows:
        log_event("MESSAGE_SYNCED_TO_CLIENT", **_row_fields(d), sync_id=sync_id, page=page)


# ── The retry sweep (workers.py) ─────────────────────────────────────────────

async def retry_due_pushes(now: Optional[datetime] = None) -> dict:
    """Push again what is due: failed pushes whose backoff is over, and rows
    the debounced push never took (a restart, an error). One pass; the rows
    themselves are the queue, so a restart loses nothing.

    Every conversation's attempt goes through message_push's own
    push_thread / push_store_thread, so a retry is the same notification,
    under the same per-conversation lock, as the first try.
    """
    from api.core import message_push

    MD = MessageDelivery
    now = now or _now()
    due_clause = and_(MD.status.in_((SAVED, PUSH_PENDING, PUSH_FAILED)),
                      MD.next_push_at.isnot(None), MD.next_push_at <= now)
    async with AsyncSessionLocal() as db:
        threads = (await db.execute(
            select(MD.listing_id, MD.store_id, MD.buyer_id, MD.recipient_role)
            .where(due_clause).distinct().limit(RETRY_BATCH_THREADS)
        )).all()
    report = {"threads": len(threads), "abandoned": 0}
    if not threads:
        return report
    if not message_push.push_enabled():
        # No FCM credentials on this server: nothing can be pushed, and
        # saying so per message answers "why did nobody's phone buzz?".
        settled = 0
        for listing_id, store_id, buyer_id, role in threads:
            settled += await _settle_unpushable(listing_id, store_id, buyer_id, role, now,
                                                error="PUSH_NOT_CONFIGURED")
        report["abandoned"] = settled
        return report
    import asyncio

    for listing_id, store_id, buyer_id, role in threads:
        try:
            if store_id and not listing_id:
                await asyncio.wait_for(
                    message_push.push_store_thread(store_id, buyer_id, role, trigger="retry"),
                    timeout=RETRY_PUSH_TIMEOUT_SECONDS)
            else:
                await asyncio.wait_for(
                    message_push.push_thread(listing_id, buyer_id, role, trigger="retry"),
                    timeout=RETRY_PUSH_TIMEOUT_SECONDS)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.warning("MESSAGE_DELIVERY_RETRY_FAILED conversation_id=%s recipient_role=%s error=%s",
                           conversation_id(listing_id, store_id, buyer_id), role, type(exc).__name__)
            continue
        # Due rows the attempt did not take - nothing it could announce
        # covered them - must not bring the sweep back every pass.
        report["abandoned"] += await _settle_unpushable(
            listing_id, store_id, buyer_id, role, now, error="NOT_ANNOUNCED")
    return report


async def _settle_unpushable(listing_id, store_id, buyer_id, role, now: datetime, *, error: str) -> int:
    MD = MessageDelivery
    try:
        async with AsyncSessionLocal() as db:
            rows = (await db.execute(
                select(MD).where(
                    _thread_clause(listing_id, store_id, buyer_id),
                    MD.recipient_role == role,
                    MD.status.in_((SAVED, PUSH_PENDING, PUSH_FAILED)),
                    MD.next_push_at.isnot(None), MD.next_push_at <= now,
                )
            )).scalars().all()
            if not rows:
                return 0
            await db.execute(
                update(MD).where(MD.id.in_([r.id for r in rows])).values(
                    status=PUSH_FAILED, push_error=error, next_push_at=None, updated_at=_now(),
                ).execution_options(synchronize_session=False)
            )
            await db.commit()
    except Exception as exc:
        logger.error("MESSAGE_TRACKING_FAILED stage=settle error=%s", type(exc).__name__)
        return 0
    for r in rows:
        log_event("MESSAGE_PUSH_FAILED", **_row_fields(r, status=PUSH_FAILED),
                  error=error, retryable=False, final=True, trigger="retry")
    return len(rows)


async def delivery_summary(window_hours: int = 24) -> dict:
    """Counts by status for the messages of the last `window_hours`, and how
    many are still waiting - one line in the log every few minutes, so
    "is anything stuck?" is answered without a database."""
    MD = MessageDelivery
    now = _now()
    since = now - timedelta(hours=window_hours)
    async with AsyncSessionLocal() as db:
        counts = dict((await db.execute(
            select(MD.status, func.count(MD.id)).where(MD.created_at >= since).group_by(MD.status)
        )).all())
        stale = (await db.execute(
            select(func.count(MD.id)).where(
                MD.created_at >= since, MD.status.in_(UNDELIVERED),
                MD.message_created_at < now - timedelta(minutes=10))
        )).scalar() or 0
        oldest = (await db.execute(
            select(func.min(MD.message_created_at)).where(
                MD.created_at >= since, MD.status.in_(UNDELIVERED))
        )).scalar()
    summary = {
        "window_hours": window_hours,
        "saved": int(counts.get(SAVED, 0)),
        "push_pending": int(counts.get(PUSH_PENDING, 0)),
        "push_accepted": int(counts.get(PUSH_ACCEPTED, 0)),
        "push_failed": int(counts.get(PUSH_FAILED, 0)),
        "delivered": int(counts.get(DELIVERED, 0)),
        "read": int(counts.get(READ, 0)),
        "undelivered_over_10m": int(stale),
        "oldest_undelivered_age_s": int((now - oldest).total_seconds()) if oldest else None,
    }
    log_event("MESSAGE_DELIVERY_SUMMARY", **summary)
    return summary


async def prune(now: Optional[datetime] = None) -> int:
    """Forget rows older than RETENTION_DAYS. The messages stay."""
    from sqlalchemy import delete

    MD = MessageDelivery
    cutoff = (now or _now()) - timedelta(days=RETENTION_DAYS)
    async with AsyncSessionLocal() as db:
        result = await db.execute(delete(MD).where(MD.created_at < cutoff))
        await db.commit()
    return int(result.rowcount or 0)
