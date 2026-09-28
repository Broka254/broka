# broka_native: the backend's Rust extension

The BROKA backend is Python (FastAPI) and stays Python. This crate takes
the few jobs where Python is the wrong tool, and compiles them into a Python
extension module, `broka_native` (PyO3, built with maturin). Nothing else
in the backend imports it directly: `api/core/native.py` loads it, checks
it, and hands it to the two modules that use it.

| Module | Used by | Why Rust |
|---|---|---|
| `src/text_guard.rs` | `api/core/text_guard.py` - every chat message a user sends (Zeno and direct chat) is scanned for phone numbers, WhatsApp/Telegram, emails, tills and "pay me directly" | Python's `re` backtracks: one careless rule can take seconds on a crafted message (a naive email regex takes ~480 ms on 20,000 characters) while holding the event loop. Rust's `regex` is linear-time for any pattern, including rules added later. The scan also releases the GIL. |
| `src/geo.rs` | `api/core/geo.py` - "near me" filters and "3.2 km away" labels | One implementation instead of six copied ones; the radius filter runs over a whole candidate list in one call. |

Measured on one core (Rust vs the Python reference, same results):

| Input | Python | Rust |
|---|---|---|
| Typical chat message (80 chars) | 33 µs | 6 µs |
| Disguised number ("zero seven one two 345 678") | 35 µs | 6 µs |
| 10 KB message | 3.3 ms | 0.5 ms |
| 200 KB hostile input | 219 ms | 14 ms |
| Distances to 500 listings | 257 µs | 21 µs |

## What was deliberately not moved

Most of the backend waits on PostgreSQL, Redis and HTTP APIs, where Rust
buys nothing. Image processing is already C (Pillow/libwebp) and already runs
in a thread; password hashing is already Rust (pyca `bcrypt`), and what it
needed was to be called off the event loop (`api/security.py`); JSON
responses are serialized by pydantic-core, also Rust. Sorting bids is SQL's
job (`routers/auction.py` used to hold a hook for a C++ engine that was
never built; it's gone).

A candidate belongs here when it is CPU-bound, runs on a hot path, is a
pure function of its input, and can be written twice - once in Rust, once in
Python - with identical output.

## The Python fallback

Every function here has a Python reference implementation, used when the
extension isn't loaded:

- `BROKA_NATIVE=auto` (default): use the extension if it is installed and
  was built from this checkout, else Python. Local checkouts nobody compiled
  run this way.
- `BROKA_NATIVE=required`: refuse to start without it. The Docker image sets
  this, so a deploy can't silently lose the extension.
- `BROKA_NATIVE=off`: never load it. The kill switch - set it in the
  service's environment if the extension misbehaves.

`GET /ready` reports `"native": "rust"` or `"python"`.

`api/core/native.py` refuses a build it can't trust: one with a different
`API_VERSION` (bump it in `src/python.rs` and `native.py` together when a
signature changes), one compiled from different contact-leak rules than
`rules/contact_leaks.json` on disk, or one that fails a first scan.

`tests/test_native_parity.py` feeds both engines thousands of generated
messages - disguised digits, look-alike letters, invisible characters, every
assigned BMP character - and requires identical output. The one documented
gap: Python 3.11 ships Unicode 14 and the Rust crates something newer, so
characters assigned since then may normalize differently.

## Contact-leak rules

`rules/contact_leaks.json` is read by both engines (Rust embeds it at
compile time). Patterns run on normalized text - printable ASCII, lower
case, single spaces - so they must stay in the syntax both engines share:
no lookaround, no backreferences. Rebuild the extension after editing it.

Findings are recorded as `off_platform_solicitation_detected` audit rows,
which `domains/trust/completion_rate.py` reads as a sign the deal leaked,
lowering the seller's rank. A rule has to be precise, not merely suggestive:
`tests/test_text_guard.py` holds the near misses that must stay clean.

## Building and testing

Needs the Rust toolchain in `rust-toolchain.toml` (rustup installs it on
first use).

```bash
cd backend/native
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo clippy --locked --all-targets --features python -- -D warnings
cargo test --locked              # the core, no Python needed

cd ..                            # backend/
pip install ./native             # builds the wheel with maturin, installs broka_native
BROKA_NATIVE=required ENV=test SECRET_KEY=<32+ characters> \
  DATABASE_URL="sqlite+aiosqlite:///:memory:" \
  python -m pytest tests/test_native_parity.py tests/test_text_guard.py -q -o addopts=""
```

The Python bindings (`src/python.rs`) are behind the `python` feature, which
maturin turns on; `cargo test` builds the core alone. `Cargo.lock` is
committed and every build uses `--locked`.

## Adding a function

1. Write it in plain Rust in its own module, with unit tests.
2. Write the Python reference next to where the backend uses it, step for
   step the same.
3. Expose it in `src/python.rs` (release the GIL with `py.detach` around the
   Rust work), add it to `broka_native.pyi`, and bump `API_VERSION` in both
   `src/python.rs` and `api/core/native.py` if an existing signature changed.
4. Add a differential test to `tests/test_native_parity.py`.
