"""Zeno as the user's assistant - POST /zeno/assistant/turn.

The one endpoint behind the Zeno tab, typed or spoken. See service.py for
the turn and intents.py for what Zeno may do.

And Zeno helping a seller write a listing (selling.py):
POST /zeno/listing-draft/describe, POST /zeno/listing-draft/describe/turn
and POST /zeno/listing-draft/price/turn - and listing it for them from the
photo, as a conversation (autolist.py): POST /zeno/listing-draft/autolist,
/autolist/turn and /autolist/price.
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
from . import autolist, selling, service

router = APIRouter()

# The app sends its whole transcript; the model reads the last 12 entries.
_HISTORY_KEEP = 40
_HISTORY_ENTRY_MAX_CHARS = 2000
# Base64 of a 10 MB photo - the ceiling every image upload in BROKA has
# (core/image_processing.MAX_UPLOAD_BYTES). The app sends a far smaller one.
_IMAGE_MAX_B64_CHARS = (10 * 1024 * 1024 * 4) // 3 + 4


def _recent_history(v) -> list[dict]:
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
        return _recent_history(v)


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


# ── Zeno helping a seller write a listing (selling.py) ───────────────────────

_ATTR_MAX = 20
_ATTR_KEY_MAX = 40
_ATTR_VALUE_MAX = 80


class ListingDraftIn(BaseModel):
    """The listing the seller is writing - there is no listing row yet.
    Every field is the seller's own entry in the sell wizard, bounded
    because it goes into a billed prompt."""
    name: str = Field(default="", max_length=120)
    category: str = Field(default="", max_length=60)
    subcategory: Optional[str] = Field(default=None, max_length=60)
    condition: Optional[str] = Field(default=None, max_length=20)
    attributes: dict[str, str] = Field(default_factory=dict)
    description: str = Field(default="", max_length=2000)
    asking_price: Optional[float] = Field(default=None, ge=0, le=selling.MAX_SUGGESTED_PRICE)
    price_unit: Optional[str] = Field(default=None, max_length=24)
    price_negotiable: Optional[bool] = None
    listing_type: Literal["direct", "auction"] = "direct"
    location: Optional[str] = Field(default=None, max_length=80)

    @field_validator("attributes", mode="before")
    @classmethod
    def _bounded_attributes(cls, v):
        """Category details ("storage": "128GB"), clipped rather than
        refused: a seller must not be stopped by a long value."""
        if not isinstance(v, dict):
            return {}
        out = {}
        for key, value in list(v.items())[:_ATTR_MAX]:
            if value is None or isinstance(value, (dict, list)):
                continue
            out[str(key)[:_ATTR_KEY_MAX]] = str(value)[:_ATTR_VALUE_MAX]
        return out


class DescribeIn(BaseModel):
    draft: ListingDraftIn = Field(default_factory=ListingDraftIn)
    # The first listing photo, by its upload id (POST /media/images) - or,
    # from a build whose upload hasn't finished, inline.
    photo_id: Optional[str] = Field(default=None, max_length=64)
    image_base64: Optional[str] = Field(default=None, max_length=_IMAGE_MAX_B64_CHARS)
    language: str = Field(default="english", max_length=20)
    # Set by app builds that let the seller answer Zeno's questions. Older
    # builds show only the description, so the questions come back in it
    # as blank "Label: " lines for the seller to fill in.
    conversation: bool = False


@router.post("/listing-draft/describe")
async def describe_listing_draft(
    body: DescribeIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Zeno writes the listing's description from its first photo:
    {"description", "reply", "questions"} - "Label: value" lines, and what
    to ask the seller for what the photo can't show. Premium: each one
    spends one of the plan's AI descriptions (a 402 without one). The
    seller edits the result in the description step - nothing here
    touches a listing.

    Rate-limited on Zeno's per-user bucket: it is a model call."""
    await zeno_chat_limiter.check_and_record(current_user["id"])
    return await selling.describe(
        db, current_user["id"], body.draft.model_dump(), body.language,
        photo_id=body.photo_id, image_base64=body.image_base64,
        conversation=body.conversation,
    )


class DescribeQuestionIn(BaseModel):
    label: str = Field(max_length=60)
    question: str = Field(default="", max_length=300)


class DescribeTurnIn(BaseModel):
    draft: ListingDraftIn = Field(default_factory=ListingDraftIn)
    # The description so far and what Zeno asked last - both as the
    # previous turn returned them.
    description: str = Field(default="", max_length=2000)
    questions: list[DescribeQuestionIn] = Field(default_factory=list, max_length=10)
    message: str = Field(max_length=1000)
    history: list[dict] = Field(default_factory=list)
    language: str = Field(default="english", max_length=20)

    @field_validator("history", mode="before")
    @classmethod
    def _recent_history_only(cls, v):
        return _recent_history(v)

    @model_validator(mode="after")
    def _something_to_answer(self):
        if not self.message.strip():
            raise ValueError("Answer Zeno, or use the description as it is.")
        return self


