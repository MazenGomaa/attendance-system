# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status (updated 2026-10-07)

- **Python server** (`app.py`, Termux/PC): stable. Recent fixes: no silent overwrites (identity = device/cookie, else same ID + same name), full Raw history, Arabic-digit normalisation, shared `parse_roster()`.
- **Android host app** (`flutter_app/`): Phases 0–3 done and merged (PRs #1–#3). Latest tested APK: GitHub pre-release `app-build-10`, on a Samsung S24 Ultra (Android 16): tunnels, swipe-away survival, crash resume, dashboard, new subject, pre-class check, link-change alerts, outage recovery. See `flutter_app/README.md` for phases and design notes.
- **Location accuracy (after the 2026-10-05 class export)**: false out-of-bounds came from coarse fixes (±100 m / ±2000 m cell-tower centroids). Now: the page watches location ≤10 s for the best fresh fix; Out of bounds needs distance − accuracy > radius, else "Low accuracy (±N m)"; hall = pinned location (`/admin/set-hall`, journal op `hall`; app menu "Pin hall to this phone") or median of fixes ≤100 m; "duplicate location" needs same IP too. Precise-looking 2–3 km outliers in that export are unexplained (stale fixes?): check their Maps links in the next export. Student page shows no accuracy numbers. App has an "Open admin page in browser" button (localhost, so web Pin hall can use GPS). User-tested on `app-build-14`. Class code rejected; time window not built.
- **Manual add (2026-10-08)**: instructor adds a student with no phone/dead battery: `/admin/add-student` (web form) / `addStudent()` (app: Students tab person-add icon or menu), journal op `manual`. Same ID/name/roster rules; same ID + same name = "exists", other name = 409. Record has `manual: true`, no IP/GPS; Raw Match `manual`, Final `Added_Manually` column, Audited status "Added manually" (not "No GPS"). Not yet tested on the phone.
- **Next**: the user's real classroom test (Phase 4). Ask for the session's `_Raw.csv`, the app's Debug → "Copy all" report, and student complaints, then fix what they show.
- **Pending decisions**: class-list import not yet tested on a phone (no list yet); app signing still uses the dev key in the repo (fine while the app is for the user only; before sharing the APK, move signing to a private key in GitHub secrets, since changing keys later forces reinstalls); no official `v1.0.0` release yet (planned after the classroom test).
- **Rejected/deferred**: local Wi-Fi/hotspot mode (browsers block location on plain-HTTP pages; removed), device fingerprinting and rotating QR (not useful enough).
- **Working with the user**: they test on their phone and paste Debug reports; builds come from CI (`.github/workflows/android-apk.yml`), which publishes `app-build-N` pre-releases (latest 5 kept). This cloud environment can't reach `dl.google.com`, so Android builds only happen in CI; the Flutter SDK can be fetched from storage.googleapis.com for `flutter analyze` / `flutter test`.

## Running the app

```bash
# Windows (also works: double-click run.bat)
python run.py

# Linux / macOS (also works: ./run.sh)
python3 run.py
```

`run.py` is the only entry point. On first run it checks Python 3.9+, creates `.venv`, installs deps from `requirements.txt`, and auto-downloads the correct `cloudflared` binary for the current OS/CPU. Subsequent runs detect and prompt to fix any missing packages, then launch immediately.

Do **not** run `main.py` directly unless the venv is already activated — it has no bootstrap logic. The app serves on port 8000 (overridden by `PORT` env var).

## Tests

```bash
tests/parity.sh          # PYTHON=... DART=... (Flutter SDK's dart); runs everything below
python tests/scenarios.py --base http://127.0.0.1:8765 [--mode password|nopassword]
cd flutter_app && flutter test
```

`tests/scenarios.py` is a black-box HTTP spec (stdlib only) run against both the Python server (`tests/serve_python.py`) and the Dart server (`flutter_app/bin/serve.dart`); `parity.sh` also checks the two servers' CSV exports are identical. CI (`.github/workflows/android-apk.yml`) runs it on every push touching either server.

## Architecture

Three Python files do everything; no database, no migrations, no build pipeline.

**`state.py`** — process-wide singletons:
- `Config` dataclass: session metadata, feature flags, security secrets (all set at startup by `main.py`; never persisted to disk).
- `Store` dataclass: in-memory structures — `records` (master list, edited in place), `rid_index` (O(1) rid→record dict), `client_to_rid`, `id_to_rid`, `ip_to_rids` (flags only, never identity), `seen_ips`, `events` (admin edit/conflict feed), `log` (append-only history of every submission; the Raw CSV). Use `store.add_record(r)` to append; never append to `store.records` directly.
- `admin_lock`: a `threading.Lock` acquired by any code that mutates `Store` while possibly exporting (the export path also holds it).

**`app.py`** — Starlette application mounted by `main.py` (deliberately not FastAPI: no pydantic, so Termux installs need no Rust). Routes register via the `@_route(path, method)` decorator and must return `Response` objects, not dicts:
- `/api/init` (POST): single round-trip on page load; returns session info + page token + existing record for prefill.
- `/submit` (POST): create-or-edit path; the resolve → dedup → write block has **no `await` inside it**, which is the atomicity guarantee — the single-threaded event loop cannot interleave two submissions mid-block. Identity = deviceId/cookie, else existing ID **and** matching name (`name_key()` folds Arabic spelling variants); a taken ID with a different name is refused and logged. Shared IP / GPS proximity must never select a record (CGNAT students share IPs) — they are export flags only. Every outcome goes through `_log()`.
- `/admin/*`: state read, add-student (manual entry, no device/IP/GPS), reset-devices, new-session, export, download (`?file=final|raw|audited`), end-session (sets `config.ended` so `/submit` returns 410, exports, copies to Downloads, then calls `config.request_shutdown`, which `main.py` wires to `uvicorn.Server.should_exit`). Admin access is gated by `_check_admin()` which checks password cookie/header first, then falls back to loopback/trusted-CIDR check (Host must be `localhost` or an IP: DNS-rebinding guard) when no password is set. Admin POSTs must send `X-Requested-With: att-admin` (CSRF; enforced in `_SecurityHeaders`).
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

**`flutter_app/`** — Android host app (Flutter): runs the same server, ported to Dart in `lib/server/` (pure `dart:io`, no Flutter imports), plus bundled `cloudflared` tunnels under a foreground service. Built by CI into a GitHub pre-release APK; see `flutter_app/README.md`. The student/admin pages come from `static/` (copied in by `flutter_app/tool/sync_static.sh`).

## Key design constraints

- **Two servers, one behaviour.** `app.py` and `flutter_app/lib/server/` must stay in step: any change to endpoints, messages, identity rules or CSV columns goes into both, with a check in `tests/scenarios.py`; `tests/parity.sh` must pass. The Dart server also writes a journal (`lib/server/model.dart` `Journal`) so the app can resume after being killed; keep every state change journaled.

- **`workers=1` is mandatory.** Multiple workers = multiple processes = split in-memory state = broken dedup. Do not add multi-process concurrency.
- **Atomicity via event loop.** The submit critical section avoids `await`, relying on cooperative multitasking to prevent races. Any refactor that adds an `await` inside the `resolve → dedup → write` block in `/submit` breaks this.
- **Roster file** (`roster.csv` or `roster.txt` in the project root; imported via a file picker in the app): optional; if present, only numeric IDs in it are accepted. First column, one per line, UTF-8-BOM safe, Arabic-Indic digits normalised, leading zeros ignored. Parsed by `parse_roster()` (`app.py`) / `parseRoster()` (Dart); `tests/roster_fixture.csv` + scenario mode `roster` keep them identical.
- **Anti-curl page token**: HMAC signed by `config.page_secret` (generated fresh each run), valid for ~90 s (3 × 30 s buckets). `/submit` rejects requests without one.
- **Admin password** stored as `sha256(salt + pw)` and compared with `hmac.compare_digest`. Salt and hash live only in `config` (memory) for the run.
- **No location hints to students**: the student page and `/submit` replies never show accuracy, distance or in/out status (that would teach cheaters what to fake); those appear only on the admin side and in exports.
- **Arabic name validation**: 4+ whitespace-separated tokens, each matching `[؀-ۿ]+`, max 100 chars total.
- **Student IDs**: Arabic-Indic/Persian digits are normalised to ASCII (`normalize_digits`) before validation, on the page and in both servers.
