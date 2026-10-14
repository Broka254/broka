"""The request body ceiling (api/core/body_limit.py).

There was none: any caller could make the API buffer a body of any size in
memory before a route - or a rate limit - saw it. Covered for every way a
body arrives: a declared Content-Length, and a chunked stream with none.
"""
import pytest
from fastapi import FastAPI, File, UploadFile
from httpx import ASGITransport, AsyncClient
from pydantic import BaseModel

from api.core.body_limit import BodySizeLimitMiddleware

LIMIT = 1024


class Body(BaseModel):
    text: str


def _app() -> FastAPI:
    app = FastAPI()

    @app.post("/json")
    async def json_route(body: Body):
        return {"len": len(body.text)}

    @app.post("/upload")
    async def upload(file: UploadFile = File(...)):
        return {"len": len(await file.read())}

    app.add_middleware(BodySizeLimitMiddleware, max_bytes=LIMIT)
    return app


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=_app()), base_url="http://t") as c:
        yield c


@pytest.mark.asyncio
class TestBodyLimit:
    async def test_small_bodies_pass(self, client):
        assert (await client.post("/json", json={"text": "x" * 100})).json() == {"len": 100}
        r = await client.post("/upload", files={"file": ("a.bin", b"y" * 100)})
        assert r.json() == {"len": 100}

    async def test_a_declared_oversized_body_is_refused_unread(self, client):
        r = await client.post("/json", json={"text": "x" * (LIMIT * 2)})
        assert r.status_code == 413
        assert "limit" in r.json()["detail"].lower()

    async def test_an_oversized_upload_is_refused(self, client):
        r = await client.post("/upload", files={"file": ("a.bin", b"y" * (LIMIT * 2))})
        assert r.status_code == 413

    async def test_a_chunked_body_is_cut_off_as_it_streams(self, client):
        async def chunks():
            for _ in range(10):
                yield b'{"text": "' + b"x" * 300
            yield b'"}'
        # No Content-Length: httpx streams a generator with chunked encoding.
        r = await client.post("/json", content=chunks(), headers={"content-type": "application/json"})
        assert r.status_code == 413

    async def test_the_api_is_wrapped(self):
        from api.core.config import settings
        from main import app
        limits = [m for m in app.user_middleware if m.cls is BodySizeLimitMiddleware]
        assert len(limits) == 1
        assert limits[0].kwargs["max_bytes"] == settings.max_request_body_mb * 1024 * 1024
        # The biggest legitimate upload (25 MB of audio) fits.
        assert settings.max_request_body_mb * 1024 * 1024 > 25 * 1024 * 1024
