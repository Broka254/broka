"""The real BROKA backend, run locally for the two-phone call simulation.

    python scripts/call_e2e/server.py --port 8765 --seed-out /tmp/seed.json

What it changes from production, and nothing else:

  * SQLite and in-memory call state / signalling: one instance, as Render
    runs it, without Redis.
  * Firebase "configured" with a stand-in sender, so the incoming-call push
    path runs; its delay can be set (the 2026-11-13 incident: the push, and
    the work before it, ran past the app's 10-second wait).
  * Cloudflare TURN answered by a stand-in that returns relay servers with
    a fake credential, or fails, as the scenario says.
  * POST /__e2e/config sets those two per scenario.

Everything else - every endpoint, the signalling relay, the call state
machine, the logs - is the code that runs on Render. JSON_LOGS=true gives
the same log lines production writes.
"""
import argparse
import asyncio
import json
import os
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(HERE, "..", "..", "backend")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--seed-out", required=True)
    args = parser.parse_args()

    db_dir = tempfile.mkdtemp(prefix="broka_call_e2e_")
    os.environ.setdefault("ENV", "test")
    os.environ.setdefault("SECRET_KEY", "call-e2e-secret-key-that-is-at-least-32-characters")
    os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{db_dir}/e2e.db"
    os.environ.pop("REDIS_URL", None)
    os.environ["JSON_LOGS"] = "true"
    sys.path.insert(0, os.path.abspath(BACKEND))

    from fastapi import Body
    import uvicorn

    from api.core import cloudflare_turn_client
    from api.core.cloudflare_turn_client import CloudflareTurnError
    from api.database import AsyncSessionLocal, Listing, NegotiationMessage, User, init_db
    from api.routers import calls
    from api.security import create_access_token
    from main import app

    scenario = {"turn": "ok", "push_delay": 0.0}

    async def fake_ice_servers(ttl: int = 3600) -> dict:
        if scenario["turn"] != "ok":
            raise CloudflareTurnError("Cloudflare TURN credential generation failed")
        return {
            "ice_servers": [
                {"urls": ["stun:stun.cloudflare.com:3478"]},
                {"urls": ["turn:turn.cloudflare.com:3478?transport=udp",
                          "turn:turn.cloudflare.com:3478?transport=tcp",
                          "turns:turn.cloudflare.com:5349?transport=tcp"],
                 "username": "e2e-user", "credential": "e2e-credential-not-real"},
            ],
            "expires_in": ttl,
        }

    async def fake_send_fcm(token, title, body, data, **kwargs):
        if scenario["push_delay"]:
            await asyncio.sleep(scenario["push_delay"])
        return calls.FcmResult(True, message_id=f"e2e-{uuid.uuid4().hex[:8]}")

    cloudflare_turn_client.generate_ice_servers = fake_ice_servers
    calls._get_fcm = lambda: object()
    calls._send_fcm = fake_send_fcm
    # One account places a dozen calls a minute here; production allows ten.
    from api.core.rate_limit import RateLimiter
    for name in ("call_initiate_limiter", "turn_credential_limiter",
                 "call_ws_connect_limiter", "call_ws_preauth_limiter", "call_events_limiter"):
        setattr(calls, name, RateLimiter(f"{name}_e2e", 10_000, 60))

    @app.post("/__e2e/config")
    async def configure(body: dict = Body(...)):
        scenario.update({k: v for k, v in body.items() if k in scenario})
        return scenario

    @app.post("/__e2e/drop")
    async def drop(body: dict = Body(...)):
        """A phone's signalling socket dropped from under it - the network
        going, as a lift doorway or a Wi-Fi/cell handoff does it."""
        ws = calls._rooms.get(body.get("room"), {}).get(body.get("user"))
        if ws is None:
            return {"dropped": False}
        await ws.close(code=4000, reason="network dropped (e2e)")
        return {"dropped": True}

    async def seed() -> dict:
        await init_db()
        async with AsyncSessionLocal() as db:
            seller = User(name="Xavier Bravin", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
            buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
            db.add_all([seller, buyer])
            await db.flush()
            listing = Listing(seller_id=seller.id, name="Airtel Smart Connect Home & Office WiFi",
                              category="Electronics", price=4500, lat=-1.28, lng=36.82)
            db.add(listing)
            await db.flush()
            db.add(NegotiationMessage(listing_id=listing.id, sender_id=buyer.id, role="buyer",
                                      recipient_role="seller", content="Is it still available?",
                                      buyer_id=buyer.id, via_ai=False, msg_type="text"))
            await db.commit()
            # Both phones registered for pushes, so the incoming-call push
            # path runs (through the stand-in sender above).
            from api.core import push_devices
            for user in (seller, buyer):
                await push_devices.register(db, user.id, f"e2e-fcm-{user.id}", kind="fcm",
                                            platform="android")
            await db.commit()
            return {
                "listing_id": listing.id,
                "caller": {"id": buyer.id, "name": buyer.name,
                           "token": create_access_token({"sub": buyer.id})},
                "callee": {"id": seller.id, "name": seller.name,
                           "token": create_access_token({"sub": seller.id})},
            }

    seeded = asyncio.run(seed())
    with open(args.seed_out, "w") as f:
        json.dump(seeded, f)
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
