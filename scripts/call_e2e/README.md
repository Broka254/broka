# Two-phone call simulation

Runs both phones' `WebRtcService` against the real backend, locally, through
the call scenarios in CALLING.md ("A call placed is a call the caller can
join", 2026-11-13). It is not a device test, and it cannot show audio being
carried: see "What is simulated" below.

```
# from the repository root
python scripts/call_e2e/server.py --port 8765 --seed-out /tmp/seed.json &
cd flutter_app
BROKA_E2E_SEED=/tmp/seed.json flutter test test/e2e/call_e2e_test.dart \
  --dart-define=API_URL=http://127.0.0.1:8765
```

Without `BROKA_E2E_SEED` the test file skips itself, which is what CI's
`flutter test` does.

## What is real

- Both phones' `WebRtcService`: signalling, timers, reconnects, ICE restarts,
  outcomes and the diagnostics they report.
- Real WebSockets and HTTP to the real FastAPI app: the relay, the call state
  machine, `/calls/initiate` with its push wait, `/calls/cancel-setup`, the
  call-token routes, and the `[call-event]` logs exactly as Render writes them
  (`JSON_LOGS=true`).

## What is simulated

- **The native WebRTC stack** (`SimPc` in the test). Each phone is given a
  network: `open` (Wi-Fi: host and server-reflexive candidates reach the other
  side) or `symmetric` (carrier-grade NAT, as on most Kenyan mobile data: only
  a TURN relay gets through). A connection comes up only when the candidates
  the phones actually exchanged contain a pair that network allows. Relay
  candidates exist only when the backend issued TURN credentials.
- **No audio is encoded or carried.** "Audio both ways" means each phone's
  microphone track is on a send-and-receive transceiver and the other side's
  track is playing, not held.
- **Firebase and Cloudflare** are stand-ins (`server.py`): the push "sends"
  after a delay the scenario sets, and TURN credentials are fake or refused.
- SQLite and in-memory call state instead of Supabase and Upstash.

Real Wi-Fi, real carrier NAT, real TURN relaying and real audio need two
Android phones; CALLING.md lists what to check on them.
