"""Turn an uploaded image into the WebP sizes BROKA serves.

Every image a user uploads - listing photos, store logos and photos, the
profile photo - goes through `process_image` before it is stored:

  1. **It must really be an image.** The bytes are opened by Pillow, not
     trusted from a file extension or a Content-Type header. Anything Pillow
     can't read, or a format outside ALLOWED_FORMATS, is refused.
  2. **Bounded work.** Over MAX_UPLOAD_BYTES is refused before decoding, and
     so is anything declaring more than MAX_PIXELS - a tiny file can claim
     a 50,000 x 50,000 canvas and exhaust memory when decoded (a
     "decompression bomb").
  3. **Upright.** Phones record rotation in EXIF instead of rotating the
     pixels; the rotation is applied, so every viewer sees the same image.
  4. **No metadata.** The output is re-encoded from pixels, so EXIF and XMP
     are dropped - including the GPS coordinates most phone photos carry,
     which would otherwise publish where the seller lives. The colour
     profile is kept, since dropping it shifts colours and says nothing
     about anyone.
  5. **Sizes.** WebP at each of VARIANTS' longest-side limits, never
     enlarged. `thumb` fills a product card in a two-column grid, `medium`
     the product page, `large` a full-screen zoom.

CPU-bound and synchronous; callers run it off the event loop
(`asyncio.to_thread`).
"""
from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass, field

from PIL import Image, ImageOps, UnidentifiedImageError

# name -> longest side in pixels. Order matters to readers that want "the
# biggest available": smallest first.
VARIANTS: tuple[tuple[str, int], ...] = (
    ("thumb", 480),
    ("medium", 960),
    ("large", 1600),
)

MAX_UPLOAD_BYTES = 10 * 1024 * 1024
# Declared canvas limits. A JPEG is decoded at reduced scale (draft mode, a
# JPEG feature: the decoder skips detail it would throw away), so a big one
# costs little memory. PNG/WebP/GIF have no such mode and decode at full
# size - 16 MP is ~64 MB as RGBA, which a 512 MB instance can afford for a
# few concurrent uploads; phone screenshots and logos are far below it.
MAX_PIXELS = 40_000_000          # JPEG: ~ an 8000 x 5000 photo
MAX_PIXELS_FULL_DECODE = 16_000_000
ALLOWED_FORMATS = frozenset({"JPEG", "MPO", "PNG", "WEBP", "GIF"})
WEBP_QUALITY = 80


class ImageRejected(ValueError):
    """The upload can't be used. The message is safe to show the user."""


@dataclass
class ProcessedImage:
    width: int
    height: int
    sha256: str
    # name -> (webp bytes, width, height)
    variants: dict[str, tuple[bytes, int, int]] = field(default_factory=dict)


def process_image(raw: bytes) -> ProcessedImage:
    if not raw:
        raise ImageRejected("The file is empty.")
    if len(raw) > MAX_UPLOAD_BYTES:
        raise ImageRejected("Images must be 10 MB or smaller.")

    try:
        img = Image.open(io.BytesIO(raw))
    except (UnidentifiedImageError, OSError, ValueError):
        raise ImageRejected("That file isn't an image we can read.")

    if img.format not in ALLOWED_FORMATS:
        raise ImageRejected("Use a JPEG, PNG, WebP or GIF image.")
    width, height = img.size
    is_jpeg = img.format in ("JPEG", "MPO")
    limit = MAX_PIXELS if is_jpeg else MAX_PIXELS_FULL_DECODE
    if width < 1 or height < 1 or width * height > limit:
        raise ImageRejected("That image is too large to process.")

    try:
        img.seek(0)          # first frame of an animated GIF/WebP
        if is_jpeg:
            # Decode at the smallest scale that still covers the largest
            # size we keep. A 6000x4000 photo decodes at 1/2 or 1/4 scale
            # instead of 24 megapixels.
            biggest = VARIANTS[-1][1]
            img.draft("RGB", (biggest, biggest))
        img.load()
    except Exception:
        raise ImageRejected("That image is damaged or incomplete.")

    icc_profile = img.info.get("icc_profile")
    img = ImageOps.exif_transpose(img)

    has_alpha = img.mode in ("RGBA", "LA") or (
        img.mode == "P" and "transparency" in img.info
    )
    img = img.convert("RGBA" if has_alpha else "RGB")

    out = ProcessedImage(
        width=img.width,
        height=img.height,
        sha256=hashlib.sha256(raw).hexdigest(),
    )
    # Largest size first, each smaller one resized from the previous: one
    # decoded image in memory, never a full-size copy per size.
    current = img
    for name, longest in reversed(VARIANTS):
        current = _fit(current, longest)
        buf = io.BytesIO()
        save_kwargs = {"format": "WEBP", "quality": WEBP_QUALITY, "method": 4}
        if icc_profile:
            save_kwargs["icc_profile"] = icc_profile
        current.save(buf, **save_kwargs)
        out.variants[name] = (buf.getvalue(), current.width, current.height)
    out.variants = {name: out.variants[name] for name, _ in VARIANTS}
    return out


def _fit(img: Image.Image, longest: int) -> Image.Image:
    """`img` scaled so its longest side is at most `longest`; never enlarged."""
    w, h = img.size
    if max(w, h) <= longest:
        return img
    scale = longest / max(w, h)
    return img.resize(
        (max(1, round(w * scale)), max(1, round(h * scale))), Image.Resampling.LANCZOS,
    )


def to_jpeg(webp_bytes: bytes, quality: int = 88) -> bytes:
    """Re-encode a stored variant as JPEG, for services that want JPEG
    input (the AI showcase generator is given the seller's first photo)."""
    img = Image.open(io.BytesIO(webp_bytes))
    img = img.convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


# Link previews (og:image). WhatsApp - how most store links are shared -
# doesn't show WebP preview images, so previews are JPEG, at the 1.91:1 size
# every preview card uses.
PREVIEW_SIZE = (1200, 630)
PREVIEW_BACKGROUND = (3, 4, 10)   # BROKA's near-black


def to_link_preview(image_bytes: bytes, fit: str = "cover", quality: int = 82) -> bytes:
    """A 1200x630 JPEG of a stored image. "cover" fills the frame and crops
    the overflow from the centre (photos); "contain" fits the whole image on
    BROKA's dark background (logos, which must not be cropped)."""
    img = Image.open(io.BytesIO(image_bytes))
    img.load()
    has_alpha = img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info)
    img = img.convert("RGBA" if has_alpha else "RGB")
    width, height = PREVIEW_SIZE
    canvas = Image.new("RGB", PREVIEW_SIZE, PREVIEW_BACKGROUND)
    if fit == "contain":
        inner = (int(width * 0.8), int(height * 0.8))
        scale = min(inner[0] / img.width, inner[1] / img.height)
        size = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
        placed = img.resize(size, Image.Resampling.LANCZOS)
        offset = ((width - size[0]) // 2, (height - size[1]) // 2)
        canvas.paste(placed, offset, placed if placed.mode == "RGBA" else None)
    else:
        if img.mode == "RGBA":
            flat = Image.new("RGB", img.size, PREVIEW_BACKGROUND)
            flat.paste(img, mask=img.split()[3])
            img = flat
        canvas = ImageOps.fit(img, PREVIEW_SIZE, Image.Resampling.LANCZOS, centering=(0.5, 0.5))
    buf = io.BytesIO()
    canvas.save(buf, format="JPEG", quality=quality, optimize=True, progressive=True)
    return buf.getvalue()
