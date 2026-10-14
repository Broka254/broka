"""Dispute resolution flow v2 - seller explanation before buyer decides

Revision ID: 0006
Revises: 0005
Create Date: 2026-06-27

No schema changes in this revision. All changes are logic-only in:
  - api/routers/negotiate.py
  - api/core/workers.py

Changes:
  1. Auto-refund (workers._fire_auto_refund) now correctly refunds 97%
     (agreed_price * 0.97) instead of 100%. This matches the manual
     buyer_chooses_refund path and the spec ("97% of the actual amount").

  2. A2 (wrong item): Zeno no longer immediately shows the buyer
     refund/replace buttons. Instead:
       a. Zeno freezes funds and asks the seller for an explanation.
       b. Seller responds via the new "seller_explains_wrong_item" intent.
       c. Zeno relays the explanation to the buyer and THEN shows
          the refund / replacement choice.

  3. A3 (damaged goods): Same sequencing fix as A2. After image analysis
     and seller notification, Zeno waits for the seller to respond via
     the new "seller_explains_damaged" intent before presenting the
     buyer with refund / replacement options.

New intents added to negotiate.py message handler:
  - seller_explains_wrong_item  (A2 seller reply)
  - seller_explains_damaged     (A3 seller reply)

Flutter buttons required (add to deal status screen):
  - Seller UI when dispute_branch == "A2" or "A3" and
    deal.status == "awaiting_resolution":
    → "Explain" button → sends intent="seller_explains_wrong_item"
      or "seller_explains_damaged" with content=<seller's explanation text>

The complete dispute tree (unchanged from 0005, included for reference):

  GOODS ARRIVE
  ├── Buyer confirms (buyer_confirms_arrived)
  │   └── Zeno asks condition → awaiting_condition_check
  │       ├── All good (buyer_confirms_goods_ok) → A1 → release 97%
  │       ├── Wrong item (buyer_reports_wrong_item) → A2
  │       │   └── Seller explains (seller_explains_wrong_item)
  │       │       ├── Buyer wants refund (buyer_chooses_refund) → refund 97%
  │       │       └── Buyer wants replacement (buyer_chooses_replacement) → A4
  │       │           └── Seller ships (seller_ships_replacement)
  │       │               └── Buyer confirms arrival → A1 → release 97%
  │       └── Damaged (buyer_reports_damaged) → A3 (image analysis)
  │           └── Seller explains (seller_explains_damaged)
  │               ├── Buyer wants refund (buyer_chooses_refund) → refund 97%
  │               └── Buyer wants replacement (buyer_chooses_replacement) → A4
  │                   └── (same as A2 replacement path above)
  │
  └── Buyer silent on expected delivery date
      └── Zeno asks → buyer_delivery_silence timer
          ├── Buyer responds → buyer_confirms_arrived OR goods_not_arrived
          └── 4 days silent (check-ins: day 1,2,3,4; SMS on day 3)
              → auto-release 97% to seller

  GOODS DON'T ARRIVE (goods_not_arrived intent)
  └── Zeno contacts seller (goods_not_arrived_contact_seller timer)
      ├── Seller responds (seller_explains_non_arrival)
      │   └── Buyer waits; re-confirms arrival later
      └── 3 days silent (check-ins: day 1,2,3; SMS on day 2)
          → auto-refund buyer 97%
"""
from typing import Sequence, Union

revision: str = "0006"
down_revision: Union[str, None] = "0005"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # No DDL changes — logic-only revision.
    pass


def downgrade() -> None:
    # No DDL to reverse.
    pass
