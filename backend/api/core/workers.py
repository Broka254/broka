"""
BROKA v4.0 - Background Worker Infrastructure
─────────────────────────────────────────────────────────────────────────────
Two-tier worker system:

  Tier 1 — ARQ (production, Redis-backed, crash-durable)
    • Jobs persist across restarts. Multiple instances for horizontal scaling.
    • Retry logic, timeouts, job deduplication built in.
    • Requires REDIS_URL env var + `arq` package.

  Tier 2 — In-process asyncio queue (dev / single-instance fallback)
    • Zero dependencies. Jobs lost on process exit.
    • Activates automatically when ARQ / Redis is unavailable.

Named queues: notifications, ai, fraud, payments, listings

Usage:
    await enqueue("notifications", task_send_fcm_notification,
                  fcm_token="...", title="...", body="...")

ARQ worker launch (production):
    arq api.core.workers.WorkerSettings
"""
from __future__ import annotations

import asyncio
import logging
from typing import Any, Callable, Coroutine

logger = logging.getLogger(__name__)
Task = Callable[..., Coroutine[Any, Any, None]]


# ── In-process asyncio worker (fallback) ─────────────────────────────────────

class BackgroundWorker:
    """Single-process async task queue with configurable concurrency."""

    def __init__(self, name: str = "default", concurrency: int = 4, max_queue: int = 500):
        self.name         = name
        self._queue: asyncio.Queue = asyncio.Queue(maxsize=max_queue)
        self._concurrency = concurrency
        self._running     = False
        self._tasks: list[asyncio.Task] = []

    async def start(self) -> None:
        self._running = True
        self._tasks = [asyncio.create_task(self._worker(i)) for i in range(self._concurrency)]
        logger.info("[worker:%s] started %d worker(s)", self.name, self._concurrency)

    async def stop(self) -> None:
        self._running = False
        for _ in self._tasks:
            await self._queue.put(None)
        await asyncio.gather(*self._tasks, return_exceptions=True)
        logger.info("[worker:%s] stopped", self.name)

    async def enqueue(self, fn: Task, **kwargs: Any) -> None:
        try:
            await asyncio.wait_for(self._queue.put((fn, kwargs)), timeout=0.1)
        except (asyncio.QueueFull, asyncio.TimeoutError):
            logger.warning("[worker:%s] queue full — dropping task %s", self.name, fn.__name__)

    async def _worker(self, wid: int) -> None:
        while self._running:
            item = await self._queue.get()
            if item is None:
                break
            fn, kwargs = item
            try:
                await fn(**kwargs)
            except Exception as exc:
                logger.error("[worker:%s-%d] task %s failed: %s", self.name, wid, fn.__name__, exc)
            finally:
                self._queue.task_done()


# ── Named queues (in-process) ─────────────────────────────────────────────────

_queues: dict[str, BackgroundWorker] = {
    "notifications": BackgroundWorker("notifications", concurrency=4),
    "ai":            BackgroundWorker("ai",            concurrency=2),
    "fraud":         BackgroundWorker("fraud",         concurrency=2),
    "payments":      BackgroundWorker("payments",      concurrency=2),
    "listings":      BackgroundWorker("listings",      concurrency=2),
}

# Legacy singleton for backward compat
worker = _queues["fraud"]


async def start_all_workers() -> None:
    for q in _queues.values():
        await q.start()


# ── Periodic sweep loop ─────────────────────────────────────────────────────
# Unlike the queues above (on-demand, run-once tasks), this is a genuine
# recurring loop - the deterministic mechanism behind AI-announced deal
# timers ("I'll refund you in 48h if the seller doesn't respond"). Zeno only
# communicates the deadline in conversation; this loop is the ONLY thing
# that ever checks whether a deadline passed and fires the resulting action.
# No AI judgment or AI-held trigger is involved in actually moving funds.

_sweep_task: asyncio.Task | None = None
_sweep_running = False
_nudge_task: asyncio.Task | None = None
_nudge_running = False

# The availability nudge has its own, much faster loop.
#
# It used to ride the 300s sweep alongside ML retraining and escrow
# reconciliation. The deadline it enforces is 5 minutes, and a 5-minute
# deadline checked every 5 minutes fires somewhere between 5 and 10 minutes
# late - so "the seller gets a reminder after 5 minutes" was, at best, a
# coin flip on ten. The check itself is one indexed query that returns
# nothing the overwhelming majority of the time, so running it every 60s
# costs approximately nothing and bounds the error at one minute.
NUDGE_SWEEP_SECONDS = 60


async def _nudge_loop(interval_seconds: int = NUDGE_SWEEP_SECONDS) -> None:
    """The fast loop: availability reminders and the auction lifecycle.

    Everything here enforces a deadline a user is actively waiting on, so
    it cannot ride the 300s sweep - see NUDGE_SWEEP_SECONDS for the
    original reasoning and task_close_due_auctions for why an auction end
    in particular has to be prompt.
    """
    global _nudge_running
    _nudge_running = True
    logger.info("[nudge] availability sweep started (every %ds)", interval_seconds)
    while _nudge_running:
        try:
            await task_check_interest_nudges({})
        except Exception as exc:
            logger.error("[nudge] availability sweep failed: %s", exc)
        # Auctions ride this 60s loop rather than the 300s sweep - an
        # auction end is a deadline bidders are watching in real time. See
        # task_close_due_auctions.
        try:
            await task_close_due_auctions({})
        except Exception as exc:
            logger.error("[nudge] auction close sweep failed: %s", exc)
        try:
            await task_notify_auctions_ending_soon({})
        except Exception as exc:
            logger.error("[nudge] auction ending-soon sweep failed: %s", exc)
        try:
            await task_lapse_unpaid_auction_wins({})
        except Exception as exc:
            logger.error("[nudge] auction payment-lapse sweep failed: %s", exc)
        await asyncio.sleep(interval_seconds)


async def _periodic_sweep_loop(interval_seconds: int = 300) -> None:
    """Runs deal timer sweep + dispute timer sweep every interval_seconds."""
    global _sweep_running
    _sweep_running = True
    while _sweep_running:
        # Heartbeat. Production logs for a full session showed no sweep
        # output at all, which made "is the sweep even running?" and "is the
        # sweep running and finding nothing?" indistinguishable from the
        # outside - and the answer mattered, because the availability nudge
        # was silently finding nothing on every pass for weeks. DEBUG so it
        # costs nothing at the default level, but it is there when needed.
        logger.debug("[sweep] pass starting")
        try:
            await task_check_deal_timers({})
        except Exception as exc:
            logger.error("[sweep] deal timer check failed: %s", exc)
        try:
            await task_reconcile_econfirm_escrows({})
        except Exception as exc:
            logger.error("[sweep] E-Confirm reconciliation failed: %s", exc)
        try:
            await task_check_dispute_timers()
        except Exception as exc:
            logger.error("[sweep] dispute timer check failed: %s", exc)
        try:
            await task_refresh_dispute_summary_cache()
        except Exception as exc:
            logger.error("[sweep] dispute summary cache refresh failed: %s", exc)
        try:
            await task_recompute_dcr_and_leaks()
        except Exception as exc:
            logger.error("[sweep] DCR/leak recompute failed: %s", exc)
        try:
            await task_retrain_ml_models()
        except Exception as exc:
            logger.error("[sweep] ML retrain failed: %s", exc)
        try:
            await task_check_call_expiry()
        except Exception as exc:
            logger.error("[sweep] call expiry check failed: %s", exc)
        await asyncio.sleep(interval_seconds)


async def task_reconcile_econfirm_escrows(ctx: dict) -> None:
    """
    Periodic sweep (Phase 8 of the E-Confirm integration): E-Confirm's
    callbacks aren't exposed to BROKA (per the integration spec), so this
    is what actually resolves a deal stuck at "still pending" after a
    process restart, a missed payment-status poll, or a release that
    returned payout_initiated rather than an immediate Completed - not
    just a nice-to-have, the only path to eventual consistency for a
    buyer who never re-opens the app to trigger a fresh GET
    /deal/{deal_id}/payment-status.

    Same AsyncSessionLocal-per-call pattern as task_check_deal_timers
    above. Bounded to 200 escrows per pass (see ExternalEscrowRepository.
    get_reconcilable) so one sweep can't run unboundedly long; anything
    left over gets picked up on the next 300s pass.
    """
    from api.database import AsyncSessionLocal
    from api.domains.escrow.repository import ExternalEscrowRepository
    from api.domains.escrow.service import EscrowService

    async with AsyncSessionLocal() as session:
        repo = ExternalEscrowRepository(session)
        pending = await repo.get_reconcilable()
        if not pending:
            return
        svc = EscrowService(session)
        checked, failed = 0, 0
        for escrow in pending:
            try:
                await svc.reconcile_econfirm_escrow(escrow.deal_id)
                checked += 1
            except Exception as exc:
                failed += 1
                logger.error(
                    "[sweep] econfirm reconcile failed deal=%s: %s",
                    escrow.deal_id, exc,
                )
        logger.info("[sweep] econfirm reconciliation: checked=%d failed=%d", checked, failed)


async def start_periodic_sweep(interval_seconds: int = 300) -> None:
    global _sweep_task, _nudge_task
    _sweep_task = asyncio.create_task(_periodic_sweep_loop(interval_seconds))
    # Separate task, not another entry in the 300s loop - see NUDGE_SWEEP_SECONDS.
    _nudge_task = asyncio.create_task(_nudge_loop())
    logger.info("[sweep] periodic deal-timer sweep started (every %ds)", interval_seconds)


async def stop_periodic_sweep() -> None:
    global _sweep_running, _sweep_task, _nudge_running, _nudge_task
    _sweep_running = False
    _nudge_running = False
    for task in (_sweep_task, _nudge_task):
        if task:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
    logger.info("[sweep] periodic deal-timer sweep stopped")


async def stop_all_workers() -> None:
    for q in _queues.values():
        await q.stop()


# ── ARQ Redis-backed enqueue ──────────────────────────────────────────────────

