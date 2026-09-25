#!/usr/bin/env python3
"""Generate graphify.md: a map of this repository for people and coding agents.

    python scripts/graphify.py            # rewrite graphify.md
    python scripts/graphify.py --check    # exit 1 if graphify.md is out of date
    python scripts/graphify.py --stdout   # print it instead

Everything in the map is read from the source - the backend by parsing
Python (ast), the app and the web storefront by pattern - so it can't drift
from the code the way a hand-written overview does. CI regenerates it on
every push to main (.github/workflows/build.yml, job "repo-map").

The output is deterministic: no timestamps, no commit ids, everything
sorted. It changes only when the code's shape does, so regenerating it
doesn't produce a commit on every push.

Standard library only, Python 3.11+.
"""
from __future__ import annotations

import argparse
import ast
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"
APP = ROOT / "flutter_app"
WEB = ROOT / "web"
OUTPUT = ROOT / "graphify.md"

HTTP_METHODS = ("get", "post", "put", "patch", "delete", "websocket")


# ── Small helpers ─────────────────────────────────────────────────────────────

def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def first_line(text: str | None) -> str:
    """The first sentence of a docstring or comment block: its first
    paragraph, cut at the first full stop, decoration lines skipped."""
    if not text:
        return ""
    paragraph: list[str] = []
    for raw in text.strip().splitlines():
        line = raw.strip().strip("=-─#/*").strip()
        if not line or set(line) <= set("=-─_*#"):
            if paragraph:
                break
            continue
        paragraph.append(line)
    return _sentence(" ".join(paragraph))


def _sentence(text: str) -> str:
    match = re.search(r"(?<!\be\.g)(?<!\bi\.e)\.(\s|$)", text)
    return _clip(text[: match.start() + 1] if match else text)


def _clip(text: str, limit: int = 140) -> str:
    text = " ".join(text.split()).replace("|", "\\|")
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def module_doc(path: Path) -> str:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except (SyntaxError, UnicodeDecodeError):
        return ""
    return first_line(ast.get_docstring(tree))


def leading_comment(path: Path) -> str:
    """First sentence of the comment block at the top of a Dart/TS file."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        return ""
    block: list[str] = []
    for line in lines[:40]:
        s = line.strip()
        if s.startswith(("//", "/*", "*")):
            text = s.lstrip("/*").rstrip("*/").strip()
            if text.startswith(("ignore", "eslint", "@ts-", "prettier")):
                continue
            block.append(text)
        elif block or (s and not s.startswith(("import", "'use", '"use', "library", "part"))):
            break
    return first_line("\n".join(block))


def dotted(node: ast.AST) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return f"{dotted(node.value)}.{node.attr}"
    return ""


def module_path(module: str) -> Path:
    base = BACKEND / Path(*module.split("."))
    return base.with_suffix(".py") if base.with_suffix(".py").exists() else base / "__init__.py"


# ── Backend: mounted routers and their endpoints ──────────────────────────────

@dataclass(frozen=True)
class Endpoint:
    method: str
    path: str
    auth: str
    handler: str
    source: str
    shadowed: bool = False


def _auth_of(fn: ast.AST) -> str:
    """Who may call it, from the dependencies in its signature."""
    names = {dotted(n.args[0]) for n in ast.walk(fn)
             if isinstance(n, ast.Call) and dotted(n.func) == "Depends" and n.args}
    names |= {dotted(n.func) for n in ast.walk(fn) if isinstance(n, ast.Call)}
    if "require_admin" in names:
        return "admin"
    if "get_current_user" in names:
        return "user"
    if "get_current_user_optional" in names:
        return "optional"
    return "public"


def _routes_in(path: Path, router_var: str) -> list[tuple[str, str, str, str, int]]:
    """(method, path, auth, handler, line) for each @router_var.<method>(...)."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    out = []
    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for dec in fn.decorator_list:
            if not (isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute)):
                continue
            if dotted(dec.func.value) != router_var or dec.func.attr not in HTTP_METHODS:
                continue
            route = dec.args[0].value if dec.args and isinstance(dec.args[0], ast.Constant) else ""
            method = "WS" if dec.func.attr == "websocket" else dec.func.attr.upper()
            auth = "token" if method == "WS" else _auth_of(fn)
            out.append((method, route, auth, fn.name, fn.lineno))
    return out


