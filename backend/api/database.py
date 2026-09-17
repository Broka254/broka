"""
BROKA - Database Layer
SQLite for local dev; PostgreSQL for production (Render).
"""

import os
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import declarative_base, sessionmaker, relationship
from sqlalchemy import (
    Column, String, Float, Integer, Boolean,
    DateTime, Date, ForeignKey, Enum, Text, UniqueConstraint, Index,
)
from datetime import datetime, date
import enum
import uuid


def _build_db_url() -> str:
    url = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./broka.db")
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql+asyncpg://", 1)
    elif url.startswith("postgresql://") and "+asyncpg" not in url:
        url = url.replace("postgresql://", "postgresql+asyncpg://", 1)
    return url


def _build_engine_and_factory(url: str):
    is_sqlite = url.startswith("sqlite")
    connect_args = {"check_same_thread": False} if is_sqlite else {}

    # Pool tuning only applies to real network-hop databases - SQLite is a
    # single local file, no connection pool concept applies the same way,
    # and create_async_engine rejects pool_size/max_overflow for it anyway.
    #
    # pool_recycle and pool_pre_ping specifically guard against a common
    # production failure mode this app had no protection against: most
    # managed Postgres providers (Render's included) silently close
    # connections that sit idle past some server-side timeout, often well
    # under an hour. Without pool_recycle, SQLAlchemy can hand out a
    # connection the server already dropped, surfacing as an intermittent
    # "connection was closed" error that looks random and is worst
    # precisely during low-traffic periods (idle connections are the ones
    # most likely to have been culled). pool_pre_ping adds a cheap
    # liveness check before handing out any pooled connection as a second
    # layer of defence. pool_size/max_overflow are env-configurable since
    # the right ceiling depends on Xavier's actual Postgres plan's
    # connection limit, not a number this code can know in advance.
    pool_kwargs = {} if is_sqlite else {
        "pool_size":    int(os.getenv("DB_POOL_SIZE", "10")),
        "max_overflow": int(os.getenv("DB_MAX_OVERFLOW", "20")),
        "pool_recycle": 300,
        "pool_pre_ping": True,
    }

    eng = create_async_engine(url, echo=False, connect_args=connect_args, **pool_kwargs)
    return eng, sessionmaker(eng, class_=AsyncSession, expire_on_commit=False)


DATABASE_URL = _build_db_url()
engine, _session_factory = _build_engine_and_factory(DATABASE_URL)
Base = declarative_base()


def AsyncSessionLocal() -> AsyncSession:
    """Callable drop-in for the old sessionmaker instance so every
    existing `AsyncSessionLocal()` call site - routers via get_db(),
    subscribers, scripts, tests - keeps working with no changes needed.
    Always delegates to the *current* _session_factory, so reset_engine()
    below can repoint it without any caller needing to re-import anything.
    """
    return _session_factory()


def reset_engine() -> None:
    """Rebuild engine/DATABASE_URL/the session factory from whatever
    DATABASE_URL is set to right now.

    engine used to be built exactly once, the moment this module was
    first imported, and Python caches that import for the rest of the
    process - so a test fixture's `monkeypatch.setenv("DATABASE_URL", ...)`
    had no effect on it: every test module ended up sharing the one
    engine/db that was live at first import, however isolated each
    module's own sqlite file looked from inside that module. That's how
    test_categories.py's and test_traders.py's same-named "Electronics"
    Category rows ended up in the same database and tripped
    scalar_one_or_none() in trader_specialization_subscribers.py (see
    job-logs__7_.txt). Call this right after monkeypatching DATABASE_URL
    in a test fixture. Production never calls this - it builds the
    engine once at startup, same as always.
    """
    global DATABASE_URL, engine, _session_factory
    DATABASE_URL = _build_db_url()
    engine, _session_factory = _build_engine_and_factory(DATABASE_URL)


# ─── Enums ───────────────────────────────────────────────────────────────────

class ListingType(str, enum.Enum):
    direct  = "direct"
    auction = "auction"

class ListingStatus(str, enum.Enum):
    active    = "active"
    pending   = "pending"
    completed = "completed"
    cancelled = "cancelled"

class DealStatus(str, enum.Enum):
    negotiating = "negotiating"
    agreed      = "agreed"
    paid        = "paid"                      # M-Pesa commission confirmed (funds held in escrow)
    released    = "released"                  # buyer confirmed delivery → seller paid out
    refunded    = "refunded"                  # dispute resolved in buyer's favour
    disputed    = "disputed"                  # open dispute, funds frozen
    cancelled   = "cancelled"
    # ── Post-delivery dispute sub-states (funds still in escrow) ─────────────
    # These states are transient: funds stay frozen while Zeno mediates.
    # Every transition is triggered by an explicit user button-tap (an intent
    # in /negotiate/message), never by AI text output alone.
    awaiting_condition_check = "awaiting_condition_check"  # goods arrived, Zeno asking about condition
    awaiting_resolution      = "awaiting_resolution"       # buyer reported problem — choosing refund vs replace
    awaiting_replacement     = "awaiting_replacement"      # seller agreed to replace, waiting for shipment
    goods_not_arrived        = "goods_not_arrived"         # expected date passed, goods not confirmed arrived

class MpesaStatus(str, enum.Enum):
    pending = "pending"
    success = "success"
    failed  = "failed"


# ─── Models ──────────────────────────────────────────────────────────────────

class AccountType(str, enum.Enum):
    buyer        = "buyer"          # can browse, negotiate, purchase
    buyer_seller = "buyer_seller"   # buyer permissions + can list/sell