async def _arq_enqueue(queue_name: str, fn: Task, **kwargs: Any) -> bool:
    try:
        from api.core.config import settings
        if not settings.redis_enabled:
            return False
        from arq import create_pool
        from arq.connections import RedisSettings
        import re
        m = re.match(r"redis://(?:([^:@]+)(?::([^@]+))?@)?([^:/]+)(?::(\d+))?(?:/(\d+))?", settings.redis_url)
        if m:
            rs = RedisSettings(
                host=m.group(3) or "localhost",
                port=int(m.group(4) or 6379),
                database=int(m.group(5) or 0),
                password=m.group(2),
            )
        else:
            rs = RedisSettings()
        pool = await create_pool(rs)
        await pool.enqueue_job(fn.__name__, _queue_name=queue_name, **kwargs)
        await pool.aclose()
        return True
    except Exception as exc:
        logger.warning("[arq] enqueue failed (falling back in-process): %s", exc)
        return False


async def enqueue(queue_name: str, fn: Task, **kwargs: Any) -> None:
    """Enqueue a background task. Uses ARQ (Redis) in production, asyncio queue in dev."""
    arq_ok = await _arq_enqueue(queue_name, fn, **kwargs)
    if not arq_ok:
        q = _queues.get(queue_name, _queues["fraud"])
        await q.enqueue(fn, **kwargs)


# ── ARQ WorkerSettings ─────────────────────────────────────────────────────────

async def _arq_on_startup(ctx: dict) -> None:
    """Initialise Sentry in an ARQ worker process.

    Workers are launched by `arq`, not by main.py, so init_observability
    never runs in them. Without this, anything a job reports to Sentry - a
    reconciliation alert raised inside task_reconcile_econfirm_escrows, an
    unhandled job error - was silently dropped in exactly the processes
    that run the money-reconciliation jobs.
    """
    from api.core.config import settings
    if settings.sentry_dsn:
        from api.core.observability import _init_sentry
        _init_sentry(settings.sentry_dsn, settings.env)
    else:
        logger.info("[worker] SENTRY_DSN not set - Sentry disabled in this worker")


class WorkerSettings:
    """
    ARQ worker config. Launch with:
        arq api.core.workers.WorkerSettings
    """
    on_startup = _arq_on_startup
    functions = [
        "api.core.workers.task_recompute_trust_score",
        "api.core.workers.task_send_fcm_notification",
        "api.core.workers.task_expire_featured_listings",
        "api.core.workers.task_send_email_notification",
        "api.core.workers.task_ai_summary",
        "api.core.workers.task_fraud_sweep",
        "api.core.workers.task_reconcile_mpesa",
        "api.core.workers.task_reconcile_econfirm_escrows",
        "api.core.workers.task_refresh_dispute_summary_cache",
        "api.core.workers.task_recompute_dcr_and_leaks",
        "api.core.workers.task_retrain_ml_models",
    ]
    max_jobs         = 20
    job_timeout      = 300
    retry_jobs       = True
    max_tries        = 3
    keep_result      = 3_600
    queue_read_limit = 10


# ── Task definitions ──────────────────────────────────────────────────────────

async def task_recompute_trust_score(ctx: dict, user_id: str, db_url: str) -> None:
    from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
    from sqlalchemy.orm import sessionmaker
    engine  = create_async_engine(db_url, echo=False)
    Session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with Session() as session:
        from api.core.fraud import compute_trust_score
        await compute_trust_score(user_id, session)
        await session.commit()
    await engine.dispose()


async def task_send_fcm_notification(ctx: dict, fcm_token: str, title: str, body: str) -> None:
    try:
        import asyncio as _asyncio
        import firebase_admin.messaging as msg
        # Same fix as api/routers/calls.py's _send_fcm (calling audit,
        # 2026-09-14): firebase_admin's send() is synchronous blocking HTTP.
        # Called bare from an async task it stalls the worker's whole event
        # loop for the round trip, holding up every other queued job behind
        # a network call to Google.
        await _asyncio.to_thread(
            msg.send,
            msg.Message(notification=msg.Notification(title=title, body=body), token=fcm_token),
        )
        logger.info("[worker] FCM sent to ...%s", fcm_token[-4:])
    except Exception as exc:
        logger.warning("[worker] FCM failed: %s", exc)


async def task_expire_featured_listings(ctx: dict, db_url: str) -> None:
    from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
    from sqlalchemy.orm import sessionmaker
    from sqlalchemy import select
    from datetime import datetime
    engine  = create_async_engine(db_url, echo=False)
    Session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with Session() as session:
        from api.database import Listing
        now    = datetime.utcnow()
        result = await session.execute(
            select(Listing).where(Listing.is_featured == True, Listing.featured_until <= now)
        )
        expired = result.scalars().all()
        for listing in expired:
            listing.is_featured = False
        if expired:
            await session.commit()
    await engine.dispose()


async def task_check_call_expiry() -> None:
    """Backstop cleanup for stale call sessions (api/core/call_state.py).
    On the Redis backend this is a no-op - Redis's own key TTL already
    reclaims expired sessions - so this only does real work on the
    in-memory fallback (dev / no REDIS_URL set), where nothing else would
    ever reclaim a session left behind by a caller who vanished mid-call
    without the client reporting anything back. Not the primary ring/
    connect timeout - see DEFAULT_SESSION_TTL_SECONDS in call_state.py for
    why that's client-driven instead."""
    from api.core import call_state
    removed = await call_state.sweep_expired()
    if removed:
        logger.info("[sweep] call expiry: removed %d stale call session(s)", removed)


async def task_check_deal_timers(ctx: dict) -> None:
    """
    Periodic sweep (see start_periodic_sweep): fires AI-announced
    auto-resolution timers once their deadline passes, IF the awaited party
    never responded (timer_cancelled_at is still null).

    timer_type values:
      "seller_silence_refund"   - seller went quiet after escrow funded;
                                   auto-refund the buyer if still unanswered.
      "buyer_silence_release"   - buyer received goods but never confirmed;
                                   auto-release funds to seller if still silent.
      "seller_claimed_delivery" - seller says delivered, buyer hasn't
                                   confirmed. Runs 4 active check-ins (each
                                   with a real push notification) over ~7
                                   days before any release - see
                                   _process_delivery_checkin below. This is
                                   the highest-stakes branch, so it gets the
                                   most caution and the most chances for the
                                   buyer to respond or dispute before any
                                   money moves.

    This function is the ONLY thing that fires these actions. Zeno can
    announce a deadline or record a seller's delivery claim in conversation,
    but has no mechanism to trigger, skip, or bypass this check - the
    decision is purely deterministic facts checked directly against the
    database (deadlines, cancellation flags, check-in counts).
    """
    from datetime import datetime
    from sqlalchemy import select
    from api.database import AsyncSessionLocal, Deal, DealStatus, User

    async with AsyncSessionLocal() as session:
        now = datetime.utcnow()
        result = await session.execute(
            select(Deal).where(
                Deal.timer_deadline.isnot(None),
                Deal.timer_deadline <= now,
                Deal.timer_cancelled_at.is_(None),
                Deal.timer_fired_at.is_(None),
                Deal.status.in_((
                    DealStatus.paid,
                    DealStatus.goods_not_arrived,
                    DealStatus.awaiting_replacement,
                    DealStatus.awaiting_condition_check,
                    DealStatus.awaiting_resolution,
                )),
            )
        )
        due_deals = result.scalars().all()

        # ── Detect expected-delivery-date passing → start buyer-delivery-silence ──
        # If the expected delivery date has now passed and the buyer has not
        # yet confirmed arrival (deal still in 'paid' status), Zeno asks them
        # "did it arrive?" and starts the 4-day silence sequence. This is a
        # separate check from the timer_deadline query above — it fires once
        # on the day after expected delivery (allowing a 24h grace window).
        delivery_check_result = await session.execute(
            select(Deal).where(
                Deal.status == DealStatus.paid,
                Deal.expected_delivery_date.isnot(None),
                Deal.expected_delivery_date <= now,
                Deal.timer_type.is_(None),          # no timer already running
                Deal.buyer_delivery_silence_started_at.is_(None),  # not already started
                Deal.seller_claimed_delivery_at.is_(None),          # seller hasn't claimed yet
            )
        )
        delivery_due_deals = delivery_check_result.scalars().all()
        for deal in delivery_due_deals:
            try:
                await _start_buyer_delivery_silence(session, deal, now)
            except Exception as exc:
                logger.error("[sweep] failed to start delivery-silence for deal %s: %s", deal.id, exc)

        if delivery_due_deals:
            await session.commit()
            logger.info("[sweep] started buyer-delivery-silence for %d deal(s)", len(delivery_due_deals))

        for deal in due_deals:
            try:
                # Race guard: this deal was read in the bulk select above,
                # which can be stale by the time THIS iteration runs (a
                # manual buyer/seller action in routers/negotiate.py could
                # have already moved it past the status that made it
                # eligible here - especially for deals later in a large
                # batch). Re-fetch under a row lock and re-verify against
                # the same status set the bulk query used; skip silently
                # if another transaction already handled it. See
                # domains/escrow/service.lock_deal_if_status.
                from api.domains.escrow.service import lock_deal_if_status
                locked_deal = await lock_deal_if_status(session, deal.id, (
                    DealStatus.paid, DealStatus.goods_not_arrived,
                    DealStatus.awaiting_replacement, DealStatus.awaiting_condition_check,
                    DealStatus.awaiting_resolution,
                ))
                if locked_deal is None:
                    logger.info("[sweep] deal %s already handled elsewhere - skipping", deal.id)
                    continue
                deal = locked_deal

                if deal.timer_type == "seller_silence_refund":
                    await _fire_auto_refund(session, deal)
                    deal.timer_fired_at = now
                elif deal.timer_type == "buyer_silence_release":
                    await _fire_auto_release(session, deal)
                    deal.timer_fired_at = now
                elif deal.timer_type == "seller_claimed_delivery":
                    # Multi-step - does NOT set timer_fired_at until the
                    # final check-in actually results in a release.
                    await _process_delivery_checkin(session, deal, now)
                elif deal.timer_type == "goods_not_arrived_contact_seller":
                    # Branch B: expected delivery date passed, buyer reported
                    # goods haven't arrived. Zeno contacts seller every 24h
                    # for 3 days. If still no response → auto-refund buyer.
                    await _process_goods_not_arrived_checkin(session, deal, now)
                elif deal.timer_type == "buyer_delivery_silence":
                    # Buyer didn't respond to "did goods arrive?" on expected
                    # delivery date. 4-day / 24h-checkin / SMS-day-3 sequence,
                    # then auto-release if still silent.
                    await _process_buyer_delivery_silence_checkin(session, deal, now)
                else:
                    logger.warning("[sweep] deal %s has unknown timer_type=%s - skipping",
                                    deal.id, deal.timer_type)
                    continue
            except Exception as exc:
                logger.error("[sweep] failed to fire timer for deal %s: %s", deal.id, exc)

        if due_deals:
            await session.commit()
            logger.info("[sweep] processed %d due deal timer(s)", len(due_deals))
        # Only now that the status changes are committed may the rest of the
        # system hear about them - see _queue_after_commit.
        await _publish_queued_events(session)


