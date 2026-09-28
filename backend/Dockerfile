# ── Stage 1: the Rust extension (native/) ────────────────────────────────────
# Compiled into a wheel here and installed in the runtime stage below, so the
# image that serves traffic carries no compiler. The full python:3.11 image
# already has the C linker, curl and CA certificates (no apt-get step to
# break), and is the same Debian release as the slim runtime image: the
# wheel links against the glibc it will run on.
FROM python:3.11 AS native

# rustup-init pinned and checked against its SHA-256, the way the official
# rust images install it. The compiler version is native/rust-toolchain.toml's.
ARG RUSTUP_VERSION=1.29.1
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) target=x86_64-unknown-linux-gnu; sha256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71 ;; \
      arm64) target=aarch64-unknown-linux-gnu; sha256=15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433 ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/rustup-init \
      "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${target}/rustup-init"; \
    echo "${sha256}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none; \
    rm /tmp/rustup-init
RUN pip install --no-cache-dir "maturin==1.15.0"

WORKDIR /build
COPY native/ ./
# --locked: exactly the dependency versions in Cargo.lock, or fail.
RUN set -eux; \
    rustup toolchain install "$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)" --profile minimal; \
    maturin build --release --locked --out /wheels

# ── Stage 2: the API ──────────────────────────────────────────────────────────
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --from=native /wheels /tmp/wheels
RUN pip install --no-cache-dir --no-index /tmp/wheels/*.whl && rm -rf /tmp/wheels

COPY . .

# The image is built with the extension, so it runs with it or not at all:
# validate_startup() refuses to start if it can't load (api/core/native.py).
# BROKA_NATIVE=off in the service's environment overrides this - the kill
# switch, which runs the Python fallback.
ENV BROKA_NATIVE=required

EXPOSE 8000

# Schema is created by init_db(), which main.py's FastAPI lifespan runs on
# startup. Alembic is NOT run here, deliberately:
#
#   * requirements.txt installs asyncpg only. migrations/env.py rewrites
#     postgresql+asyncpg:// to postgresql://, whose DBAPI is psycopg2 -
#     which is not installed. `alembic upgrade head` therefore died with
#     ModuleNotFoundError before uvicorn was ever reached, and because the
#     command was `alembic ... && uvicorn ...`, the container never served
#     a request.
#   * Installing psycopg2 would NOT fix it: the chain is internally
#     inconsistent. 0001 creates mpesa_transactions.callback_processed and
#     ledger_entries; 0002 adds the same column and creates the same table
#     again, so a fresh database fails on "duplicate column name:
#     callback_processed" regardless of driver.
#
# init_db() is the real mechanism - create_all() plus idempotent ALTERs and
# index patches - and is what every environment, including tests, has
# actually been using. See migrations/README.md before touching Alembic.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
