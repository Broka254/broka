"""Give auctions a real lifecycle: starts_at/ends_at, close outcome, winner deal

Revision ID: 0021
Revises: 0020
Create Date: 2026-09-18

Before this, an auction had exactly one timestamp - Listing.auction_date -
and nothing on the backend read it. `auction_meta.status` was a free-text
string set to "live" by whatever placed the first bid and never moved
again. So an auction had no start, no end, no close, and no winner: bids
were accepted forever, and "the auction is over" existed only as a Flutter
countdown reaching zero on the buyer's own device clock.

What this adds, all on auction_meta (the one-to-one lifecycle record)
rather than on listings, which stays the catalogue row:

  starts_at / ends_at      the authoritative window. One nullable
                           timestamp cannot express a window - and
                           auction_date never even said which end it was.
  starting_price           floor for the first bid. NOT the reserve.
  current_bidder_id        who holds the top bid, so "you've been outbid"
                           needs no extra query under the bid lock.
  closed_at                set once, under a row lock. Its presence is
                           what makes closing idempotent.
  outcome                  won | no_bids | reserve_not_met | unpaid
  winning_amount           the price that becomes the Deal's goods amount
  deal_id                  the winner's Deal - one auction, one deal
  payment_deadline         when an unpaid win lapses
  ending_soon_notified_at  so the reminder goes out once, not every sweep

Backfill: existing rows get ends_at = listings.auction_date where it is
set. That is the interpretation the only reader it ever had (the Flutter
countdown) already used, so nothing changes meaning. starts_at is left
NULL for those, which lifecycle.py treats as "already open" - the correct
reading for an auction that has been accepting bids with no start gate at
all. Rows with no auction_date get no ends_at and are treated as not yet
schedulable; they cannot take bids until a window is set, which is the
safe direction.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "0021"
down_revision: Union[str, None] = "0020"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


_NEW_COLUMNS = (
    ("starts_at",               sa.Column("starts_at", sa.DateTime, nullable=True)),
    ("ends_at",                 sa.Column("ends_at", sa.DateTime, nullable=True)),
    ("starting_price",          sa.Column("starting_price", sa.Float, nullable=True)),
    ("current_bidder_id",       sa.Column("current_bidder_id", sa.String, nullable=True)),
    ("closed_at",               sa.Column("closed_at", sa.DateTime, nullable=True)),
    ("outcome",                 sa.Column("outcome", sa.String, nullable=True)),
    ("winning_amount",          sa.Column("winning_amount", sa.Float, nullable=True)),
    ("deal_id",                 sa.Column("deal_id", sa.String, nullable=True)),
    ("payment_deadline",        sa.Column("payment_deadline", sa.DateTime, nullable=True)),
    ("ending_soon_notified_at", sa.Column("ending_soon_notified_at", sa.DateTime, nullable=True)),
)


def _existing() -> set:
    bind = op.get_bind()
    return {c["name"] for c in sa.inspect(bind).get_columns("auction_meta")}


def upgrade() -> None:
    have = _existing()
    for name, column in _NEW_COLUMNS:
        if name not in have:
            op.add_column("auction_meta", column)

    # Backfill the window from the one timestamp that existed. Written as
    # a correlated UPDATE rather than a join so it runs identically on
    # SQLite and PostgreSQL.
    op.execute(
        """
        UPDATE auction_meta
           SET ends_at = (
               SELECT listings.auction_date
                 FROM listings
                WHERE listings.id = auction_meta.listing_id
           )
         WHERE ends_at IS NULL
        """
    )

    op.create_index("ix_auction_meta_ends_at", "auction_meta", ["ends_at"])
    op.create_index("ix_auction_meta_starts_at", "auction_meta", ["starts_at"])


def downgrade() -> None:
    for index in ("ix_auction_meta_starts_at", "ix_auction_meta_ends_at"):
        try:
            op.drop_index(index, table_name="auction_meta")
        except Exception:
            pass
    have = _existing()
    for name, _ in reversed(_NEW_COLUMNS):
        if name in have:
            op.drop_column("auction_meta", name)
