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

FIX (buying-agent bug-hunt, 2026-09-17) — six defects found by reading
this handler against what the rest of the feature promises:

1. LEAKED THE BUYER'S BUDGET. The auto-opener told the seller, verbatim,
   the maximum the buyer had authorised ("...under KES 50,000"). On a
   negotiation product that is the single worst thing to hand the other
   side before talking: the seller now knows the ceiling and has no
   reason to go below it. The opener no longer states the budget at all -
   it says which listing it is about and asks to talk, which is all the
   seller needs to decide whether to engage.

2. match_count could never exceed 1. The candidate query selected
   status == "active" only, while the first match set status = "matched"
   - so a standing request stopped matching the instant it matched once,
   and both UIs ("N matches found", Home's "Zeno is watching for you"
   card) could only ever display "1 match found!". "matched" is now a
   candidate status too: a standing request keeps watching until the
   buyer cancels or updates it, which is what "Zeno keeps watching after
   you leave" means everywhere it is written in this feature.

3. Buyers matched their own listings. Nothing excluded
   listing.seller_id == req.buyer_id, so a user who both buys and sells
   (the normal case on this marketplace) got Zeno opening a negotiation
   with them about their own item.

4. Case-sensitive category equality. BuyAgentRequest.category is the
   canonical Category.name resolved through ilike() in
   buy_agent/actions.py; Listing.category is a free-text string a seller
   typed (api/schemas.py ListingCreate: plain `str`). "electronics" vs
   "Electronics" never matched on Postgres. Compared case-insensitively
   now, on both sides.

5. min_price and listing status were collected but never checked -
   a listing below the buyer's stated floor, or one already sold/
   cancelled between the event and this handler, still matched.

6. Duplicate openers. With (2) fixed, and on any event redelivery, the
   same (listing, buyer) pair could be messaged repeatedly. One opener
   per thread now, checked against what is already in the table.

Also added: the buyer is actually notified. Both entry points promise it
in so many words - buy_agent_sheet.dart's "you'll be notified when a
match comes in" and the Hub's "Zeno will notify you when new matches
appear" - and nothing anywhere sent anything. A match now pushes through
the same api.core.push service every other notification in this codebase
uses, fire-and-forget (a missing FCM token or a push failure must never
cost the match itself).

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

FIX (buying-agent review, 2026-09-26):

1. `query` and `attributes` were stored on every watch Zeno sets up from a
   conversation and never read here. A watch for "Pixel 8" in Electronics
   fired on any Electronics listing under budget - a soundbar, a kettle -
   pushed "matches what you asked Zeno to watch for", and, when
   authorised, told that seller the same. Every word of the query must now
   appear in the listing (the rule GET /listings?search= uses), and a
   listing that states a spec short of the ask (8GB against 12GB) is
   skipped; one that doesn't state it still gets through.

2. Condition was compared case-sensitively against listings' lower-case
   values. Requests are normalised at write time now (buy_agent/service.py
   clean_condition); the comparison here is case-insensitive for rows
   written before that.

3. match_count was read, incremented in Python and written back, so two
   listings matching one watch at the same moment both wrote the same
   number. It is incremented in SQL, and only while the request is still
   watching - the UPDATE re-checks the status, so a watch cancelled while
   this ran is not revived as "matched".

4. This handler runs INSIDE POST /listings (event_catalog.emit awaits its
   handlers) and sent one push per matched buyer, one after another, each
   allowed 15 seconds. A slow FCM made the seller wait for every watching
   buyer's notification before their own listing was confirmed. The
   tokens are read in one query and the pushes go out in the background,
   a few at a time.
