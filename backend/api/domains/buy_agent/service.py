"""Buy-Agent Service v1 — standing 'find & negotiate for me' requests.
Matching lives in api/core/buy_agent_subscribers.py, triggered by the
already-live ListingCreated event; this service only owns CRUD + the
one-active-request-per-buyer cap (Ch.9, Ch.22 — do not relax this).
"""
from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime
from typing import Any
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession
from fastapi import HTTPException

from api.database import BuyAgentRequest, User
from api.core.config import settings

logger = logging.getLogger(__name__)

# Statuses that make a request "the buyer's current standing request".
# Kept here rather than repeated at four call sites, and deliberately the
# same tuple api/core/buy_agent_subscribers.py watches from - a request
# this service will hand back, update or cancel is exactly a request the
# matcher is still working on.
LIVE_STATUSES: tuple[str, ...] = ("active", "matched")

# Statuses that count against BUY_AGENT_MAX_ACTIVE: every status the
# matcher still watches from. This used to be ("active",) alone, so that a
# request which had found something would not block a new search - but a
# "matched" request keeps matching (buy_agent_subscribers.WATCHING_STATUSES),
# and GET /me, update and cancel only ever reach the newest row. A buyer
# whose first watch had matched could start a second one, and the first
# went on pushing matches and opening negotiations on their behalf where
# they could neither see nor stop it. The app offers to replace the current
# watch instead (zeno_screen.dart).
CAPPED_STATUSES: tuple[str, ...] = LIVE_STATUSES


def _validate_price_range(max_price: float | None, min_price: float | None) -> None:
    """Single choke point for the two price rules, enforced in the service
    rather than only in buy_agent/actions.py.

    Before this, actions.py validated min<=max for CREATE_BUYING_REQUEST
    while the plain POST /buy-agent-requests endpoint (which the Flutter
    sheet still uses) validated nothing at all: a request with
    max_price=0, or a negative budget, was accepted and stored, and then
    quietly matched nothing forever because no listing can satisfy it
    (api/schemas.py's ListingCreate already requires price > 0). Failing
    at write time says so instead."""
    if max_price is not None and max_price <= 0:
        raise HTTPException(status_code=422, detail="max_price must be greater than zero.")
    if min_price is not None and min_price < 0:
        raise HTTPException(status_code=422, detail="min_price cannot be negative.")
    if min_price is not None and max_price is not None and min_price > max_price:
        raise HTTPException(status_code=422, detail="min_price cannot be greater than max_price.")


def clean_condition(condition: str | None) -> str | None:
    """A request's condition, spelt the way listings store it.

    Listings keep "new" / "used" / "refurbished" in lower case
    (listings/validation.py). A request stored "Used" as typed, and the
    matcher's case-sensitive comparison meant it could never match a single
    listing; a value outside the three matched nothing at all. Both now
    fail or normalise at write time instead of silently watching for
    nothing."""
    from api.domains.listings.validation import CONDITIONS
    if condition is None or not str(condition).strip():
        return None
    value = str(condition).strip().lower()
    if value not in CONDITIONS:
        raise HTTPException(status_code=422, detail="condition must be new, used or refurbished.")
    return value


async def lock_buyer(db: AsyncSession, buyer_id: str) -> None:
    """Serialise this buyer's buy-agent writes for the rest of the
    transaction by locking their users row (SELECT ... FOR UPDATE).

    There is no row to lock for "the buyer's standing requests" before one
    exists, and no constraint can express BUY_AGENT_MAX_ACTIVE, so the
    buyer's own row stands in: a second create for the same buyer waits
    here until the first commits, then counts it. A no-op on SQLite, which
    has no FOR UPDATE and serialises writers anyway."""
    await db.execute(select(User.id).where(User.id == buyer_id).with_for_update())


