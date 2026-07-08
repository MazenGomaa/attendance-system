# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the app

```bash
# Install dependencies (into the bundled .venv or a fresh venv)
pip install -r requirements.txt

# Launch (interactive CLI prompts for course name, geofence, tunnels, etc.)
python main.py
```

There are no tests and no build step. The app starts, asks a few config questions, then serves on port 8000 (overridden by `PORT` env var).

## Architecture

Three Python files do everything; no database, no migrations, no build pipeline.

**`state.py`** — process-wide singletons:
- `Config` dataclass: session metadata, feature flags, security secrets (all set at startup by `main.py`; never persisted to disk).
- `Store` dataclass: six in-memory structures — `records` (master list), `rid_index` (O(1) rid→record dict), `client_to_rid`, `id_to_rid`, `ip_to_rids`, `seen_ips`. Use `store.add_record(r)` to append; never append to `store.records` directly.
- `admin_lock`: a `threading.Lock` acquired by any code that mutates `Store` while possibly exporting (the export path also holds it).

**`app.py`** — FastAPI application mounted by `main.py`:
- `/api/init` (POST): single round-trip on page load; returns session info + page token + existing record for prefill.
- `/submit` (POST): create-or-edit path; the resolve → dedup → write block has **no `await` inside it**, which is the atomicity guarantee — the single-threaded event loop cannot interleave two submissions mid-block.
- `/admin/*`: state read, reset-devices, new-session, export, download. Admin access is gated by `_check_admin()` which checks password cookie/header first, then falls back to loopback/trusted-CIDR check when no password is set.
- Lifespan hook: exports CSVs on shutdown (Ctrl+C).

**`main.py`** — launcher only:
- Interactive CLI prompts → populates `config` fields.
- Optionally starts 1–4 Cloudflare Quick Tunnels (`cloudflared` binary, found via PATH or next to `main.py`).
- Generates QR codes (ASCII + PNG via `qrcode[pil]`).
- Calls `uvicorn.run(app, workers=1)`.

**`static/`** — plain HTML/CSS/JS, no framework, no bundler:
- `index.html`: student submission form (RTL Arabic, calls `/api/init` then `/submit`).
- `admin.html`: admin dashboard (live count, recent records, merge log, reset/export buttons).
- `login.html`: shown instead of admin dashboard when a password is set and the request is unauthenticated.

**`exports/`** — CSV output directory, created on first run. Two files per session:
- `<session>_Raw.csv`: Name, ID, Submitted_At, Last_Updated, Latitude, Longitude, Accuracy_m, IP.
- `<session>_Audited.csv`: same plus Distance_km, SameIP_Count, Status (written only when geofencing is on).

## Key design constraints

- **`workers=1` is mandatory.** Multiple workers = multiple processes = split in-memory state = broken dedup. Do not add multi-process concurrency.
- **Atomicity via event loop.** The submit critical section avoids `await`, relying on cooperative multitasking to prevent races. Any refactor that adds an `await` inside the `resolve → dedup → write` block in `/submit` breaks this.
- **Roster file** (`roster.csv` or `roster.txt` in the project root): optional; if present, only numeric IDs in it are accepted. First column, one per line, UTF-8-BOM safe.
- **Anti-curl page token**: HMAC signed by `config.page_secret` (generated fresh each run), valid for ~90 s (3 × 30 s buckets). `/submit` rejects requests without one.
- **Admin password** stored as `sha256(salt + pw)` and compared with `hmac.compare_digest`. Salt and hash live only in `config` (memory) for the run.
- **Arabic name validation**: 4+ whitespace-separated tokens, each matching `[؀-ۿ]+`, max 100 chars total.
