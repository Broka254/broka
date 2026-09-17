"""Matches new listings against open Buy-Agent requests the instant they
are created (Ch.8 — refines Volume 5 Ch.10's originally-proposed periodic
scan into event-driven matching, since ListingCreated already carries
category and price).

FIX (redesign-guide audit, 2026-08-11): was registered on the legacy
api.core.events @subscribe bus. That bus only invokes in-process handlers
when REDIS_URL is unset (see api/core/events.py) — the moment Redis is
configured (config.py's own startup log calls this "production-grade
operation", i.e. the recommended deploy config), publish() routes to Redis
Streams instead and nothing ever reads the stream back out
(consume_redis_stream exists but is never called anywhere in this
codebase). So the single most central mechanic in the Buying Agent design
doc — "Zeno is watching for you" actually finding matches — was silently
dead under the recommended production config. Moved to the Event Catalog
(api.core.event_catalog), whose handlers fire unconditionally inside
emit() regardless of transport. publish(ListingCreated(...))
(api/domains/listings/service.py, the only call site) already bridges to
EventType.LISTING_CREATED on every call via api.core.events._bridge_to_catalog
- no other file needs to change for this fix to take effect.

FIX (ChatGPT-review audit, 2026-08-15) — two real gaps a second-pass
review caught that are worth being direct about:

1. Matching only ever checked category + max_price, silently ignoring
   condition, subcategory, distance, and must_have_features even when a
   buyer's standing request specified them - so "Samsung Galaxy, 8GB RAM,
   under 10km, good condition" behaved identically to "anything
   electronics under budget." _listing_satisfies_request below adds the
   hard constraints that were already being collected and stored but
   never actually checked at match time. must_have_features is matched as
   a best-effort case-insensitive substring check against the listing's
   name+description - this is a real limitation (it's text matching, not
   structured attribute comparison) and is called out as such rather than
   presented as equivalent to a real spec/attribute check; the deeper fix
   (matching against Listing.attributes with a shared schema) needs the
   attribute-value validation this codebase doesn't have yet at write
   time either (see database.py's category_filters note).

2. The auto-opener message was being sent to every matching seller
   regardless of BuyAgentRequest.negotiation_authorized - which existed
   as a column (correctly defaulting to False) but was never actually
   checked here, and (separately fixed, see buy_agent/actions.py and
   service.py) was never even settable by a buyer until this same pass.
   So the authorization boundary the design doc describes (§24: "Zeno
   must not negotiate automatically... unless the user has
   pre-authorized") existed in name only for the autonomous path. Now
   gated: an unauthorized match still flips status to "matched" and
   increments match_count (the buyer still sees "Match found!" and can
   review it), it just doesn't auto-message the seller - the buyer
   reaches that through the same explicit-confirmation START_NEGOTIATION
   action every other match already goes through.

Not changed, and worth being equally direct about why: matching still
reacts to one listing at a time and commits to the first one that
satisfies every constraint, rather than collecting several candidates and
picking the best-scored one. CREATE_BUYING_REQUEST already runs an
immediate search against existing inventory before a standing request is
even created (see actions.py's _create_buying_request flow, surfaced via
the Buying Agent Hub's confirm-and-search step) — so the standing watch's
job is specifically to catch *future* listings, not to hold out for a
better one that may never arrive. Changing that to a batched/scored
comparison is a real, larger design decision (how long to wait, whether
"good enough now" beats "maybe-better later") that deserves an explicit
product call, not a unilateral change bundled into a matching-completeness
fix.
"""
from __future__ import annotations

import json
import math
from sqlalchemy import select

from api.core.event_catalog import subscribe_to, EventType, EventEnvelope
from api.database import AsyncSessionLocal, BuyAgentRequest, NegotiationMessage, Listing


def _haversine_km(lat1, lng1, lat2, lng2) -> float:
    R = 6371
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _listing_satisfies_request(listing: Listing, req: BuyAgentRequest) -> bool:
    """Hard-constraint check beyond the SQL-level category+price pre-filter
    the caller already applied. Every check is opt-in: a constraint the
    buyer never specified never excludes a listing, and a listing missing
    the corresponding data is treated as "unknown, don't exclude" rather
    than a hard fail - most listings won't have every optional field
    filled in, and excluding on missing data would silently starve
    matching rather than just being permissive about what it can't verify.
    """
    if req.subcategory_id and listing.subcategory_id and req.subcategory_id != listing.subcategory_id:
        return False

    if req.condition and listing.condition and req.condition != listing.condition:
        return False

    if req.max_distance_km and req.lat is not None and req.lng is not None \
            and listing.lat is not None and listing.lng is not None:
        if _haversine_km(req.lat, req.lng, listing.lat, listing.lng) > req.max_distance_km:
            return False

    if req.must_have_features:
        try:
            features = json.loads(req.must_have_features) if isinstance(req.must_have_features, str) else req.must_have_features
        except (TypeError, ValueError):
            features = []
        if features:
            haystack = f"{listing.name} {listing.description or ''}".lower()
            # Best-effort text match, not structured attribute comparison -
            # see this module's docstring. A feature phrase that doesn't
            # appear verbatim in the listing's name/description (e.g. the
            # seller wrote "8gb" instead of "8GB RAM") won't match even
            # when the listing genuinely qualifies.
            if not all(f.lower() in haystack for f in features if f):
                return False

    return True


@subscribe_to(EventType.LISTING_CREATED)
async def on_listing_created_match_buy_agents(envelope: EventEnvelope) -> None:
    listing_id = envelope.payload.get("listing_id") or envelope.aggregate_id
    category = envelope.payload.get("category")
    price = envelope.payload.get("price")
    if not listing_id or category is None or price is None:
        return

    async with AsyncSessionLocal() as db:
        candidates = (await db.execute(
            select(BuyAgentRequest).where(
                BuyAgentRequest.status == "active",
                BuyAgentRequest.category == category,
                BuyAgentRequest.max_price >= price,
            )
        )).scalars().all()
        if not candidates:
            return

        listing = await db.get(Listing, listing_id)
        if not listing:
            return

        for req in candidates:
            if not _listing_satisfies_request(listing, req):
                continue

            if req.negotiation_authorized:
                opening = (
                    f"Hi! I'm Zeno, reaching out on behalf of a buyer with a standing "
                    f"request for {req.category} under KES {req.max_price:,.0f}. "
                    f"Your listing \"{listing.name}\" at KES {listing.price:,.0f} looks "
                    f"like a match - would you be open to a conversation?"
                )
                db.add(NegotiationMessage(
                    listing_id=listing_id, sender_id="broker", role="broker",
                    recipient_role="seller", content=opening, buyer_id=req.buyer_id,
                    msg_type="text", via_ai=True, is_agent_initiated=True,
                ))
            req.status = "matched"
            req.match_count = (req.match_count or 0) + 1

        await db.commit()