# Days after the seller's delivery claim at which each check-in fires.
# 4 check-ins spread across a 7-day window, per the explicit design
# decision: enough real chances for the buyer to respond before any
# auto-release, while keeping the total wait bounded and predictable.
_CHECKIN_SCHEDULE_DAYS = [1, 3, 5, 7]


async def _process_delivery_checkin(session, deal, now) -> None:
    """
    One step of the seller_claimed_delivery sequence. Each call either:
      - fires the next scheduled check-in (sends a real push notification
        asking the buyer to confirm or dispute), or
      - if all 4 check-ins are exhausted and the buyer still never
        responded, performs the actual auto-release.

    Buyer responding at any point (buyer_confirms_received /
    buyer_disputes_delivery intents) sets timer_cancelled_at, which removes
    the deal from the sweep's query entirely - this function never runs
    again for that deal once the buyer has acted.
    """
    from datetime import timedelta
    from api.database import DealStatus

    claimed_at = deal.seller_claimed_delivery_at
    if claimed_at is None:
        # Shouldn't happen, but fail safe - don't release without a claim.
        deal.timer_cancelled_at = now
        return

    days_since_claim = (now - claimed_at).total_seconds() / 86400
    next_checkin_index = deal.checkin_count  # 0-based: how many have fired so far

    if next_checkin_index >= len(_CHECKIN_SCHEDULE_DAYS):
        # All check-ins exhausted, buyer never responded - release now.
        await _fire_auto_release(session, deal)
        deal.timer_fired_at = now
        logger.info("[sweep] deal %s auto-released after %d unanswered check-ins",
                     deal.id, len(_CHECKIN_SCHEDULE_DAYS))
        return

    scheduled_day = _CHECKIN_SCHEDULE_DAYS[next_checkin_index]
    if days_since_claim < scheduled_day:
        # Not due yet - re-check on the next sweep pass.
        return

    # Fire this check-in: send a real push notification to the buyer, AND
    # post an in-thread message so the existing GlobalPollerService
    # new-message detection surfaces a local notification even without FCM
    # configured (FCM client-side setup isn't complete yet as of this
    # writing - see FCM_SETUP_REMAINING.md - so this message-based path is
    # the realistic notification mechanism for now).
    deal.checkin_count = next_checkin_index + 1
    deal.last_checkin_at = now
    is_final = deal.checkin_count >= len(_CHECKIN_SCHEDULE_DAYS)

    checkin_text = (
        "This is your final reminder: the seller says your order was "
        "delivered. If I don't hear from you, I'll release the funds to "
        "the seller automatically. Please confirm or let me know if "
        "there's an issue."
        if is_final else
        "Checking in: the seller says your order was delivered - has it "
        "arrived? Let me know either way so we can wrap this up."
    )
    try:
        from api.database import NegotiationMessage
        checkin_msg = NegotiationMessage(
            listing_id=deal.listing_id, sender_id="broker",
            role="broker", recipient_role="buyer",
            content=checkin_text, buyer_id=deal.buyer_id, msg_type="text",
        )
        session.add(checkin_msg)
    except Exception as exc:
        logger.error("[sweep] could not post check-in message for deal %s: %s", deal.id, exc)

    try:
        await _send_checkin_notification(deal, is_final=is_final)
    except Exception as exc:
        logger.error("[sweep] check-in notification failed for deal %s: %s", deal.id, exc)

    logger.info("[sweep] deal %s check-in %d/%d sent (day %d)",
                deal.id, deal.checkin_count, len(_CHECKIN_SCHEDULE_DAYS), scheduled_day)

    # Schedule re-check on the next sweep pass for either the next check-in
    # or the final release decision - timer_deadline stays <= now so the
    # sweep's query keeps picking this deal up each pass without needing a
    # second timer field.
    deal.timer_deadline = now


async def _send_checkin_notification(deal, is_final: bool) -> None:
    """
    Sends a real push/local notification to the buyer asking them to
    confirm or dispute delivery - this is the active reminder mechanism
    that makes the eventual auto-release safe (the buyer gets repeated,
    real chances to respond, not just a silently-waiting message).

    Uses the same FCM-readiness path as calls/messages (see
    routers/calls.py _send_fcm) - if the buyer's device isn't registered
    for push, this is a no-op (the in-app GlobalPollerService poll will
    still surface it next time the buyer opens the app).
    """
    from sqlalchemy import select
    from api.database import AsyncSessionLocal, User
    async with AsyncSessionLocal() as session:
        result = await session.execute(select(User).where(User.id == deal.buyer_id))
        buyer = result.scalar_one_or_none()
    if not buyer or not getattr(buyer, "fcm_token", None):
        return
    try:
        from api.routers.calls import _send_fcm
        title = ("Final reminder: confirm your delivery"
                  if is_final else "Did your order arrive?")
        body = ("This is your last reminder - if we don't hear from you, "
                "funds will be released to the seller automatically."
                if is_final else
                "The seller says your order was delivered. Please confirm "
                "or let us know if there's an issue.")
        await _send_fcm(buyer.fcm_token, title, body, {
            "type": "delivery_checkin",
            "dealId": deal.id,
            "listingId": deal.listing_id,
        })
    except Exception as exc:
        logger.warning("[sweep] could not send check-in push for deal %s: %s", deal.id, exc)


# Branch B schedule: Zeno contacts the seller every 24 hours for 3 days.
# If seller still hasn't responded after all contacts → auto-refund buyer.
_GOODS_NOT_ARRIVED_SCHEDULE_DAYS = [1, 2, 3]  # days after goods_not_arrived_started_at


async def _start_buyer_delivery_silence(session, deal, now) -> None:
    """
    Called by the sweep when expected_delivery_date has passed and the buyer
    has not confirmed arrival. Posts an in-thread question to the buyer
    ("did it arrive?") and starts the 4-day silence sequence.
    timer_type = "buyer_delivery_silence" drives subsequent sweep passes.
    """
    from api.database import NegotiationMessage
    deal.buyer_delivery_silence_started_at = now
    deal.timer_type = "buyer_delivery_silence"
    deal.timer_deadline = now  # re-check immediately on next sweep pass
    deal.timer_cancelled_at = None
    deal.timer_fired_at = None
    deal.checkin_count = 0
    deal.last_checkin_at = None

    question_msg = NegotiationMessage(
        listing_id=deal.listing_id, sender_id="broker",
        role="broker", recipient_role="buyer",
        content=(
            "Today was the expected delivery date for your order. "
            "Has the item arrived? Please tap 'Goods arrived' or 'Goods not arrived' below. "
            "If I don't hear from you within 4 days, funds will be automatically released to the seller."
        ),
        buyer_id=deal.buyer_id, msg_type="text",
    )
    session.add(question_msg)
    logger.info("[sweep] deal %s: expected delivery date passed — started buyer-delivery-silence sequence",
                deal.id)


async def _process_goods_not_arrived_checkin(session, deal, now) -> None:
    """
    Branch B sweep handler.

    The buyer reported goods didn't arrive on the expected date.
    Zeno already sent the first contact to the seller immediately (in the
    goods_not_arrived intent handler in negotiate.py). This sweep fires
    follow-up contacts every 24 hours for 3 days total. If the seller
    never responds (timer_cancelled_at stays null — set in the
    seller_explains_non_arrival intent when the seller replies), the buyer
    is auto-refunded on day 3.

    Seller responding at any point sets timer_cancelled_at, removing this
    deal from the sweep query permanently for this Branch B cycle.
    """
    from datetime import timedelta
    from api.database import DealStatus, NegotiationMessage

    started_at = deal.goods_not_arrived_started_at
    if started_at is None:
        deal.timer_cancelled_at = now
        return

    days_elapsed = (now - started_at).total_seconds() / 86400
    next_checkin_index = deal.goods_not_arrived_checkin_count or 0

    if next_checkin_index >= len(_GOODS_NOT_ARRIVED_SCHEDULE_DAYS):
        # All 3 contact attempts exhausted, seller still silent → refund buyer.
        await _fire_auto_refund(session, deal)
        deal.timer_fired_at = now
        logger.info("[sweep] deal %s auto-refunded (seller silent after goods-not-arrived report)",
                    deal.id)
        return

    scheduled_day = _GOODS_NOT_ARRIVED_SCHEDULE_DAYS[next_checkin_index]
    if days_elapsed < scheduled_day:
        return  # Not yet due — re-check next sweep pass

    deal.goods_not_arrived_checkin_count = next_checkin_index + 1
    is_final = deal.goods_not_arrived_checkin_count >= len(_GOODS_NOT_ARRIVED_SCHEDULE_DAYS)

    # Post in-thread message to seller
    seller_msg = (
        "FINAL NOTICE: The buyer says the item still hasn't arrived. "
        "If I don't hear from you within 24 hours, the buyer will be automatically refunded."
        if is_final else
        f"Reminder (day {deal.goods_not_arrived_checkin_count}/{len(_GOODS_NOT_ARRIVED_SCHEDULE_DAYS)}): "
        "The buyer is still waiting for their item. Please respond urgently or the buyer will be refunded."
    )
    try:
        checkin_msg = NegotiationMessage(
            listing_id=deal.listing_id, sender_id="broker",
            role="broker", recipient_role="seller",
            content=seller_msg, buyer_id=deal.buyer_id, msg_type="text",
        )
        session.add(checkin_msg)
    except Exception as exc:
        logger.error("[sweep] could not post goods-not-arrived check-in for deal %s: %s", deal.id, exc)

    # Send SMS-style push on the second-last day (index len-2)
    if next_checkin_index == len(_GOODS_NOT_ARRIVED_SCHEDULE_DAYS) - 2:
        try:
            await _send_seller_nondelivery_sms(deal)
        except Exception as exc:
            logger.error("[sweep] seller non-delivery SMS failed for deal %s: %s", deal.id, exc)

    # Also notify the buyer that we're still chasing
    buyer_update = NegotiationMessage(
        listing_id=deal.listing_id, sender_id="broker",
        role="broker", recipient_role="buyer",
        content=(
            "I'm still chasing the seller about your missing item. "
            + ("If there's no response by tomorrow, you'll be automatically refunded."
               if is_final else
               f"Day {deal.goods_not_arrived_checkin_count} of 3 follow-ups sent.")
        ),
        buyer_id=deal.buyer_id, msg_type="text",
    )
    session.add(buyer_update)

    # Keep timer_deadline <= now so sweep keeps picking this deal up
    deal.timer_deadline = now
    logger.info("[sweep] deal %s goods-not-arrived check-in %d/%d sent",
                deal.id, deal.goods_not_arrived_checkin_count,
                len(_GOODS_NOT_ARRIVED_SCHEDULE_DAYS))


