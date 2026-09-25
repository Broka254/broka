"""A ceiling on how big a request body may be.

Without one, any caller could send a body of any size and the server would
buffer it all in memory before a route saw it: a JSON body is read whole to
be parsed, and nothing stopped a public endpoint (signup, say) receiving a
gigabyte. One such request is enough to exhaust a small instance.

The largest legitimate bodies are uploads: speech for transcription (25 MB,
OpenAI's own limit - api/routers/stt.py), and older app builds that still
send photos as base64 inside JSON. MAX_REQUEST_BODY_MB (default 32) sits
above those. Individual routes keep their own, smaller limits.

Both ways a body can arrive are covered: a declared Content-Length over the
limit is refused before anything is read, and a body sent without one
(chunked) is counted as it streams and cut off once it passes the limit.
Plain ASGI rather than BaseHTTPMiddleware, so bodies are never buffered here.
"""
from __future__ import annotations

import json
from typing import Awaitable, Callable

from starlette.exceptions import HTTPException

Scope = dict
Message = dict
Receive = Callable[[], Awaitable[Message]]
Send = Callable[[Message], Awaitable[None]]

_DETAIL = "Request too large."


class BodySizeLimitMiddleware:
    def __init__(self, app, max_bytes: int):
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        declared = _content_length(scope)
        if declared is not None and declared > self.max_bytes:
            await _reject(send, self.max_bytes)
            return

        received = 0
        max_bytes = self.max_bytes

        async def limited_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > max_bytes:
                    # An HTTPException, so FastAPI's body parsing re-raises
                    # it as is and it becomes a 413 - any other exception
                    # there would be reported as a 400 or a 500.
                    raise HTTPException(status_code=413, detail=_DETAIL)
            return message

        await self.app(scope, limited_receive, send)


def _content_length(scope: Scope):
    for name, value in scope.get("headers", []):
        if name == b"content-length":
            try:
                return int(value)
            except ValueError:
                return None
    return None


async def _reject(send: Send, max_bytes: int) -> None:
    body = json.dumps({
        "detail": f"{_DETAIL} The limit is {max_bytes // (1024 * 1024)} MB.",
    }).encode()
    await send({
        "type": "http.response.start",
        "status": 413,
        "headers": [
            (b"content-type", b"application/json"),
            (b"content-length", str(len(body)).encode()),
            (b"connection", b"close"),
        ],
    })
    await send({"type": "http.response.body", "body": body})