"""
from __future__ import annotations

import asyncio
import json
import logging
import math
from datetime import datetime
from sqlalchemy import func, select, update

from api.core.event_catalog import subscribe_to, EventType, EventEnvelope
from api.core.text_search import search_terms
from api.database import (
    AsyncSessionLocal, BuyAgentRequest, ListingStatus, NegotiationMessage, Listing, User,
)
from api.domains.buy_agent.matching import states_a_shortfall
from api.domains.buy_agent.service import not_expired
from api.domains.listings.validation import load_attributes

logger = logging.getLogger(__name__)

# How many match pushes go out at once. Bounded so one listing that
# matches hundreds of watches doesn't open hundreds of connections to FCM.
PUSH_CONCURRENCY = 8

# Strong references to in-flight push batches - asyncio keeps only a weak
# one to a running task, so an unreferenced task can be collected mid-send
# (same reason as api/core/events.py's _inflight).
_inflight: set = set()

# Statuses a standing request still watches from. "matched" is included on
# purpose - see fix (2) in this module's docstring: a request that found
# one listing has not stopped being a standing request, and match_count is
# documented (buy_agent/service.py) as a lifetime counter.
WATCHING_STATUSES = ("active", "matched")


def _haversine_km(lat1, lng1, lat2, lng2) -> float:
    R = 6371
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _listing_satisfies_request(listing: Listing, req: BuyAgentRequest) -> bool:
    """Hard-constraint check beyond the SQL-level category+price pre-filter
    the caller already applied. Every *buyer-supplied* constraint is
    opt-in: a constraint the buyer never specified never excludes a
    listing, and a listing missing the corresponding data is treated as
    "unknown, don't exclude" rather than a hard fail - most listings won't
    have every optional field filled in, and excluding on missing data
    would silently starve matching rather than just being permissive about
    what it can't verify.

    The two checks that are NOT opt-in are the ones that protect the buyer
    rather than express their preference: a listing must be live, and it
    must not be the buyer's own (see fixes 3 and 5 in the module
    docstring).
    """
    # Not a preference - a sold/cancelled/pending listing is not something
    # to open a negotiation about. ListingCreated fires on creation so this
    # is normally active, but the handler runs after the fact and the row is
    # re-read from a fresh session, so it can legitimately have moved on.
    if listing.status is not None and listing.status != ListingStatus.active:
        return False
    # Nor is one buyers cannot see because its fee is unpaid or ran out.
    from api.domains.listings.paid import is_live
    if not is_live(listing):
        return False

    # Not a preference either - a user who both buys and sells must not have
    # Zeno open a negotiation with them about their own item.
    if listing.seller_id and listing.seller_id == req.buyer_id:
        return False

    if req.min_price is not None and listing.price is not None and listing.price < req.min_price:
        return False

    if req.subcategory_id and listing.subcategory_id and req.subcategory_id != listing.subcategory_id:
        return False

    if req.condition and listing.condition \
            and req.condition.strip().lower() != str(listing.condition).strip().lower():
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
        if not isinstance(features, list):
            features = []
        if features:
            haystack = f"{listing.name} {listing.description or ''}".lower()
            # Best-effort text match, not structured attribute comparison -
            # see this module's docstring. A feature phrase that doesn't
            # appear verbatim in the listing's name/description (e.g. the
            # seller wrote "8gb" instead of "8GB RAM") won't match even
            # when the listing genuinely qualifies.
            if not all(str(f).lower() in haystack for f in features if f):
                return False

    # What the buyer named ("Pixel 8"). Every word has to appear in the
    # name, category or description - GET /listings?search='s own rule
    # (api/core/text_search.py), so a watch fires on what the same words
    # would have found in search, and on nothing else in the category.
    terms = search_terms(req.query)
    if terms:
        haystack = f"{listing.name} {listing.category or ''} {listing.description or ''}".lower()
        if not all(t in haystack for t in terms):
            return False

    # Specs the buyer stated ("12GB"). Only a value the listing states and
    # falls short on excludes it; a listing silent on the field is let
    # through, like every other optional field here.
    if req.attributes:
        try:
            wanted = json.loads(req.attributes) if isinstance(req.attributes, str) else req.attributes
        except (TypeError, ValueError):
            wanted = None
        if isinstance(wanted, dict) and wanted:
            stored = load_attributes(listing.attributes) or {}
            if any(states_a_shortfall(str(k), v, stored) for k, v in wanted.items()):
                return False

    return True


async def _opened_threads(db, listing_id: str, buyer_ids: list[str]) -> set[str]:
    """The buyers, among `buyer_ids`, whose thread on this listing Zeno has
    already opened. Guards against the duplicate openers a re-delivered
    event, or a standing request matching the same listing twice, would
    otherwise send to a seller (fix 6 in the module docstring). One query
    for every candidate rather than one per candidate. Scoped to
    agent-initiated broker messages only, so a human conversation that is
    already underway in the same thread is irrelevant to it."""
    if not buyer_ids:
        return set()
    rows = (await db.execute(
        select(NegotiationMessage.buyer_id).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.buyer_id.in_(buyer_ids),
            NegotiationMessage.role == "broker",
            # The seller-facing opener specifically - that is the message
            # this guards against sending twice. Constraining recipient_role
            # rather than marking the query # visibility-ok is also what
            # keeps tests/test_message_visibility_guard.py satisfied
            # honestly: this reads buyer ids and never any content, but the
            # audience it means is a real part of the predicate, not an
            # exemption.
            NegotiationMessage.recipient_role == "seller",
            NegotiationMessage.is_agent_initiated.is_(True),
        ).distinct()
    )).scalars().all()
    return set(rows)


async def _push_matches(pushes: list[tuple[str, str, str]]) -> None:
    """Send the match notifications for one listing: (fcm_token,
    listing_id, listing_name) each. Both entry points into this feature
    promise them in writing (buy_agent_sheet.dart, buy_agent_hub_screen.dart).
    Failures are logged, never raised - the match is already committed and
    must not be undone by a push problem, exactly like
    api/core/push_subscribers.py's own _notify."""
    from api.core.push import push_service

    gate = asyncio.Semaphore(PUSH_CONCURRENCY)

    async def one(token: str, listing_id: str, listing_name: str) -> None:
        async with gate:
            try:
                await push_service.send(
                    token,
                    title="🔎 Zeno found a match",
                    body=f'"{listing_name}" matches what you asked Zeno to watch for.',
                    data={"type": "buy_agent_match", "listing_id": listing_id, "screen": "product"},
                )
            except Exception as exc:
                logger.error("[buy_agent] match notification failed listing=%s: %s", listing_id, exc)

    await asyncio.gather(*(one(*p) for p in pushes))


