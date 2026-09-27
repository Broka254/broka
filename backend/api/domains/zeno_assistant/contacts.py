"""Who "Jane" is, when the user tells Zeno to call Jane.

Only ever someone the user is already talking to on BROKA: the other party
in one of their own negotiation threads - the seller of a listing they
messaged about, or a buyer who messaged about one of theirs. That is the
relationship /calls/initiate itself requires before a seller can ring a
buyer, and it is the right boundary for an assistant too: "call Jane" must
never turn into ringing a stranger who happens to be called Jane.

Matching is plain string matching done here, on the server, against those
threads. The model only ever passes on the words the user said ("the Axio
guy"); it never writes an id, so nothing it is talked into can point a
call at anyone outside the user's own conversations. Neither other users'
names nor listing titles go into the model's prompt, so they cannot steer
it either.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, NegotiationMessage, User

# Enough for anyone's recent conversations; the query is two indexed
# group-bys, not a scan of every message.
MAX_PARTNERS = 60

# Words that say nothing about WHICH person: "call the seller of the
# Axio" should match on "axio", not on "the" or "seller".
_FILLER = {
    "the", "my", "a", "an", "of", "for", "about", "from", "with", "on", "to", "and",
    "seller", "buyer", "guy", "lady", "man", "woman", "person", "owner", "one",
    "who", "is", "selling", "sells", "sold", "buying", "bought", "that", "this",
    "him", "her", "them", "mr", "mrs", "ms", "miss", "dr", "please", "again", "back",
    "wa", "ya", "yule", "muuzaji", "mnunuzi",
}


@dataclass(frozen=True)
class Partner:
    """One conversation the user is in, from their side."""

    listing_id: str
    listing_name: str
    peer_id: str
    peer_name: str
    # The user's own role in this thread: "buyer" when they messaged about
    # someone else's listing, "seller" when it is their listing.
    role: str
    buyer_id: str
    last_at: Optional[datetime]

    def to_target(self) -> dict:
        """What the app needs to open this thread or call this person.

        Nothing the user doesn't already have: their own inbox returns the
        same ids for the same thread."""
        return {
            "listing_id": self.listing_id,
            "listing_name": self.listing_name,
            "peer_id": self.peer_id,
            "peer_name": self.peer_name,
            "role": self.role,
            "buyer_id": self.buyer_id,
        }


async def conversation_partners(db: AsyncSession, user_id: str) -> list[Partner]:
    """Everyone the user has a thread with, newest conversation first."""
    partners: list[Partner] = []

    # As the buyer: listings they messaged about, and whose seller that is.
    # visibility-ok: selects ids and timestamps only, no message content
    as_buyer = (await db.execute(
        select(NegotiationMessage.listing_id, func.max(NegotiationMessage.created_at))
        .where(NegotiationMessage.buyer_id == user_id)
        .group_by(NegotiationMessage.listing_id)
    )).all()
    if as_buyer:
        last = {lid: at for lid, at in as_buyer}
        rows = (await db.execute(
            select(Listing.id, Listing.name, User.id, User.name)
            .join(User, Listing.seller_id == User.id)
            .where(Listing.id.in_(list(last)), Listing.seller_id != user_id)
        )).all()
        for lid, lname, sid, sname in rows:
            partners.append(Partner(lid, lname or "", sid, sname or "", "buyer", user_id, last.get(lid)))

    # As the seller: buyers who messaged about the user's listings.
    # visibility-ok: selects ids and timestamps only, no message content
    as_seller = (await db.execute(
        select(NegotiationMessage.listing_id, NegotiationMessage.buyer_id,
               func.max(NegotiationMessage.created_at))
        .join(Listing, Listing.id == NegotiationMessage.listing_id)
        .where(
            Listing.seller_id == user_id,
            NegotiationMessage.buyer_id.isnot(None),
            NegotiationMessage.buyer_id != user_id,
        )
        .group_by(NegotiationMessage.listing_id, NegotiationMessage.buyer_id)
    )).all()
    if as_seller:
        buyer_ids = {bid for _, bid, _ in as_seller}
        listing_ids = {lid for lid, _, _ in as_seller}
        names = dict((await db.execute(
            select(User.id, User.name).where(User.id.in_(buyer_ids))
        )).all())
        titles = dict((await db.execute(
            select(Listing.id, Listing.name).where(Listing.id.in_(listing_ids))
        )).all())
        for lid, bid, at in as_seller:
            if bid not in names:
                continue
            partners.append(Partner(lid, titles.get(lid) or "", bid, names[bid] or "", "seller", bid, at))

    partners.sort(key=lambda p: p.last_at or datetime.min, reverse=True)
    return partners[:MAX_PARTNERS]


def _words(text: str) -> list[str]:
    return [w for w in re.findall(r"[a-z0-9]+", (text or "").lower())]


def resolve(partners: list[Partner], said: str) -> list[Partner]:
    """The partners [said] can mean, best first - at most one per person.

    A name beats a listing: "call Jane" is Jane even if some listing is
    called "Jane's chair". Within a person, their newest thread is the one
    used (a call has to be about some listing, and the latest is the one
    they are most likely talking about), unless the words name a listing.
    """
    words = [w for w in _words(said) if w not in _FILLER and len(w) >= 2]
    if not words:
        return []

    scored: list[tuple[int, int, Partner]] = []
    for order, p in enumerate(partners):
        name = _words(p.peer_name)
        title = set(_words(p.listing_name))
        score = 0
        for w in words:
            if w in name:
                score += 10 if w == (name[0] if name else None) else 8
            elif any(n.startswith(w) and len(w) >= 3 for n in name):
                score += 5
            elif w in title:
                score += 3
        if score:
            scored.append((score, -order, p))
    if not scored:
        return []

    scored.sort(key=lambda s: (s[0], s[1]), reverse=True)
    best = scored[0][0]
    picked: dict[str, Partner] = {}
    for score, _, p in scored:
        # Only the strongest matches: "jane" matching Jane Wanjiru should
        # not also offer Jack because one of his listings says "jane".
        if score < best:
            break
        picked.setdefault(p.peer_id, p)
    return list(picked.values())
