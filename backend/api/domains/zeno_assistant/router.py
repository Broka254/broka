"""Zeno as the user's assistant - POST /zeno/assistant/turn.

The one endpoint behind the Zeno tab, typed or spoken. See service.py for
the turn and intents.py for what Zeno may do.
"""
from __future__ import annotations

from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator, model_validator
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.rate_limit import zeno_chat_limiter
from api.core.vision import ImageRejected, prepare_for_model
from api.database import get_db
from api.security import get_current_user
from . import service

router = APIRouter()

# The app sends its whole transcript; the model reads the last 12 entries.
_HISTORY_KEEP = 40
_HISTORY_ENTRY_MAX_CHARS = 2000
# Base64 of a 10 MB photo - the ceiling every image upload in BROKA has
# (core/image_processing.MAX_UPLOAD_BYTES). The app sends a far smaller one.
_IMAGE_MAX_B64_CHARS = (10 * 1024 * 1024 * 4) // 3 + 4


class AssistantTurnIn(BaseModel):
    # Bounded: it is pasted into a billed prompt. May be empty when a photo
    # is attached - "what is this?" is the photo itself.
    message: str = Field(default="", max_length=1000)
    history: list[dict] = Field(default_factory=list)
    language: str = Field(default="english", max_length=20)
    # "voice" asks for replies that read well aloud.
    mode: Literal["text", "voice"] = "text"
    # Set when the user opened Zeno from a listing to ask about it. Only
    # the id: the server reads the listing itself (listing_context.py).
    listing_id: Optional[str] = Field(default=None, max_length=64)
    # A photo for Zeno to look at with this message (raw base64). Checked
    # and shrunk before any model sees it - see core/vision.py.
    image_base64: Optional[str] = Field(default=None, max_length=_IMAGE_MAX_B64_CHARS)

    @model_validator(mode="after")
    def _something_to_answer(self):
        if not self.message.strip() and not self.image_base64:
            raise ValueError("Say something, or attach a photo.")
        return self

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
    image = None
    if body.image_base64:
        # Before the voice entitlement below: a photo that can't be used
        # must not cost the user one of their voice turns.
        try:
            image = await prepare_for_model(body.image_base64)
        except ImageRejected as exc:
            raise HTTPException(status_code=422, detail=str(exc))
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
        listing_id=body.listing_id,
        image_base64=image,
    )
