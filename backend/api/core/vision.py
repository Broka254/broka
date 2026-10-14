"""Getting a user's photo ready for Zeno to look at.

A photo sent to Zeno (the Zeno tab, the negotiation room, a damaged-goods
report) reaches an outside AI provider, so it goes through the same
processing as every other image BROKA accepts (core/image_processing.py)
before it leaves:

  * **It must be an image.** Anything Pillow can't read is refused here,
    with a message the user can be shown, instead of being forwarded to a
    provider that bills for the attempt and answers with a 400.
  * **No metadata.** A phone photo carries where it was taken; the provider
    has no business knowing where the user lives.
  * **Small.** The model reads a photo at well under 1000px; sending the
    camera's 12 MP costs upload time on a Kenyan mobile connection and
    input tokens for detail the model throws away. The medium listing size
    (960px), as JPEG - the one format every provider in the chain takes.
"""
from __future__ import annotations

import asyncio
import base64
import binascii

from api.core.image_processing import ImageRejected, process_image, to_jpeg

__all__ = ["ImageRejected", "prepare_for_model"]


def _decode(image_base64: str) -> bytes:
    data = (image_base64 or "").strip()
    # The app sends raw base64, but a data URI is what a browser's FileReader
    # produces and is easy to send by mistake.
    if data.startswith("data:"):
        data = data.partition(",")[2]
    try:
        return base64.b64decode(data, validate=False)
    except (binascii.Error, ValueError):
        raise ImageRejected("That photo couldn't be read. Please try again.")


def _prepare_sync(image_base64: str) -> str:
    processed = process_image(_decode(image_base64))
    webp = processed.variants["medium"][0]
    return base64.b64encode(to_jpeg(webp, quality=85)).decode()


async def prepare_for_model(image_base64: str) -> str:
    """The photo as raw base64 JPEG, at most 960px on its longest side, with
    its metadata gone. Raises ImageRejected (safe to show) for anything that
    isn't a usable image. CPU-bound, so it runs off the event loop."""
    return await asyncio.to_thread(_prepare_sync, image_base64)
