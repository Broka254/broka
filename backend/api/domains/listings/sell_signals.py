"""The measured inputs to the sell probability, read for many listings at once.

Both readers of the score - a seller's listing screen and the nightly
snapshot that draws its history - read them here, so the number on the
screen and the line under it are the same model fed the same way. They used
to gather their own: the snapshot left out the price benchmark the screen
used, so the chart and the headline disagreed on the same day.

One query per signal for the whole batch, never one per listing.
"""
from __future__ import annotations

from typing import Dict, Iterable, List

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Interest, Listing, NegotiationMessage, Wishlist
from api.domains.media.service import parse_id_list, split_legacy_photos


def _photo_count(listing: Listing) -> int:
    ids = parse_id_list(getattr(listing, "photo_ids", None))
    if ids:
        return len(ids)
    legacy = getattr(listing, "verified_photos", None)
    return len(split_legacy_photos(legacy)) if legacy else 0


async def engagement_signals(
    db: AsyncSession, listings: Iterable[Listing],
) -> Dict[str, dict]:
    """{listing_id: {likes, interested_buyers, best_offer, photo_count,
    description_chars}} - the ListingSignals fields that come from what
    buyers did and what the seller wrote.

    `interested_buyers` is every buyer who pressed "Is it available?"
    (Interest) or has a conversation about the listing the seller can see:
    their own direct messages, or Zeno's relays of them to the seller. Most
    buyers simply write, and counting only the button missed them. A buyer
    who has only talked to Zeno privately is not counted - the seller would
    learn of an interest the buyer has not shown them.
    """
    rows: List[Listing] = list(listings)
    ids = [l.id for l in rows]
    if not ids:
        return {}

    saves = dict((await db.execute(
        select(Wishlist.listing_id, func.count(Wishlist.id))
        .where(Wishlist.listing_id.in_(ids)).group_by(Wishlist.listing_id)
    )).all())

    buyers: Dict[str, set] = {lid: set() for lid in ids}
    best_offer: Dict[str, float] = {}
    for lid, buyer_id, offer in (await db.execute(
        select(Interest.listing_id, Interest.buyer_id, Interest.offer_price)
        .where(Interest.listing_id.in_(ids))
    )).all():
        if buyer_id:
            buyers[lid].add(buyer_id)
        if offer and offer > best_offer.get(lid, 0.0):
            best_offer[lid] = float(offer)

    # visibility-ok: reads listing and buyer ids only, to count buyers; no message content is selected or returned
    for lid, buyer_id in (await db.execute(
        select(NegotiationMessage.listing_id, NegotiationMessage.buyer_id)
        .where(
            NegotiationMessage.listing_id.in_(ids),
            or_(
                # The buyer's own words in the direct chat...
                (NegotiationMessage.role == "buyer")
                & or_(NegotiationMessage.via_ai.is_(False),
                      NegotiationMessage.via_ai.is_(None)),
                # ...or Zeno passing them on to the seller.
                (NegotiationMessage.role == "broker")
                & or_(NegotiationMessage.recipient_role.is_(None),
                      NegotiationMessage.recipient_role == "seller"),
            ),
        )
        .distinct()
    )).all():
        if buyer_id and lid in buyers:
            buyers[lid].add(buyer_id)

    return {
        l.id: {
            "likes": int(saves.get(l.id, 0)),
            # Never the seller themselves: a seller testing their own
            # listing's chat is not a buyer.
            "interested_buyers": len(buyers[l.id] - {l.seller_id}),
            "best_offer": best_offer.get(l.id),
            "photo_count": _photo_count(l),
            "description_chars": len((l.description or "").strip()),
        }
        for l in rows
    }
