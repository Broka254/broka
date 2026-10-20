"""Durable service-communication publication and delivery.

The database holds the queue. A published in-app recipient row is committed
before any provider request, and provider calls always happen outside a
database transaction. A process that dies mid-send leaves a claim that the
next pass recovers; a provider success that was not recorded is retried only
at the at-least-once boundary FCM itself provides.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import random
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta
from typing import Awaitable, Callable, Optional

from sqlalchemy import and_, exists, func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import push_devices
from api.core.audit import record_audit
from api.core.config import settings
from api.core.timeutil import to_naive_utc
from api.database import AsyncSessionLocal, User
from api.models.service_communication import (
    ServiceCommunication,
    ServiceCommunicationDeviceDelivery,
    ServiceCommunicationRecipient,
    ServiceCommunicationVersion,
)
from api.domains.service_communications.audience import (
    AudienceValidationError,
    count_audience,
    missing_user_ids,
    parse_stored_audience,
)

logger = logging.getLogger(__name__)

PushSender = Callable[..., Awaitable[object]]

_FAILURE_CATEGORIES = {
    "invalid_token", "push_not_configured", "provider_error",
    "provider_transient", "invalid_message", "provider_timeout",
    "provider_exception", "lease_check_failed", "claim_lost", "no_device",
    "retry_exhausted", "partial_failure", "communication_missing",
    "communication_expired",
}

_PERMANENT_RECIPIENT_FAILURES = (
    "invalid_token", "invalid_message", "communication_missing",
    "communication_expired",
)
# These are not retryable automatically, but an administrator may retry them
# after fixing configuration or after the user registers a device.
_ADMIN_RETRY_WITHOUT_FLAG = ("push_not_configured", "no_device")

# Firebase documents four weeks as the maximum message retention. A campaign
# may expire later than that, but a larger TTL is rejected by the provider.
_FCM_MAX_TTL_SECONDS = 28 * 24 * 60 * 60


def _runtime_stats_reset() -> dict:
    return {
        "last_pass_at": None,
        "last_pass_seconds": 0.0,
        "communications_claimed": 0,
        "communications_published": 0,
        "recipients_resolved": 0,
        "recipients_claimed": 0,
        "messages_attempted": 0,
        "provider_accepted": 0,
        "confirmed_delivered": 0,
        "failures": 0,
        "retries_scheduled": 0,
        "retries_exhausted": 0,
    }


_runtime_stats: dict = _runtime_stats_reset()


@dataclass
class PushOutcome:
    accepted: bool
    message_id: Optional[str] = None
    failure_category: Optional[str] = None
    retryable: bool = False
    configured: bool = True


@dataclass
class PassResult:
    communications_claimed: int = 0
    communications_published: int = 0
    recipients_resolved: int = 0
    recipients_claimed: int = 0
    messages_attempted: int = 0
    provider_accepted: int = 0
    confirmed_delivered: int = 0
    failures: int = 0
    retries_scheduled: int = 0
    retries_exhausted: int = 0
    errors: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return asdict(self)


def _now(value: Optional[datetime] = None) -> datetime:
    return to_naive_utc(value) if value is not None else datetime.utcnow()


def _claim_token() -> str:
    return uuid.uuid4().hex


def _fingerprint(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _safe_message_id(value: object) -> Optional[str]:
    if value is None:
        return None
    return str(value)[:255] or None


def _safe_failure_category(value: object) -> Optional[str]:
    if value is None:
        return None
    category = str(value).strip().lower()[:64]
    return category if category in _FAILURE_CATEGORIES else "provider_error"


def _retry_delay(attempt: int) -> timedelta:
    base = settings.service_communication_retry_base_seconds
    ceiling = settings.service_communication_retry_max_seconds
    raw = min(ceiling, base * (2 ** max(0, attempt - 1)))
    # Jitter avoids every device that failed during one FCM incident coming
    # back in the same second and reproducing the burst.
    return timedelta(seconds=random.uniform(max(0.0, raw * 0.75), raw * 1.25))


def _channels(value: str | None) -> list[str]:
    try:
        parsed = json.loads(value or '["in_app"]')
    except (TypeError, ValueError):
        return ["in_app"]
    if not isinstance(parsed, list):
        return ["in_app"]
    return [str(item) for item in parsed]


def _push_data(communication: ServiceCommunication) -> dict[str, str]:
    data = {
        "type": "service_communication",
        "communication_id": communication.id,
        "communication_type": communication.communication_type,
        "severity": communication.severity,
        "screen": "service_communications",
    }
    if communication.deep_link:
        data["deep_link"] = communication.deep_link
    return data


async def _default_push_sender(**kwargs) -> object:
    # Look the sender up at call time: this is the same one sender every call,
    # message and deal notification uses, and tests can stand in for it.
    from api.routers import calls
    return await calls._send_fcm(**kwargs)


def _outcome_from_provider(result: object) -> PushOutcome:
    accepted = bool(getattr(result, "sent", False)) or (result is True)
    if not accepted and not hasattr(result, "sent") and result:
        accepted = bool(result)
    configured = bool(getattr(result, "configured", True))
    category = _safe_failure_category(getattr(result, "failure_category", None))
    retryable = bool(getattr(result, "retryable", False))
    if accepted:
        return PushOutcome(
            True, message_id=_safe_message_id(getattr(result, "message_id", None)),
            configured=configured,
        )
    if not category:
        if getattr(result, "unregistered", False):
            category, retryable = "invalid_token", False
        elif not configured:
            category, retryable = "push_not_configured", False
        else:
            category, retryable = "provider_error", True
    elif category in ("invalid_token", "push_not_configured", "invalid_message"):
        # A provider cannot make a permanent token/message failure retryable
        # merely by setting the flag in an otherwise malformed result.
        retryable = False
    return PushOutcome(
        False, failure_category=category, retryable=retryable, configured=configured,
    )


async def _send_one(
    sender: PushSender, semaphore: asyncio.Semaphore, *, token: str,
    title: str, body: str, data: dict,
    before_send: Optional[Callable[[], Awaitable[bool]]] = None,
    ttl_seconds: Optional[int] = None,
) -> PushOutcome:
    async with semaphore:
        try:
            if before_send is not None and not await before_send():
                # The recipient lease was reclaimed while this device waited
                # for provider capacity. Sending now would duplicate work
                # owned by a newer worker, so this attempt stops before FCM.
                return PushOutcome(
                    False, failure_category="claim_lost", retryable=False,
                )
        except Exception as exc:
            logger.warning(
                "[service_communications] recipient lease check failed type=%s",
                type(exc).__name__,
            )
            return PushOutcome(
                False, failure_category="lease_check_failed", retryable=True,
            )
        # A renewal sets this lease to claim_seconds from now. Keep a margin
        # inside it so the completion write cannot race its own expiry.
        timeout = min(
            settings.service_communication_provider_timeout_seconds,
            max(0.1, settings.service_communication_claim_seconds - 5.0),
        )
        try:
            # FCM's SDK call runs in a thread and has no application-level
            # deadline of its own. Without this bound, one stuck provider
            # connection pins a claim until the process restarts and delays
            # every recipient behind it. The sender thread cannot be killed
            # safely, but the worker can stop waiting and retry the row.
            result = await asyncio.wait_for(
                sender(
                    token=token, title=title, body=body, data=data,
                    ttl_seconds=ttl_seconds,
                ),
                timeout=timeout,
            )
            return _outcome_from_provider(result)
        except asyncio.TimeoutError:
            logger.warning(
                "[service_communications] provider call timed out after %.1fs",
                timeout,
            )
            return PushOutcome(
                False, failure_category="provider_timeout", retryable=True,
            )
        except Exception as exc:
            # Exception text can contain a provider payload and a registration
            # token. Record and log only the sanitized class/category.
            logger.warning(
                "[service_communications] provider call failed type=%s",
                type(exc).__name__,
            )
            return PushOutcome(
                False, failure_category="provider_exception", retryable=True,
            )


async def claim_publishing(
    db: AsyncSession, *, now: Optional[datetime] = None,
    limit: Optional[int] = None,
) -> tuple[str | None, list[str]]:
    """Atomically move due/scheduled rows into a claimed publishing state.

    A compare-and-swap UPDATE is used rather than SELECT-then-modify, so two
    workers that read the same candidates cannot both win. PostgreSQL's row
    locks recheck the predicate after a concurrent update; SQLite serializes
    writers. Both end with exactly one claim token owning each row.
    """
    now = _now(now)
    token = _claim_token()
    limit = limit or settings.service_communication_communication_batch
    expires = now + timedelta(seconds=settings.service_communication_claim_seconds)
    due = or_(
        and_(
            ServiceCommunication.status == "scheduled",
            ServiceCommunication.scheduled_at.is_not(None),
            ServiceCommunication.scheduled_at <= now,
        ),
        and_(
            ServiceCommunication.status == "publishing",
            or_(
                ServiceCommunication.publish_claim_token.is_(None),
                ServiceCommunication.publish_claim_expires_at.is_(None),
                ServiceCommunication.publish_claim_expires_at < now,
            ),
        ),
    )
    candidate_ids = (
        select(ServiceCommunication.id)
        .where(due)
        .order_by(ServiceCommunication.scheduled_at, ServiceCommunication.id)
        .limit(limit)
    )
    await db.execute(
        update(ServiceCommunication)
        .where(ServiceCommunication.id.in_(candidate_ids), due)
        .values(
            status="publishing",
            publish_claim_token=token,
            publish_claim_expires_at=expires,
            updated_at=now,
        )
    )
    await db.commit()
    rows = (await db.execute(
        select(ServiceCommunication.id)
        .where(ServiceCommunication.publish_claim_token == token)
        .order_by(ServiceCommunication.scheduled_at, ServiceCommunication.id)
    )).scalars().all()
    return (token if rows else None), list(rows)


async def _record_system_audit(
    db: AsyncSession, action: str, communication_id: str, detail: dict,
) -> None:
    await record_audit(
        db, "system", action, "service_communication", communication_id,
        detail=json.dumps({"request_id": "-", **detail}, separators=(",", ":")),
    )


async def _renew_publish_claim(
    db: AsyncSession, communication_id: str, claim_token: str, now: datetime,
) -> bool:
    """Extend the audience-expansion lease only while this worker still owns it.

    A large audience is inserted over several committed batches. Without this
    compare-and-swap renewal, a pass slower than the original lease could be
    reclaimed by a second worker, and both would try to insert the same
    recipients. The conditional UPDATE makes the old owner stop before it can
    write another batch.
    """
    lease_now = max(now, datetime.utcnow())
    expires = lease_now + timedelta(
        seconds=settings.service_communication_claim_seconds
    )
    result = await db.execute(
        update(ServiceCommunication)
        .where(
            ServiceCommunication.id == communication_id,
            ServiceCommunication.status == "publishing",
            ServiceCommunication.publish_claim_token == claim_token,
        )
        .values(
            publish_claim_expires_at=expires,
            updated_at=lease_now,
        )
    )
    return int(result.rowcount or 0) == 1


async def _fail_publish_claim(
    db: AsyncSession, communication_id: str, claim_token: str, *, now: datetime,
    action: str, reason: str, detail: Optional[dict] = None,
) -> bool:
    """Fail a campaign only while this worker still owns its publication lease."""
    result = await db.execute(
        update(ServiceCommunication)
        .where(
            ServiceCommunication.id == communication_id,
            ServiceCommunication.status == "publishing",
            ServiceCommunication.publish_claim_token == claim_token,
        )
        .values(
            status="failed",
            completed_at=now,
            publish_claim_token=None,
            publish_claim_expires_at=None,
            updated_at=now,
        )
    )
    if int(result.rowcount or 0) != 1:
        await db.rollback()
        return False
    await _record_system_audit(db, action, communication_id, {
        "status": "failed", "reason": reason, **(detail or {}),
    })
    await db.commit()
    return True


async def _renew_recipient_claim_in_session(
    db: AsyncSession, recipient_id: str, owned_token: str, *, now: datetime,
) -> bool:
    lease_now = max(now, datetime.utcnow())
    expires = lease_now + timedelta(
        seconds=settings.service_communication_claim_seconds
    )
    result = await db.execute(
        update(ServiceCommunicationRecipient)
        .where(
            ServiceCommunicationRecipient.id == recipient_id,
            ServiceCommunicationRecipient.status == "sending",
            ServiceCommunicationRecipient.claim_token == owned_token,
        )
        .values(claim_expires_at=expires, updated_at=lease_now)
    )
    return int(result.rowcount or 0) == 1


async def _renew_recipient_claim(
    recipient_id: str, owned_token: str, *, now: datetime,
) -> bool:
    """Renew a recipient lease just before a provider call acquires capacity."""
    async with AsyncSessionLocal() as db:
        renewed = await _renew_recipient_claim_in_session(
            db, recipient_id, owned_token, now=now,
        )
        await db.commit()
    return renewed


async def _update_recipient_if_claimed(
    db: AsyncSession, recipient_id: str, owned_token: str, *, now: datetime,
    **values,
) -> bool:
    """Apply a terminal recipient state only while the caller still owns it."""
    result = await db.execute(
        update(ServiceCommunicationRecipient)
        .where(
            ServiceCommunicationRecipient.id == recipient_id,
            ServiceCommunicationRecipient.status == "sending",
            ServiceCommunicationRecipient.claim_token == owned_token,
        )
        .values(updated_at=now, **values)
    )
    return int(result.rowcount or 0) == 1


async def _finish_claimed_recipient(
    recipient_id: str, owned_token: str, *, now: datetime, **values,
) -> bool:
    async with AsyncSessionLocal() as db:
        changed = await _update_recipient_if_claimed(
            db, recipient_id, owned_token, now=now, **values,
        )
        await db.commit()
    return changed


async def publish_claimed(
    communication_id: str, claim_token: str, *,
    now: Optional[datetime] = None,
) -> int:
    """Resolve the audience and mark the communication published.

    Only DB work happens here. Recipient rows are inserted in bounded batches
    and committed before the caller starts any provider request. Re-running
    after a crash is safe: the NOT EXISTS query skips rows already present.
    """
    now = _now(now)
    async with AsyncSessionLocal() as db:
        communication = (await db.execute(
            select(ServiceCommunication).where(ServiceCommunication.id == communication_id)
        )).scalar_one_or_none()
        if communication is None:
            return -1
        if (
            communication.status != "publishing"
            or communication.publish_claim_token != claim_token
        ):
            return -1
        if communication.expires_at is not None and communication.expires_at <= now:
            await _fail_publish_claim(
                db, communication_id, claim_token, now=now,
                action="service_communication_expired",
                reason="expired_before_publication",
            )
            return -1

        # Keep this as a plain value. An IntegrityError below rolls the
        # session back, which expires every ORM object loaded before it; the
        # final expiry check then cannot lazy-load in async code.
        expires_at = communication.expires_at

        try:
            audience = parse_stored_audience(communication.audience_json)
            count = await count_audience(db, audience)
        except AudienceValidationError as exc:
            logger.error(
                "[service_communications] invalid stored audience id=%s: %s",
                communication.id, exc,
            )
            await _fail_publish_claim(
                db, communication_id, claim_token, now=now,
                action="service_communication_failed", reason="invalid_audience",
            )
            return -1

        if count > settings.service_communication_max_audience:
            logger.error(
                "[service_communications] audience too large id=%s count=%d max=%d",
                communication.id, count, settings.service_communication_max_audience,
            )
            await _fail_publish_claim(
                db, communication_id, claim_token, now=now,
                action="service_communication_failed", reason="audience_too_large",
            )
            return -1

        conflicts = 0
        batch = max(1, min(1000, settings.service_communication_recipient_batch * 10))
        while True:
            if not await _renew_publish_claim(db, communication_id, claim_token, now):
                await db.rollback()
                logger.warning(
                    "[service_communications] publication claim lost id=%s",
                    communication_id,
                )
                return -1
            user_ids = await missing_user_ids(db, communication_id, audience, batch)
            if not user_ids:
                break
            db.add_all([
                ServiceCommunicationRecipient(
                    communication_id=communication_id,
                    user_id=user_id,
                    status="queued",
                    next_attempt_at=now,
                    created_at=now,
                    updated_at=now,
                )
                for user_id in user_ids
            ])
            try:
                await db.commit()
            except IntegrityError:
                # A stale worker can race a reclaimed one at the unique
                # (communication_id, user_id) boundary. Roll back this batch
                # and let the next bounded query observe the winner's rows;
                # the claim renewal above prevents an unbounded replay.
                await db.rollback()
                conflicts += 1
                if conflicts >= 3:
                    logger.error(
                        "[service_communications] repeated recipient insert conflict id=%s",
                        communication_id,
                    )
                    return -1
                continue

        total_recipients = int((await db.execute(
            select(func.count(ServiceCommunicationRecipient.id)).where(
                ServiceCommunicationRecipient.communication_id == communication_id,
            )
        )).scalar() or 0)
        if total_recipients > settings.service_communication_max_audience:
            await _fail_publish_claim(
                db, communication_id, claim_token, now=now,
                action="service_communication_failed", reason="audience_too_large",
                detail={"recipients": total_recipients},
            )
            return -1

        final_now = max(now, datetime.utcnow())
        if expires_at is not None and expires_at <= final_now:
            await _fail_publish_claim(
                db, communication_id, claim_token, now=final_now,
                action="service_communication_expired",
                reason="expired_during_publication",
            )
            return -1

        # Finalise with the same conditional ownership as every batch. The
        # previous ORM assignment could overwrite a newer worker's state when
        # a lease expired during the final count.
        finalised = await db.execute(
            update(ServiceCommunication)
            .where(
                ServiceCommunication.id == communication_id,
                ServiceCommunication.status == "publishing",
                ServiceCommunication.publish_claim_token == claim_token,
                or_(
                    ServiceCommunication.expires_at.is_(None),
                    ServiceCommunication.expires_at > final_now,
                ),
            )
            .values(
                status="published",
                published_at=func.coalesce(ServiceCommunication.published_at, final_now),
                audience_count=total_recipients,
                publish_claim_token=None,
                publish_claim_expires_at=None,
                updated_at=final_now,
            )
        )
        if int(finalised.rowcount or 0) != 1:
            # The expiry predicate can lose after the check above. Return this
            # campaign to a terminal state rather than leaving it published
            # with an expiry already in the past and unreachable to customers.
            await _fail_publish_claim(
                db, communication_id, claim_token, now=final_now,
                action="service_communication_expired",
                reason="expired_during_publication",
            )
            return -1
        await _record_system_audit(db, "service_communication_published", communication_id, {
            "status": "published", "recipients": total_recipients,
        })
        await db.commit()
        logger.info(
            "[service_communications] event=published id=%s recipients=%d",
            communication_id, total_recipients,
        )
        return total_recipients


async def reap_stale_recipients(db: AsyncSession, *, now: datetime) -> None:
    """Turn abandoned or exhausted attempts into a terminal, visible state."""
    await db.execute(
        update(ServiceCommunicationRecipient)
        .where(
            ServiceCommunicationRecipient.status == "sending",
            ServiceCommunicationRecipient.claim_expires_at.is_not(None),
            ServiceCommunicationRecipient.claim_expires_at < now,
            ServiceCommunicationRecipient.attempt_count >= settings.service_communication_max_attempts,
        )
        .values(
            status="failed",
            retry_eligible=False,
            failure_category="retry_exhausted",
            claim_token=None,
            claim_expires_at=None,
            updated_at=now,
        )
    )
    await db.execute(
        update(ServiceCommunicationRecipient)
        .where(
            ServiceCommunicationRecipient.status == "retry_scheduled",
            ServiceCommunicationRecipient.attempt_count >= settings.service_communication_max_attempts,
        )
        .values(
            status="failed",
            retry_eligible=False,
            failure_category="retry_exhausted",
            next_attempt_at=None,
            updated_at=now,
        )
    )
    await db.commit()


async def claim_recipients(
    db: AsyncSession, *, now: Optional[datetime] = None,
    limit: Optional[int] = None,
) -> tuple[str | None, list[str]]:
    now = _now(now)
    token = _claim_token()
    limit = limit or settings.service_communication_recipient_batch
    expires = now + timedelta(seconds=settings.service_communication_claim_seconds)
    due = and_(
        ServiceCommunicationRecipient.attempt_count < settings.service_communication_max_attempts,
        or_(
            and_(
                ServiceCommunicationRecipient.status.in_(("queued", "retry_scheduled")),
                or_(
                    ServiceCommunicationRecipient.next_attempt_at.is_(None),
                    ServiceCommunicationRecipient.next_attempt_at <= now,
                ),
            ),
            and_(
                ServiceCommunicationRecipient.status == "sending",
                or_(
                    ServiceCommunicationRecipient.claim_expires_at.is_(None),
                    ServiceCommunicationRecipient.claim_expires_at < now,
                ),
            ),
        ),
        exists().where(
            and_(
                ServiceCommunication.id == ServiceCommunicationRecipient.communication_id,
                # Recipient rows are committed before the campaign's final
                # status update, so another replica could otherwise deliver a
                # push for a campaign that never becomes visible in-app (it
                # could still fail its audience/expiry finalisation). Delivery
                # starts only after publication is committed.
                ServiceCommunication.status == "published",
            )
        ),
    )
    candidate_ids = (
        select(ServiceCommunicationRecipient.id)
        .where(due)
        .order_by(ServiceCommunicationRecipient.next_attempt_at, ServiceCommunicationRecipient.id)
        .limit(limit)
    )
    await db.execute(
        update(ServiceCommunicationRecipient)
        .where(ServiceCommunicationRecipient.id.in_(candidate_ids), due)
        .values(
            status="sending",
            claim_token=token,
            claim_expires_at=expires,
            attempt_count=ServiceCommunicationRecipient.attempt_count + 1,
            last_attempt_at=now,
            next_attempt_at=None,
            retry_eligible=False,
            updated_at=now,
        )
    )
    await db.commit()
    rows = (await db.execute(
        select(ServiceCommunicationRecipient.id)
        .where(ServiceCommunicationRecipient.claim_token == token)
    )).scalars().all()
    return (token if rows else None), list(rows)


async def _prepare_device_attempts(
    db: AsyncSession, recipient: ServiceCommunicationRecipient,
    communication: ServiceCommunication, *, now: datetime,
) -> tuple[list[tuple[str, str]], list[str], bool]:
    """Create/refresh device rows before the provider call.

    Returns (token, fingerprint-suffix) pairs, the raw tokens to forget if a
    provider says they are dead, and whether push is configured. The suffix
    is the device row id, so provider results can be applied without ever
    putting a token in memory longer than this call needs it.
    """
    from api.routers import calls

    if "push" not in _channels(communication.channels_json):
        return [], [], True
    if calls._get_fcm() is None:
        return [], [], False

    tokens = await push_devices.tokens_for(db, recipient.user_id)
    if not tokens:
        return [], [], True

    fingerprints = {_fingerprint(token): token for token in tokens}
    existing = (await db.execute(
        select(ServiceCommunicationDeviceDelivery).where(
            ServiceCommunicationDeviceDelivery.recipient_id == recipient.id,
            ServiceCommunicationDeviceDelivery.device_fingerprint.in_(list(fingerprints)),
        )
    )).scalars().all()
    by_fp = {row.device_fingerprint: row for row in existing}
    attempts: list[tuple[str, str]] = []
    for fingerprint, token in fingerprints.items():
        row = by_fp.get(fingerprint)
        if row is not None and row.status in ("provider_accepted", "delivered"):
            continue
        if row is None:
            row = ServiceCommunicationDeviceDelivery(
                recipient_id=recipient.id,
                communication_id=communication.id,
                device_fingerprint=fingerprint,
                status="sending",
                attempt_count=1,
                last_attempt_at=now,
                retry_eligible=False,
                created_at=now,
                updated_at=now,
            )
            db.add(row)
        else:
            row.status = "sending"
            row.attempt_count += 1
            row.last_attempt_at = now
            row.retry_eligible = False
            row.failure_category = None
            row.next_attempt_at = None
            row.updated_at = now
        await db.flush()
        attempts.append((token, row.id))
    return attempts, list(fingerprints.values()), True


async def deliver_recipient(
    recipient_id: str, claim_token: str, *, now: Optional[datetime] = None,
    sender: Optional[PushSender] = None,
    semaphore: Optional[asyncio.Semaphore] = None,
) -> dict:
    """Deliver one claimed recipient, recording every device independently."""
    now = _now(now)
    sender = sender or _default_push_sender
    semaphore = semaphore or asyncio.Semaphore(
        settings.service_communication_provider_concurrency
    )

    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient).where(
                ServiceCommunicationRecipient.id == recipient_id,
            )
        )).scalar_one_or_none()
        if recipient is None or recipient.status != "sending" or recipient.claim_token != claim_token:
            return {"status": "skipped"}
        communication = await db.get(ServiceCommunication, recipient.communication_id)
        if communication is None:
            changed = await _update_recipient_if_claimed(
                db, recipient_id, claim_token, now=now,
                status="failed", failure_category="communication_missing",
                retry_eligible=False, claim_token=None, claim_expires_at=None,
            )
            if not changed:
                await db.rollback()
                return {"status": "claim_lost"}
            await db.commit()
            return {"status": "failed", "category": "communication_missing"}

        if not await _renew_recipient_claim_in_session(
            db, recipient_id, claim_token, now=now,
        ):
            await db.rollback()
            return {"status": "claim_lost"}

        channels = _channels(communication.channels_json)
        if "push" not in channels:
            # An in-app recipient row is itself reliable evidence that the
            # announcement is available in the authenticated feed.
            changed = await _update_recipient_if_claimed(
                db, recipient_id, claim_token, now=now,
                status="delivered", delivered_at=communication.published_at or now,
                retry_eligible=False, failure_category=None,
                claim_token=None, claim_expires_at=None, next_attempt_at=None,
            )
            if not changed:
                await db.rollback()
                return {"status": "claim_lost"}
            await db.commit()
            return {"status": "delivered", "channel": "in_app", "attempted": 0}

        if communication.expires_at is not None and communication.expires_at <= datetime.utcnow():
            # Delivery can start long after publication when a large audience
            # is draining. A push that arrives after the in-app notice has
            # already disappeared is stale, so it must not be sent at all.
            changed = await _update_recipient_if_claimed(
                db, recipient_id, claim_token, now=now,
                status="failed", failure_category="communication_expired",
                retry_eligible=False, claim_token=None, claim_expires_at=None,
                next_attempt_at=None,
            )
            if not changed:
                await db.rollback()
                return {"status": "claim_lost"}
            await db.commit()
            return {"status": "failed", "category": "communication_expired", "attempted": 0}

        attempts, tokens, configured = await _prepare_device_attempts(
            db, recipient, communication, now=now,
        )
        await db.commit()

    if not configured:
        changed = await _finish_claimed_recipient(
            recipient_id, claim_token, now=now, status="failed",
            failure_category="push_not_configured", retry_eligible=False,
            claim_token=None, claim_expires_at=None, next_attempt_at=None,
        )
        if not changed:
            return {"status": "claim_lost"}
        return {"status": "failed", "category": "push_not_configured", "attempted": 0}
    if not tokens:
        changed = await _finish_claimed_recipient(
            recipient_id, claim_token, now=now, status="failed",
            failure_category="no_device", retry_eligible=False,
            claim_token=None, claim_expires_at=None, next_attempt_at=None,
        )
        if not changed:
            return {"status": "claim_lost"}
        return {"status": "failed", "category": "no_device", "attempted": 0}
    if not attempts:
        # Every registered device already accepted an earlier attempt.
        changed = await _finish_claimed_recipient(
            recipient_id, claim_token, now=now, status="provider_accepted",
            failure_category=None, retry_eligible=False, claim_token=None,
            claim_expires_at=None, next_attempt_at=None,
        )
        if not changed:
            return {"status": "claim_lost"}
        return {"status": "provider_accepted", "duplicate_prevented": True, "attempted": 0}

    # Provider requests are outside every DB transaction above and below.
    async def renew_claim() -> bool:
        return await _renew_recipient_claim(
            recipient_id, claim_token, now=now,
        )

    push_ttl = None
    if communication.expires_at is not None:
        # Do not let FCM show an announcement after its in-app expiry. FCM's
        # default TTL is four weeks, long after a maintenance window is over,
        # but its documented maximum is also four weeks.
        remaining = int((communication.expires_at - datetime.utcnow()).total_seconds())
        push_ttl = min(_FCM_MAX_TTL_SECONDS, max(1, remaining))

    results = await asyncio.gather(*(
        _send_one(
            sender, semaphore, token=token, title=communication.title,
            body=communication.body, data=_push_data(communication),
            before_send=renew_claim, ttl_seconds=push_ttl,
        )
        for token, _ in attempts
    ))

    dead_tokens = [
        token for (token, _), outcome in zip(attempts, results)
        if outcome.failure_category == "invalid_token"
    ]

    async with AsyncSessionLocal() as db:
        recipient = (await db.execute(
            select(ServiceCommunicationRecipient)
            .where(ServiceCommunicationRecipient.id == recipient_id)
            .execution_options(populate_existing=True)
        )).scalar_one_or_none()
        if recipient is None:
            return {"status": "missing"}
        if recipient.status != "sending" or recipient.claim_token != claim_token:
            # A newer worker owns this recipient now. Do not let an old,
            # slow attempt overwrite its state.
            return {"status": "claim_lost"}
        if not await _renew_recipient_claim_in_session(
            db, recipient_id, claim_token, now=now,
        ):
            await db.rollback()
            return {"status": "claim_lost"}

        accepted_any = False
        retryable_count = 0
        exhausted_count = 0
        first_message_id = None
        categories: list[str] = []
        for (_, device_row_id), outcome in zip(attempts, results):
            device = await db.get(ServiceCommunicationDeviceDelivery, device_row_id)
            if device is None:
                continue
            device.last_attempt_at = now
            device.updated_at = now
            if outcome.accepted:
                accepted_any = True
                device.status = "provider_accepted"
                device.provider_message_id = outcome.message_id
                device.failure_category = None
                device.retry_eligible = False
                device.next_attempt_at = None
                first_message_id = first_message_id or outcome.message_id
            else:
                category = outcome.failure_category or "provider_error"
                categories.append(category)
                device.failure_category = category
                if outcome.retryable:
                    if device.attempt_count < settings.service_communication_max_attempts:
                        device.status = "retry_scheduled"
                        device.retry_eligible = True
                        device.next_attempt_at = now + _retry_delay(device.attempt_count)
                        retryable_count += 1
                    else:
                        device.status = "failed"
                        device.retry_eligible = False
                        device.next_attempt_at = None
                        device.failure_category = "retry_exhausted"
                        exhausted_count += 1
                else:
                    device.status = "failed"
                    device.retry_eligible = False
                    device.next_attempt_at = None

        # Once any device accepted, the recipient has succeeded at the level
        # the product promises. Retrying another device would risk duplicate
        # copies on a phone and is not needed for in-app visibility.
        final_status: str
        final_category: Optional[str]
        final_retryable: bool
        final_next_attempt: Optional[datetime]
        final_message_id = first_message_id
        if accepted_any:
            final_status = "provider_accepted"
            final_category = "partial_failure" if categories else None
            final_retryable = False
            final_next_attempt = None
            for (_, device_row_id) in attempts:
                device = await db.get(ServiceCommunicationDeviceDelivery, device_row_id)
                if device is not None and device.status != "provider_accepted":
                    device.status = "failed"
                    device.retry_eligible = False
                    device.next_attempt_at = None
        elif retryable_count:
            next_attempts = [
                row.next_attempt_at for row in (await db.execute(
                    select(ServiceCommunicationDeviceDelivery).where(
                        ServiceCommunicationDeviceDelivery.recipient_id == recipient.id,
                        ServiceCommunicationDeviceDelivery.status == "retry_scheduled",
                    )
                )).scalars().all() if row.next_attempt_at is not None
            ]
            final_status = "retry_scheduled"
            # Keep the actionable provider category on the recipient; the
            # status already says the retry is scheduled. Replacing it with
            # the status name hid whether the next attempt was worth waiting
            # for after a quota, timeout or transient network failure.
            final_category = categories[0] if categories else "provider_error"
            final_retryable = True
            final_next_attempt = (
                min(next_attempts) if next_attempts
                else now + _retry_delay(recipient.attempt_count)
            )
            final_message_id = None
        else:
            final_status = "failed"
            final_category = (
                "retry_exhausted" if exhausted_count
                else (categories[0] if categories else "provider_error")
            )
            final_retryable = False
            final_next_attempt = None
            final_message_id = None
        changed = await _update_recipient_if_claimed(
            db, recipient_id, claim_token, now=now,
            status=final_status,
            provider_message_id=final_message_id,
            failure_category=final_category,
            retry_eligible=final_retryable,
            next_attempt_at=final_next_attempt,
            claim_token=None,
            claim_expires_at=None,
        )
        if not changed:
            await db.rollback()
            return {"status": "claim_lost"}
        await db.commit()
        status = final_status
        category = final_category

    for token in dead_tokens:
        await push_devices.forget(token)

    return {
        "status": status, "category": category, "attempted": len(attempts),
    }


async def complete_published_communications(db: AsyncSession, *, now: datetime) -> int:
    pending = exists().where(
        and_(
            ServiceCommunicationRecipient.communication_id == ServiceCommunication.id,
            ServiceCommunicationRecipient.status.in_(("queued", "sending", "retry_scheduled")),
        )
    )
    result = await db.execute(
        update(ServiceCommunication)
        .where(
            ServiceCommunication.status == "published",
            ServiceCommunication.published_at.is_not(None),
            ~pending,
        )
        .values(status="completed", completed_at=now, updated_at=now)
    )
    await db.commit()
    return int(result.rowcount or 0)


async def run_service_communications_pass(
    *, now: Optional[datetime] = None, sender: Optional[PushSender] = None,
    communication_limit: Optional[int] = None,
    recipient_limit: Optional[int] = None,
) -> PassResult:
    """One bounded pass: publish due rows, deliver claimed recipients, settle."""
    started = datetime.utcnow()
    now = _now(now)
    result = PassResult()
    sender = sender or _default_push_sender
    semaphore = asyncio.Semaphore(settings.service_communication_provider_concurrency)

    async with AsyncSessionLocal() as db:
        await reap_stale_recipients(db, now=now)
        claim_token, communication_ids = await claim_publishing(
            db, now=now, limit=communication_limit,
        )
    result.communications_claimed = len(communication_ids)

    for communication_id in communication_ids:
        try:
            inserted = await publish_claimed(
                communication_id, claim_token or "", now=now,
            )
            if inserted >= 0:
                result.communications_published += 1
                result.recipients_resolved += inserted
            else:
                result.errors.append(f"publish:{communication_id}")
        except Exception as exc:
            logger.error(
                "[service_communications] publish failed id=%s type=%s",
                communication_id, type(exc).__name__,
            )
            result.errors.append(f"publish:{communication_id}:{type(exc).__name__}")

    async with AsyncSessionLocal() as db:
        recipient_claim_token, recipient_ids = await claim_recipients(
            db, now=now, limit=recipient_limit,
        )
    result.recipients_claimed = len(recipient_ids)

    deliveries = await asyncio.gather(*(
        deliver_recipient(
            recipient_id, recipient_claim_token or "", now=now,
            sender=sender, semaphore=semaphore,
        )
        for recipient_id in recipient_ids
    ), return_exceptions=True)
    for item in deliveries:
        if isinstance(item, BaseException):
            logger.error(
                "[service_communications] delivery failed type=%s",
                type(item).__name__,
            )
            result.errors.append(f"deliver:{type(item).__name__}")
            result.failures += 1
            continue
        status = item.get("status")
        result.messages_attempted += int(item.get("attempted") or 0)
        if status == "provider_accepted":
            result.provider_accepted += 1
        elif status == "delivered":
            result.confirmed_delivered += 1
        elif status == "retry_scheduled":
            result.retries_scheduled += 1
        elif status == "failed":
            result.failures += 1
            if item.get("category") == "retry_exhausted":
                result.retries_exhausted += 1

    async with AsyncSessionLocal() as db:
        completed = await complete_published_communications(db, now=now)
    if completed:
        logger.info(
            "[service_communications] event=completed campaigns=%d", completed,
        )

    elapsed = (datetime.utcnow() - started).total_seconds()
    _runtime_stats.update({
        "last_pass_at": now,
        "last_pass_seconds": elapsed,
        "communications_claimed": result.communications_claimed,
        "communications_published": result.communications_published,
        "recipients_resolved": result.recipients_resolved,
        "recipients_claimed": result.recipients_claimed,
        "messages_attempted": result.messages_attempted,
        "provider_accepted": result.provider_accepted,
        "confirmed_delivered": result.confirmed_delivered,
        "failures": result.failures,
        "retries_scheduled": result.retries_scheduled,
        "retries_exhausted": result.retries_exhausted,
    })
    if result.communications_claimed or result.recipients_claimed:
        logger.info(
            "[service_communications] event=pass claimed=%d published=%d recipients=%d "
            "attempted=%d accepted=%d delivered=%d retries=%d failed=%d elapsed=%.2fs",
            result.communications_claimed, result.communications_published,
            result.recipients_claimed, result.messages_attempted, result.provider_accepted,
            result.confirmed_delivered, result.retries_scheduled,
            result.failures, elapsed,
        )
    return result


async def retry_eligible_recipients(
    db: AsyncSession, communication_id: str, *, recipient_ids: Optional[list[str]] = None,
    limit: int = 500, now: Optional[datetime] = None, commit: bool = True,
) -> int:
    """Requeue failed recipients that still have provider retry budget.

    The attempt count is deliberately not reset: an administrator can retry
    an eligible failure, but cannot turn the configured provider retry cap
    into an unbounded send loop.
    """
    now = _now(now)
    conditions = [
        ServiceCommunicationRecipient.communication_id == communication_id,
        or_(
            ServiceCommunicationRecipient.failure_category.is_(None),
            and_(
                ServiceCommunicationRecipient.failure_category.notin_(
                    _PERMANENT_RECIPIENT_FAILURES,
                ),
                or_(
                    ServiceCommunicationRecipient.retry_eligible.is_(True),
                    ServiceCommunicationRecipient.failure_category.in_(
                        _ADMIN_RETRY_WITHOUT_FLAG,
                    ),
                ),
            ),
        ),
        ServiceCommunicationRecipient.attempt_count < settings.service_communication_max_attempts,
        or_(
            ServiceCommunicationRecipient.status.in_(("failed", "retry_scheduled")),
            ServiceCommunicationRecipient.retry_eligible.is_(True),
        ),
    ]
    if recipient_ids is not None:
        # An omitted selection means every eligible recipient; an explicit
        # empty selection must not mean the same thing. That ambiguity could
        # turn a UI bug into a mass retry.
        selected = recipient_ids[:limit]
        if not selected:
            return 0
        conditions.append(ServiceCommunicationRecipient.id.in_(selected))
    candidates = (
        select(ServiceCommunicationRecipient.id)
        .where(*conditions)
        .order_by(ServiceCommunicationRecipient.id)
        .limit(limit)
    )
    result = await db.execute(
        update(ServiceCommunicationRecipient)
        .where(ServiceCommunicationRecipient.id.in_(candidates), *conditions)
        .values(
            status="queued",
            next_attempt_at=now,
            retry_eligible=False,
            claim_token=None,
            claim_expires_at=None,
            updated_at=now,
        )
    )
    if (result.rowcount or 0) > 0:
        # Completion is reversible for an explicit administrative retry:
        # the delivery worker only claims recipients whose parent is back in
        # an active publication state.
        await db.execute(
            update(ServiceCommunication)
            .where(
                ServiceCommunication.id == communication_id,
                ServiceCommunication.status == "completed",
            )
            .values(status="published", completed_at=None, updated_at=now)
        )
    if commit:
        await db.commit()
    return int(result.rowcount or 0)


async def runtime_diagnostics(db: AsyncSession) -> dict:
    """Admin-visible durable backlog plus this process's last pass."""
    recipient_rows = (await db.execute(
        select(ServiceCommunicationRecipient.status, func.count())
        .group_by(ServiceCommunicationRecipient.status)
    )).all()
    communication_rows = (await db.execute(
        select(ServiceCommunication.status, func.count())
        .group_by(ServiceCommunication.status)
    )).all()
    return {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "worker": {
            "mode": "database_scheduled_loop",
            "sweep_seconds": settings.service_communication_sweep_seconds,
            "claim_seconds": settings.service_communication_claim_seconds,
            "recipient_batch": settings.service_communication_recipient_batch,
            "provider_concurrency": settings.service_communication_provider_concurrency,
            "provider_timeout_seconds": settings.service_communication_provider_timeout_seconds,
            "retention_days": settings.service_communication_retention_days,
            "last_pass": {
                **_runtime_stats,
                "last_pass_at": (
                    _runtime_stats["last_pass_at"].isoformat() + "Z"
                    if isinstance(_runtime_stats["last_pass_at"], datetime) else None
                ),
            },
        },
        "backlog": {
            "communications": {str(status): int(count) for status, count in communication_rows},
            "recipients": {str(status): int(count) for status, count in recipient_rows},
            "pending_recipients": sum(
                int(count) for status, count in recipient_rows
                if str(status) in ("queued", "sending", "retry_scheduled")
            ),
        },
    }


async def create_version(
    db: AsyncSession, communication: ServiceCommunication, editor_id: str,
) -> None:
    db.add(ServiceCommunicationVersion(
        communication_id=communication.id,
        version=communication.version,
        title=communication.title,
        body=communication.body,
        communication_type=communication.communication_type,
        severity=communication.severity,
        audience_json=communication.audience_json,
        channels_json=communication.channels_json,
        deep_link=communication.deep_link,
        edited_by_id=editor_id,
        created_at=datetime.utcnow(),
    ))


__all__ = [
    "PushOutcome", "PassResult", "claim_publishing", "publish_claimed",
    "claim_recipients", "deliver_recipient", "run_service_communications_pass",
    "retry_eligible_recipients", "runtime_diagnostics", "create_version",
    "complete_published_communications",
]