# Branch B-silence schedule: buyer didn't respond to "did goods arrive?"
# Same shape as seller_claimed_delivery: 4 check-ins over 4 days, then
# auto-release. SMS is sent on day 3 (second-to-last check-in).
_BUYER_DELIVERY_SILENCE_SCHEDULE_DAYS = [1, 2, 3, 4]


async def _process_buyer_delivery_silence_checkin(session, deal, now) -> None:
    """
    Branch B-silence sweep handler.

    Expected delivery date passed. Zeno asked the buyer "did it arrive?"
    but got no response. 4-day / 24h-checkin sequence. If buyer is still
    silent after 4 days → auto-release funds to seller (same as the
    seller_claimed_delivery branch logic — buyer had 4 explicit chances).

    This also runs for Branch A4 (replacement) when the buyer goes quiet
    after the seller ships a replacement — per spec, the same 4-day/SMS
    rules apply there too.

    Buyer responding at any point with buyer_confirms_arrived or
    goods_not_arrived sets timer_cancelled_at, removing this deal from
    the sweep query.
    """
    from datetime import timedelta
    from api.database import DealStatus, NegotiationMessage

    started_at = deal.buyer_delivery_silence_started_at
    if started_at is None:
        deal.timer_cancelled_at = now
        return

    days_elapsed = (now - started_at).total_seconds() / 86400
    next_checkin_index = deal.checkin_count or 0

    if next_checkin_index >= len(_BUYER_DELIVERY_SILENCE_SCHEDULE_DAYS):
        # All 4 check-ins exhausted, buyer silent → release to seller.
        await _fire_auto_release(session, deal)
        deal.timer_fired_at = now
        logger.info("[sweep] deal %s auto-released (buyer silent re delivery arrival)",
                    deal.id)
        return

    scheduled_day = _BUYER_DELIVERY_SILENCE_SCHEDULE_DAYS[next_checkin_index]
    if days_elapsed < scheduled_day:
        return

    deal.checkin_count = next_checkin_index + 1
    deal.last_checkin_at = now
    is_final = deal.checkin_count >= len(_BUYER_DELIVERY_SILENCE_SCHEDULE_DAYS)
    is_sms_day = next_checkin_index == len(_BUYER_DELIVERY_SILENCE_SCHEDULE_DAYS) - 2  # day 3

    replacement_note = (
        f" (replacement #{deal.replacement_cycle})"
        if (deal.replacement_cycle or 0) > 0 else ""
    )

    checkin_text = (
        f"FINAL REMINDER: Did your item{replacement_note} arrive? "
        "If I don't hear from you, funds will be released to the seller automatically — "
        "this is your last chance to raise any issue."
        if is_final else
        f"Checking in (day {deal.checkin_count}/4): did your item{replacement_note} arrive? "
        "Please tap 'Goods arrived' or 'Goods not arrived' to let me know."
    )

    try:
        checkin_msg = NegotiationMessage(
            listing_id=deal.listing_id, sender_id="broker",
            role="broker", recipient_role="buyer",
            content=checkin_text, buyer_id=deal.buyer_id, msg_type="text",
        )
        session.add(checkin_msg)
    except Exception as exc:
        logger.error("[sweep] could not post buyer-delivery-silence check-in for deal %s: %s",
                     deal.id, exc)

    # SMS on day 3 (second-to-last)
    if is_sms_day:
        try:
            await _send_buyer_delivery_silence_sms(deal)
        except Exception as exc:
            logger.error("[sweep] buyer delivery silence SMS failed for deal %s: %s", deal.id, exc)

    # Push notification
    try:
        await _send_checkin_notification(deal, is_final=is_final)
    except Exception as exc:
        logger.error("[sweep] buyer delivery silence push failed for deal %s: %s", deal.id, exc)

    deal.timer_deadline = now
    logger.info("[sweep] deal %s buyer-delivery-silence check-in %d/%d sent",
                deal.id, deal.checkin_count, len(_BUYER_DELIVERY_SILENCE_SCHEDULE_DAYS))


async def _send_seller_nondelivery_sms(deal) -> None:
    """
    Sends an SMS-style push notification to the seller on the penultimate
    day of the goods-not-arrived sequence warning them the buyer will be
    refunded tomorrow if they don't respond.
    """
    from sqlalchemy import select
    from api.database import AsyncSessionLocal, User
    async with AsyncSessionLocal() as session:
        result = await session.execute(select(User).where(User.id == deal.seller_id))
        seller = result.scalar_one_or_none()
    if not seller or not getattr(seller, "fcm_token", None):
        return
    try:
        from api.routers.calls import _send_fcm
        await _send_fcm(
            seller.fcm_token,
            "URGENT: Respond or buyer will be refunded tomorrow",
            f"The buyer says their order hasn't arrived. Reply in BROKA now "
            f"or a refund will be issued automatically within 24 hours.",
            {"type": "non_delivery_warning", "dealId": deal.id, "listingId": deal.listing_id},
        )
    except Exception as exc:
        logger.warning("[sweep] seller non-delivery SMS push failed for deal %s: %s", deal.id, exc)


async def _send_buyer_delivery_silence_sms(deal) -> None:
    """
    Sends an SMS-style push notification to the buyer on day 3 of the
    delivery-silence sequence warning them funds will auto-release tomorrow.
    """
    from sqlalchemy import select
    from api.database import AsyncSessionLocal, User
    async with AsyncSessionLocal() as session:
        result = await session.execute(select(User).where(User.id == deal.buyer_id))
        buyer = result.scalar_one_or_none()
    if not buyer or not getattr(buyer, "fcm_token", None):
        return
    try:
        from api.routers.calls import _send_fcm
        replacement_note = (
            f" (replacement #{deal.replacement_cycle})"
            if (deal.replacement_cycle or 0) > 0 else ""
        )
        await _send_fcm(
            buyer.fcm_token,
            "Last reminder: confirm your delivery tomorrow",
            f"Did your item{replacement_note} arrive? If we don't hear from you in 24 hours, "
            f"funds will be released to the seller automatically.",
            {"type": "delivery_silence_warning", "dealId": deal.id, "listingId": deal.listing_id},
        )
    except Exception as exc:
        logger.warning("[sweep] buyer delivery silence SMS push failed for deal %s: %s", deal.id, exc)


async def task_check_interest_nudges(ctx: dict) -> None:
    """
    Periodic sweep (see start_periodic_sweep): if a buyer expressed interest
    in a listing and the seller hasn't replied within ~5 minutes, sends the
    seller a real SMS — not a push notification, deliberately, since the
    whole point is reaching someone who currently has no reason to have the
    app open — asking them to confirm availability.

    Same separation of concerns as task_check_deal_timers: Zeno drafts the
    wording (now core/nudge_templates, system-generated), but this function is the only
    thing that decides whether and when to actually send anything, based on
    real NegotiationMessage timestamps, never an AI judgment call.

    Scope is deliberately narrow for now: only the "buyer expressed
    interest" trigger sets a nudge_deadline. Other stalled-negotiation
    scenarios aren't covered by this sweep.
    """
    from datetime import datetime
    from sqlalchemy import select
    from api.database import AsyncSessionLocal, Interest

    async with AsyncSessionLocal() as session:
        now = datetime.utcnow()
        result = await session.execute(
            select(Interest).where(
                Interest.nudge_deadline.isnot(None),
                Interest.nudge_deadline <= now,
                Interest.nudge_sent_at.is_(None),
                Interest.nudge_cancelled_at.is_(None),
            )
        )
        due = result.scalars().all()
        if not due:
            return

        sent = 0
        for interest in due:
            try:
                if await _seller_has_responded(session, interest):
                    # Real reply found in the thread — nothing to send.
                    interest.nudge_cancelled_at = now
                    continue
                if await _fire_availability_nudge(session, interest):
                    interest.nudge_sent_at = now
                    sent += 1
                # else: SMS send failed (or listing/seller/buyer missing,
                # which _fire_availability_nudge marks cancelled itself) —
                # if still due, next sweep pass retries it.
            except Exception as exc:
                logger.error("[sweep] interest nudge check failed for interest %s: %s",
                             interest.id, exc)

        await session.commit()
        if sent:
            logger.info("[sweep] sent %d availability nudge SMS", sent)


