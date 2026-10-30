"""Launch offers: the first N listings / stores are free, one per user.

LaunchOfferClaim is the durable counter behind both offers. Counting rows
in `listings`/`stores` cannot do this job: listings get deleted, stores get
renamed, and a count-then-insert race hands the same free slot to two
people at once. A claim row is written in the SAME transaction that creates
the listing/store it pays for, so a rolled-back create consumes nothing,
and the two unique indexes below are what actually enforce the rules:

  * UNIQUE(offer_type, rank)      - a rank (1..limit) is handed out once;
  * UNIQUE(offer_type, user_id)   - one offer per user, however many times
                                    they delete and re-post.

A claim is never recycled. Deleting a free listing does not free its slot:
recycling would let one seller (or a ring of fresh accounts is stopped by
the per-user rule, but cycling one account is not) farm free listings
forever, and "first 50" would stop meaning first.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


class LaunchOfferType:
    LISTING_FREE = "listing_free"   # first N personal listings post free
    STORE_FREE = "store_free"       # first N stores set up free


class LaunchOfferClaim(Base):
    __tablename__ = "launch_offer_claims"
    __table_args__ = (
        sa.UniqueConstraint("offer_type", "rank", name="uq_launch_offer_rank"),
        sa.UniqueConstraint("offer_type", "user_id", name="uq_launch_offer_user"),
        sa.Index("ix_launch_offer_type", "offer_type"),
    )

    id         = sa.Column(sa.String, primary_key=True, default=_uuid)
    offer_type = sa.Column(sa.String(24), nullable=False)
    user_id    = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    # The listing/store this claim paid for. Kept even after that row is
    # soft-deleted, so the audit trail says what the free slot bought.
    entity_id  = sa.Column(sa.String, nullable=False, index=True)
    rank       = sa.Column(sa.Integer, nullable=False)  # 1 = first claim
    # When the free time this claim bought runs out (the listing's/store's
    # paid_until at grant time). A renewal moves paid_until, not this.
    expires_at = sa.Column(sa.DateTime, nullable=True)
    claimed_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
