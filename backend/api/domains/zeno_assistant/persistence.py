"""Durable store for the account-level Zeno conversations.

Listing-specific Zeno rooms already persist in NegotiationMessage (via_ai
rows scoped by listing/buyer); this module is only for the general
assistant and the Buying Agent, which previously lived in the phone's
SharedPreferences alone. One conversation per (owner, mode, listing);
turns are appended with a per-turn client key so a retried request does
not write twice. Ownership is always checked - a user can only read the
conversations they own.
"""
from __future__ import annotations

import asyncio as _asyncio
import random as _random
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from datetime import datetime as _dt

from api.database import ZenoConversation, ZenoTurn

# Two phones hammering the same conversation race on MAX(seq)+1. Each retry
# re-reads MAX after a short jittered pause, so N racers settle in ~N
# rounds; this bound comfortably covers a burst of simultaneous appends.
_SEQ_RETRIES = 25

_MODES = ("assistant", "buying")


def _normalise_mode(mode: str) -> str:
    m = (mode or "").strip().lower()
    if m not in _MODES:
        raise ValueError("mode must be 'assistant' or 'buying'")
    return m


def _convo_filter(owner_id: str, mode: str, listing_id: Optional[str]):
    return (
        ZenoConversation.owner_id == owner_id,
        ZenoConversation.mode == mode,
        (
            ZenoConversation.listing_id == listing_id
            if listing_id is not None
            else ZenoConversation.listing_id.is_(None)
        ),
    )


async def _find_conversation(
    db: AsyncSession,
    owner_id: str,
    mode: str,
    listing_id: Optional[str],
) -> Optional[ZenoConversation]:
    """The conversation row, or None. Reads never create: opening Zeno on a
    second device must not mint an empty row that later splits the thread."""
    mode = _normalise_mode(mode)
    listing_id = (listing_id or "").strip() or None
    result = await db.execute(
        select(ZenoConversation).where(*_convo_filter(owner_id, mode, listing_id))
    )
    return result.scalars().first()


async def _get_or_create_conversation(
    db: AsyncSession,
    owner_id: str,
    mode: str,
    listing_id: Optional[str],
) -> ZenoConversation:
    mode = _normalise_mode(mode)
    listing_id = (listing_id or "").strip() or None
    convo = await _find_conversation(db, owner_id, mode, listing_id)
    if convo is not None:
        return convo
    convo = ZenoConversation(owner_id=owner_id, mode=mode, listing_id=listing_id)
    db.add(convo)
    try:
        await db.commit()
    except IntegrityError:
        # Two devices creating the same conversation at once: the unique
        # index keeps the first, and the loser takes it.
        await db.rollback()
        convo = await _find_conversation(db, owner_id, mode, listing_id)
        if convo is None:
            raise
        return convo
    await db.refresh(convo)
    return convo


