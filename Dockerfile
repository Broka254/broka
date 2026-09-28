# Root-context mirror of backend/Dockerfile, for `docker build .` from the
# repository root. The DEPLOYED image is backend/Dockerfile - render.yaml
# names it explicitly, with dockerContext: ./backend - so this file exists
# only for local root-context builds and must stay behaviourally identical
# to it. Change both together.
#
# A third copy of this file, named `Docker` (no extension), also sat here.
# Docker only ever reads `Dockerfile`, so it built nothing, was referenced
# by nothing, and existed purely to disagree with the other two about how
# the app starts. Removed rather than kept in sync.
# ── Stage 1: the Rust extension (backend/native/) ────────────────────────────
# See backend/Dockerfile for why each step is there.
FROM python:3.11 AS native

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
COPY backend/native/ ./
RUN set -eux; \
    rustup toolchain install "$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)" --profile minimal; \
    maturin build --release --locked --out /wheels

# ── Stage 2: the API ──────────────────────────────────────────────────────────
FROM python:3.11-slim

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --from=native /wheels /tmp/wheels
RUN pip install --no-cache-dir --no-index /tmp/wheels/*.whl && rm -rf /tmp/wheels

COPY backend/ .

ENV BROKA_NATIVE=required

EXPOSE 8000

# No `alembic upgrade head`. The schema is created by init_db() from
# main.py's FastAPI lifespan; the Alembic chain is not the live mechanism
# and does not currently run. backend/Dockerfile carries the full
# explanation, and migrations/README.md the detail.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
