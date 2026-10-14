"""The production start path must reach uvicorn without Alembic.

WHY THIS FILE EXISTS
====================
Every Dockerfile in this repository used to start the app with

    sh -c "alembic upgrade head && uvicorn main:app ..."

and that command could never succeed. `requirements.txt` installs asyncpg;
migrations/env.py rewrites postgresql+asyncpg:// to postgresql://, whose
DBAPI is psycopg2, which is not installed - so `alembic upgrade head` died
with ModuleNotFoundError, and because of the `&&`, uvicorn was never
reached. A fresh deploy served no traffic at all.

Installing psycopg2 would not have fixed it: revision 0001 creates
mpesa_transactions.callback_processed and ledger_entries, and 0002 adds
the same column and creates the same table again, so the chain fails on a
fresh database whatever the driver.

The tests below pin both halves - the arrangement that works now, and the
two faults - so that neither "just add psycopg2" nor "put the migration
back in the entrypoint" can be done without a red test explaining why.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
BACKEND = REPO_ROOT / "backend"


def _dockerfiles() -> dict[str, str]:
    """Every Dockerfile in the repo, by path, as text."""
    found = {}
    for path in (REPO_ROOT / "Dockerfile", BACKEND / "Dockerfile"):
        if path.exists():
            found[str(path.relative_to(REPO_ROOT))] = path.read_text()
    return found


def _cmd_line(dockerfile_text: str) -> str:
    for raw in dockerfile_text.splitlines():
        line = raw.strip()
        if line.startswith("CMD") or line.startswith("ENTRYPOINT"):
            return line
    return ""


class TestContainerCommand:
    def test_every_dockerfile_starts_uvicorn(self):
        files = _dockerfiles()
        assert files, "expected at least one Dockerfile"
        for name, text in files.items():
            cmd = _cmd_line(text)
            assert cmd, f"{name} has no CMD/ENTRYPOINT"
            assert "uvicorn" in cmd, f"{name} does not start uvicorn: {cmd}"

    def test_no_dockerfile_runs_alembic(self):
        """The regression itself: uvicorn must not sit behind a migration.

        Guarding the whole file, not just CMD, so a RUN or an entrypoint
        script that shells out to alembic is caught too.
        """
        for name, text in _dockerfiles().items():
            code = "\n".join(
                line for line in text.splitlines()
                if not line.lstrip().startswith("#")
            )
            assert "alembic" not in code.lower(), (
                f"{name} invokes alembic in the deployed image. "
                f"`alembic upgrade head` cannot succeed here - see "
                f"migrations/README.md - and chaining it before uvicorn "
                f"means the container serves nothing."
            )

    def test_command_reaches_uvicorn_when_executed(self):
        """Run the real CMD, with uvicorn stubbed, and prove it is reached.

        The point is the SHAPE of the command, not starting a server: a
        stub named `uvicorn` early on PATH records that it was invoked. If
        the command ever goes back to `alembic ... && uvicorn ...`, alembic
        fails first and the stub is never reached, failing this test.
        """
        cmd_line = _cmd_line((BACKEND / "Dockerfile").read_text())
        args = re.findall(r'"([^"]*)"', cmd_line)
        assert args, f"could not parse CMD: {cmd_line}"

        tmp = BACKEND / ".pytest-docker-cmd"
        tmp.mkdir(exist_ok=True)
        try:
            marker = tmp / "reached"
            stub = tmp / "uvicorn"
            stub.write_text(
                "#!/bin/sh\n"
                f'printf "%s" "$*" > "{marker}"\n'
                "exit 0\n"
            )
            stub.chmod(0o755)

            env = dict(os.environ)
            env["PATH"] = f"{tmp}{os.pathsep}{env.get('PATH', '')}"
            # A shell-form CMD needs a shell; an exec-form one does not.
            if args[:2] == ["sh", "-c"]:
                run = subprocess.run(
                    ["sh", "-c", args[2]], cwd=BACKEND, env=env,
                    capture_output=True, text=True, timeout=120,
                )
            else:
                run = subprocess.run(
                    args, cwd=BACKEND, env=env,
                    capture_output=True, text=True, timeout=120,
                )

            assert marker.exists(), (
                "the container command did not reach uvicorn "
                f"(exit={run.returncode})\nstdout={run.stdout}\nstderr={run.stderr}"
            )
            assert "main:app" in marker.read_text()
            assert run.returncode == 0
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class TestRustExtensionInTheImage:
    """The deployed image carries the Rust extension (backend/native) and
    refuses to run without it; both Dockerfiles build it the same way."""

    def test_every_dockerfile_builds_installs_and_requires_it(self):
        for name, text in _dockerfiles().items():
            assert "maturin build --release --locked" in text, name
            assert "pip install --no-cache-dir --no-index /tmp/wheels/*.whl" in text, name
            assert re.search(r"^ENV BROKA_NATIVE=required$", text, re.M), name

    def test_dockerfiles_pin_the_same_verified_rustup(self):
        pins = {
            name: (re.search(r"RUSTUP_VERSION=(\S+)", text).group(1),
                   sorted(re.findall(r"sha256=([0-9a-f]{64})", text)))
            for name, text in _dockerfiles().items()
        }
        assert len({repr(pin) for pin in pins.values()}) == 1, pins
        assert all(len(hashes) == 2 for _, hashes in pins.values()), pins

    def test_local_build_output_stays_out_of_the_image(self):
        assert "native/target/" in (BACKEND / ".dockerignore").read_text()
        assert "backend/native/target/" in (REPO_ROOT / ".dockerignore").read_text()


class TestRenderConfig:
    def test_render_deploys_the_backend_dockerfile(self):
        cfg = yaml.safe_load((REPO_ROOT / "render.yaml").read_text())
        web = [s for s in cfg["services"] if s.get("type") == "web"][0]
        assert web["dockerfilePath"] == "./backend/Dockerfile"

    def test_render_does_not_advertise_auto_migrations(self):
        """The header claimed "Alembic auto-migrations" it never performed.

        A comment is the only place a deployment claim like this lives, so
        it is the only place a reader can be misled by it.
        """
        text = (REPO_ROOT / "render.yaml").read_text().lower()
        assert "alembic auto-migration" not in text


class TestTheFaultsThatMadeThisNecessary:
    """Both are still true. If either stops being true, revisit the setup."""

    def test_no_sync_postgres_driver_is_installed(self):
        """env.py needs psycopg2 for a postgresql:// URL. Nothing ships it."""
        assert "psycopg2" not in (BACKEND / "requirements.txt").read_text()
        with pytest.raises(ModuleNotFoundError):
            __import__("psycopg2")

    def test_the_migration_chain_is_broken_on_a_fresh_database(self, tmp_path):
        """0001 and 0002 both create ledger_entries and add the same column.

        Run against SQLite so the driver fault above cannot mask this one.
        A chain that fails here fails identically on Postgres.
        """
        if shutil.which("alembic") is None:
            pytest.skip("alembic CLI not installed")
        db = tmp_path / "fresh.db"
        env = dict(os.environ)
        env["DATABASE_URL"] = f"sqlite+aiosqlite:///{db}"
        env.setdefault("SECRET_KEY", "ci-test-secret-key-long-enough-for-testing")
        run = subprocess.run(
            [sys.executable, "-m", "alembic", "upgrade", "head"],
            cwd=BACKEND, env=env, capture_output=True, text=True, timeout=300,
        )
        assert run.returncode != 0, (
            "the Alembic chain now succeeds on a fresh database. If that is "
            "intentional, this test and migrations/README.md both need "
            "updating - and Alembic can be considered for the entrypoint again."
        )
        assert "callback_processed" in (run.stderr + run.stdout)


class TestInitDbIsTheRealMechanism:
    async def test_lifespan_creates_the_schema(self):
        """No Alembic anywhere: init_db() alone must produce a usable schema."""
        from sqlalchemy import select

        from api.database import AsyncSessionLocal, AuctionMeta, Listing, init_db

        await init_db()
        async with AsyncSessionLocal() as db:
            # Tables from create_all(), from the ALTER list, and from a
            # late-registered domain model - one of each kind.
            await db.execute(select(Listing).limit(1))
            await db.execute(select(AuctionMeta.ending_soon_notified_at).limit(1))
            from api.models.store import Store
            await db.execute(select(Store).limit(1))

    def test_main_runs_init_db_on_startup(self):
        text = (BACKEND / "main.py").read_text()
        assert "await init_db()" in text
        assert "lifespan=lifespan" in text