def backend_endpoints() -> list[Endpoint]:
    main = BACKEND / "main.py"
    tree = ast.parse(main.read_text(encoding="utf-8"))

    # Local name -> (module, attribute) for everything main.py imports.
    names: dict[str, tuple[str, str | None]] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            for alias in node.names:
                local = alias.asname or alias.name
                if node.module == "api.routers" or module_path(f"{node.module}.{alias.name}").exists():
                    names[local] = (f"{node.module}.{alias.name}", None)     # a module
                else:
                    names[local] = (node.module, alias.name)                 # an object in it

    endpoints: list[Endpoint] = []
    includes = sorted(
        (n for n in ast.walk(tree)
         if isinstance(n, ast.Call) and dotted(n.func) == "app.include_router" and n.args),
        key=lambda n: (n.lineno, n.col_offset),
    )
    for node in includes:
        target = node.args[0]
        prefix = next((k.value.value for k in node.keywords
                       if k.arg == "prefix" and isinstance(k.value, ast.Constant)), "")
        if isinstance(target, ast.Attribute) and isinstance(target.value, ast.Name):
            module, _ = names.get(target.value.id, (None, None))
            var = target.attr
        elif isinstance(target, ast.Name):
            module, var = names.get(target.id, (None, None))
        else:
            continue
        if not module or not var:
            continue
        path = module_path(module)
        if not path.exists():
            continue
        for method, route, auth, handler, line in _routes_in(path, var):
            endpoints.append(Endpoint(method, f"{prefix}{route}" or "/", auth, handler,
                                      f"{rel(path)}:{line}"))

    for method, route, auth, handler, line in _routes_in(main, "app"):
        endpoints.append(Endpoint(method, route, auth, handler, f"{rel(main)}:{line}"))

    # FastAPI serves the first route registered for a method and path; a
    # later one with the same pair is never reached.
    seen: set[tuple[str, str]] = set()
    marked = []
    for e in endpoints:
        key = (e.method, e.path)
        marked.append(Endpoint(e.method, e.path, e.auth, e.handler, e.source, key in seen))
        seen.add(key)

    order = {m: i for i, m in enumerate(("GET", "POST", "PUT", "PATCH", "DELETE", "WS"))}
    return sorted(set(marked), key=lambda e: (e.path, order.get(e.method, 9), e.shadowed, e.handler))


# ── Backend: modules, models, dependencies, jobs, settings ────────────────────

def backend_packages() -> dict[str, list[tuple[str, str]]]:
    """Domain/core package -> [(file, docstring line)]."""
    groups: dict[str, list[tuple[str, str]]] = {}
    for domain in sorted((BACKEND / "api" / "domains").iterdir()):
        if domain.is_dir() and not domain.name.startswith("_"):
            files = [(p.name, module_doc(p)) for p in sorted(domain.glob("*.py"))
                     if p.name != "__init__.py" or module_doc(p)]
            if files:
                groups[f"api/domains/{domain.name}"] = files
    for sub in ("core", "models", "routers"):
        files = [(p.name, module_doc(p)) for p in sorted((BACKEND / "api" / sub).glob("*.py"))
                 if p.name != "__init__.py"]
        groups[f"api/{sub}"] = files
    return groups


def backend_models() -> list[tuple[str, str, str]]:
    """(table, class, source) for every SQLAlchemy model."""
    out = []
    for path in [BACKEND / "api" / "database.py", *sorted((BACKEND / "api" / "models").glob("*.py"))]:
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for cls in tree.body:
            if not isinstance(cls, ast.ClassDef):
                continue
            for stmt in cls.body:
                if (isinstance(stmt, ast.Assign) and any(dotted(t) == "__tablename__" for t in stmt.targets)
                        and isinstance(stmt.value, ast.Constant)):
                    out.append((stmt.value.value, cls.name, f"{rel(path)}:{cls.lineno}"))
    return sorted(out)


def _unit_of(module: str) -> str | None:
    """'api.domains.stores.service' -> 'domains.stores'; 'api.core.x' -> 'core.x'."""
    parts = module.split(".")
    if len(parts) >= 3 and parts[:2] == ["api", "domains"]:
        return f"domains.{parts[2]}"
    if len(parts) >= 3 and parts[:2] == ["api", "core"]:
        return f"core.{parts[2]}"
    if len(parts) >= 2 and parts[0] == "api" and parts[1] in ("database", "security", "schemas"):
        return parts[1]
    if len(parts) >= 3 and parts[:2] == ["api", "routers"]:
        return f"routers.{parts[2]}"
    return None


