"""Marketing campaigns and the content generated for them.

A seller's Marketing Studio work is a *campaign*: what they chose to
promote, how they configured it, and the ready-to-share creatives that were
generated for each platform. These are new tables, so init_db()'s
create_all() creates them (api/core/migrations_guide.py's rule for a new
table; ALTER TABLE is only for new columns on an existing one).

Nothing here is a second catalogue. `product_ids` points at real
`listings` rows through the store, and every prompt is built from those rows
on the server - a price or title sent by a client is never the source of
truth (api/domains/stores/marketing.py).

Ownership is store-scoped and enforced by the service on every read and
write: a campaign belongs to exactly one store and its owner, and nothing
public reads these tables except the attribution endpoint, which only
increments a counter for a campaign token that belongs to the store in the
URL.

Generated media is stored as an ordinary media asset (`asset_id`) and
referred to by id, never as bytes or base64 in a relational column.
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Column, Date, DateTime, ForeignKey, Index, Integer, String, Text, UniqueConstraint

from api.database import Base

# Every platform the studio generates for. The service validates against
# this set, and each has its own limits and output shape (PLATFORMS in
# api/domains/stores/marketing.py) - the same copy is not reused across
# them.
PLATFORMS = ("whatsapp", "instagram", "tiktok", "facebook", "x")
LANGUAGES = ("en", "sw")
OBJECTIVES = (
    "new_store",       # introduce the store
    "product",         # promote one product
    "new_stock",       # announce new stock
    "discount",        # a genuine discount the seller supplies
    "awareness",       # brand awareness
    "seasonal",        # seasonal offer
    "storefront",      # get people to the storefront
    "enquiries",       # encourage questions/negotiation
)
TONES = ("friendly", "professional", "bold", "playful", "premium")


class MarketingCampaign(Base):
    __tablename__ = "marketing_campaigns"
    __table_args__ = (
        Index("ix_marketing_campaigns_store_created", "store_id", "created_at"),
        UniqueConstraint("link_token", name="uq_marketing_campaign_link_token"),
    )

    id         = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    store_id   = Column(String, ForeignKey("stores.id"), nullable=False, index=True)
    owner_id   = Column(String, ForeignKey("users.id"), nullable=False, index=True)

    title      = Column(String(120), nullable=False)
    objective  = Column(String(24), nullable=False, default="product")
    audience   = Column(String(120), nullable=True)
    tone       = Column(String(16), nullable=False, default="friendly")
    # "en" (English) or "sw" (Kiswahili). The generator is told which; the
    # fallback templates are written in both.
    language   = Column(String(8), nullable=False, default="en")
    instructions = Column(Text, nullable=True)
    # JSON lists. product_ids is [] for a whole-store campaign.
    product_ids  = Column(Text, nullable=False, default="[]")
    platforms    = Column(Text, nullable=False, default="[]")
    # draft = saved configuration, nothing generated yet; generated = at
    # least one creative exists. There is no "published": BROKA does not
    # post to social platforms, and must never say it did.
    status     = Column(String(12), nullable=False, default="draft")
    # The campaign's attribution token. Links are
    # <store url>?via=<platform>&c=<token>; a visit carrying it is counted
    # against this campaign in MarketingCampaignEvent. Random, not a row id,
    # so it cannot be used to enumerate campaigns.
    link_token = Column(String(24), nullable=False)
    # The weekly plan (JSON list) and how the content was produced (JSON:
    # provider, fallback, reason). Kept with the campaign so reopening a
    # draft shows exactly what the seller saw - never regenerated silently.
    plan       = Column(Text, nullable=True)
    generation = Column(Text, nullable=True)

    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    # Soft delete, like a store's: a deleted draft is gone from every read
    # but its attribution rows stay attached to a real campaign.
    deleted_at = Column(DateTime, nullable=True, index=True)


class MarketingCreative(Base):
    """One platform's generated piece for a campaign.

    `body` is the caption/message/script text; `hashtags` is a JSON list;
    `media` is JSON design metadata (template, aspect ratio, background,
    colours, where the real product image sits) - a *layout specification*
    the app and web can render, not a claim that a video was produced. A
    rendered image, where one was made, is `asset_id` (a media asset). A
    TikTok/Instagram Reel creative is a script/storyboard, and format says
    so; it is never labelled a finished video.
    """
    __tablename__ = "marketing_creatives"
    __table_args__ = (
        Index("ix_marketing_creatives_campaign", "campaign_id"),
    )

    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    campaign_id = Column(String, ForeignKey("marketing_campaigns.id"), nullable=False, index=True)
    platform    = Column(String(16), nullable=False)
    # message | caption | status | feed_post | story | carousel | script |
    # video_plan | product_highlight
    format      = Column(String(24), nullable=False)
    headline    = Column(String(160), nullable=True)
    body        = Column(Text, nullable=False, default="")
    hashtags    = Column(Text, nullable=True)   # JSON list
    cta         = Column(String(160), nullable=True)
    media       = Column(Text, nullable=True)   # JSON design spec
    asset_id    = Column(String, nullable=True)  # rendered poster, if any
    # "ai" or "template": how this creative was produced. A template result
    # is still real, useful copy built from the seller's own products - it
    # is labelled so nobody mistakes it for a model's work.
    source      = Column(String(12), nullable=False, default="template")
    # Which generation produced it. Regenerating replaces the creatives of
    # a campaign rather than accumulating unbounded rows.
    created_at  = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at  = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class MarketingCampaignEvent(Base):
    """Aggregated campaign activity: created, generated, downloaded, shared,
    and attributed visits/product views.

    One row per (campaign, kind, platform, day), incremented in place - the
    same shape and counting rule as StoreDailyCount, so the table grows by a
    handful of rows per campaign per day however many people tap a link.
    Days are Kenyan days (UTC+3), matching the store dashboard's charts.

    These are observations BROKA can make (a campaign was generated; a link
    was shared using BROKA's share action; a visit arrived carrying the
    token). They are not impressions, advertising spend, sales or revenue.
    """
    __tablename__ = "marketing_campaign_events"
    __table_args__ = (
        UniqueConstraint(
            "campaign_id", "kind", "platform", "day",
            name="uq_marketing_event_day",
        ),
        Index("ix_marketing_events_store_day", "store_id", "day"),
    )

    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    campaign_id = Column(String, ForeignKey("marketing_campaigns.id"), nullable=False, index=True)
    store_id    = Column(String, ForeignKey("stores.id"), nullable=False, index=True)
    kind        = Column(String(16), nullable=False)
    platform    = Column(String(16), nullable=False, default="")
    day         = Column(Date, nullable=False)
    count       = Column(Integer, nullable=False, default=0)
