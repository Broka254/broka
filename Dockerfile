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
FROM python:3.11-slim

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ .

EXPOSE 8000

# No `alembic upgrade head`. The schema is created by init_db() from
# main.py's FastAPI lifespan; the Alembic chain is not the live mechanism
# and does not currently run. backend/Dockerfile carries the full
# explanation, and migrations/README.md the detail.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