def domain_dependencies() -> dict[str, set[str]]:
    """Domain -> the other domains and core modules it imports (anywhere in
    the file, including imports inside functions)."""
    deps: dict[str, set[str]] = defaultdict(set)
    for domain in sorted((BACKEND / "api" / "domains").iterdir()):
        if not domain.is_dir():
            continue
        me = f"domains.{domain.name}"
        for path in domain.rglob("*.py"):
            tree = ast.parse(path.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                modules = []
                if isinstance(node, ast.ImportFrom):
                    if node.level:                       # relative: inside this domain
                        continue
                    if node.module:
                        modules.append(node.module)
                        modules += [f"{node.module}.{a.name}" for a in node.names]
                elif isinstance(node, ast.Import):
                    modules += [a.name for a in node.names]
                for m in modules:
                    unit = _unit_of(m)
                    if unit and unit != me and (unit.count(".") == 1 or unit in ("database", "security", "schemas")):
                        deps[me].add(unit)
            deps.setdefault(me, set())
    # "core.x" entries that are really packages' attributes collapse to real modules.
    real_core = {f"core.{p.stem}" for p in (BACKEND / "api" / "core").glob("*.py")} | {
        f"core.{p.name}" for p in (BACKEND / "api" / "core").iterdir() if p.is_dir()}
    real_domains = {f"domains.{p.name}" for p in (BACKEND / "api" / "domains").iterdir() if p.is_dir()}
    for me in deps:
        deps[me] = {d for d in deps[me] if d in real_core or d in real_domains
                    or d in ("database", "security", "schemas")}
    return deps


def background_jobs() -> list[tuple[str, str, str]]:
    path = BACKEND / "api" / "core" / "workers.py"
    tree = ast.parse(path.read_text(encoding="utf-8"))
    return sorted(
        (fn.name, first_line(ast.get_docstring(fn)), f"{rel(path)}:{fn.lineno}")
        for fn in tree.body
        if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)) and fn.name.startswith("task_")
    )


def environment_variables() -> list[str]:
    text = (BACKEND / "api" / "core" / "config.py").read_text(encoding="utf-8")
    found = set(re.findall(r"""os\.(?:getenv|environ\.get)\(\s*["']([A-Z][A-Z0-9_]+)["']""", text))
    return sorted(found)


def backend_tests() -> list[tuple[str, str]]:
    return [(p.name, module_doc(p)) for p in sorted((BACKEND / "tests").glob("test_*.py"))]


# ── Flutter app ───────────────────────────────────────────────────────────────

def app_routes() -> list[tuple[str, str]]:
    text = (APP / "lib" / "main.dart").read_text(encoding="utf-8")
    return sorted(set(re.findall(r"'(/[\w\-/]*)'\s*:\s*\([^)]*\)\s*=>\s*(?:const\s+)?(\w+)", text)))


def app_areas() -> dict[str, list[tuple[str, str]]]:
    lib = APP / "lib"
    out: dict[str, list[tuple[str, str]]] = {}
    for feature in sorted((lib / "features").iterdir()):
        if feature.is_dir():
            files = sorted(feature.rglob("*.dart"))
            out[f"lib/features/{feature.name}"] = [
                (f.relative_to(feature).as_posix(), leading_comment(f)) for f in files]
    for sub in ("core", "services", "models", "utils", "widgets", "theme", "data"):
        d = lib / sub
        if d.is_dir():
            out[f"lib/{sub}"] = [(f.relative_to(d).as_posix(), leading_comment(f))
                                 for f in sorted(d.rglob("*.dart"))]
    return out


def app_screens() -> list[str]:
    return sorted(p.name for p in (APP / "lib" / "screens").glob("*.dart"))


def app_tests() -> list[tuple[str, str]]:
    return [(p.name, leading_comment(p)) for p in sorted((APP / "test").glob("*_test.dart"))]


# ── Web storefront ────────────────────────────────────────────────────────────

def web_routes() -> list[tuple[str, str, str]]:
    app_dir = WEB / "src" / "app"
    out = []
    for f in sorted(list(app_dir.rglob("page.tsx")) + list(app_dir.rglob("route.ts"))):
        parts = f.relative_to(app_dir).parent.parts
        url = "/" + "/".join(re.sub(r"^\[(.+)\]$", r":\1", p) for p in parts)
        kind = "page" if f.name == "page.tsx" else "route"
        out.append((url if url != "/." else "/", kind, leading_comment(f)))
    return out


def web_lib() -> list[tuple[str, str]]:
    files = sorted((WEB / "src" / "lib").glob("*.ts")) + sorted((WEB / "src" / "components").glob("*.tsx"))
    return [(rel(f), leading_comment(f)) for f in files if not f.name.endswith((".test.ts", ".test.tsx"))]