@router.post("/listing-draft/describe/turn")
async def describe_listing_draft_turn(
    body: DescribeTurnIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The seller answers what Zeno asked while writing their description:
    {"description", "reply", "questions"} with the answer folded in. Free
    once the plan has descriptions - only the look at the photo is counted
    (above).

    Rate-limited on Zeno's per-user bucket: it is a model call."""
    await zeno_chat_limiter.check_and_record(current_user["id"])
    return await selling.describe_turn(
        db, current_user["id"], body.draft.model_dump(), body.description,
        [q.model_dump() for q in body.questions], body.message.strip(), body.history,
        body.language,
    )


class PriceTurnIn(BaseModel):
    draft: ListingDraftIn
    message: str = Field(default="", max_length=1000)
    history: list[dict] = Field(default_factory=list)
    language: str = Field(default="english", max_length=20)
    # The seller tapped "check BROKA": search similar live listings and
    # price against them. The one counted step.
    research: bool = False

    @field_validator("history", mode="before")
    @classmethod
    def _recent_history_only(cls, v):
        return _recent_history(v)

    @model_validator(mode="after")
    def _something_to_answer(self):
        if not self.message.strip() and not self.research:
            raise ValueError("Say something, or ask Zeno to check BROKA.")
        return self


@router.post("/listing-draft/price/turn")
async def price_listing_draft(
    body: PriceTurnIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """One turn of Zeno helping a seller price their listing (Pro and
    Elite). {"reply", "suggested_price", "offer_research", "comparables"} -
    comparables only on a turn with research=true, which spends one of the
    plan's price checks."""
    await zeno_chat_limiter.check_and_record(current_user["id"])
    message = body.message.strip() or "Check how similar listings on BROKA are priced."
    return await selling.price_turn(
        db, current_user["id"], body.draft.model_dump(), message, body.history,
        body.language, research=body.research,
    )


# ── Zeno listing an item from its photo (autolist.py) ────────────────────────

class AutolistIn(BaseModel):
    # Whatever the seller had already entered: Zeno keeps it.
    draft: ListingDraftIn = Field(default_factory=ListingDraftIn)
    # The first listing photo, by its upload id - or inline from a build
    # whose upload hasn't finished.
    photo_id: Optional[str] = Field(default=None, max_length=64)
    image_base64: Optional[str] = Field(default=None, max_length=_IMAGE_MAX_B64_CHARS)
    language: str = Field(default="english", max_length=20)


@router.post("/listing-draft/autolist")
async def autolist_listing_draft(
    body: AutolistIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Zeno fills a listing in from its first photo: {"reply", "listing":
    {"name", "category", "category_id", "subcategory", "subcategory_id",
    "condition", "attributes", "description"}, "questions"}. The category
    is one of BROKA's or null. Spends one of the plan's AI descriptions
    (a 402 without one); nothing here touches a listing.

    Rate-limited on Zeno's per-user bucket: it is a model call."""
    await zeno_chat_limiter.check_and_record(current_user["id"])
    return await autolist.look(
        db, current_user["id"], body.draft.model_dump(), body.language,
        photo_id=body.photo_id, image_base64=body.image_base64,
    )


class AutolistTurnIn(BaseModel):
    # The listing and what Zeno asked last, as the previous turn returned
    # them (category and condition are checked again here).
    listing: ListingDraftIn
    questions: list[DescribeQuestionIn] = Field(default_factory=list, max_length=10)
    message: str = Field(max_length=1000)
    history: list[dict] = Field(default_factory=list)
    language: str = Field(default="english", max_length=20)

    @field_validator("history", mode="before")
    @classmethod
    def _recent_history_only(cls, v):
        return _recent_history(v)

    @model_validator(mode="after")
    def _something_to_answer(self):
        if not self.message.strip():
            raise ValueError("Answer Zeno, or carry on with the listing as it is.")
        return self


@router.post("/listing-draft/autolist/turn")
async def autolist_listing_draft_turn(
    body: AutolistTurnIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The seller answers or corrects Zeno: the whole listing back, as
    above, with their words in it. Free once the plan has descriptions.

    Rate-limited on Zeno's per-user bucket: it is a model call."""
    await zeno_chat_limiter.check_and_record(current_user["id"])
    return await autolist.turn(
        db, current_user["id"], body.listing.model_dump(),
        [q.model_dump() for q in body.questions], body.message.strip(), body.history, body.language,
    )


class AutolistPriceIn(BaseModel):
    draft: ListingDraftIn
    language: str = Field(default="english", max_length=20)


@router.post("/listing-draft/autolist/price")
async def autolist_listing_draft_price(
    body: AutolistPriceIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The fair range and the one number to ask: {"reply", "low", "high",
    "suggested_price", "basis": "broka" | "estimate", "comparables",
    "can_check_broka"}. Grounded on similar live BROKA listings on a plan
    with price checks (spending one), Zeno's estimate on any other.

    Rate-limited on Zeno's per-user bucket: it is a model call."""
    await zeno_chat_limiter.check_and_record(current_user["id"])
    return await autolist.price(db, current_user["id"], body.draft.model_dump(), body.language)
