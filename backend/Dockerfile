FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

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