class User(Base):
    __tablename__ = "users"
    id                 = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    name               = Column(String, nullable=False)   # official name
    nickname           = Column(String, nullable=True)   # preferred name for AI/broker ("what should Zeno call you")
    # NEW v6.1 onboarding rework: phone is the unique login identifier.
    # Email downgraded from required+unique to optional (a large share of
    # users are unfamiliar/uncomfortable with email-based signup — see
    # CHANGES.md v6.1 entry). Kept nullable+unique so it can still be attached
    # later (password recovery, invoices, cross-border) without a collision.
    phone              = Column(String, unique=True, nullable=False, index=True)
    # NEW: OTP is optional at signup (can be skipped and done later from
    # Profile) — this records whether the phone was actually confirmed via
    # SMS code, as opposed to just typed in. Defaults False; set True only
    # by the verified (phone_verify_token) path in auth/service.py.
    phone_verified     = Column(Boolean, default=False, nullable=False)
    email              = Column(String, unique=True, nullable=True, index=True)
    email_verified     = Column(Boolean, default=False, nullable=False)
    password_hash      = Column(String, nullable=False)
    lat                = Column(Float, nullable=True)
    lng                = Column(Float, nullable=True)
    rating             = Column(Float, default=5.0)
    completed_deals    = Column(Integer, default=0)
    is_verified        = Column(Boolean, default=False)
    verify_tier        = Column(String, nullable=True)      # "basic" | "gold"
    verify_expires_at  = Column(DateTime, nullable=True)    # when badge expires
    preferred_language = Column(String, default="english", nullable=True)
    # "male" | "female" | "prefer_not_to_say" | NULL.
    #
    # NULL is not the same as "prefer_not_to_say" in intent - it means the
    # account predates this field, or signup skipped it - but both resolve
    # to the SAME output everywhere (see core/nudge_templates.pronouns_for).
    # That is deliberate: if an undisclosed gender produced different
    # wording from a declined one, the message itself would leak which
    # users had declined to answer.
    gender             = Column(String, nullable=True)
    location_visible   = Column(Boolean, default=True)   # user controls if location shows on public profile
    biometric_enrolled = Column(String, nullable=True)   # 'fingerprint' | 'face' | None
    # Profile selfie stored as base64 string
    profile_photo      = Column(Text, nullable=True)
    fcm_token          = Column(String, nullable=True)   # Firebase Cloud Messaging device token
    # iOS PushKit VoIP token. Deliberately a SEPARATE column from
    # fcm_token: iOS needs a VoIP push (not a normal alert) to wake a
    # terminated app for an incoming call, and that is delivered over APNs
    # against a different token entirely. One column for both would mean
    # each registration silently clobbered the other on a dual-registered
    # device.
    apns_voip_token    = Column(String, nullable=True)
    is_admin           = Column(Boolean, default=False, nullable=False)
    last_seen          = Column(DateTime, nullable=True)  # updated by /auth/heartbeat
    # NEW 2026-08-29: minimal seam for the AI Showcase premium gate. There
    # is no subscription/billing system anywhere in this codebase yet (the
    # closest thing, verify_tier "basic"/"gold" above, is a paid one-time
    # SELLER VERIFICATION, not a recurring feature-access plan - a
    # different concept) and the showcase spec is explicit that one must
    # not be built for this feature. This is deliberately just a bare
    # boolean, not a plan/expiry/billing model - the smallest thing an
    # entitlement check can look at now, and a real subscription system
    # can set later without a schema change. Currently irrelevant in
    # practice: SHOWCASE_AI_REQUIRE_PREMIUM defaults off during the
    # debugging/testing phase (see api/core/config.py), so
    # is_premium_user() lets everyone through regardless of this value
    # until that's flipped on.
    is_premium         = Column(Boolean, default=False, nullable=False)
    # NEW v3.0: trust score (0-100) computed by fraud engine
    trust_score        = Column(Integer, default=100, nullable=True)
    # NEW v3.0: flag set when fraud engine marks user high-risk
    is_flagged         = Column(Boolean, default=False, nullable=False)
    created_at         = Column(DateTime, default=datetime.utcnow)

    # ── NEW v6.1: account type + seller business identity ────────────────────
    # Every account starts as `buyer`. Upgrading to `buyer_seller` is a
    # separate, later action (POST /auth/upgrade-to-seller) — onboarding never
    # forces the buyer/seller choice up front (see CHANGES.md v6.1).
    account_type          = Column(Enum(AccountType), default=AccountType.buyer, nullable=False)
    business_name          = Column(String, nullable=True)   # raw name, e.g. "Clanix"
    business_category      = Column(String, nullable=True)   # e.g. "Wholesale", "Electronics"
    business_location      = Column(String, nullable=True)   # immediate locality, e.g. "Sira"
    business_description   = Column(Text, nullable=True)     # free text — this is what Zeno reads
    # Auto-generated from the three structured fields above at upgrade time,
    # e.g. "Clanix · Wholesale · Sira" — never free-typed by the seller, so it
    # can't drift into "Clanix-Ugunja" / "Clanix ugunja" / "CLANIX" variants
    # that would otherwise fragment search and confuse Zeno's matching.
    business_display_name  = Column(String, nullable=True)

    listings = relationship("Listing", back_populates="seller", foreign_keys="Listing.seller_id")


class OtpPurpose(str, enum.Enum):
    registration   = "registration"
    login_recovery = "login_recovery"


class PhoneOtp(Base):
    """Short-lived OTP for phone verification during registration.

    Stateless-token handoff: once verified, the caller gets a signed
    `phone_verify_token` (api.security.create_phone_verify_token) to present
    to /auth/register — the OTP row itself is only needed for the
    request -> verify round trip, not for the registration call itself.
    """
    __tablename__ = "phone_otps"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    phone       = Column(String, nullable=False, index=True)
    code_hash   = Column(String, nullable=False)
    purpose     = Column(Enum(OtpPurpose), default=OtpPurpose.registration, nullable=False)
    attempts    = Column(Integer, default=0, nullable=False)
    consumed    = Column(Boolean, default=False, nullable=False)
    expires_at  = Column(DateTime, nullable=False)
    created_at  = Column(DateTime, default=datetime.utcnow)


class EmailOtp(Base):
    """Short-lived OTP for email verification during registration.

    Deliberately a separate table from PhoneOtp rather than a shared one with
    both columns nullable: nothing would then stop a row with neither
    identifier set, and every query would have to say which it meant anyway.

    Same stateless handoff as the phone flow — verifying yields a signed
    `email_verify_token` (api.security.create_email_verify_token) that
    /auth/register presents, so the row is only needed for the
    request -> verify round trip.
    """
    __tablename__ = "email_otps"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    email       = Column(String, nullable=False, index=True)
    code_hash   = Column(String, nullable=False)
    purpose     = Column(Enum(OtpPurpose), default=OtpPurpose.registration, nullable=False)
    attempts    = Column(Integer, default=0, nullable=False)
    consumed    = Column(Boolean, default=False, nullable=False)
    expires_at  = Column(DateTime, nullable=False)
    created_at  = Column(DateTime, default=datetime.utcnow)


class Category(Base):
    __tablename__ = "categories"
    id        = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    name      = Column(String, nullable=False)
    icon      = Column(String, nullable=True)
    parent_id = Column(String, ForeignKey("categories.id"), nullable=True)


class CategoryFilter(Base):
    __tablename__ = "category_filters"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    category_id = Column(String, ForeignKey("categories.id"), nullable=False)
    field_name  = Column(String, nullable=False)
    field_type  = Column(String, nullable=False)
    options     = Column(Text, nullable=True)


