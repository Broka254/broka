"""Store visit and share counting, and the owner's stats.

What gets counted
-----------------
A **visit** is someone opening the storefront: the app's store screen
(POST /stores/{id}/visit) or the public web page (GET /store/{slug}).
Where they came from is read from the `?via=` tag BROKA's share buttons
add to the link (…/store/clanix?via=whatsapp), falling back to the web
page's Referer header, and to "direct" when there's neither.

A visit is counted once per visitor per store per VISIT_WINDOW: reopening
the page, pulling to refresh or paging through products isn't a new
visitor. Crawlers and link-preview fetchers (WhatsApp and Facebook fetch
a shared link to draw its preview card) aren't visitors at all. The visitor is the signed-in user in the app, or a hash of IP and
user agent on the web (never stored - it only names a short-lived cache
key). The owner looking at their own store isn't a visit.

A **share** is a tap on a share button, by the owner or a buyer, with the
channel it went to.

Storage
-------
StoreDailyCount rows, one per (store, day, kind, surface, source),
incremented in place. Days are Kenyan calendar days (UTC+3, no daylight
saving), so "today" on the owner's chart matches their own today.

Counting never fails the request it rides on: a visit that can't be
recorded is logged and dropped, since a missed count is better than a
storefront that doesn't open.
"""
from __future__ import annotations

import asyncio
import hashlib
import logging
import time
from collections import OrderedDict
from datetime import date, datetime, timedelta, timezone
from typing import Optional
from urllib.parse import urlparse

from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.models.store import StoreDailyCount

logger = logging.getLogger(__name__)

KENYA = timezone(timedelta(hours=3))

SURFACES = ("app", "web")
VISIT_SOURCES = ("whatsapp", "tiktok", "instagram", "facebook", "x", "qr", "direct", "other")
SHARE_CHANNELS = ("whatsapp", "tiktok", "instagram", "facebook", "x", "copy", "qr", "other")

# Short forms people type or other tools produce.
_VIA_ALIASES = {
    "wa": "whatsapp", "whatsapp-status": "whatsapp", "whatsapp_status": "whatsapp",
    "ig": "instagram", "insta": "instagram",
    "fb": "facebook", "meta": "facebook",
    "tt": "tiktok",
    "twitter": "x",
}
# Referer host suffix -> source.
_REFERRERS = (
    ("whatsapp.com", "whatsapp"), ("wa.me", "whatsapp"),
    ("tiktok.com", "tiktok"),
    ("instagram.com", "instagram"),
    ("facebook.com", "facebook"), ("fb.com", "facebook"), ("fb.me", "facebook"),
    ("messenger.com", "facebook"),
    ("twitter.com", "x"), ("x.com", "x"), ("t.co", "x"),
)
# Our own pages linking to a store count as a direct visit.
_OWN_HOSTS = ("broka.co.ke",)

VISIT_WINDOW_SECONDS = 30 * 60
MAX_STATS_DAYS = 90


def today() -> date:
    return datetime.now(KENYA).date()


def visit_source(via: Optional[str], referer: Optional[str] = None) -> str:
    tag = (via or "").strip().lower()
    if tag:
        tag = _VIA_ALIASES.get(tag, tag)
        return tag if tag in VISIT_SOURCES else "other"
    host = ""
    if referer:
        try:
            host = (urlparse(referer).hostname or "").lower()
        except ValueError:
            host = ""
    if not host:
        return "direct"
    for suffix, source in _REFERRERS:
        if host == suffix or host.endswith("." + suffix):
            return source
    if any(host == h or host.endswith("." + h) for h in _OWN_HOSTS):
        return "direct"
    return "other"


def share_channel(value: Optional[str]) -> str:
    tag = (value or "").strip().lower()
    tag = _VIA_ALIASES.get(tag, tag)
    return tag if tag in SHARE_CHANNELS else "other"


# Link-preview fetchers and crawlers. Pasting a store link into WhatsApp or
# Facebook makes their servers fetch the page to build the preview card -
# that is not a person visiting, and counting it would credit every share
# with a visit. Matched case-insensitively as substrings of the User-Agent.
_BOT_MARKERS = (
    "whatsapp", "facebookexternalhit", "facebookcatalog", "meta-externalagent",
    "twitterbot", "telegrambot", "slackbot", "discordbot", "linkedinbot",
    "skypeuripreview", "pinterest", "googlebot", "google-inspectiontool",
    "adsbot", "bingbot", "yandex", "baiduspider", "duckduckbot", "applebot",
    "bytespider", "petalbot", "semrush", "ahrefs", "mj12bot", "embedly",
    "vkshare", "viber", "snapchat", "headlesschrome", "python-requests",
    "curl/", "wget/", "go-http-client", "okhttp", "bot/", "bot;", "crawler",
    "spider", "preview",
)


def is_bot(user_agent: Optional[str]) -> bool:
    """True for crawlers and link-preview fetchers - and for requests with
    no User-Agent at all, which no real browser sends."""
    ua = (user_agent or "").lower()
    if not ua.strip():
        return True
    return any(marker in ua for marker in _BOT_MARKERS)


def anonymous_visitor_key(ip: Optional[str], user_agent: Optional[str]) -> str:
    raw = f"{ip or '-'}|{user_agent or '-'}".encode()
    return "w:" + hashlib.sha256(raw).hexdigest()[:24]


# ── "Seen recently" ──────────────────────────────────────────────────────────