async def _seller_has_responded(session, interest) -> bool:
    """
    True if the seller sent any message in this specific buyer's thread
    since the interest was created. Checked against real NegotiationMessage
    rows, which both the AI-assisted and direct-chat send paths write to
    with role="seller" — so this covers a reply either way without needing
    to touch those endpoints.
    """
    from sqlalchemy import select
    from api.database import NegotiationMessage
    # visibility-ok: selects ids only, used as an existence check for a seller reply
    result = await session.execute(
        select(NegotiationMessage.id).where(
            NegotiationMessage.listing_id == interest.listing_id,
            NegotiationMessage.buyer_id == interest.buyer_id,
            NegotiationMessage.role == "seller",
            NegotiationMessage.created_at >= interest.created_at,
        ).limit(1)
    )
    return result.scalar_one_or_none() is not None


async def _fire_availability_nudge(session, interest) -> bool:
    """Drafts (AI, with a template fallback) and sends the SMS. Returns True
    only on confirmed send, so the caller knows whether to mark it done."""
    from datetime import datetime
    from sqlalchemy import select
    from api.database import Listing, User
    from api.core.sms import get_sms_provider

    listing_r = await session.execute(select(Listing).where(Listing.id == interest.listing_id))
    listing = listing_r.scalar_one_or_none()
    seller = None
    if listing:
        seller_r = await session.execute(select(User).where(User.id == listing.seller_id))
        seller = seller_r.scalar_one_or_none()
    buyer_r = await session.execute(select(User).where(User.id == interest.buyer_id))
    buyer = buyer_r.scalar_one_or_none()

    if not listing or not seller or not buyer:
        # Permanent condition (e.g. listing removed since) — stop retrying.
        interest.nudge_cancelled_at = datetime.utcnow()
        return False

    # SYSTEM-GENERATED, NOT AI-GENERATED (2026-09-14).
    #
    # This used to call AIBrokerService.draft_availability_nudge_sms() with
    # a single hard-coded fallback string on failure. Three problems:
    # a transactional SMS cannot be corrected once sent and the seller
    # cannot reply to it to fix a misunderstanding; every nudge paid the
    # latency and cost of an LLM round trip; and the model could invent a
    # price, a product detail, or a commitment BROKA has not made. The only
    # thing it genuinely bought was wording variety, and a template set
    # provides that deterministically - see core/nudge_templates.
    from api.core.nudge_templates import compose_availability_nudge, is_quiet_hours

    # Don't wake anyone. A 3am SMS about a second-hand fridge is not
    # urgency, it's a nuisance - and the kind of traffic that gets a
    # shortcode flagged. Returning False without setting nudge_sent_at
    # leaves this interest due, so the next sweep retries it in daylight.
    # The deal is not lost by waiting; the buyer is asleep too.
    if is_quiet_hours():
        logger.info("[sweep] nudge for interest %s deferred - quiet hours", interest.id)
        return False

    text = compose_availability_nudge(
        seller_name=seller.name,
        buyer_name=buyer.name,
        listing_name=listing.name,
        price=getattr(listing, "price", None),
        # The BUYER's gender, not the seller's. The seller is the recipient
        # and is addressed as "you", which never needs one; every pronoun in
        # these templates refers to the buyer.
        buyer_gender=getattr(buyer, "gender", None),
        # Stable per interest, so a retry reproduces the identical message
        # rather than a differently-worded second copy the seller would
        # reasonably read as a second buyer.
        seed=interest.id,
    )

    try:
        return bool(await get_sms_provider().send(seller.phone, text))
    except Exception as exc:
        logger.error("[sweep] SMS send raised for interest %s: %s", interest.id, exc)
        return False


async def task_retrain_ml_models() -> None:
    """
    Volume 2 §4.3's weekly retrain job, plus §4.4's "start logging/
    collecting features from day one" (feature_extraction's queries run
    regardless of whether anything ends up training - that IS the
    logging, since there's no separate feature store to write to yet).

    Gated via the same Redis stats-cache helper task_refresh_dispute_
    summary_cache uses (core/stats_cache.py), not the DB-based gate
    task_recompute_dcr_and_leaks uses - lower stakes than DCR's ranking-
    critical gate warrants. Missing a week here in the worst case (Redis
    restart/flush) just means train_all() runs an extra time; for the
    foreseeable future at BROKA's current data volume it will find every
    category below the 300-deal threshold and train nothing regardless
    (see train.py), so an occasional redundant run costs almost nothing.
    """
    from datetime import datetime as _dt, timedelta as _timedelta
    from api.database import AsyncSessionLocal
    from api.core.stats_cache import cache_get_json, cache_set_json
    from api.core.ml.train import train_all

    _ML_RETRAIN_KEY = "broka:ml:last_train_run"
    refresh_every = _timedelta(days=7)

    existing = await cache_get_json(_ML_RETRAIN_KEY)
    if existing and existing.get("computed_at"):
        try:
            last = _dt.fromisoformat(existing["computed_at"])
            if _dt.utcnow() - last < refresh_every:
                return  # ran within the last week - nothing to do this tick
        except ValueError:
            pass

    async with AsyncSessionLocal() as session:
        results = await train_all(session)

    await cache_set_json(_ML_RETRAIN_KEY, {"computed_at": _dt.utcnow().isoformat(), "results": results}, ttl_seconds=14 * 86400)
    logger.info("[worker] ML retrain pass complete: %s", results)


async def task_recompute_dcr_and_leaks() -> None:
    """
    Volume 2 §3.7: nightly leak-flagging + DCR/rank_score recompute.
    "Nightly" here means self-gated to ~24h inside this function (same
    reason as task_refresh_dispute_summary_cache - this codebase's only
    periodic-execution mechanism is the 5-minute sweep loop above, not ARQ
    cron), but gated via the database rather than Redis: this result
    affects real search ranking, so the gate needs to survive a Redis
    restart/flush without silently skipping a night's recompute or
    (worse) re-running every 5 minutes because the gate itself vanished.

    flag_leaked_deals() runs first, exactly as §3.7 specifies ("runs
    before recompute_all_dcr() in the same nightly job"), since freshly
    leaked deals need to be counted in the same pass that scores them.
    """
    from sqlalchemy import select as _select, func as _func
    from datetime import datetime as _dt, timedelta as _timedelta
    from api.database import AsyncSessionLocal, SellerMetrics
    from api.domains.trust.completion_rate import flag_leaked_deals, recompute_all_dcr

    async with AsyncSessionLocal() as session:
        last_run_r = await session.execute(_select(_func.max(SellerMetrics.updated_at)))
        last_run = last_run_r.scalar()
        if last_run and (_dt.utcnow() - last_run) < _timedelta(hours=24):
            return  # ran within the last day - nothing to do this tick

        flagged = await flag_leaked_deals(session)
        processed = await recompute_all_dcr(session)

        # Snapshot AFTER the rescore, so the row records today's fresh
        # dcr_score and rank_score rather than yesterday's.
        #
        # Wrapped separately: a snapshot failure must not undo or obscure
        # the rescore, which is the part listings ranking depends on. A
        # missing day in a graph is a cosmetic gap; a stale rank_score
        # changes what every buyer sees.
        snapshots = 0
        try:
            from api.domains.trust.metric_snapshots import (
                write_daily_snapshots, write_listing_snapshots,
            )
            snapshots = await write_daily_snapshots(session)
            snapshots += await write_listing_snapshots(session)
        except Exception as exc:
            logger.error("[worker] seller metric snapshot failed: %s", exc)

        logger.info(
            "[worker] DCR recompute done: %d deals newly flagged as leaked, "
            "%d sellers rescored, %d snapshots written",
            flagged, processed, snapshots,
        )


# ── Dispute-resolution summary (Volume 2 §2.3) ────────────────────────────────
#
# Served to buyers by the UNAUTHENTICATED GET /disputes/v2/stats/summary, so
# the one thing it must never do is run its aggregate per request. It used to
# be gated only by its own Redis cache - and with Redis unset or down (a
# supported configuration: README calls Redis "strongly recommended", not
# required) every request missed and ran an unbounded query that loaded every
# closed case in 90 days as full ORM objects.
#
# Now: a process-local copy with its own freshness gate sits in front of
# Redis; a cold miss computes ONCE behind a lock no matter how many requests
# arrive together; a failed computation is remembered briefly so a broken
# database is not retried per request; and the query reads three columns
# with a hard row cap.

_DISPUTE_SUMMARY_REFRESH_SECONDS = 4 * 3600
_DISPUTE_SUMMARY_FAILURE_BACKOFF_SECONDS = 300
_DISPUTE_SUMMARY_MAX_ROWS = 50_000
# (expires_at on the monotonic clock, payload or None after a failure)
_dispute_summary_memo: tuple[float, Any] | None = None
_dispute_summary_lock: tuple[Any, asyncio.Lock] | None = None


def _dispute_summary_null_payload() -> dict:
    """"No data" - the frontend hides the stat for nulls rather than printing
    0%, which would misleadingly read as "BROKA fails every dispute"."""
    return {
        "resolved_within_24h_pct": None,
        "median_resolution_hours": None,
        "escrow_success_rate_pct": None,
        "window":      "trailing_90_days",
        "sample_size": 0,
        "computed_at": None,
    }


def _dispute_summary_fresh(payload: Any) -> bool:
    from datetime import datetime as _dt
    if not isinstance(payload, dict) or not payload.get("computed_at"):
        return False
    try:
        age = _dt.utcnow() - _dt.fromisoformat(payload["computed_at"])
    except (TypeError, ValueError):
        return False
    return age.total_seconds() < _DISPUTE_SUMMARY_REFRESH_SECONDS


def _dispute_summary_lock_for_loop() -> asyncio.Lock:
    """One lock per running event loop - an asyncio.Lock must not be shared
    across loops (tests and some deployments run more than one)."""
    global _dispute_summary_lock
    loop = asyncio.get_running_loop()
    if _dispute_summary_lock is None or _dispute_summary_lock[0] is not loop:
        _dispute_summary_lock = (loop, asyncio.Lock())
    return _dispute_summary_lock[1]