# ── CI and docs ───────────────────────────────────────────────────────────────

def ci_jobs() -> list[tuple[str, str, str]]:
    out = []
    for wf in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        in_jobs = False
        job = None
        for line in wf.read_text(encoding="utf-8").splitlines():
            if re.match(r"^jobs:\s*$", line):
                in_jobs = True
                continue
            if in_jobs and re.match(r"^\S", line):
                in_jobs = False
            if not in_jobs:
                continue
            m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if m:
                job = m.group(1)
                continue
            m = re.match(r"^    name:\s*(.+)$", line)
            if m and job:
                out.append((rel(wf), job, m.group(1).strip().strip("'\"")))
                job = None
    return out


def docs() -> list[tuple[str, str]]:
    out = []
    for md in sorted(ROOT.glob("*.md")):
        if md.name == OUTPUT.name:
            continue
        title = ""
        for line in md.read_text(encoding="utf-8").splitlines():
            if line.startswith("#"):
                title = _clip(line.lstrip("#").strip())
                break
        out.append((md.name, title))
    return out


# ── Rendering ─────────────────────────────────────────────────────────────────

START_HERE = """\
BROKA is a mobile marketplace for East Africa: buyers and sellers deal through
Zeno, an AI broker, and money moves through escrow (E-Confirm; legacy M-Pesa
flows). Three deployables share this repository:

| Part | What it is | Runs on |
|---|---|---|
| `backend/` | FastAPI API, async SQLAlchemy. Entry point `backend/main.py` | Render (Postgres + Redis) |
| `flutter_app/` | The Android/iOS app. Entry point `flutter_app/lib/main.dart` | Phones; APK from CI releases |
| `web/` | Next.js web storefront at `broka.co.ke/store/<name>` | Vercel |

Read `AGENTS.md` first for how to build, test and change things safely.

Where things usually are:

- **An API endpoint** — the Endpoints table below gives its handler's file and
  line. Domain code lives in `backend/api/domains/<area>/` (`router.py` is
  HTTP only, `service.py` holds the logic); older routes are in
  `backend/api/routers/`.
- **A table or column** — Data model below. New columns on existing tables
  are added in `init_db()`'s `migrations` list in `backend/api/database.py`
  (Alembic does not run on deploy).
- **Money** — `backend/api/domains/escrow/`, `backend/api/routers/mpesa.py`,
  `backend/api/core/ledger.py`, `backend/api/core/reconciliation.py`, and the
  timed sweeps in `backend/api/core/workers.py`.
- **A screen in the app** — App routes below map route names to widgets;
  most screens are in `flutter_app/lib/screens/`, newer features in
  `flutter_app/lib/features/<feature>/`.
- **Tests** — `backend/tests/test_<area>*.py`, `flutter_app/test/`,
  `web/src/**/*.test.ts(x)`.
"""


