"""Auctions switched off (AUCTIONS_ENABLED, off for launch).

A winning bid is paid through BROKA's own escrow, and while in-app
payments are paused there is nothing to hold it: no outside escrow service
takes a bid's money or closes an auction. So until that exists, auctions
are kept out of sight rather than deleted - the code, the tables and the
close sweep stay, and the setting brings them back.

What "off" does, and where:
  * creating, changing or bidding on one is refused here, with a message
    an older app build (which still offers "Auction" in the sell wizard
    and a Bid button) can show;
  * no list a buyer browses includes one - listings/paid.live_clause, the
    filter every public listing query shares;
  * the Auction House lists none (auctions/router.py), the "ending soon"
    reminder isn't sent (core/workers.py) and the plans stop selling
    auctions (pricing/plans.py).
An auction someone already has open by its link still shows, read-only,
with its result: a winner told they won must be able to see what they won.
"""
from __future__ import annotations

from fastapi import HTTPException

from api.core.config import settings

AUCTIONS_OFF_CODE = "AUCTIONS_OFF"
AUCTIONS_OFF_MESSAGE = (
    "Auctions aren't available on BROKA yet. List it as a direct sale - "
    "buyers can still make you offers, and Zeno negotiates for you."
)


def auctions_enabled() -> bool:
    return settings.auctions_enabled


def require_auctions() -> None:
    """Dependency for every route that creates, changes or bids on an
    auction. A 409 rather than a 404, like payments' guard
    (pricing/safe_payment.require_in_app_payments): an older build reads
    `code` and `message` from the detail and shows the message."""
    if not settings.auctions_enabled:
        raise HTTPException(status_code=409, detail={
            "code": AUCTIONS_OFF_CODE,
            "message": AUCTIONS_OFF_MESSAGE,
        })
