"""Zeno as the user's assistant - POST /zeno/assistant/turn.

The one endpoint behind the Zeno tab, typed or spoken. See service.py for
the turn and intents.py for what Zeno may do.
"""
from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, field_validator
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.rate_limit import zeno_chat_limiter
from api.database import get_db
from api.security import get_current_user
from . import service

router = APIRouter()

# The app sends its whole transcript; the model reads the last 12 entries.
_HISTORY_KEEP = 40
_HISTORY_ENTRY_MAX_CHARS = 2000


class AssistantTurnIn(BaseModel):
    # Bounded: it is pasted into a billed prompt.
    message: str = Field(min_length=1, max_length=1000)
    history: list[dict] = Field(default_factory=list)
    language: str = Field(default="english", max_length=20)
    # "voice" asks for replies that read well aloud.
    mode: Literal["text", "voice"] = "text"

    @field_validator("history", mode="before")
    @classmethod
    def _recent_history_only(cls, v):
        """Keep the newest entries, each reduced to role and clipped
        content, rather than rejecting a long conversation with a 422 - the
        same rule as the Buying Agent's /converse."""
        if v is None:
            return []
        if not isinstance(v, list):
            raise ValueError("history must be a list")
        cleaned = []
        for h in v[-_HISTORY_KEEP:]:
            if not isinstance(h, dict):
                continue
            content = h.get("content")
            content = content if isinstance(content, str) else ("" if content is None else str(content))
            cleaned.append({
                "role": "user" if h.get("role") == "user" else "assistant",
                "content": content[:_HISTORY_ENTRY_MAX_CHARS],
            })
        return cleaned


@router.post("/assistant/turn")
async def assistant_turn(
    body: AssistantTurnIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """One turn: Zeno's reply, and at most one action for the app to take.

    `action` is null or {"type": NAVIGATE | SEARCH | FIND_FOR_ME | CALL |
    OPEN_CHAT, ...}. A CALL (or a request that fits several people) comes
    with requires_confirmation - the app asks before anything rings, and
    the call itself goes through POST /calls/initiate and its own checks.

    Rate-limited on the same per-user bucket as the chat it replaces
    (/negotiate/chat): most turns are a model call.
    """
    await zeno_chat_limiter.check_and_record(current_user["id"])
    if body.mode == "voice":
        # Voice mode is premium (PRICING.md). The microphone streams from
        # the phone straight to the speech provider, where BROKA cannot
        # count it; each spoken turn reaches this endpoint, so the turn is
        # what the plan's voice requests count. Typed turns stay free.
        from api.domains.premium import entitlements
        await entitlements.consume(db, current_user["id"], entitlements.Feature.VOICE)
    return await service.assistant_turn(
        db=db,
        user_id=current_user["id"],
        message=body.message,
        history=body.history,
        language=body.language,
        voice=body.mode == "voice",
    )
