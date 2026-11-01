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

from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from datetime import datetime as _dt

from api.database import ZenoConversation, ZenoTurn

_MODES = ("assistant", "buying")


def _normalise_mode(mode: str) -> str:
    m = (mode or "").strip().lower()
    if m not in _MODES:
        raise ValueError("mode must be 'assistant' or 'buying'")
    return m


async def _get_or_create_conversation(
    db: AsyncSession,
    owner_id: str,
    mode: str,
    listing_id: Optional[str],
) -> ZenoConversation:
    mode = _normalise_mode(mode)
    listing_id = (listing_id or "").strip() or None
    result = await db.execute(
        select(ZenoConversation).where(
            ZenoConversation.owner_id == owner_id,
            ZenoConversation.mode == mode,
            (
                ZenoConversation.listing_id == listing_id
                if listing_id is not None
                else ZenoConversation.listing_id.is_(None)
            ),
        )
    )
    convo = result.scalars().first()
    if convo is not None:
        return convo
    convo = ZenoConversation(owner_id=owner_id, mode=mode, listing_id=listing_id)
    db.add(convo)
    try:
        await db.commit()
    except IntegrityError:
        # Two devices creating the same conversation at once: keep the first.
        await db.rollback()
        result = await db.execute(
            select(ZenoConversation).where(
                ZenoConversation.owner_id == owner_id,
                ZenoConversation.mode == mode,
                (
                    ZenoConversation.listing_id == listing_id
                    if listing_id is not None
                    else ZenoConversation.listing_id.is_(None)
                ),
            )
        )
        convo = result.scalars().first()
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
    """Append one turn, idempotent on (conversation, client_turn_id)."""
    convo = await _get_or_create_conversation(db, owner_id, mode, listing_id)
    client_turn_id = (client_turn_id or "").strip() or None
    if client_turn_id:
        existing = (
            await db.execute(
                select(ZenoTurn).where(
                    ZenoTurn.conversation_id == convo.id,
                    ZenoTurn.client_turn_id == client_turn_id,
                )
            )
        ).scalars().first()
        if existing is not None:
            return existing
    seq = (
        await db.execute(
            select(func.max(ZenoTurn.seq)).where(ZenoTurn.conversation_id == convo.id)
        )
    ).scalar() or 0
    turn = ZenoTurn(
        conversation_id=convo.id,
        role="user" if role == "user" else "assistant",
        content=(content or "")[:8000],
        client_turn_id=client_turn_id,
        seq=int(seq) + 1,
    )
    db.add(turn)
    try:
        await db.commit()
    except IntegrityError:
        # A retry racing the first append: hand back the stored row.
        await db.rollback()
        if client_turn_id:
            existing = (
                await db.execute(
                    select(ZenoTurn).where(
                        ZenoTurn.conversation_id == convo.id,
                        ZenoTurn.client_turn_id == client_turn_id,
                    )
                )
            ).scalars().first()
            if existing is not None:
                return existing
        raise
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
    convo = await _get_or_create_conversation(db, owner_id, mode, listing_id)
    result = await db.execute(
        select(ZenoTurn)
        .where(ZenoTurn.conversation_id == convo.id)
        .order_by(ZenoTurn.seq)
        .limit(max(1, min(int(limit or 200), 500)))
    )
    return list(result.scalars().all())


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
    convo = await _get_or_create_conversation(db, owner_id, mode, listing_id)
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