class Listing(Base):
    __tablename__ = "listings"
    id            = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    seller_id     = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    name          = Column(String, nullable=False)
    description   = Column(Text, nullable=True)
    category      = Column(String, nullable=False, index=True)
    subcategory_id = Column(String, ForeignKey("categories.id"), nullable=True)
    condition     = Column(String, nullable=True)  # "new" | "used" | "refurbished"
    attributes    = Column(Text, nullable=True)    # JSON dict of category-specific values (0017)
    price         = Column(Float, nullable=False)
    lat           = Column(Float, nullable=False)
    lng           = Column(Float, nullable=False)
    location_name = Column(String, nullable=True)
    # Structured location (2026-08-29): location_name above stays exactly as
    # every other reader (search .ilike() filter in listings/service.py,
    # negotiate.py prompts, auctions/service.py, trader profiles, buy_agent
    # matching...) already expects it - unchanged, still free text. These
    # are additive: the new 3-part location step writes here, and
    # ListingService derives location_name from them automatically
    # ("Subcounty, County") so every existing reader keeps working
    # untouched. location_country is fixed to "Kenya" for now (not yet
    # client-settable - see sell_location_screen.dart) but stored as a
    # real column so expanding beyond Kenya later is a UI change, not a
    # schema one.
    location_country   = Column(String, nullable=False, default="Kenya")
    location_county     = Column(String, nullable=True)
    location_subcounty  = Column(String, nullable=True)
    listing_type  = Column(Enum(ListingType), default=ListingType.direct)
    status        = Column(Enum(ListingStatus), default=ListingStatus.active, index=True)
    views         = Column(Integer, default=0)
    target_bidders= Column(Integer, nullable=True)
    auction_date  = Column(DateTime, nullable=True)
    reserve_price = Column(Float, nullable=True)
    verified_photos = Column(Text, nullable=True)
    verified_video  = Column(Text, nullable=True)
    advert_video    = Column(Text, nullable=True)
    is_featured     = Column(Boolean, default=False)          # pinned to top of feed
    featured_until  = Column(DateTime, nullable=True)         # auto-expires
    # AI Showcase/Cover Image (2026-08-29, Design Journal - fal.ai showcase
    # spec). Deliberately separate from verified_photos, which stays the
    # buyer-facing proof-of-condition gallery on View Deal and is NEVER
    # replaced by this. showcase_image_url follows the same inline-base64
    # "data:<mime>;base64,..." convention as verified_photos/media.py's
    # media_url - see api/domains/showcase/service.py - not a real external
    # URL despite the name, matching this codebase's existing image
    # storage approach everywhere else (no S3/CDN exists here). NULL means
    # "no showcase" - readers fall back to the first verified_photos entry
    # (product_card.dart).
    showcase_image_url    = Column(Text, nullable=True)
    # "gallery" | "ai" - which path produced showcase_image_url. Lets the
    # UI show an "✨ AI Showcase" badge only when it's actually true,
    # without re-deriving it from anything else. NULL alongside a NULL
    # showcase_image_url just means "never set."
    showcase_image_source = Column(String, nullable=True)
    # Store feature (Phase 1). NULL = a personal listing, exactly as before -
    # every existing seller keeps working unchanged. Set = this listing is
    # merchandised under that Store's public catalog, in addition to still
    # appearing in Home/search/category results and the seller's own
    # listings tab (see api/domains/stores/service.py - a store's catalog
    # is this same Listing row filtered by store_id, never a duplicate
    # product record). seller_id above is untouched and remains the actual
    # owner/negotiation counterparty regardless of store_id.
    store_id      = Column(String, ForeignKey("stores.id"), nullable=True, index=True)
    created_at    = Column(DateTime, default=datetime.utcnow, index=True)

    seller = relationship("User", back_populates="listings", foreign_keys=[seller_id])
    bids   = relationship("Bid", back_populates="listing")


class Interest(Base):
    __tablename__ = "interests"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id  = Column(String, ForeignKey("listings.id"))
    buyer_id    = Column(String, ForeignKey("users.id"))
    offer_price = Column(Float, nullable=True)
    created_at  = Column(DateTime, default=datetime.utcnow)
    # v6.2 SMS availability nudge — set at creation to created_at + 5min.
    # The periodic sweep (task_check_interest_nudges) fires an AI-drafted
    # SMS to the seller if they haven't replied by this deadline. Mirrors
    # the Deal.timer_* pattern: the deadline is a plain fact the sweep
    # checks, not something the AI holds any power over.
    nudge_deadline = Column(DateTime, nullable=True)
    # Set once the sweep actually sends the nudge — prevents double-send on
    # the next sweep pass.
    nudge_sent_at  = Column(DateTime, nullable=True)
    # Set when the sweep finds the seller already responded (or the
    # listing/seller/buyer no longer exists) — distinct from nudge_sent_at
    # so a query can tell "resolved, no SMS needed" apart from "we texted
    # them", same split as Deal.timer_cancelled_at vs timer_fired_at.
    nudge_cancelled_at = Column(DateTime, nullable=True)


class NegotiationMessage(Base):
    __tablename__ = "negotiation_messages"
    id             = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id     = Column(String, ForeignKey("listings.id"))
    sender_id      = Column(String, nullable=False)
    role           = Column(String, nullable=False)
    recipient_role = Column(String, nullable=True)
    # content is NULL when msg_type is "voice" or "image" — use media_url instead.
    content        = Column(Text, nullable=True)
    # buyer_id: scopes messages to a specific buyer's conversation thread.
    # NULL on legacy rows (pre-fix) — those rows are visible to any buyer/seller.
    buyer_id       = Column(String, nullable=True, index=True)
    # via_ai: True when the human's message was sent through the AI broker route,
    # False when it was sent as a plain direct-chat message.
    via_ai         = Column(Boolean, default=False, nullable=True)
    # msg_type: "text" (default) | "voice" | "image" | "call"
    msg_type       = Column(String, default="text", nullable=True)
    # media_url: storage URL for voice notes and images.
    media_url      = Column(Text, nullable=True)
    # duration_secs: for voice notes only.
    duration_secs  = Column(Integer, nullable=True)
    # call_type: "audio" | "video" - only set when msg_type == "call".
    call_type      = Column(String, nullable=True)
    created_at     = Column(DateTime, default=datetime.utcnow, index=True)
    # True when this message opened the thread on the buyer's behalf via a
    # standing Buy-Agent request (core/buy_agent_subscribers.py), rather
    # than the buyer initiating contact themselves. negotiate_screen.dart
    # renders a disclosure label above such messages - Ch.22's guardrail.
    is_agent_initiated = Column(Boolean, nullable=True)

    # (listing_id, buyer_id) is the thread-identity pair filtered on
    # throughout negotiate.py (history, inbox, deal-status) and
    # domains/trust/completion_rate.py (leak-detection evidence) - this was
    # entirely unindexed before, meaning every one of those queries was a
    # full table scan. The composite's leading column (listing_id) also
    # serves plain "WHERE listing_id=X" queries efficiently on its own, so
    # no separate single-column index on listing_id is needed alongside
    # this - only buyer_id (used alone in get_inbox's buyer-view query)
    # gets its own index above.
    __table_args__ = (
        Index("ix_negotiation_messages_listing_buyer", "listing_id", "buyer_id"),
    )


class ThreadReadState(Base):
    """
    One row per (listing, buyer, role) - the "watermark" timestamp up to
    which that side has read the thread. Same approach WhatsApp/Telegram
    use: rather than flagging every individual message as read (which means
    touching potentially hundreds of rows every time someone opens a chat),
    we store a single "read everything up to this moment" pointer per side
    and derive both the inbox unread count and per-message seen ticks from
    a simple timestamp comparison against this.
    """
    __tablename__ = "thread_read_state"
    id            = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id    = Column(String, ForeignKey("listings.id"), nullable=False)
    buyer_id      = Column(String, nullable=False)
    role          = Column(String, nullable=False)  # "buyer" | "seller" - whose watermark this is
    last_read_at  = Column(DateTime, nullable=False, default=datetime.utcnow)
    # Second watermark: "this side's device had received everything up to
    # here", which is strictly earlier than or equal to last_read_at.
    #
    # Delivery and reading are genuinely different events and users treat
    # them differently - "it didn't send" vs "they're ignoring me" is the
    # single most common source of chat anxiety, and one watermark can't
    # tell them apart. Set whenever the recipient's app has demonstrably
    # received the messages (chat socket connected, thread history fetched,
    # or the background poller pulled the inbox) WITHOUT the thread
    # necessarily being open and on screen, which is what last_read_at
    # means. Same watermark approach for the same reason: one row per side
    # per thread instead of a status column on every message.
    last_delivered_at = Column(DateTime, nullable=True)

    __table_args__ = (
        UniqueConstraint("listing_id", "buyer_id", "role", name="uq_thread_read_state"),
    )


class Bid(Base):
    __tablename__ = "bids"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id  = Column(String, ForeignKey("listings.id"))
    bidder_id   = Column(String, ForeignKey("users.id"))
    amount      = Column(Float, nullable=False)
    created_at  = Column(DateTime, default=datetime.utcnow)

    listing = relationship("Listing", back_populates="bids")