async def _compute_dispute_summary() -> dict:
    """The aggregate itself: three columns, bounded, newest first."""
    from datetime import datetime as _dt, timedelta as _timedelta
    from statistics import median as _median
    from sqlalchemy import select as _select
    from api.database import AsyncSessionLocal
    from api.models.dispute import DisputeCase, CaseState

    window_start = _dt.utcnow() - _timedelta(days=90)
    async with AsyncSessionLocal() as session:
        rows = (await session.execute(
            _select(DisputeCase.created_at, DisputeCase.closed_at, DisputeCase.fund_action)
            .where(
                DisputeCase.state.in_((CaseState.closed_refunded, CaseState.closed_released)),
                DisputeCase.closed_at.isnot(None),
                DisputeCase.closed_at >= window_start,
            )
            .order_by(DisputeCase.closed_at.desc())
            .limit(_DISPUTE_SUMMARY_MAX_ROWS)
        )).all()

    total = len(rows)
    if total == 0:
        payload = _dispute_summary_null_payload()
        payload["computed_at"] = _dt.utcnow().isoformat()
        return payload

    resolution_hours = [
        (closed_at - created_at).total_seconds() / 3600.0
        for created_at, closed_at, _fund_action in rows
    ]
    within_24h    = sum(1 for h in resolution_hours if h <= 24.0)
    fund_executed = sum(1 for _c, _d, fund_action in rows if fund_action)
    return {
        "resolved_within_24h_pct": round(100.0 * within_24h / total, 1),
        "median_resolution_hours": round(_median(resolution_hours), 1),
        # % of closed cases where escrow actually executed a fund action
        # (refund or release) rather than closing with none recorded -
        # i.e. "did escrow do its job," not just "was the case closed."
        "escrow_success_rate_pct": round(100.0 * fund_executed / total, 1),
        "window":       "trailing_90_days",
        "sample_size":  total,
        "computed_at":  _dt.utcnow().isoformat(),
    }


async def get_dispute_summary(*, compute_if_stale: bool = True) -> dict | None:
    """The current summary, computing it at most once per refresh interval.

    compute_if_stale=False only reads (memo, then Redis) - for callers on a
    latency-sensitive path, like a chat reply, that can live without it.
    Never raises.
    """
    import time as _time
    from api.core.stats_cache import cache_get_json, cache_set_json, DISPUTE_SUMMARY_KEY

    global _dispute_summary_memo

    def _memo_hit():
        memo = _dispute_summary_memo
        if memo is not None and _time.monotonic() < memo[0]:
            return True, memo[1]
        return False, None

    hit, value = _memo_hit()
    if hit:
        return value

    cached = await cache_get_json(DISPUTE_SUMMARY_KEY)
    if _dispute_summary_fresh(cached):
        _dispute_summary_memo = (_time.monotonic() + _DISPUTE_SUMMARY_REFRESH_SECONDS, cached)
        return cached
    if not compute_if_stale:
        return cached  # stale is better than nothing for a read-only caller

    async with _dispute_summary_lock_for_loop():
        # Whoever held the lock before us may have just computed it.
        hit, value = _memo_hit()
        if hit:
            return value
        try:
            payload = await _compute_dispute_summary()
        except Exception as exc:
            logger.error("[worker] dispute summary computation failed: %s", exc)
            _dispute_summary_memo = (
                _time.monotonic() + _DISPUTE_SUMMARY_FAILURE_BACKOFF_SECONDS, cached,
            )
            return cached
        _dispute_summary_memo = (_time.monotonic() + _DISPUTE_SUMMARY_REFRESH_SECONDS, payload)
        # TTL longer than the refresh interval: the sweep refreshes well
        # before it expires, so the TTL only matters as a safety net if the
        # sweep itself stops running.
        await cache_set_json(DISPUTE_SUMMARY_KEY, payload, ttl_seconds=6 * 3600)
        logger.info("[worker] dispute summary refreshed: %s", payload)
        return payload


async def task_refresh_dispute_summary_cache(ctx: dict | None = None) -> None:
    """
    Keeps the platform-wide dispute-resolution summary (Volume 2 §2.3) warm.
    Self-gated to roughly every 4 hours through get_dispute_summary, so most
    sweep ticks are a memo or Redis read that returns immediately.

    Powers GET /disputes/v2/stats/summary (domains/disputes/router.py) and
    the off-platform-solicitation redirect in routers/negotiate.py (§2.2).
    `ctx` is accepted because ARQ passes one to every registered job.
    """
    await get_dispute_summary()


async def task_check_dispute_timers() -> None:
    """
    Sweep for DisputeTimer objects whose fires_at has passed.
    This is the ONLY mechanism that fires dispute timers — no AI code path does this.

    Timer kinds handled:
      auto_refund_buyer      → seller went silent; refund buyer 97%
      auto_release_seller    → buyer went silent; release to seller 97%
      checkin_buyer          → ask buyer "have your goods arrived?"
      checkin_seller         → ask seller "why haven't goods arrived?"
      seller_explanation_due → seller didn't explain in time; auto-refund
      replacement_arrival_due → replacement didn't arrive in time; auto-refund
    """
    from datetime import datetime as _dt
    from sqlalchemy import select as _select
    from api.database import AsyncSessionLocal, Deal, DealStatus, User, NegotiationMessage
    from api.models.dispute import DisputeCase, DisputeTimer, TimerKind, CaseState, EventType
    from api.domains.disputes.service import DisputeEngineService
    from api.core.config import settings as _settings

    now = _dt.utcnow()

    async with AsyncSessionLocal() as session:
        # Find all unfired, uncancelled timers that are due
        result = await session.execute(
            _select(DisputeTimer).where(
                DisputeTimer.fired_at.is_(None),
                DisputeTimer.cancelled_at.is_(None),
                DisputeTimer.fires_at <= now,
            )
        )
        due_timers = result.scalars().all()
        if not due_timers:
            return

        logger.info("[dispute_sweep] processing %d due dispute timers", len(due_timers))

        for timer in due_timers:
            try:
                case_r = await session.execute(
                    _select(DisputeCase).where(DisputeCase.id == timer.case_id)
                )
                case = case_r.scalar_one_or_none()
                if not case or case.state.is_terminal:
                    timer.fired_at = now
                    timer.cancelled_reason = "case_already_closed"
                    continue

                deal_r = await session.execute(
                    _select(Deal).where(Deal.id == timer.deal_id)
                )
                deal = deal_r.scalar_one_or_none()
                if not deal:
                    timer.fired_at = now
                    continue

                buyer_r = await session.execute(
                    _select(User).where(User.id == deal.buyer_id)
                )
                buyer = buyer_r.scalar_one_or_none()
                seller_r = await session.execute(
                    _select(User).where(User.id == deal.seller_id)
                )
                seller = seller_r.scalar_one_or_none()

                svc = DisputeEngineService(session)

                b_name = buyer.name if buyer else "Buyer"
                s_name = seller.name if seller else "Seller"
                b_first = b_name.split()[0]
                s_first = s_name.split()[0]

                is_last_checkin = (timer.checkin_index >= timer.total_checkins - 1)
                send_sms = (timer.send_sms_on_index is not None and
                            timer.checkin_index == timer.send_sms_on_index)

                # ── TERMINAL TIMERS ───────────────────────────────────────────

                if timer.timer_kind in (TimerKind.auto_refund_buyer,
                                         TimerKind.seller_explanation_due,
                                         TimerKind.replacement_arrival_due):
                    # Refund 97% to buyer - through execute_fund_action ONLY.
                    # It is the single place a dispute refund pays out: it
                    # takes the deal row lock, claims the payout so it can
                    # happen once, calls M-Pesa B2C, and writes the ledger.
                    # This branch used to call _mpesa_b2c itself first and
                    # THEN execute_fund_action - two 97% refunds to the buyer
                    # on every timed auto-refund, the first of them made
                    # before any of those guards ran (so it paid even when
                    # another path had already settled the deal and
                    # execute_fund_action refused with a 409).
                    from api.models.dispute import CaseState as CS, EventType as ET
                    case.state = CS.ready_for_refund
                    await svc.execute_fund_action(case, actor_id="system", actor_role="system")
                    # What was actually refunded, as recorded by the payout.
                    net = case.fund_amount
                    logger.info("[dispute_sweep] auto-refunded deal %s (timer=%s)",
                                deal.id, timer.timer_kind.value)

                    # Notify buyer
                    if buyer:
                        msg = NegotiationMessage(
                            listing_id=deal.listing_id, sender_id="broker",
                            role="broker", recipient_role="buyer",
                            content=(
                                f"{b_first}, I've refunded KES {net:,.0f} (97% of the agreed amount) "
                                f"to your M-Pesa because there was no resolution in time. "
                                f"ZAC: {case.zac_code or 'pending'}."
                            ),
                            buyer_id=deal.buyer_id, msg_type="text",
                        )
                        session.add(msg)
                    if seller:
                        msg = NegotiationMessage(
                            listing_id=deal.listing_id, sender_id="broker",
                            role="broker", recipient_role="seller",
                            content=(
                                f"{s_first}, the deal has been refunded to the buyer because "
                                f"the response deadline was not met. Please contact support "
                                f"if you believe this is an error."
                            ),
                            buyer_id=deal.buyer_id, msg_type="text",
                        )
                        session.add(msg)

                elif timer.timer_kind == TimerKind.auto_release_seller:
                    # Release 97% to seller (buyer was unresponsive)
                    from api.models.dispute import CaseState as CS
                    case.state = CS.ready_for_release
                    await svc.execute_fund_action(case, actor_id="system", actor_role="system")
                    logger.info("[dispute_sweep] auto-released deal %s (buyer silence)",
                                deal.id)
                    if buyer:
                        msg = NegotiationMessage(
                            listing_id=deal.listing_id, sender_id="broker",
                            role="broker", recipient_role="buyer",
                            content=(
                                f"{b_first}, funds have been released to {s_first} because "
                                f"there was no response after the deadline. "
                                f"Contact support if you have concerns."
                            ),
                            buyer_id=deal.buyer_id, msg_type="text",
                        )
                        session.add(msg)

                # ── CHECK-IN TIMERS (schedule next or terminal) ───────────────

                elif timer.timer_kind == TimerKind.checkin_buyer:
                    if is_last_checkin:
                        # Final checkin passed — auto-release
                        from api.models.dispute import CaseState as CS
                        case.state = CS.ready_for_release
                        await svc.execute_fund_action(case, actor_id="system", actor_role="system")
                        logger.info("[dispute_sweep] buyer silence exhausted — releasing deal %s", deal.id)
                    else:
                        # Send reminder; schedule next checkin
                        reminder = (
                            f"{b_first}, Zeno here. Have the goods arrived? "
                            f"Please reply here urgently — funds are still on hold. "
                            f"(Reminder {timer.checkin_index + 1}/{timer.total_checkins})"
                        )
                        if send_sms and buyer and buyer.phone:
                            try:
                                from api.core.push import send_sms as _sms
                                await _sms(buyer.phone,
                                    f"BROKA: {b_first}, have your goods arrived? "
                                    f"Please respond in the BROKA app urgently. "
                                    f"Funds will be released if no reply received.")
                            except Exception as e:
                                logger.warning("[dispute_sweep] SMS failed: %s", e)
                        if buyer:
                            msg = NegotiationMessage(
                                listing_id=deal.listing_id, sender_id="broker",
                                role="broker", recipient_role="buyer",
                                content=reminder, buyer_id=deal.buyer_id, msg_type="text",
                            )
                            session.add(msg)
                        # Schedule next checkin
                        next_timer = DisputeTimer(
                            case_id=case.id, deal_id=deal.id,
                            timer_kind=TimerKind.checkin_buyer,
                            fires_at=now + __import__("datetime").timedelta(hours=24),
                            checkin_index=timer.checkin_index + 1,
                            total_checkins=timer.total_checkins,
                            send_sms_on_index=timer.send_sms_on_index,
                        )
                        session.add(next_timer)

                elif timer.timer_kind == TimerKind.checkin_seller:
                    if is_last_checkin:
                        # Final checkin — auto-refund buyer
                        from api.models.dispute import CaseState as CS
                        case.state = CS.ready_for_refund
                        await svc.execute_fund_action(case, actor_id="system", actor_role="system")
                        logger.info("[dispute_sweep] seller silence exhausted — refunding deal %s", deal.id)
                    else:
                        reminder = (
                            f"{s_first}, Zeno here. The buyer reports their goods haven't arrived. "
                            f"Please respond urgently. "
                            f"(Reminder {timer.checkin_index + 1}/{timer.total_checkins})"
                        )
                        if send_sms and seller and seller.phone:
                            try:
                                from api.core.push import send_sms as _sms
                                await _sms(seller.phone,
                                    f"BROKA: {s_first}, a buyer says their goods haven't arrived. "
                                    f"Please respond in the BROKA app urgently.")
                            except Exception as e:
                                logger.warning("[dispute_sweep] SMS to seller failed: %s", e)
                        if seller:
                            msg = NegotiationMessage(
                                listing_id=deal.listing_id, sender_id="broker",
                                role="broker", recipient_role="seller",
                                content=reminder, buyer_id=deal.buyer_id, msg_type="text",
                            )
                            session.add(msg)
                        next_timer = DisputeTimer(
                            case_id=case.id, deal_id=deal.id,
                            timer_kind=TimerKind.checkin_seller,
                            fires_at=now + __import__("datetime").timedelta(hours=24),
                            checkin_index=timer.checkin_index + 1,
                            total_checkins=timer.total_checkins,
                            send_sms_on_index=timer.send_sms_on_index,
                        )
                        session.add(next_timer)

                timer.fired_at = now
                await session.commit()

            except Exception as exc:
                logger.error("[dispute_sweep] error processing timer %s: %s", timer.id, exc)
                await session.rollback()