def _push_in_background(pushes: list[tuple[str, str, str]]) -> None:
    if not pushes:
        return
    task = asyncio.create_task(_push_matches(pushes))
    _inflight.add(task)
    task.add_done_callback(_inflight.discard)


@subscribe_to(EventType.LISTING_CREATED)
async def on_listing_created_match_buy_agents(envelope: EventEnvelope) -> None:
    listing_id = envelope.payload.get("listing_id") or envelope.aggregate_id
    category = envelope.payload.get("category")
    price = envelope.payload.get("price")
    if not listing_id or category is None or price is None:
        return
    try:
        price = float(price)
    except (TypeError, ValueError):
        logger.warning("[buy_agent] ListingCreated carried a non-numeric price %r", price)
        return

    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        candidates = (await db.execute(
            select(BuyAgentRequest).where(
                BuyAgentRequest.status.in_(WATCHING_STATUSES),
                # A watch past its date has ended, whether or not the sweep
                # has marked it yet (buy_agent/service.py not_expired).
                not_expired(now),
                # Case-insensitive on both sides: the request holds the
                # canonical Category.name, the listing holds whatever the
                # seller typed. See fix (4) in the module docstring.
                func.lower(BuyAgentRequest.category) == str(category).strip().lower(),
                BuyAgentRequest.max_price >= price,
            )
        )).scalars().all()
        if not candidates:
            return

        listing = await db.get(Listing, listing_id)
        if not listing:
            return
        # Plain values, not the ORM row: these are used after the session
        # that loaded them has closed.
        listing_name = listing.name

        matching = [req for req in candidates if _listing_satisfies_request(listing, req)]
        # Already matched and already introduced - nothing new to say to
        # the seller, and nothing new to tell the buyer.
        opened = await _opened_threads(db, listing_id, [req.buyer_id for req in matching])

        matched_buyers: list[str] = []
        for req in matching:
            if req.buyer_id in opened:
                continue
            # In SQL, and only while the request is still watching: a
            # read-increment-write lost counts when two listings matched at
            # once, and a request cancelled since the SELECT above must not
            # come back as "matched" (fix 3 in the module docstring).
            counted = await db.execute(
                update(BuyAgentRequest)
                .where(
                    BuyAgentRequest.id == req.id,
                    BuyAgentRequest.status.in_(WATCHING_STATUSES),
                    not_expired(now),
                )
                .values(
                    status="matched",
                    match_count=func.coalesce(BuyAgentRequest.match_count, 0) + 1,
                )
                .execution_options(synchronize_session=False)
            )
            if counted.rowcount != 1:
                continue

            if req.negotiation_authorized:
                # Deliberately says nothing about req.max_price: telling a
                # seller the buyer's ceiling before negotiating gives away
                # the buyer's whole position (fix 1 in the module
                # docstring).
                opening = (
                    f"Hi! I'm Zeno, reaching out on behalf of a buyer who asked me to watch "
                    f"for {req.category} like this. Your listing \"{listing_name}\" looks like "
                    f"a match for what they're after - would you be open to a conversation?"
                )
                db.add(NegotiationMessage(
                    listing_id=listing_id, sender_id="broker", role="broker",
                    recipient_role="seller", content=opening, buyer_id=req.buyer_id,
                    msg_type="text", via_ai=True, is_agent_initiated=True,
                ))
                # A buyer with two live requests (possible for rows written
                # before the cap counted "matched") gets one opener per
                # thread, not one per request.
                opened.add(req.buyer_id)
            matched_buyers.append(req.buyer_id)

        await db.commit()

        tokens = []
        if matched_buyers:
            tokens = (await db.execute(
                select(User.fcm_token).where(User.id.in_(matched_buyers), User.fcm_token.isnot(None))
            )).scalars().all()

    # After the commit, never before: a buyer told "Zeno found a match"
    # for something that then failed to save would be worse than a late
    # notification. And in the background: see fix (4) above.
    _push_in_background([(t, listing_id, listing_name) for t in tokens if t])