class _MemorySeen:
    """In-process fallback: bounded, expiring. Per process, so with several
    instances and no Redis a visitor can be counted once per instance -
    an overcount bounded by the instance count, never a flood."""

    def __init__(self, max_entries: int = 50_000):
        self._entries: OrderedDict[str, float] = OrderedDict()
        self._max = max_entries
        self._lock = asyncio.Lock()

    async def first_time(self, key: str, ttl: int) -> bool:
        now = time.monotonic()
        async with self._lock:
            expires = self._entries.get(key)
            if expires is not None and expires > now:
                return False
            self._entries[key] = now + ttl
            self._entries.move_to_end(key)
            while len(self._entries) > self._max:
                self._entries.popitem(last=False)
            return True

    def clear(self) -> None:
        self._entries.clear()


class _Seen:
    def __init__(self):
        self._memory = _MemorySeen()
        self._client = None
        self._client_loop = None

    async def first_time(self, key: str, ttl: int) -> bool:
        from api.core.config import settings
        if not settings.redis_enabled:
            return await self._memory.first_time(key, ttl)
        try:
            loop = asyncio.get_running_loop()
            if self._client is None or self._client_loop is not loop:
                import redis.asyncio as aioredis
                self._client = aioredis.from_url(
                    settings.redis_url, decode_responses=True, socket_connect_timeout=2,
                )
                self._client_loop = loop
            return bool(await self._client.set(f"broka:seen:{key}", "1", nx=True, ex=ttl))
        except Exception as e:
            logger.warning("[store_stats] Redis unavailable, using memory: %s", e)
            return await self._memory.first_time(key, ttl)

    def clear(self) -> None:
        """Tests only: forget every visitor seen by this process."""
        self._memory.clear()


seen = _Seen()


# ── Recording ────────────────────────────────────────────────────────────────

async def _increment(
    db: AsyncSession, store_id: str, kind: str, surface: str, source: str,
) -> None:
    day = today()
    match = (
        StoreDailyCount.store_id == store_id,
        StoreDailyCount.day == day,
        StoreDailyCount.kind == kind,
        StoreDailyCount.surface == surface,
        StoreDailyCount.source == source,
    )
    # UPDATE first (the common case once a store has had a visit today),
    # INSERT when there's no row yet; the unique constraint turns two
    # concurrent first-visits-of-the-day into one insert and one retry.
    for _ in range(3):
        result = await db.execute(
            update(StoreDailyCount).where(*match)
            .values(count=StoreDailyCount.count + 1)
            .execution_options(synchronize_session=False)
        )
        if result.rowcount:
            await db.commit()
            return
        db.add(StoreDailyCount(
            store_id=store_id, day=day, kind=kind, surface=surface, source=source, count=1,
        ))
        try:
            await db.commit()
            return
        except IntegrityError:
            await db.rollback()
    logger.warning("[store_stats] gave up counting %s for store %s", kind, store_id)


async def record_visit(
    db: AsyncSession, store_id: str, surface: str, source: str, visitor: str,
) -> bool:
    """Count a visit unless this visitor was already counted recently.
    Returns whether it was counted."""
    try:
        if not await seen.first_time(f"visit:{store_id}:{visitor}", VISIT_WINDOW_SECONDS):
            return False
        await _increment(db, store_id, "visit", surface, source)
        return True
    except Exception:
        logger.exception("[store_stats] could not record a visit to %s", store_id)
        try:
            await db.rollback()
        except Exception:
            pass
        return False


async def record_share(db: AsyncSession, store_id: str, surface: str, channel: str) -> None:
    try:
        await _increment(db, store_id, "share", surface, channel)
    except Exception:
        logger.exception("[store_stats] could not record a share of %s", store_id)
        try:
            await db.rollback()
        except Exception:
            pass


# ── Reading ──────────────────────────────────────────────────────────────────

async def stats_for(db: AsyncSession, store_id: str, days: int) -> dict:
    """The owner's numbers for the last `days` days, today included. Every
    day, source, surface and channel is present (zero when nothing
    happened), so the app draws a chart without filling gaps itself."""
    days = max(1, min(days, MAX_STATS_DAYS))
    end = today()
    start = end - timedelta(days=days - 1)
    rows = (await db.execute(
        select(
            StoreDailyCount.day, StoreDailyCount.kind, StoreDailyCount.surface,
            StoreDailyCount.source, func.sum(StoreDailyCount.count),
        )
        .where(StoreDailyCount.store_id == store_id, StoreDailyCount.day >= start)
        .group_by(
            StoreDailyCount.day, StoreDailyCount.kind,
            StoreDailyCount.surface, StoreDailyCount.source,
        )
    )).all()

    by_day = {start + timedelta(days=i): 0 for i in range(days)}
    by_source = {s: 0 for s in VISIT_SOURCES}
    by_surface = {s: 0 for s in SURFACES}
    by_channel = {c: 0 for c in SHARE_CHANNELS}
    for day, kind, surface, source, count in rows:
        count = int(count or 0)
        if isinstance(day, datetime):
            day = day.date()
        if kind == "visit":
            if day in by_day:
                by_day[day] += count
            by_source[source if source in by_source else "other"] += count
            if surface in by_surface:
                by_surface[surface] += count
        elif kind == "share":
            by_channel[source if source in by_channel else "other"] += count

    return {
        "days": days,
        "from": start.isoformat(),
        "to": end.isoformat(),
        "visits": {
            "total": sum(by_day.values()),
            "by_day": [{"date": d.isoformat(), "count": n} for d, n in by_day.items()],
            "by_source": by_source,
            "by_surface": by_surface,
        },
        "shares": {"total": sum(by_channel.values()), "by_channel": by_channel},
    }