def _queue_after_commit(session, event) -> None:
    """Hold an event until the sweep has committed the change it describes.

    EscrowReleased/EscrowRefunded are what write the ledger entry and push
    the new status over the deal's WebSocket (core/deal_hub_subscribers.py).
    The automatic release/refund below used to publish nothing at all, so
    every timer-driven settlement was missing from the ledger and invisible
    to an open deal screen. Publishing before the sweep's single commit
    would let the ledger record a settlement whose status change could
    still roll back.
    """
    session.info.setdefault("broka_post_commit_events", []).append(event)


async def _publish_queued_events(session) -> None:
    from api.core.events import publish
    events = session.info.pop("broka_post_commit_events", [])
    for event in events:
        try:
            await publish(event)
        except Exception as exc:
            logger.error("[sweep] failed to publish %s: %s", type(event).__name__, exc)


async def _econfirm_deal_fails_closed(session, deal, action: str) -> bool:
    """True (and a reconciliation alert raised) when `deal` is E-Confirm-funded.

    Same isolation the dispute engine applies in execute_fund_action: the
    automatic paths below assume BROKA holds the money - a refund pays out
    of BROKA's own M-Pesa B2C account, a release only flips the status. For
    an E-Confirm deal the principal is held by E-Confirm, so an automatic
    refund would pay the buyer from BROKA's own pocket while their money
    stayed in escrow, and an automatic release would mark the deal released
    with the seller never paid. Neither is automated for E-Confirm yet, so
    this fails closed: the deal is left as it is and a human is asked to
    resolve it with E-Confirm.
    """
    from sqlalchemy import select
    from api.core.audit import record_audit
    from api.models.external_escrow import ExternalEscrow

    escrow = (await session.execute(
        select(ExternalEscrow.id).where(ExternalEscrow.deal_id == deal.id)
    )).scalar_one_or_none()
    if escrow is None:
        return False
    reason = (
        f"automatic {action} is not available for E-Confirm deals - "
        f"resolve with E-Confirm (deal status left at {deal.status.value})"
    )
    await record_audit(session, "system", f"econfirm_auto_{action}_blocked", "deal", deal.id, reason)
    from api.core.reconciliation import report_reconciliation
    report_reconciliation(f"econfirm_auto_{action}_blocked", deal_id=deal.id, reason=reason)
    return True


async def _fire_auto_refund(session, deal) -> None:
    """Seller never responded - refund the buyer 97% (3% commission retained).
    Mirrors the manual dispute refund path in routers/disputes.py, minus the
    AI verdict (the rule that triggered this is deterministic: deadline passed,
    seller silent). Legacy (non-E-Confirm) deals only - see
    _econfirm_deal_fails_closed."""
    from datetime import datetime
    from sqlalchemy import select
    from api.core.events import EscrowRefunded
    from api.database import User, DealStatus
    if await _econfirm_deal_fails_closed(session, deal, "refund"):
        return
    _COMMISSION_RATE = 0.03
    refund_amount = round(deal.agreed_price * (1 - _COMMISSION_RATE), 2)
    deal.status = DealStatus.refunded
    deal.refunded_at = datetime.utcnow()
    buyer = (await session.execute(select(User).where(User.id == deal.buyer_id))).scalar_one_or_none()
    if buyer and buyer.phone:
        try:
            from api.routers.disputes import _mpesa_b2c_refund
            await _mpesa_b2c_refund(buyer.phone, refund_amount, deal.id)
        except Exception as exc:
            logger.error("[sweep] auto-refund B2C call failed for deal %s: %s", deal.id, exc)
    _queue_after_commit(session, EscrowRefunded(
        deal_id=deal.id, buyer_id=deal.buyer_id, seller_id=deal.seller_id,
        amount=refund_amount,
    ))
    logger.info("[sweep] auto-refunded deal %s to buyer %s — KES %.0f (97%% of %.0f)",
                deal.id, deal.buyer_id, refund_amount, deal.agreed_price)


async def _fire_auto_release(session, deal) -> None:
    """Buyer never confirmed - release funds to the seller. Mirrors the
    manual /escrow/confirm-delivery path, minus requiring the buyer's tap.
    Legacy (non-E-Confirm) deals only - see _econfirm_deal_fails_closed."""
    from datetime import datetime
    from sqlalchemy import select
    from api.core.events import EscrowReleased
    from api.database import User, DealStatus
    if await _econfirm_deal_fails_closed(session, deal, "release"):
        return
    now = datetime.utcnow()
    deal.status = DealStatus.released
    deal.delivery_confirmed_at = now
    deal.released_at = now
    seller = (await session.execute(select(User).where(User.id == deal.seller_id))).scalar_one_or_none()
    if seller:
        seller.completed_deals = (seller.completed_deals or 0) + 1
        # No rating change. This used to add +0.05 to the seller's rating on
        # every automatic release - a review nobody wrote, awarded for a
        # buyer's SILENCE. The same bump was already removed from the M-Pesa
        # callback for that reason; a rating must mean a buyer rated them.
    _queue_after_commit(session, EscrowReleased(
        deal_id=deal.id, seller_id=deal.seller_id, buyer_id=deal.buyer_id,
        amount=deal.agreed_price,
    ))
    logger.info("[sweep] auto-released deal %s to seller %s (buyer silence timeout)",
                deal.id, deal.seller_id)


async def task_send_email_notification(ctx: dict, to_email: str, subject: str, body: str) -> None:
    logger.info("[worker] email queued to=%s subject=%s", to_email, subject)
    # TODO: integrate your ESP (Resend, SendGrid, Mailgun, AWS SES)


async def task_ai_summary(ctx: dict, deal_id: str, buyer_claim: str, seller_claim: str, deal_amount: float, item_name: str) -> dict:
    from api.domains.ai_broker.service import AIBrokerService
    svc    = AIBrokerService()
    result = await svc.dispute_analysis(buyer_claim, seller_claim, deal_amount, item_name)
    try:
        from api.core.config import settings
        if settings.redis_enabled:
            import redis.asyncio as aioredis, json
            client = aioredis.from_url(settings.redis_url, decode_responses=True)
            await client.setex(f"broka:ai_summary:{deal_id}", 3600, json.dumps(result))
            await client.aclose()
    except Exception as exc:
        logger.warning("[worker] ai_summary cache failed: %s", exc)
    return result