async def append_turn(
    db: AsyncSession,
    owner_id: str,
    mode: str,
    listing_id: Optional[str],
    role: str,
    content: str,
    client_turn_id: Optional[str] = None,
) -> ZenoTurn:
    """Append one turn, idempotent on (conversation, client_turn_id).

    Two devices appending at once race on MAX(seq)+1. The loser hits the
    (conversation, seq) unique index instead of sharing a position, and is
    retried onto the next free slot - ordering stays gapless per
    conversation, and no turn is ever lost to the race.
    """
    convo = await _get_or_create_conversation(db, owner_id, mode, listing_id)
    # Plain id, not the ORM row: a rollback below expires every instance in
    # this session, and touching convo.id afterwards would lazy-load it
    # outside the greenlet (MissingGreenlet) instead of just reading it.
    convo_id = convo.id
    client_turn_id = (client_turn_id or "").strip() or None
    if client_turn_id:
        existing = (
            await db.execute(
                select(ZenoTurn).where(
                    ZenoTurn.conversation_id == convo_id,
                    ZenoTurn.client_turn_id == client_turn_id,
                )
            )
        ).scalars().first()
        if existing is not None:
            return existing
    for _ in range(_SEQ_RETRIES):
        seq = (
            await db.execute(
                select(func.max(ZenoTurn.seq)).where(ZenoTurn.conversation_id == convo_id)
            )
        ).scalar() or 0
        turn = ZenoTurn(
            conversation_id=convo_id,
            role="user" if role == "user" else "assistant",
            content=(content or "")[:8000],
            client_turn_id=client_turn_id,
            seq=int(seq) + 1,
        )
        db.add(turn)
        try:
            await db.commit()
            break
        except IntegrityError:
            # Either a retried request racing its first append (same client
            # key: hand back the stored row) or a seq collision with a
            # concurrent turn (re-read MAX and take the next slot).
            await db.rollback()
            if client_turn_id:
                existing = (
                    await db.execute(
                        select(ZenoTurn).where(
                            ZenoTurn.conversation_id == convo_id,
                            ZenoTurn.client_turn_id == client_turn_id,
                        )
                    )
                ).scalars().first()
                if existing is not None:
                    return existing
            # A seq loser pauses, then loops and re-reads MAX(seq);
            # anything else raises out of the loop below. The rollback
            # already detached the failed pending row, so the next
            # iteration builds cleanly on the same session while the
            # conversation row stays tracked for the updated_at touch-up.
            await _asyncio.sleep(_random.uniform(0.005, 0.05))
    else:
        raise IntegrityError("zeno_turns", None, Exception("seq retry exhausted"))
    await db.refresh(turn)
    convo.updated_at = _dt.utcnow()
    try:
        await db.commit()
    except Exception:
        await db.rollback()
    return turn


async def get_turns(
    db: AsyncSession,
    owner_id: str,
    mode: str,
    listing_id: Optional[str] = None,
    limit: int = 200,
) -> list[ZenoTurn]:
    convo = await _find_conversation(db, owner_id, mode, listing_id)
    if convo is None:
        return []
    result = await db.execute(
        select(ZenoTurn)
        .where(ZenoTurn.conversation_id == convo.id)
        .order_by(ZenoTurn.seq)
        .limit(max(1, min(int(limit or 200), 500)))
    )
    return list(result.scalars().all())


async def delete_conversation(
    db: AsyncSession,
    owner_id: str,
    mode: str,
    listing_id: Optional[str] = None,
) -> bool:
    """Remove one account-level conversation and its turns. Scoped to the
    owner: "new chat" on one phone must never clear another user's history.
    Returns whether anything was removed."""
    convo = await _find_conversation(db, owner_id, mode, listing_id)
    if convo is None:
        return False
    await db.execute(
        ZenoTurn.__table__.delete().where(
            ZenoTurn.conversation_id == convo.id
        )
    )
    await db.delete(convo)
    try:
        await db.commit()
    except Exception:
        await db.rollback()
        raise
    return True


async def replay_turn(
    db: AsyncSession,
    owner_id: str,
    mode: str,
    listing_id: Optional[str],
    client_turn_id: str,
) -> Optional[dict]:
    """The stored assistant reply for a retried user turn, if it completed.

    Returns None when the first attempt never finished (caller should run it
    again) so a lost response does not silently drop the user's message.
    """
    convo = await _find_conversation(db, owner_id, mode, listing_id)
    if convo is None:
        return None
    user_turn = (
        await db.execute(
            select(ZenoTurn).where(
                ZenoTurn.conversation_id == convo.id,
                ZenoTurn.client_turn_id == client_turn_id,
            )
        )
    ).scalars().first()
    if user_turn is None:
        return None
    following = (
        await db.execute(
            select(ZenoTurn)
            .where(
                ZenoTurn.conversation_id == convo.id,
                ZenoTurn.seq > user_turn.seq,
                ZenoTurn.role == "assistant",
            )
            .order_by(ZenoTurn.seq)
            .limit(1)
        )
    ).scalars().first()
    if following is None:
        return None
    return {"reply": following.content or "", "action": None, "source": "replay"}