def render() -> str:
    out: list[str] = []
    w = out.append

    w("# BROKA repository map")
    w("")
    w("> Generated by `scripts/graphify.py` from the source. Do not edit by hand:")
    w("> CI regenerates it on every push to `main`. Run `python scripts/graphify.py`")
    w("> to refresh it locally.")
    w("")
    w("## Contents")
    w("")
    for title in ("Start here", "Backend endpoints", "Backend modules", "Data model",
                  "Backend dependencies between domains", "Background jobs",
                  "Configuration (environment variables)", "Backend tests", "Flutter app",
                  "Web storefront", "CI", "Documents"):
        anchor = re.sub(r"[^a-z0-9 -]", "", title.lower()).replace(" ", "-")
        w(f"- [{title}](#{anchor})")
    w("")

    w("## Start here")
    w("")
    w(START_HERE)

    endpoints = backend_endpoints()
    w("## Backend endpoints")
    w("")
    live = [e for e in endpoints if not e.shadowed]
    by_auth = defaultdict(int)
    for e in live:
        by_auth[e.auth] += 1
    w(f"{len(live)} endpoints served by `backend/main.py`. **Auth** is read from each")
    w("handler's dependencies: `public` (none), `optional` (a token is used if sent),")
    w("`user` (sign-in required), `admin`, `token` (WebSocket, checks its own token).")
    w("Counts: " + ", ".join(f"{k} {by_auth[k]}" for k in sorted(by_auth)) + ".")
    w("")
    w("| Method | Path | Auth | Handler |")
    w("|---|---|---|---|")
    for e in endpoints:
        note = " **shadowed: never reached**" if e.shadowed else ""
        w(f"| {e.method} | `{e.path}` | {e.auth} | `{e.handler}` ({e.source}){note} |")
    w("")

    w("## Backend modules")
    w("")
    for group, files in backend_packages().items():
        w(f"### `backend/{group}/`")
        w("")
        for name, doc in files:
            w(f"- `{name}`" + (f" — {doc}" if doc else ""))
        w("")

    w("## Data model")
    w("")
    w("| Table | Model | Defined at |")
    w("|---|---|---|")
    for table, cls, source in backend_models():
        w(f"| `{table}` | `{cls}` | {source} |")
    w("")

    w("## Backend dependencies between domains")
    w("")
    w("What each `backend/api/domains/<area>` imports from other domains and from")
    w("`api/core` (imports inside functions included). Useful for the blast radius")
    w("of a change.")
    w("")
    for domain, deps in sorted(domain_dependencies().items()):
        doms = sorted(d.split(".", 1)[1] for d in deps if d.startswith("domains."))
        core = sorted(d.split(".", 1)[1] for d in deps if d.startswith("core."))
        other = sorted(d for d in deps if "." not in d)
        parts = []
        if doms:
            parts.append("domains: " + ", ".join(doms))
        if core:
            parts.append("core: " + ", ".join(core))
        if other:
            parts.append(", ".join(other))
        w(f"- **{domain.split('.', 1)[1]}** — " + ("; ".join(parts) if parts else "nothing outside itself"))
    w("")

    w("## Background jobs")
    w("")
    w("`task_*` functions in `backend/api/core/workers.py`: the in-process sweep")
    w("(every 5 minutes) and ARQ workers.")
    w("")
    for name, doc, source in background_jobs():
        w(f"- `{name}` ({source})" + (f" — {doc}" if doc else ""))
    w("")

    w("## Configuration (environment variables)")
    w("")
    w("Read by `backend/api/core/config.py`; documented in `.env.example` and")
    w("`render.yaml`. The web storefront's are in `web/.env.example`.")
    w("")
    w(", ".join(f"`{v}`" for v in environment_variables()))
    w("")

    tests = backend_tests()
    w("## Backend tests")
    w("")
    w(f"{len(tests)} files in `backend/tests/`.")
    w("")
    for name, doc in tests:
        w(f"- `{name}`" + (f" — {doc}" if doc else ""))
    w("")

    w("## Flutter app")
    w("")
    w("### Routes (`flutter_app/lib/main.dart`)")
    w("")
    w("| Route | Widget |")
    w("|---|---|")
    for route, widget in app_routes():
        w(f"| `{route}` | `{widget}` |")
    w("")
    for area, files in app_areas().items():
        w(f"### `flutter_app/{area}/`")
        w("")
        for name, doc in files:
            w(f"- `{name}`" + (f" — {doc}" if doc else ""))
        w("")
    screens = app_screens()
    w(f"### `flutter_app/lib/screens/` ({len(screens)} files)")
    w("")
    w(", ".join(f"`{s}`" for s in screens))
    w("")
    w("### Tests (`flutter_app/test/`)")
    w("")
    for name, doc in app_tests():
        w(f"- `{name}`" + (f" — {doc}" if doc else ""))
    w("")

    w("## Web storefront")
    w("")
    w("Routes under `web/src/app/` (`:name` is a dynamic segment):")
    w("")
    w("| Path | Kind | What it is |")
    w("|---|---|---|")
    for url, kind, doc in web_routes():
        w(f"| `{url}` | {kind} | {doc} |")
    w("")
    w("Modules:")
    w("")
    for name, doc in web_lib():
        w(f"- `{name}`" + (f" — {doc}" if doc else ""))
    w("")

    w("## CI")
    w("")
    w("| Workflow | Job | Name |")
    w("|---|---|---|")
    for wf, job, name in ci_jobs():
        w(f"| `{wf}` | `{job}` | {name} |")
    w("")

    w("## Documents")
    w("")
    for name, title in docs():
        w(f"- `{name}`" + (f" — {title}" if title else ""))
    w("")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="exit 1 if graphify.md is out of date")
    mode.add_argument("--stdout", action="store_true", help="print the map instead of writing it")
    args = parser.parse_args(argv)

    text = render()
    if args.stdout:
        sys.stdout.write(text)
        return 0
    current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
    if args.check:
        if current != text:
            print("graphify.md is out of date: run python scripts/graphify.py", file=sys.stderr)
            return 1
        return 0
    if current != text:
        OUTPUT.write_text(text, encoding="utf-8")
        print(f"wrote {rel(OUTPUT)}")
    else:
        print(f"{rel(OUTPUT)} is up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
