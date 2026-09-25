"""
BROKA - AI Showcase/Cover Image Router
Two routers on purpose - see service.py's module docstring for why:
  - `router`, mounted at /listings (main.py) - per-listing operations for
    an already-created listing (Edit Listing regenerate, set, remove).
  - `preview_router`, mounted at its own /showcase prefix - the wizard's
    pre-creation preview call. Deliberately NOT nested under /listings/
    {listing_id}/... (there is no listing_id yet), and given its own
    top-level prefix rather than something like /listings/showcase/preview
    to make that structurally unambiguous rather than relying on FastAPI
    path-param matching never coincidentally treating "showcase" as a
    listing_id value.
"""
from __future__ import annotations

from typing import Literal, Optional

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.security import get_current_user
from . import service

router = APIRouter()
preview_router = APIRouter()


class GenerateShowcaseIn(BaseModel):
    description: Optional[str] = Field(default=None, max_length=2000)  # seller's creative brief - optional, spec §7C
    # One of service.THEMES ("studio", "luxury", ...). Optional.
    theme: Optional[str] = Field(default=None, max_length=24)
    # "asset": store the result as an image asset and return its id and
    # URLs (current app builds). Omitted: the old base64 data URI.
    result: Optional[Literal["asset", "data_uri"]] = None


class SetShowcaseIn(BaseModel):
    image_data_uri: str      # "data:image/...;base64,..." - AI preview handed back, or a gallery pick
    source: str               # "gallery" | "ai"


class PreviewShowcaseIn(BaseModel):
    """Pre-creation generation, from the listing wizard's Showcase step -
    facts come from the in-memory draft (SellWizardData), not a DB row."""
    # The draft's first photo: its asset id (current builds - it was
    # uploaded when it was taken) or the photo itself (older builds).
    photo_id: Optional[str] = Field(default=None, max_length=64)
    photo_data_uri: Optional[str] = None  # "data:image/...;base64,..."
    name: str = Field(max_length=200)
    category: str = Field(max_length=100)
    condition: Optional[str] = Field(default=None, max_length=40)
    price: Optional[float] = None
    description: Optional[str] = Field(default=None, max_length=2000)  # seller's creative brief, optional
    theme: Optional[str] = Field(default=None, max_length=24)
    result: Optional[Literal["asset", "data_uri"]] = None


@router.post("/{listing_id}/showcase/generate")
async def generate_showcase(
    listing_id: str,
    body: GenerateShowcaseIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Generates a preview only - does not save it. Returns image_data_uri
    for the client to display with Use This Image / Regenerate / Change
    Description; call POST .../showcase to actually commit one."""
    return await service.generate_showcase_preview(
        db, listing_id, current_user["id"], body.description,
        theme=body.theme, as_asset=body.result == "asset",
    )


@router.post("/{listing_id}/showcase")
async def set_showcase(
    listing_id: str,
    body: SetShowcaseIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await service.set_showcase_image(
        db, listing_id, current_user["id"], body.image_data_uri, body.source,
    )


@router.delete("/{listing_id}/showcase")
async def remove_showcase(
    listing_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await service.remove_showcase_image(db, listing_id, current_user["id"])


@preview_router.post("/preview")
async def preview_showcase(
    body: PreviewShowcaseIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Full path: POST /showcase/preview. Used only by the listing wizard,
    before a listing exists - see PreviewShowcaseIn / service.py."""
    return await service.generate_showcase_preview_standalone(
        db, current_user["id"], body.photo_data_uri,
        body.name, body.category, body.condition, body.price, body.description,
        theme=body.theme, photo_id=body.photo_id, as_asset=body.result == "asset",
    )