class AuctionMeta(Base):
    """One-to-one with an auction-type Listing. Adds computed status,
    minimum next-bid increment, winner, and denormalized current_bid/
    bid_count so the Auction House grid doesn't aggregate Bid on every
    read (Design Journal Volume 6, Ch.6/Ch.27)."""
    __tablename__ = "auction_meta"
    id                = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id        = Column(String, ForeignKey("listings.id"), nullable=False, unique=True)
    status            = Column(String, nullable=False, default="upcoming")
    min_bid_increment = Column(Float, nullable=False, default=500.0)
    current_bid       = Column(Float, nullable=True)
    bid_count         = Column(Integer, nullable=False, default=0)
    winner_id         = Column(String, ForeignKey("users.id"), nullable=True)


class Wishlist(Base):
    __tablename__ = "wishlists"
    id         = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id    = Column(String, ForeignKey("users.id"), nullable=False)
    listing_id = Column(String, ForeignKey("listings.id"), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    __table_args__ = (
        UniqueConstraint("user_id", "listing_id", name="uq_wishlist_user_listing"),
    )


class UserSpecialization(Base):
    """Derived from what a seller actually lists (via
    trader_specialization_subscribers.py on every ListingCreated event),
    not self-declared (Design Journal Volume 6, Ch.5)."""
    __tablename__ = "user_specializations"
    id            = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id       = Column(String, ForeignKey("users.id"), nullable=False)
    category_id   = Column(String, ForeignKey("categories.id"), nullable=False)
    listing_count = Column(Integer, nullable=False, default=0)

    __table_args__ = (
        UniqueConstraint("user_id", "category_id", name="uq_specialization_user_category"),
    )


class BuyAgentRequest(Base):
    """Standing 'find & negotiate for me' request. One active row per
    buyer is enforced in buy_agent/service.py, not a DB constraint -
    "active" depends on status, not existence (Design Journal Volume 6,
    Ch.8/Ch.28).

    Fields below `must_have_features` were added across two migrations
    (0018, 0019) mapping to Design v2 §25's conceptual BuyingAgentRequest.
    Two deliberate departures from that list, not bugs:
      - `category` stays the pre-existing display-name string rather than
        becoming `category_id`. buy_agent_subscribers.py's matching query
        compares BuyAgentRequest.category == Listing.category (both legacy
        freetext strings) - switching to an id would break that live
        matching path, which §35 explicitly says to preserve. subcategory_id
        (0018) gives the structured link instead, same shape as Listing.
      - `location_name` instead of `location`, matching Listing's own
        column name rather than the doc's literal wording.
    """
    __tablename__ = "buy_agent_requests"
    id                 = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    buyer_id           = Column(String, ForeignKey("users.id"), nullable=False)
    category           = Column(String, nullable=False)
    subcategory_id     = Column(String, ForeignKey("categories.id"), nullable=True)
    query              = Column(String, nullable=True)   # original free-text ask, e.g. "iPhone 15 Pro"
    max_price          = Column(Float, nullable=False)
    min_price          = Column(Float, nullable=True)
    location_name      = Column(String, nullable=True)
    lat                = Column(Float, nullable=True)
    lng                = Column(Float, nullable=True)
    max_distance_km    = Column(Float, nullable=True)
    condition          = Column(String, nullable=True)  # "new" | "used" | "refurbished"
    attributes         = Column(Text, nullable=True)    # JSON dict, same shape as Listing.attributes
    optimization_code  = Column(String, nullable=True)  # primary - see buy_agent/actions.py OptimizationCode
    optimization_configuration = Column(Text, nullable=True)  # JSON, e.g. {"secondary": "TRUST"}
    negotiation_authorized     = Column(Boolean, nullable=False, default=False)
    must_have_features = Column(Text, nullable=True)
    status             = Column(String, nullable=False, default="active")
    # NEW (redesign-guide audit): real count of listings matched so far,
    # incremented by buy_agent_subscribers.py each time a new listing
    # matches this request. Previously there was no persisted count at all
    # (Home/Hub UI deliberately avoided inventing a number) - Design v2 §13
    # / §29 both expect a "N matches" style display, so this makes that
    # real instead of omitted.
    match_count        = Column(Integer, nullable=False, default=0)
    created_at         = Column(DateTime, default=datetime.utcnow)
    updated_at         = Column(DateTime, nullable=True, onupdate=datetime.utcnow)


class Deal(Base):
    __tablename__ = "deals"
    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id   = Column(String, ForeignKey("listings.id"), index=True)
    seller_id    = Column(String, ForeignKey("users.id"), index=True)
    buyer_id     = Column(String, ForeignKey("users.id"), index=True)
    agreed_price = Column(Float, nullable=False)
    commission   = Column(Float, nullable=False)
    # NEW: was missing entirely - every call site across escrow/, disputes/,
    # negotiate.py, workers.py, fraud.py, completion_rate.py etc. already
    # reads/writes Deal.status and assumes it's set at creation (see the
    # leak-detection comment below), so this was a genuine gap, not a
    # style choice. Mirrors Listing.status's shape exactly.
    status       = Column(Enum(DealStatus), default=DealStatus.agreed, index=True)
    created_at   = Column(DateTime, default=datetime.utcnow, index=True)

    # ── Terminal-state timestamps ─────────────────────────────────────────────
    # Present since the very first migration (migrations/versions/
    # 0001_initial_schema.py) and read/written across escrow/, negotiate.py,
    # disputes/, workers.py - but missing from this class entirely (found
    # alongside the status gap above). The matching ALTER TABLE entries
    # already exist in init_db()'s migrations list from day one, so unlike
    # status this only needed restoring here - no new migration entry
    # required.
    delivery_confirmed_at = Column(DateTime, nullable=True)  # buyer confirmed goods arrived
    released_at           = Column(DateTime, nullable=True)  # escrow paid out to seller
    refunded_at           = Column(DateTime, nullable=True)  # escrow refunded to buyer

    # ── Auto-resolution timers ──────────────────────────────────────────────
    # Zeno announces these timers in conversation (e.g. "I'll refund you in
    # 48h if the seller doesn't respond"), but Zeno never holds the power to
    # fire them - a periodic backend sweep (task_check_deal_timers) is the
    # ONLY thing that checks the deadline and acts. This means there's no
    # prompt-injection or AI-judgment risk for this specific mechanism: the
    # AI communicates a deterministic rule, the backend enforces it.
    #
    # timer_type: "seller_silence_refund" | "buyer_silence_release" |
    #             "seller_claimed_delivery" | None
    timer_type     = Column(String, nullable=True)
    timer_deadline = Column(DateTime, nullable=True)
    # Set the moment the awaited party responds (message sent, or buyer
    # explicitly confirms receipt) - cancels the timer. If still null when
    # the sweep finds timer_deadline has passed, the timer fires.
    timer_cancelled_at = Column(DateTime, nullable=True)
    timer_fired_at     = Column(DateTime, nullable=True)

    # ── Expected-delivery lifecycle (set at finalization from the actual
    # negotiated date, not invented by Zeno) ────────────────────────────────
    expected_delivery_date = Column(DateTime, nullable=True)
    # Set when the SELLER claims delivery happened (buyer has not yet
    # confirmed). This starts the risky "seller_claimed_delivery" branch -
    # never auto-releases on its own; only the check-in sequence below,
    # after exhausting all active reminders, allows the sweep to release.
    seller_claimed_delivery_at = Column(DateTime, nullable=True)
    # How many of the (currently 4) active buyer check-ins have fired for
    # the current seller_claimed_delivery_at cycle. Reset to 0 whenever a
    # new claim cycle starts.
    checkin_count = Column(Integer, default=0)
    last_checkin_at = Column(DateTime, nullable=True)

    mpesa_transactions = relationship("MpesaTransaction", back_populates="deal")

    # ── Post-delivery dispute resolution columns ─────────────────────────────
    # Tracks which resolution branch the deal is in and how many replacement
    # cycles have occurred. All state here is set by explicit user intent
    # (button tap) → negotiate.py code path. No AI output writes here directly.
    #
    # dispute_branch: which scenario Zeno is mediating
    #   "A1" - goods arrived, buyer confirms all good → release 97%
    #   "A2" - goods arrived but wrong item → refund or replace
    #   "A3" - goods arrived but damaged (image-verified) → refund or replace
    #   "A4" - replacement shipped; waiting for buyer to confirm arrival
    #   "B"  - goods never arrived; contacting seller
    dispute_branch      = Column(String, nullable=True)
    # How many replacement cycles have been attempted (no cap per spec).
    replacement_cycle   = Column(Integer, default=0, nullable=True)
    # True once the seller has responded to a wrong-item/damaged complaint
    # (seller_explains_wrong_item / seller_explains_damaged). The buyer's
    # refund/replacement choice buttons are gated on this - without it, the
    # buyer could choose before the seller ever got a chance to respond,
    # contradicting the explicit "seller explains first" design (see
    # migration 0006). Reset to False whenever a NEW dispute branch starts
    # (buyer_reports_wrong_item / buyer_reports_damaged).
    seller_has_explained = Column(Boolean, default=False, nullable=True)
    # When the seller last claimed to ship a replacement (starts A4 branch).
    replacement_shipped_at = Column(DateTime, nullable=True)

    # ── "Goods not arrived" sweep columns (Branch B) ─────────────────────────
    # If the expected delivery date passes without buyer confirming arrival,
    # Zeno contacts the seller the NEXT DAY. If no response in 3 days, refund.
    # These run via task_check_deal_timers with timer_type="goods_not_arrived_contact_seller".
    goods_not_arrived_started_at  = Column(DateTime, nullable=True)  # when Branch B began
    goods_not_arrived_checkin_count = Column(Integer, default=0, nullable=True)

    # ── "Buyer silence after delivery" sweep columns (Branch B-silence) ──────
    # If buyer doesn't respond after Zeno asks "did goods arrive?" on expected
    # delivery date, a 4-day / 24h-checkin / SMS-day-3 sequence begins.
    # Uses existing timer_type field with value "buyer_delivery_silence".
    # (Re-uses same 4-day check-in sweep as seller_claimed_delivery but for
    # the "did it arrive?" question rather than "please confirm receipt".)
    buyer_delivery_silence_started_at = Column(DateTime, nullable=True)

    # ── Deal Completion Rate / leak detection (Volume 2 §3.2, §3.7) ──────────
    # No agreed_at column: every Deal row is created already at
    # DealStatus.agreed (confirmed against every creation call site -
    # domains/escrow/service.py and routers/deal.py both create Deal rows
    # at DealStatus.agreed, never earlier), so created_at above already IS
    # the agreement timestamp Volume 2 §3.7 asks agreed_at to capture.
    # Adding a second column that would always equal created_at is
    # needless duplication, so this deliberately does not exist here.
    leak_flag        = Column(Boolean, default=False, nullable=False)
    leak_detected_at = Column(DateTime, nullable=True)


class SellerMetrics(Base):
    """
    Volume 2 §3.7: dcr_score / rank_score "on the seller-facing side (User
    or a new SellerMetrics table - a separate table is cleaner if these
    fields are expected to grow)". Went with the separate table - Chapter 4
    already earmarks more seller-level ML outputs (predicted price band,
    leakage-risk score) that would otherwise mean repeatedly widening User.

    One row per seller, upserted by domains/trust/completion_rate.py's
    recompute_all_dcr(), never written anywhere else. dcr_score/rank_score
    are nullable because a seller with zero listings never gets a row at
    all (nothing to rank) - nullable, not a sentinel like 0.0, so
    "never computed" stays distinguishable from "computed and scored low".
    """
    __tablename__ = "seller_metrics"
    user_id      = Column(String, ForeignKey("users.id"), primary_key=True)
    dcr_score    = Column(Float, nullable=True)   # 0-100, see completion_rate.compute_dcr
    rank_score   = Column(Float, nullable=True)   # 0-1 normalised, see completion_rate.recompute_all_dcr
    updated_at   = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class SellerMetricSnapshot(Base):
    """One row per seller per day. The data behind the history graphs.

    WHY IT EXISTS: the seller dashboard is meant to show each factor - DCR,
    rating, rank, response time, completed and pending deals - plotted from
    account creation, so a seller can see whether they are improving. None
    of that is recoverable after the fact: DCR is recency-weighted with a
    45-day half-life, so yesterday's value cannot be reconstructed from
    today's deal table, and rank depends on where every OTHER seller stood
    at the time. History only exists if it is written down as it happens.

    Which is why this lands in the first phase rather than alongside the
    charts that consume it. Every day the snapshot job does not run is a
    permanent hole in a graph the seller will eventually open; starting to
    record now means the line is already months long by the time the screen
    ships.

    Deliberately denormalised and append-only. One row per seller per day is
    ~365 rows/seller/year - trivial to store, and reading a year of history
    is one indexed range scan with no joins.
    """
    __tablename__ = "seller_metric_snapshots"
    id                  = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    seller_id           = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    # Date, not datetime: the grain is one per day, and a plain date makes
    # the uniqueness constraint and the "last 90 days" query obvious.
    snapshot_date       = Column(Date, nullable=False, index=True)

    overall_rating      = Column(Float, nullable=True)   # 0-10
    credibility         = Column(Float, nullable=True)   # 0-10, track record
    dcr_score           = Column(Float, nullable=True)   # 0-100
    rank_score          = Column(Float, nullable=True)   # 0-1
    rank_position       = Column(Integer, nullable=True) # 1 = best on the platform
    median_response_min = Column(Float, nullable=True)
    completed_deals     = Column(Integer, nullable=True)
    pending_deals       = Column(Integer, nullable=True)
    total_views         = Column(Integer, nullable=True)
    active_listings     = Column(Integer, nullable=True)
    created_at          = Column(DateTime, default=datetime.utcnow)

    __table_args__ = (
        # One snapshot per seller per day. Makes the daily job idempotent -
        # a re-run after a crash updates rather than duplicating, which
        # matters because a duplicated day silently doubles a point on
        # every graph that reads it.
        UniqueConstraint("seller_id", "snapshot_date", name="uq_seller_snapshot_day"),
        Index("ix_snapshot_seller_date", "seller_id", "snapshot_date"),
    )


class ListingPriceChange(Base):
    """Audit row for every accepted price edit.

    Exists to make the throttle enforceable - a rate limit with no record of
    past attempts is not a rate limit - and to give the seller a visible
    history, so "you have one change left this week" is a statement they can
    check rather than one they have to take on faith.

    Append-only. Never updated, never deleted: the point is that a price
    that moved cannot un-move.
    """
    __tablename__ = "listing_price_changes"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id  = Column(String, ForeignKey("listings.id"), nullable=False, index=True)
    seller_id   = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    old_price   = Column(Float, nullable=True)
    new_price   = Column(Float, nullable=False)
    changed_at  = Column(DateTime, default=datetime.utcnow, index=True)

    __table_args__ = (
        Index("ix_price_change_listing_time", "listing_id", "changed_at"),
    )


class ListingMetricSnapshot(Base):
    """One row per listing per day. Feeds the per-listing screen.

    Of the four signals that screen needs, three are already recoverable:
    likes from Wishlist.created_at, interested buyers from Interest.created_at,
    and price position from the current category. Views are not - Listing.views
    is a single running counter with no history, so "views per day", the
    trend line, and any freshness signal derived from them are permanently
    unavailable for every day this table does not exist.

    Same argument as SellerMetricSnapshot: it ships before the screen that
    reads it, because the screen can be built later and the history cannot.

    `views` stores the CUMULATIVE counter, not a daily delta. Deltas are
    derivable by subtracting consecutive rows, but a delta stored directly
    would be wrong for any day the job missed - it would silently attribute
    two days of traffic to one.
    """
    __tablename__ = "listing_metric_snapshots"
    id                = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id        = Column(String, ForeignKey("listings.id"), nullable=False, index=True)
    snapshot_date     = Column(Date, nullable=False, index=True)

    views             = Column(Integer, nullable=True)   # cumulative
    likes             = Column(Integer, nullable=True)   # cumulative
    interested_buyers = Column(Integer, nullable=True)   # cumulative
    sell_probability  = Column(Float, nullable=True)     # 0-100
    created_at        = Column(DateTime, default=datetime.utcnow)

    __table_args__ = (
        UniqueConstraint("listing_id", "snapshot_date", name="uq_listing_snapshot_day"),
        Index("ix_listing_snapshot_date", "listing_id", "snapshot_date"),
    )


class MpesaTransaction(Base):
    __tablename__ = "mpesa_transactions"
    id                  = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    deal_id             = Column(String, ForeignKey("deals.id"), nullable=False)
    buyer_id            = Column(String, ForeignKey("users.id"), nullable=False)
    phone               = Column(String, nullable=False)
    amount              = Column(Float, nullable=False)
    checkout_request_id = Column(String, nullable=False, index=True, unique=True)
    merchant_request_id = Column(String, nullable=True)
    mpesa_receipt       = Column(String, nullable=True)   # e.g. QJL82XXXXXX
    status              = Column(Enum(MpesaStatus), default=MpesaStatus.pending)
    # Idempotency: True once callback has been fully processed (issue #6)
    callback_processed  = Column(Boolean, default=False, nullable=False)
    created_at          = Column(DateTime, default=datetime.utcnow)

    deal = relationship("Deal", back_populates="mpesa_transactions")


# ── Refresh Tokens (issue #8) ─────────────────────────────────────────────────

class RefreshToken(Base):
    """
    Persisted refresh tokens for server-side revocation.
    jti (JWT ID) is the unique identifier for each token.
    Revoke by setting revoked_at; expired rows can be pruned by a cron job.
    """
    __tablename__ = "refresh_tokens"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id     = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    jti         = Column(String, unique=True, nullable=False, index=True)
    expires_at  = Column(DateTime, nullable=False)
    revoked_at  = Column(DateTime, nullable=True)   # None = still valid
    created_at  = Column(DateTime, default=datetime.utcnow)



class DisputeStatus(str, enum.Enum):
    open      = "open"
    resolved  = "resolved"
    dismissed = "dismissed"

class DisputeResolution(str, enum.Enum):
    release = "release"   # pay seller
    refund  = "refund"    # return to buyer
    split   = "split"     # partial resolution

class Dispute(Base):
    __tablename__ = "disputes"
    id              = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    deal_id         = Column(String, ForeignKey("deals.id"), nullable=False, index=True)
    opener_id       = Column(String, ForeignKey("users.id"), nullable=False)
    issue_type      = Column(String, nullable=False)   # not_delivered|not_as_described|payment|fraud|other
    description     = Column(Text, nullable=False)
    zeno_verdict    = Column(Text, nullable=True)       # Zeno's full analysis text
    zac_code        = Column(String, nullable=True)     # e.g. ZAC-RELEASE-7K9P2X
    resolution_type = Column(String, nullable=True)     # release|refund|split
    status          = Column(Enum(DisputeStatus), default=DisputeStatus.open)
    resolved_by     = Column(String, nullable=True)    # admin user_id who executed resolution
    created_at      = Column(DateTime, default=datetime.utcnow)
    resolved_at     = Column(DateTime, nullable=True)

class Review(Base):
    """Buyer review of a seller after a completed deal."""
    __tablename__ = "reviews"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    deal_id     = Column(String, ForeignKey("deals.id"), nullable=False, index=True)
    reviewer_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    seller_id   = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    rating      = Column(Integer, nullable=False)          # 1-5 stars
    comment     = Column(Text, default="")
    created_at  = Column(DateTime, default=datetime.utcnow)


class FeaturedPayment(Base):
    """Tracks M-Pesa payments for listing boost (featured pin)."""
    __tablename__ = "featured_payments"
    id                  = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id             = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    listing_id          = Column(String, ForeignKey("listings.id"), nullable=False, index=True)
    plan                = Column(String, nullable=False)              # "week" | "month"
    phone               = Column(String, nullable=False)
    amount              = Column(Float, nullable=False)
    checkout_request_id = Column(String, nullable=False, index=True)
    merchant_request_id = Column(String, nullable=True)
    mpesa_receipt       = Column(String, nullable=True)
    status              = Column(Enum(MpesaStatus), default=MpesaStatus.pending)
    created_at          = Column(DateTime, default=datetime.utcnow)


class VerificationPayment(Base):
    """Tracks M-Pesa payments for seller badge purchase."""
    __tablename__ = "verification_payments"
    id                  = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id             = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    tier                = Column(String, nullable=False)              # "basic" | "gold"
    phone               = Column(String, nullable=False)
    amount              = Column(Float, nullable=False)
    checkout_request_id = Column(String, nullable=False, index=True)
    merchant_request_id = Column(String, nullable=True)
    mpesa_receipt       = Column(String, nullable=True)
    status              = Column(Enum(MpesaStatus), default=MpesaStatus.pending)
    created_at          = Column(DateTime, default=datetime.utcnow)


# ─── NEW v3.0 MODELS ──────────────────────────────────────────────────────────

class AuditLog(Base):
    """Immutable record of every significant action (escrow, disputes, admin, payments)."""
    __tablename__ = "audit_logs"
    id            = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    actor_id      = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    action        = Column(String, nullable=False, index=True)
    resource_type = Column(String, nullable=False)
    resource_id   = Column(String, nullable=False, index=True)
    detail        = Column(Text, nullable=True)
    ip_address    = Column(String, nullable=True)
    created_at    = Column(DateTime, default=datetime.utcnow, index=True)


class FraudEvent(Base):
    """Records each time the fraud engine flags a user."""
    __tablename__ = "fraud_events"
    id                  = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id             = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    reason              = Column(String, nullable=False)
    triggered_by        = Column(String, nullable=True)   # deal_id / dispute_id / etc.
    trust_score_at_flag = Column(Integer, nullable=True)
    reviewed_by_admin   = Column(Boolean, default=False)
    resolved            = Column(Boolean, default=False)
    created_at          = Column(DateTime, default=datetime.utcnow, index=True)


# ─── Init ────────────────────────────────────────────────────────────────────

async def init_db():
    # ── Model registration MUST precede create_all ────────────────────────
    # create_all() only creates tables that are present in Base.metadata at
    # the moment it runs, and a model is only registered there as a side
    # effect of importing its module.
    #
    # BUG FIX (implementation audit, spec §23, 2026-09-14): these three
    # imports used to sit ~130 lines BELOW create_all(), inside the
    # ALTER TABLE block, described in their own comments as
    # "defence-in-depth ... in case this function is ever called from a
    # context that hasn't imported the store domain yet (e.g. a narrow
    # test/script)". That is precisely the case they could not handle:
    # importing a model AFTER create_all() has already run registers it too
    # late to create anything. The fallback existed, was documented, and
    # was placed where it provably could not fire.
    #
    # It has never failed in practice because every real entry point
    # (main.py's lifespan, and tests that `from main import app`) imports
    # the domain routers - and therefore the models - long before init_db()
    # is reached. So this is a latent trap, not a live fault: the one
    # scenario the fallback was written for is the one it silently failed
    # at, and it would present as a bare "no such table: stores" from a
    # standalone script or narrow test with no hint as to why.
    #
    # Hoisted so the fresh-database path is deterministic regardless of
    # entry point, which is what §23 actually asks for.
    # A failure here is logged, not swallowed. `except Exception: pass`
    # around a model import is how a typo in a class name becomes a bare
    # "no such table" much later with nothing pointing back at the cause -
    # which is exactly what happened while writing this hoist: the first
    # draft imported a `DisputeMessage` that does not exist (the class is
    # `DisputeEvent`), the ImportError went into a silent `pass`, and the
    # dispute tables would simply not have been registered. The import is
    # still guarded, because a genuinely absent optional module must not
    # stop the app booting - but it says so.
    import logging as _logging
    _init_log = _logging.getLogger(__name__)
    for _module, _names in (
        ("api.models.dispute", ("DisputeCase", "DisputeEvent", "DisputeEvidence", "DisputeTimer")),
        ("api.models.store", ("Store",)),
        ("api.models.external_escrow", ("ExternalEscrow",)),
    ):
        try:
            _mod = __import__(_module, fromlist=list(_names))
            for _n in _names:
                if not hasattr(_mod, _n):
                    _init_log.error(
                        "[init_db] %s has no attribute %s - its table will NOT be "
                        "created by create_all()", _module, _n,
                    )
        except Exception as _exc:
            _init_log.error("[init_db] could not import %s (%s) - any table it "
                            "defines will NOT be created", _module, _exc)

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # Lightweight forward-compat: add new columns to existing rows-only DBs.
        # SQLite/Postgres ignore the IF NOT EXISTS path via try/except.
        from sqlalchemy import text
        migrations = [
            # v2.x columns
            "ALTER TABLE thread_read_state ADD COLUMN last_delivered_at DATETIME",
            "ALTER TABLE users ADD COLUMN gender VARCHAR",
            "ALTER TABLE users ADD COLUMN apns_voip_token VARCHAR",
            "ALTER TABLE users ADD COLUMN is_admin BOOLEAN DEFAULT 0 NOT NULL",
            "ALTER TABLE users ADD COLUMN last_seen DATETIME",
            "ALTER TABLE deals ADD COLUMN delivery_confirmed_at DATETIME",
            "ALTER TABLE deals ADD COLUMN released_at DATETIME",
            "ALTER TABLE deals ADD COLUMN refunded_at DATETIME",
            # v3.0 new columns
            "ALTER TABLE users ADD COLUMN trust_score INTEGER DEFAULT 100",
            "ALTER TABLE users ADD COLUMN is_flagged BOOLEAN DEFAULT 0 NOT NULL",
            "ALTER TABLE disputes ADD COLUMN resolved_by VARCHAR",
            # v4.0 deal timers (0003)
            "ALTER TABLE deals ADD COLUMN timer_type VARCHAR",
            "ALTER TABLE deals ADD COLUMN timer_deadline DATETIME",
            "ALTER TABLE deals ADD COLUMN timer_cancelled_at DATETIME",
            "ALTER TABLE deals ADD COLUMN timer_fired_at DATETIME",
            # v4.0 delivery checkins (0004)
            "ALTER TABLE deals ADD COLUMN expected_delivery_date DATETIME",
            "ALTER TABLE deals ADD COLUMN seller_claimed_delivery_at DATETIME",
            "ALTER TABLE deals ADD COLUMN checkin_count INTEGER DEFAULT 0",
            "ALTER TABLE deals ADD COLUMN last_checkin_at DATETIME",
            # v5.0 full dispute resolution branches (0005)
            "ALTER TABLE deals ADD COLUMN dispute_branch VARCHAR",
            "ALTER TABLE deals ADD COLUMN replacement_cycle INTEGER DEFAULT 0",
            "ALTER TABLE deals ADD COLUMN replacement_shipped_at DATETIME",
            "ALTER TABLE deals ADD COLUMN goods_not_arrived_started_at DATETIME",
            "ALTER TABLE deals ADD COLUMN goods_not_arrived_checkin_count INTEGER DEFAULT 0",
            "ALTER TABLE deals ADD COLUMN buyer_delivery_silence_started_at DATETIME",
            # v6.2 SMS availability nudge (0009)
            "ALTER TABLE interests ADD COLUMN nudge_deadline DATETIME",
            "ALTER TABLE interests ADD COLUMN nudge_sent_at DATETIME",
            "ALTER TABLE interests ADD COLUMN nudge_cancelled_at DATETIME",
            # Categories/marketplace density redesign (0012)
            "ALTER TABLE listings ADD COLUMN subcategory_id VARCHAR",
            "ALTER TABLE listings ADD COLUMN condition VARCHAR",
            # Buy-Agent disclosure flag (0015)
            "ALTER TABLE negotiation_messages ADD COLUMN is_agent_initiated BOOLEAN",
            # OTP-optional signup (0016)
            "ALTER TABLE users ADD COLUMN phone_verified BOOLEAN DEFAULT 0 NOT NULL",
            # Split-step signup: email is optional but can now be proven with
            # an emailed code, so a verified address is distinguishable from
            # a merely typed one.
            "ALTER TABLE users ADD COLUMN email_verified BOOLEAN DEFAULT 0 NOT NULL",
            # Redesign-guide audit (Round 4, 2026-08-13): real match count on
            # a standing buy request, incremented by buy_agent_subscribers.py.
            # Added directly to the model without a matching entry here at
            # the time - this closes that gap, so the column now appears on
            # next startup against an existing DB too, not just a fresh one
            # (Base.metadata.create_all alone only creates missing *tables*,
            # never adds a missing *column* to one that already exists).
            "ALTER TABLE buy_agent_requests ADD COLUMN match_count INTEGER DEFAULT 0 NOT NULL",
            # Volume 2 Chapter 3 (Round 15-16): leak detection columns added
            # to the Deal model without a matching entry here at the time -
            # same gap as the buy_agent_requests entry above, caught this
            # time by an external audit rather than found the hard way.
            # Without this, any query touching Deal.leak_flag or
            # Deal.leak_detected_at against an already-existing deals table
            # (i.e. any real deployment, not a from-scratch database) fails
            # outright - create_all() only creates missing tables, never
            # adds a missing column to one that already exists (the new
            # SellerMetrics *table* from the same round needs no entry
            # here for that reason - create_all() handles genuinely new
            # tables fine; it's new columns on existing tables that don't
            # get picked up).
            "ALTER TABLE deals ADD COLUMN leak_flag BOOLEAN DEFAULT 0 NOT NULL",
            "ALTER TABLE deals ADD COLUMN leak_detected_at DATETIME",
            # 2026-08-28: status was referenced everywhere (escrow/, disputes/,
            # negotiate.py, workers.py, fraud.py, completion_rate.py...) but
            # never actually existed as a column on the model - same class of
            # gap as match_count/leak_flag above, except this time the model
            # itself was missing the Column(...) line too, not just this entry
            # (every fresh-DB test constructing a Deal failed outright with
            # TypeError: 'status' is an invalid keyword argument for Deal).
            # No DEFAULT here on purpose: unlike a brand-new column that
            # starts everyone at the same state, a pre-existing deals table
            # has rows genuinely spread across every status (agreed, paid,
            # released, refunded...) that this migration has no way to
            # reconstruct - defaulting every historical row to one value
            # (e.g. 'agreed') would be actively wrong for any deal that has
            # already progressed, and would make it silently vanish from
            # every downstream Deal.status == DealStatus.X query. On a real
            # deployment with pre-existing deal rows, this lands them at
            # status=NULL and they need a one-time manual backfill (cross-
            # referenced against released_at/refunded_at/mpesa_transactions)
            # to restore their true historical status - not something safe
            # to script blindly here.
            "ALTER TABLE deals ADD COLUMN status VARCHAR",
            # 2026-08-29: AI Showcase/Cover Image + structured location.
            # location_name itself is untouched on purpose (see the Listing
            # model comment) - only the new additive columns need patching.
            "ALTER TABLE listings ADD COLUMN location_country VARCHAR DEFAULT 'Kenya' NOT NULL",
            "ALTER TABLE listings ADD COLUMN location_county VARCHAR",
            "ALTER TABLE listings ADD COLUMN location_subcounty VARCHAR",
            "ALTER TABLE listings ADD COLUMN showcase_image_url TEXT",
            "ALTER TABLE listings ADD COLUMN showcase_image_source VARCHAR",
            "ALTER TABLE users ADD COLUMN is_premium BOOLEAN DEFAULT 0 NOT NULL",
            # Store feature (Phase 1, 2026-09-07): stores itself is a brand
            # new table, so create_all() above already handles it - only
            # this new COLUMN on the pre-existing listings table needs a
            # manual entry here, same reasoning as every other ADD COLUMN
            # line in this list. NULL for every existing row = every
            # already-listed item stays a personal listing, unchanged.
            "ALTER TABLE listings ADD COLUMN store_id VARCHAR",
        ]
        for stmt in migrations:
            try:
                await conn.execute(text(stmt))
            except Exception:
                pass  # column already exists

        # (v5.0 dispute engine models are imported at the top of init_db(),
        # before create_all - see the comment there for why they cannot
        # usefully live here.)

        # Store feature (Phase 1, 2026-09-07) — new table created by
        # Base.metadata.create_all above. In practice api/domains/stores/
        # service.py already imports Store at module level, and main.py
        # imports that domain's router before init_db() ever runs, so this
        # import is normally a no-op re-import by the time create_all()
        # executes - kept anyway as the same defence-in-depth belt-and-
        # suspenders the dispute-engine import above uses, in case this
        # function is ever called from a context that hasn't imported the
        # store domain yet (e.g. a narrow test/script).
        # (api.models.store is imported at the top of init_db(), before
        # create_all - see the comment there for why it cannot live here.)

        # E-Confirm marketplace escrow (2026-09) — new table, same
        # create_all()-picks-it-up-automatically story as Store above.
        # api/domains/escrow/service.py imports ExternalEscrow at module
        # level and is imported by main.py before init_db() runs, so this
        # is the same belt-and-suspenders fallback as the imports above it,
        # not the only thing making this table exist.
        # (api.models.external_escrow is imported at the top of init_db(), before
        # create_all - see the comment there for why it cannot live here.)

        # v5.1 dispute engine hardening (0008)
        schema_patches = [
            # Optimistic locking version column on dispute_cases
            "ALTER TABLE dispute_cases ADD COLUMN version INTEGER DEFAULT 0 NOT NULL",
            # Data-driven dispute type (forward-compat, nullable)
            "ALTER TABLE dispute_cases ADD COLUMN dispute_type VARCHAR",
        ]
        for stmt in schema_patches:
            try:
                await conn.execute(text(stmt))
            except Exception:
                pass  # column already exists

        # Indexes have the exact same "not retroactively applied" problem
        # as the missing-column case above: Base.metadata.create_all() only
        # creates indexes for genuinely NEW tables, never adds one to a
        # table that already exists. Found during a production-readiness
        # pass: deals/negotiation_messages had several columns marked
        # index=True in the model (some added this same pass, some already
        # there from before) with no corresponding entry here, meaning any
        # already-existing deployment's tables never actually got them -
        # every query filtering on these columns was a full table scan
        # regardless of what the model file claimed. CREATE INDEX IF NOT
        # EXISTS is portable across SQLite and Postgres (unlike ALTER
        # TABLE ADD COLUMN's IF NOT EXISTS support, which isn't reliable
        # on SQLite - hence that block using try/except instead), so this
        # doesn't strictly need the try/except the way schema_patches does,
        # but keeps it anyway for the same defence-in-depth reason: a
        # genuinely old, un-migrated deployment might not even have the
        # column yet, and one bad statement here should never block every
        # other index in this list from being created.
        index_patches = [
            "CREATE INDEX IF NOT EXISTS ix_deals_seller_id ON deals(seller_id)",
            "CREATE INDEX IF NOT EXISTS ix_deals_buyer_id ON deals(buyer_id)",
            "CREATE INDEX IF NOT EXISTS ix_deals_listing_id ON deals(listing_id)",
            "CREATE INDEX IF NOT EXISTS ix_deals_status ON deals(status)",
            "CREATE INDEX IF NOT EXISTS ix_deals_created_at ON deals(created_at)",
            "CREATE INDEX IF NOT EXISTS ix_negotiation_messages_buyer_id ON negotiation_messages(buyer_id)",
            "CREATE INDEX IF NOT EXISTS ix_negotiation_messages_created_at ON negotiation_messages(created_at)",
            "CREATE INDEX IF NOT EXISTS ix_negotiation_messages_listing_buyer ON negotiation_messages(listing_id, buyer_id)",
            # Store feature (Phase 1): store_id is marked index=True on the
            # Listing model, which - like every column above - only takes
            # effect for a table create_all() creates fresh. An already-
            # existing listings table needs it added retroactively here too.
            "CREATE INDEX IF NOT EXISTS ix_listings_store_id ON listings(store_id)",
        ]
        for stmt in index_patches:
            try:
                await conn.execute(text(stmt))
            except Exception as exc:
                print(f"⚠️ Index patch skipped ({stmt[:60]}...): {exc!r}")

    # Canonical category taxonomy (reference/application data, not a
    # schema migration) - separate from migrate_categories_from_freetext.py,
    # which only backfills subcategory_id on real historical listings.
    # Idempotent: skip-if-exists, so this is safe on every startup against
    # both a fresh database and one that's already seeded. Non-fatal on
    # failure so a seeding hiccup never takes down the whole API.
    try:
        from api.domains.categories.seed import seed_categories
        seed_result = await seed_categories()
        if any(seed_result.values()):
            print(f"✅ Categories seeded: {seed_result}")
    except Exception as e:
        print(f"⚠️ Category seeding failed (non-fatal, app will still start): {e!r}")

    print("✅ Database initialised (v5.0)")


async def get_db():
    async with AsyncSessionLocal() as session:
        yield session