async def task_fraud_sweep(ctx: dict, db_url: str) -> None:
    from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
    from sqlalchemy.orm import sessionmaker
    from sqlalchemy import select
    from datetime import datetime, timedelta
    engine  = create_async_engine(db_url, echo=False)
    Session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with Session() as session:
        from api.database import FraudEvent
        cutoff = datetime.utcnow() - timedelta(hours=24)
        result = await session.execute(
            select(FraudEvent.user_id).where(FraudEvent.created_at >= cutoff).distinct()
        )
        user_ids = [r[0] for r in result.all()]
        from api.core.fraud import compute_trust_score
        for uid in user_ids:
            await compute_trust_score(uid, session)
        if user_ids:
            await session.commit()
            logger.info("[worker:fraud_sweep] rescored %d users", len(user_ids))
    await engine.dispose()


async def task_reconcile_mpesa(ctx: dict, db_url: str) -> None:
    from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
    from sqlalchemy.orm import sessionmaker
    from sqlalchemy import select
    from datetime import datetime, timedelta
    engine  = create_async_engine(db_url, echo=False)
    Session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with Session() as session:
        from api.database import MpesaTransaction, MpesaStatus
        cutoff  = datetime.utcnow() - timedelta(minutes=10)
        result  = await session.execute(
            select(MpesaTransaction).where(
                MpesaTransaction.status     == MpesaStatus.pending,
                MpesaTransaction.created_at <= cutoff,
            )
        )
        stale = result.scalars().all()
        for tx in stale:
            tx.status = MpesaStatus.failed
            logger.warning("[worker:reconcile] stale tx=%s marked failed", tx.id)
        if stale:
            await session.commit()
    await engine.dispose()


# ── Auction lifecycle sweeps ──────────────────────────────────────────────────
# An auction's end is a deadline, and a deadline checked every 5 minutes
# fires up to 5 minutes late. For a call timer that is tolerable; for an
# auction it is not - bidding is a race, and "the auction closed four
# minutes after it said it would" is the kind of thing bidders notice and
# argue about. So auctions ride the 60s loop (the same reasoning
# NUDGE_SWEEP_SECONDS records for the availability nudge), not the 300s one.
#
# Nothing here decides anything: close_auction() owns the rules and the
# idempotency. The sweep only finds the auctions whose time has come and
# calls it. That separation is what makes a double-run harmless - two
# sweeps, a sweep plus a manual call, or a retry after a crash all converge
# on one winner and one deal.

async def task_close_due_auctions(ctx: dict) -> None:
    """Close auctions whose ends_at has passed, and hand winners to Deal."""
    from api.database import AsyncSessionLocal, Listing
    from sqlalchemy import select
    from api.domains.auctions import events as auction_events
    from api.domains.auctions import lifecycle

    async with AsyncSessionLocal() as db:
        # Two independent passes, and the second must NOT be gated on the
        # first finding anything. The retry pass used to sit after an early
        # `if not due: return`, which meant a stranded deal was only ever
        # retried on a tick that ALSO had an auction closing - on a quiet
        # marketplace, possibly never. Caught by the sweep-recovery test,
        # which is exactly that shape: close on one tick, recover on the
        # next.
        due = await lifecycle.due_for_close(db)
        closed = 0
        for listing_id in due:
            try:
                result = await lifecycle.close_auction(db, listing_id)
                if result is None or result.already_closed:
                    continue
                closed += 1
                listing = (await db.execute(
                    select(Listing).where(Listing.id == listing_id)
                )).scalar_one_or_none()
                if listing is None:
                    continue
                await auction_events.emit_close_outcome(
                    db,
                    listing_id=listing_id,
                    listing_name=listing.name,
                    seller_id=listing.seller_id,
                    outcome=result.outcome,
                    winner_id=result.winner_id,
                    winning_amount=result.winning_amount,
                    deal_id=result.deal_id,
                    payment_deadline_iso=(
                        result.payment_deadline.isoformat()
                        if result.payment_deadline else None
                    ),
                )
            except Exception as exc:
                # One bad auction must not stop the rest of the sweep. It
                # stays un-closed and is retried next pass; close_auction is
                # idempotent, so a partial failure costs a minute, not
                # correctness.
                logger.error("[sweep] auction close failed listing=%s: %s", listing_id, exc)
        if closed:
            logger.info("[sweep] auctions closed=%d", closed)

        # Second pass: auctions that closed with a winner but whose Deal
        # creation failed. close_auction commits the close before creating
        # the Deal (so a downstream failure can never reopen a finished
        # auction), which leaves this recoverable gap - a winner with
        # nothing to pay. These are closed, so the query above cannot see
        # them; they need their own.
        retried = 0
        for listing_id in await lifecycle.due_for_deal_retry(db):
            try:
                result = await lifecycle.close_auction(db, listing_id)
                if result is None or not result.deal_id:
                    continue
                retried += 1
                listing = (await db.execute(
                    select(Listing).where(Listing.id == listing_id)
                )).scalar_one_or_none()
                if listing is None:
                    continue
                # The winner was never told, because there was nothing to
                # pay. Now there is.
                await auction_events.emit_close_outcome(
                    db,
                    listing_id=listing_id,
                    listing_name=listing.name,
                    seller_id=listing.seller_id,
                    outcome=result.outcome,
                    winner_id=result.winner_id,
                    winning_amount=result.winning_amount,
                    deal_id=result.deal_id,
                    payment_deadline_iso=(
                        result.payment_deadline.isoformat()
                        if result.payment_deadline else None
                    ),
                )
            except Exception as exc:
                logger.error(
                    "[sweep] auction deal retry failed listing=%s: %s", listing_id, exc,
                )
        if retried:
            logger.info("[sweep] auction deals recovered=%d", retried)


async def task_notify_auctions_ending_soon(ctx: dict) -> None:
    """One reminder per auction, to everyone who has bid on it.

    Delivery is at-least-once with a bounded duplicate window, not
    at-most-once: the reminder stays owed until an emit actually succeeds
    (lifecycle.claim_ending_soon_attempt / confirm_ending_soon_sent), and
    the attempt counter caps how many times it can be re-sent. Losing a
    reminder is worse than a rare repeat of one - the whole point is
    reaching a bidder before the auction closes on them.
    """
    from api.database import AsyncSessionLocal, Bid, Listing
    from datetime import datetime
    from sqlalchemy import select
    from api.core.config import settings
    from api.domains.auctions import events as auction_events
    from api.domains.auctions import lifecycle

    async with AsyncSessionLocal() as db:
        metas = await lifecycle.due_for_ending_soon(db)
        for meta in metas:
            try:
                listing = (await db.execute(
                    select(Listing).where(Listing.id == meta.listing_id)
                )).scalar_one_or_none()
                if listing is None:
                    continue
                bidder_ids = sorted({r for r in (await db.execute(
                    select(Bid.bidder_id).where(Bid.listing_id == meta.listing_id)
                )).scalars().all() if r})

                if not bidder_ids:
                    # Nobody to remind. Confirm it so the auction stops
                    # being picked up every tick until it closes.
                    await lifecycle.confirm_ending_soon_sent(db, meta.listing_id)
                    continue

                # Claim one attempt BEFORE sending. This is the durable
                # part: it stops two workers on the same tick both sending,
                # and it bounds how many times a permanently failing
                # delivery can be retried.
                #
                # It replaces writing ending_soon_notified_at here. That
                # write committed and then the send was attempted, so a
                # failed send - and emit_ending_soon swallows its own
                # exceptions, so most failures were silent - left the
                # auction marked as reminded with no reminder delivered and
                # no way for the next sweep to notice.
                if not await lifecycle.claim_ending_soon_attempt(db, meta.listing_id):
                    continue

                minutes_left = max(
                    1, int((meta.ends_at - datetime.utcnow()).total_seconds() // 60)
                ) if meta.ends_at else settings.auction_ending_soon_minutes
                sent = await auction_events.emit_ending_soon(
                    listing_id=meta.listing_id,
                    listing_name=listing.name,
                    user_ids=bidder_ids,
                    minutes_left=minutes_left,
                )
                if sent:
                    # Only now is the reminder no longer owed.
                    await lifecycle.confirm_ending_soon_sent(db, meta.listing_id)
                else:
                    logger.warning(
                        "[sweep] ending-soon emit failed listing=%s - retrying next pass "
                        "(attempt %d of %d)",
                        meta.listing_id,
                        (meta.ending_soon_attempts or 0) + 1,
                        lifecycle.MAX_ENDING_SOON_ATTEMPTS,
                    )
            except Exception as exc:
                logger.error(
                    "[sweep] ending-soon notify failed listing=%s: %s", meta.listing_id, exc,
                )


async def task_lapse_unpaid_auction_wins(ctx: dict) -> None:
    """Release listings whose winner never paid.

    Without this a listing that somebody won and abandoned stays `pending`
    forever - unsellable through any other route, and invisible as a
    problem because nothing ever looks at it again.
    """
    from api.database import AsyncSessionLocal, Listing
    from sqlalchemy import select
    from api.domains.auctions import events as auction_events
    from api.domains.auctions import lifecycle

    async with AsyncSessionLocal() as db:
        overdue = await lifecycle.due_for_payment_lapse(db)
        for meta in overdue:
            listing_id = meta.listing_id
            winner_id = meta.winner_id
            try:
                outcome = await lifecycle.lapse_unpaid_win(db, listing_id)
                if outcome is None:
                    continue
                listing = (await db.execute(
                    select(Listing).where(Listing.id == listing_id)
                )).scalar_one_or_none()
                if listing is None:
                    continue
                await auction_events.emit_payment_lapsed(
                    listing_id=listing_id,
                    listing_name=listing.name,
                    seller_id=listing.seller_id,
                    winner_id=winner_id,
                )
            except Exception as exc:
                logger.error(
                    "[sweep] auction payment lapse failed listing=%s: %s", listing_id, exc,
                )
