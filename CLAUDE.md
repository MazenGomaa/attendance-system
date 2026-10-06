# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the app

```bash
# Windows (also works: double-click run.bat)
python run.py

# Linux / macOS (also works: ./run.sh)
python3 run.py
```

`run.py` is the only entry point. On first run it checks Python 3.9+, creates `.venv`, installs deps from `requirements.txt`, and auto-downloads the correct `cloudflared` binary for the current OS/CPU. Subsequent runs detect and prompt to fix any missing packages, then launch immediately.

Do **not** run `main.py` directly unless the venv is already activated — it has no bootstrap logic. There are no tests and no build step. The app serves on port 8000 (overridden by `PORT` env var).

## Architecture

Three Python files do everything; no database, no migrations, no build pipeline.

**`state.py`** — process-wide singletons:
- `Config` dataclass: session metadata, feature flags, security secrets (all set at startup by `main.py`; never persisted to disk).
- `Store` dataclass: in-memory structures — `records` (master list, edited in place), `rid_index` (O(1) rid→record dict), `client_to_rid`, `id_to_rid`, `ip_to_rids` (flags only, never identity), `seen_ips`, `events` (admin edit/conflict feed), `log` (append-only history of every submission; the Raw CSV). Use `store.add_record(r)` to append; never append to `store.records` directly.
- `admin_lock`: a `threading.Lock` acquired by any code that mutates `Store` while possibly exporting (the export path also holds it).

**`app.py`** — Starlette application mounted by `main.py` (deliberately not FastAPI: no pydantic, so Termux installs need no Rust). Routes register via the `@_route(path, method)` decorator and must return `Response` objects, not dicts:
- `/api/init` (POST): single round-trip on page load; returns session info + page token + existing record for prefill.
- `/submit` (POST): create-or-edit path; the resolve → dedup → write block has **no `await` inside it**, which is the atomicity guarantee — the single-threaded event loop cannot interleave two submissions mid-block. Identity = deviceId/cookie, else existing ID **and** matching name (`name_key()` folds Arabic spelling variants); a taken ID with a different name is refused and logged. Shared IP / GPS proximity must never select a record (CGNAT students share IPs) — they are export flags only. Every outcome goes through `_log()`.
- `/admin/*`: state read, reset-devices, new-session, export, download (`?file=final|raw|audited`), end-session (sets `config.ended` so `/submit` returns 410, exports, copies to Downloads, then calls `config.request_shutdown`, which `main.py` wires to `uvicorn.Server.should_exit`). Admin access is gated by `_check_admin()` which checks password cookie/header first, then falls back to loopback/trusted-CIDR check (Host must be `localhost` or an IP: DNS-rebinding guard) when no password is set. Admin POSTs must send `X-Requested-With: att-admin` (CSRF; enforced in `_SecurityHeaders`).
- Lifespan hook: exports CSVs on shutdown (Ctrl+C).

**`run.py`** — cross-platform bootstrap (the real entry point):
- Checks Python ≥ 3.9, creates `.venv`, installs deps, auto-downloads `cloudflared`.
- On subsequent runs: detects missing packages and offers to install them.
- Delegates to `main.py` via `subprocess.call([venv_python, "main.py"])`.

**`main.py`** — session launcher (called by `run.py`):
- Interactive CLI prompts → populates `config` fields.
- Optionally starts 1–4 Cloudflare Quick Tunnels (`cloudflared` binary, found via PATH or next to `main.py`).
- Generates QR codes (ASCII + PNG via `qrcode[pil]`, or pure-Python `pypng` on Termux).
- Runs `uvicorn.Server(...workers=1)` and sets `config.request_shutdown`; on exit terminates tunnels and runs `termux-wake-unlock` if present.

**`static/`** — plain HTML/CSS/JS, no framework, no bundler:
- `index.html` + `index.js`: student submission form (RTL Arabic, calls `/api/init` then `/submit`).
- `admin.html` + `admin.js`: admin dashboard (live counts incl. out-of-bounds, recent records with distance, edit/conflict log, download/reset buttons).
- `login.html` + `login.js`: shown instead of admin dashboard when a password is set and the request is unauthenticated.
- Keep JavaScript in the `.js` files: the CSP is `script-src 'self'`, so inline `<script>` blocks are blocked.

**`exports/`** — CSV output directory, created on first run. Per session:
- `<session>_Raw.csv`: every submission from `store.log` (created / updated / refused, with Prev_Name/Prev_ID, Maps_Link, Device hash, Note).
- `<session>_Final.csv`: one row per student, plus Edits, Maps_Link, SameIP_Count/SameIP_IDs, SameName_IDs.
- `<session>_Audited.csv`: Final's columns plus Distance_km, Status (written only when geofencing is on).

## Key design constraints

- **`workers=1` is mandatory.** Multiple workers = multiple processes = split in-memory state = broken dedup. Do not add multi-process concurrency.
- **Atomicity via event loop.** The submit critical section avoids `await`, relying on cooperative multitasking to prevent races. Any refactor that adds an `await` inside the `resolve → dedup → write` block in `/submit` breaks this.
- **Roster file** (`roster.csv` or `roster.txt` in the project root): optional; if present, only numeric IDs in it are accepted. First column, one per line, UTF-8-BOM safe.
- **Anti-curl page token**: HMAC signed by `config.page_secret` (generated fresh each run), valid for ~90 s (3 × 30 s buckets). `/submit` rejects requests without one.
- **Admin password** stored as `sha256(salt + pw)` and compared with `hmac.compare_digest`. Salt and hash live only in `config` (memory) for the run.
- **Arabic name validation**: 4+ whitespace-separated tokens, each matching `[؀-ۿ]+`, max 100 chars total.