class BuyAgentService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def create_request(
        self,
        buyer_id: str,
        category: str,
        max_price: float,
        must_have_features: list[str],
        subcategory_id: str | None = None,
        query: str | None = None,
        min_price: float | None = None,
        location_name: str | None = None,
        lat: float | None = None,
        lng: float | None = None,
        max_distance_km: float | None = None,
        condition: str | None = None,
        attributes: dict | None = None,
        optimization_code: str | None = None,
        optimization_configuration: dict | None = None,
        negotiation_authorized: bool = False,
    ) -> dict:
        _validate_price_range(max_price, min_price)
        condition = clean_condition(condition)

        await lock_buyer(self.db, buyer_id)
        # Cap is settings.buy_agent_max_active (BUY_AGENT_MAX_ACTIVE, default
        # 1 — Appendix C). count()-based rather than an existence check so
        # the env var has real effect; at the documented default of 1 this
        # is exactly equivalent to the old "any active request blocks" check.
        if await self._active_count(buyer_id) >= settings.buy_agent_max_active:
            raise HTTPException(
                status_code=409,
                detail="You already have an active buy request. Cancel it before creating a new one.",
            )

        # A renamed category's old name ("Vehicles", from an older app build)
        # is stored under the current one ("Automobiles"): matching compares
        # it with the listing's category name, which is always current.
        from api.domains.categories.seed import canonical_category_name
        category = canonical_category_name(category)

        now = datetime.utcnow()
        req = BuyAgentRequest(
            id=str(uuid.uuid4()), buyer_id=buyer_id, category=category, max_price=max_price,
            must_have_features=json.dumps(must_have_features or []), status="active",
            created_at=now, updated_at=now,
            subcategory_id=subcategory_id, query=query, min_price=min_price,
            location_name=location_name, lat=lat, lng=lng, max_distance_km=max_distance_km,
            condition=condition, attributes=json.dumps(attributes) if attributes else None,
            optimization_code=optimization_code,
            optimization_configuration=json.dumps(optimization_configuration) if optimization_configuration else None,
            # FIX (ChatGPT-review audit, 2026-08-15): this column existed
            # (default=False, correctly the safe default) but was never
            # settable anywhere - no param here, on either action-layer
            # params model, or any router/Flutter path - so it could never
            # actually become True. buy_agent_subscribers.py's auto-opener
            # is now gated on it (see that file), so it has to be
            # genuinely settable for autonomous negotiation to ever work
            # at all, not just exist as an inert column.
            negotiation_authorized=negotiation_authorized,
            match_count=0,
        )
        self.db.add(req)

        # Two creates racing (a double-tapped "keep watching", two devices)
        # could both count 0 and both insert. The lock_buyer() above is what
        # stops that on PostgreSQL: this re-count after the flush only ever
        # saw its own transaction's row, never the other's uncommitted one,
        # so on its own it let both through (tests/test_buy_agent.py
        # test_two_creates_at_once_cannot_exceed_the_cap). It stays for
        # SQLite, which has no FOR UPDATE but lets one writer in at a time:
        # there this flush waits for the other create to commit, so the
        # re-count does see its row and turns the race into the same honest
        # 409 a serial caller would have got.
        await self.db.flush()
        if await self._active_count(buyer_id) > settings.buy_agent_max_active:
            await self.db.rollback()
            raise HTTPException(
                status_code=409,
                detail="You already have an active buy request. Cancel it before creating a new one.",
            )

        await self.db.commit()
        return self._dict(req)

    async def _active_count(self, buyer_id: str) -> int:
        return (await self.db.execute(
            select(func.count(BuyAgentRequest.id)).where(
                BuyAgentRequest.buyer_id == buyer_id,
                BuyAgentRequest.status.in_(CAPPED_STATUSES),
            )
        )).scalar_one()

    async def get_request_row(self, buyer_id: str, statuses: tuple[str, ...]) -> BuyAgentRequest | None:
        """Shared row-fetch behind get_active_for_buyer/update_request/
        cancel_request - "the buyer's current standing request", scoped to
        whichever statuses the caller cares about. Newest first so a caller
        that (in theory) finds more than one non-cancelled row picks the
        current one, not an old one a bug left behind."""
        return (await self.db.execute(
            select(BuyAgentRequest).where(
                BuyAgentRequest.buyer_id == buyer_id,
                BuyAgentRequest.status.in_(statuses),
            ).order_by(BuyAgentRequest.created_at.desc(), BuyAgentRequest.id.desc())
        )).scalars().first()

    async def get_active_for_buyer(self, buyer_id: str) -> dict | None:
        # FIX (redesign-guide audit): previously only matched status=="active".
        # buy_agent_subscribers.py sets status="matched" the instant a listing
        # matches, so a matched request became invisible to this endpoint the
        # moment it found what it was looking for - home_screen.dart's
        # "Match found!" branch (_buildActiveBuyAgentSection) had real code
        # for this state but GET /buy-agent-requests/me could never actually
        # return it. Now surfaces both.
        req = await self.get_request_row(buyer_id, statuses=LIVE_STATUSES)
        return self._dict(req) if req else None

    async def update_request(self, buyer_id: str, **fields: Any) -> dict | None:
        """Partial update of the buyer's current standing request (Design v2
        §17 UPDATE_BUYING_REQUEST / CHANGE_BUDGET). Only keys actually
        present in **fields are touched - omit a key entirely to leave it
        unchanged (this is "no change", not "set to null"; there is
        deliberately no way to clear a field back to empty via this action,
        matching create_request's own required-field shape which never
        allowed empty values either).

        A successful update resets status back to "active": once criteria
        change, a prior "matched" status can no longer be trusted to
        describe whether the *new* criteria are still met, and re-matching
        happens naturally the next time a qualifying listing is created.
        match_count is deliberately NOT reset - it is a lifetime counter of
        matches found for this standing request, not a per-criteria one.

        Returns None if the buyer has no active/matched request to update.
        """
        # Locked first, like create_request: an update racing a cancel
        # could otherwise load the row before the cancel committed and then
        # write status="active" over it, bringing a cancelled watch back.
        await lock_buyer(self.db, buyer_id)
        req = await self.get_request_row(buyer_id, statuses=LIVE_STATUSES)
        if not req:
            return None

        if "category" in fields and fields["category"] is not None:
            req.category = fields["category"]
        if "subcategory_id" in fields:
            req.subcategory_id = fields["subcategory_id"]
        if "query" in fields and fields["query"] is not None:
            req.query = fields["query"]
        if "max_price" in fields and fields["max_price"] is not None:
            req.max_price = fields["max_price"]
        if "min_price" in fields:
            req.min_price = fields["min_price"]
        if "location_name" in fields and fields["location_name"] is not None:
            req.location_name = fields["location_name"]
        if "lat" in fields and fields["lat"] is not None:
            req.lat = fields["lat"]
        if "lng" in fields and fields["lng"] is not None:
            req.lng = fields["lng"]
        if "max_distance_km" in fields:
            req.max_distance_km = fields["max_distance_km"]
        if "condition" in fields:
            req.condition = clean_condition(fields["condition"])
        if "attributes" in fields and fields["attributes"] is not None:
            req.attributes = json.dumps(fields["attributes"])
        if "must_have_features" in fields and fields["must_have_features"] is not None:
            req.must_have_features = json.dumps(fields["must_have_features"])
        if "negotiation_authorized" in fields and fields["negotiation_authorized"] is not None:
            req.negotiation_authorized = fields["negotiation_authorized"]

        # Validated against the POST-UPDATE values, not the incoming ones:
        # "lower my budget to 20k" is only invalid relative to whatever
        # min_price the request already carries. Raising before the commit
        # leaves the session dirty but uncommitted - get_db() never commits
        # on teardown (api/database.py), so closing the session discards
        # the mutations above.
        _validate_price_range(req.max_price, req.min_price)

        req.status = "active"
        req.updated_at = datetime.utcnow()
        await self.db.commit()
        return self._dict(req)

    async def cancel_request(self, buyer_id: str) -> dict | None:
        """Sets status='cancelled' on the buyer's current standing request.
        A cancelled request no longer counts toward the one-active-request
        cap (create_request counts CAPPED_STATUSES), freeing the slot for a
        new one. Returns None if the buyer had nothing to cancel.

        Before this existed, there was NO way to reach "cancelled" from
        anywhere in the app: nothing ever set status away from
        "active"/"matched", so a buyer who hit BUY_AGENT_MAX_ACTIVE (default
        1) had no UI escape hatch to ever create a second request.
        """
        await lock_buyer(self.db, buyer_id)
        req = await self.get_request_row(buyer_id, statuses=LIVE_STATUSES)
        if not req:
            return None
        req.status = "cancelled"
        req.updated_at = datetime.utcnow()
        await self.db.commit()
        return self._dict(req)

    @staticmethod
    def _json(raw: str | None, fallback: Any) -> Any:
        """Tolerant read of the three JSON-in-a-Text-column fields.

        json.loads() on a malformed value used to take the whole endpoint
        down with a 500 - and the value it parses is not always ours:
        must_have_features comes from an LLM parse (ai_broker/service.py)
        and attributes from client-supplied JSON. A row that somehow holds
        something unreadable should cost that one field, not the buyer's
        access to their own standing request."""
        if not raw:
            return fallback
        try:
            value = json.loads(raw)
        except (TypeError, ValueError):
            logger.warning("[buy_agent] unreadable JSON column, falling back: %r", raw[:120])
            return fallback
        return value if isinstance(value, type(fallback)) or fallback is None else fallback

    def _dict(self, r: BuyAgentRequest) -> dict:
        return {
            "id": r.id, "category": r.category, "max_price": r.max_price,
            "must_have_features": self._json(r.must_have_features, []),
            "status": r.status,
            # created_at is nullable at the DB level (the model's default
            # only fires on rows this code inserts), so a row written by
            # anything else - a manual fix-up, a restored backup - must not
            # 500 the buyer's own request out of existence.
            "created_at": r.created_at.isoformat() if r.created_at else None,
            "subcategory_id": r.subcategory_id, "query": r.query, "min_price": r.min_price,
            "location_name": r.location_name, "lat": r.lat, "lng": r.lng,
            "max_distance_km": r.max_distance_km, "condition": r.condition,
            "attributes": self._json(r.attributes, None),
            "optimization_code": r.optimization_code,
            "optimization_configuration": self._json(r.optimization_configuration, None),
            "negotiation_authorized": bool(r.negotiation_authorized),
            "match_count": r.match_count or 0,
            "updated_at": r.updated_at.isoformat() if r.updated_at else None,
        }
