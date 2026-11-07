"""Response compression for the API's JSON.

No response was compressed: every listing page, inbox and dashboard went
out as plain JSON, which shrinks several times over with gzip - on a
mobile connection, data the user pays for. Every client already asks for
it: dart:io's HttpClient sends `Accept-Encoding: gzip` and decompresses
transparently, so installed app builds benefit without an update, and a
client that doesn't ask gets the response exactly as before.

Left alone: /media/ (WebP and JPEG, already compressed) and /tts/ (MP3
and WAV audio) - gzip costs CPU there and saves nothing - and the admin
alert stream, a server-sent event stream that gzip would hold back in its
buffer instead of delivering each event as it happens.
"""
from starlette.middleware.gzip import GZipMiddleware
from starlette.types import ASGIApp, Receive, Scope, Send

# Below this, gzip's header and the CPU cost more than the bytes saved.
MINIMUM_SIZE = 1024

_UNCOMPRESSED_PREFIXES = ("/media/", "/tts/", "/admin/alerts/stream")


class JsonCompressionMiddleware:
    def __init__(self, app: ASGIApp, minimum_size: int = MINIMUM_SIZE) -> None:
        self.app = app
        self.gzip = GZipMiddleware(app, minimum_size=minimum_size)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and not scope.get("path", "").startswith(_UNCOMPRESSED_PREFIXES):
            await self.gzip(scope, receive, send)
            return
        await self.app(scope, receive, send)
