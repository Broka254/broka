"""SoldOutReport - a buyer saying a listing is no longer available.

With payments outside BROKA nothing in the app knows when an item sells, so
the people who find out are buyers who call and hear "it's gone". One report
marks the listing sold out (Listing.sold_out_reported_at) and takes it out of
every list buyers browse; its seller is told and can say it is still there,
which puts it back (api/domains/listings/sold_out.py).

One row per listing and reporter, never reused: a seller revoking a report
doesn't let the same person report it again, so one rival can't keep taking
a seller's listing down.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


class SoldOutReport(Base):
    __tablename__ = "sold_out_reports"

    id          = sa.Column(sa.String, primary_key=True, default=lambda: str(uuid.uuid4()))
    listing_id  = sa.Column(sa.String, sa.ForeignKey("listings.id"), nullable=False, index=True)
    reporter_id = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    created_at  = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    # Set when the seller said the item is still available.
    revoked_at  = sa.Column(sa.DateTime, nullable=True)

    __table_args__ = (
        sa.UniqueConstraint("listing_id", "reporter_id", name="uq_sold_out_report_listing_reporter"),
    )
