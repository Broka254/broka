"""Give every live personal listing a launch window.

Revision ID: 0022
Revises: 0021
Create Date: 2026-10-31

Listings created while listing fees are off used to keep paid_until NULL -
"no fee deadline" - so the seller dashboard's time-left row could only say
"No expiry" even though a listing's maximum live window is one launch
window (FREE_LISTING_OFFER_DAYS, 60 days). Creation now stamps that window
on every personal listing (listings/service.py), claimed or not, so the
countdown and the 2-day SMS have a date to read.

Rows that predate that change still carry NULL. This stamps them with a
full fresh window from migration time - generous on purpose: nothing that
buyers can see today disappears, everything just gains a deadline 60 days
out with an SMS 2 days before and a free renewal while fees are off
(pricing/payments.renew_free).

Scope, and why each exclusion is there:
  * store_id IS NULL - a store listing's clock is its store's subscription
    (listings/paid.live_clause), never its own paid_until; stamping one
    would invent a deadline nothing reads.
  * listing_type != 'auction' - auctions pay through plans and have their
    own lifecycle window, not listing time.
  * status = 'active' - sold, cancelled or completed listings must not be
    resurrected into anyone's "needing payment" list.
  * paid_until IS NULL only - rerunning this (or a deploy that runs it
    twice) touches nothing new, and never shortens a window creation or a
    payment already granted.

Downgrade cannot know which rows this stamped (NULL is gone), so it is a
no-op by design: the windows it grants are live data, not schema.
"""
from datetime import datetime, timedelta
from typing import Sequence, Union

from alembic import op

revision: str = "0022"
down_revision: Union[str, None] = "0021"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

def _window_days() -> int:
    # FREE_LISTING_OFFER_DAYS as deployed; creation reads the same setting,
    # so backfilled rows match what new rows get. Falls back to the default
    # when settings cannot load (the value the setting defaults to).
    try:
        from api.core.config import settings

        return max(1, int(settings.free_listing_offer_days))
    except Exception:
        return 60


def upgrade() -> None:
    bind = op.get_bind()
    deadline = datetime.utcnow() + timedelta(days=_window_days())
    bind.exec_driver_sql(
        """
        UPDATE listings
        SET paid_until = :deadline
        WHERE paid_until IS NULL
          AND store_id IS NULL
          AND listing_type != 'auction'
          AND status = 'active'
        """,
        {"deadline": deadline},
    )


def downgrade() -> None:
    pass
