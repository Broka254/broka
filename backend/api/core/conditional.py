"""Conditional GETs: an ETag on a JSON answer, and an empty 304 for a caller
that already holds it.

The app polls or reopens several lists whose answer is nearly always the one
it already has - the inbox, a chat's history, the call history. Each sends
the last ETag back as If-None-Match and gets a few hundred bytes instead of
the whole list. A client that sends nothing gets the same body as before,
plus the header, so older app builds are unaffected.
"""
from __future__ import annotations

import hashlib
import json
from typing import Any, Optional

from fastapi import Request, Response
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse


def body_etag(payload: Any) -> str:
    """A weak validator for a JSON body: the same data, the same tag."""
    body = json.dumps(payload, sort_keys=True, default=str, separators=(",", ":"))
    return 'W/"' + hashlib.sha256(body.encode("utf-8")).hexdigest()[:32] + '"'


def etag_matches(if_none_match: Optional[str], etag: str) -> bool:
    if not if_none_match:
        return False

    def bare(tag: str) -> str:
        tag = tag.strip()
        return tag[2:] if tag.startswith("W/") else tag

    return (any(bare(t) == bare(etag) for t in if_none_match.split(","))
            or if_none_match.strip() == "*")


def conditional_json(request: Request, content: Any, *, tag_over: Any = None) -> Response:
    """`content` as JSON with an ETag, or an empty 304 when the caller's
    If-None-Match is that tag.

    `tag_over`, when given, is what the tag is computed from instead of the
    body: the body less fields that follow the clock ("Active 5m ago"),
    which would otherwise change the tag every minute with nothing new in
    the list and the 304 would never come.
    """
    payload = jsonable_encoder(content)
    etag = body_etag(payload if tag_over is None else jsonable_encoder(tag_over))
    headers = {"ETag": etag, "Cache-Control": "private, no-cache"}
    if etag_matches(request.headers.get("if-none-match"), etag):
        return Response(status_code=304, headers=headers)
    return JSONResponse(content=payload, headers=headers)
