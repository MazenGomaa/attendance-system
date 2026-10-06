# Attendance System

> **Note:** This project was built by [Claude](https://claude.com/claude-code) (Anthropic's Claude Code), working iteratively with the project owner across design, implementation, review, and fixes.

A lightweight, self-hosted attendance tool built for Arabic-speaking university classrooms. Students scan a QR code on their phone, enter their name and student ID, and the professor gets a live count and a downloadable CSV — no accounts, no cloud service, no database.

Handles up to ~1000 simultaneous students via Cloudflare Quick Tunnels (free, no account needed).

---

## Quick start

**Only prerequisite: Python 3.9+**

```bash
# Windows
python run.py

# Linux / macOS
python3 run.py

# Termux (Android)
pkg install python
python run.py
```

`run.py` handles everything automatically:
- **First run:** creates a private `.venv`, installs all dependencies, downloads the correct `cloudflared` binary for your OS and CPU.
- **Subsequent runs:** checks for any missing packages (and offers to install them), then launches immediately.

---

## Installation

### Standard (Windows / Linux / macOS)

1. Copy this folder to the machine that will host the session.
2. Run `python run.py` (Windows) or `python3 run.py` (Linux / macOS).
3. Answer the startup prompts (see [Configuration](#configuration)).
4. Share the QR code or tunnel URL with students.

No global installs. Everything lives inside `.venv` in the project folder. To rebuild from scratch, delete `.venv` and re-run `run.py`.

### Termux (Android)

```bash
pkg install python
python run.py
```

PyPI has no prebuilt wheels for Android, so `run.py` detects Termux and installs a lean, pure-Python set instead of `requirements.txt`: `fastapi<0.126`, `pydantic<2`, `uvicorn`, `qrcode`, `pypng`, `python-multipart`. Nothing needs compiling, so it installs in about a minute. Pydantic v1 is used because v2's `pydantic-core` is written in Rust. QR PNGs are written with `pypng` instead of Pillow.

**Python 3.14+ only:** pydantic v1 doesn't run there, so `run.py` falls back to building `pydantic-core` from source. That needs Rust and takes 10–30 minutes:

```bash
pkg install rust binutils
termux-wake-lock          # keep the phone from sleeping during the build
python run.py
```

### Offline rooms

Pre-download wheels on a machine with internet, then ship the `vendor/` folder:

```bash
pip download -r requirements.txt -d vendor
```

Edit the pip line in `run.py` to add `--no-index --find-links vendor`, or install manually:

```bash
python3 -m venv .venv
.venv/bin/pip install --no-index --find-links vendor -r requirements.txt
```

Also place the matching `cloudflared` binary next to `run.py` so no download is attempted.

### Moving between devices

Copy the folder. If the OS or CPU architecture changes, delete `.venv` and the `cloudflared` binary first — `run.py` will rebuild them (takes ~1 min).

---

## Configuration

`run.py` → `main.py` asks six questions at startup:

| Prompt | Default | Notes |
|--------|---------|-------|
| Course / subject name | `Session` | Used in exported filenames |
| Require location + GPS audit? | `N` | When `y`, students must allow location; a post-session audit CSV is written |
| Treat one IP as one device? | `Y` | Blocks browser-switching to submit twice; safe for CGNAT when GPS is off |
| Number of Cloudflare tunnels (1–4) | `2` | Each tunnel adds ~200 concurrent slots; 2 tunnels ≈ 400 students |
| Allow admin from another device on your network? | `N` | Enables admin access from e.g. a tablet on the same hotspot |
| Admin password | *(blank)* | Blank = no password, localhost-only admin; set one when using a shared network |

### Roster validation (optional)

Create `roster.csv` or `roster.txt` in the project root. One student ID per line; anything after a comma is ignored:

```
20231001,Ahmed Ali
20231002
20231003
```

When a roster file is present, only listed IDs are accepted. IDs are matched after stripping leading zeros (`007123` matches `7123`). See `roster.csv.example` for the full format.

### Environment

| Variable | Default | Effect |
|----------|---------|--------|
| `PORT` | `8000` | Override the listen port |

---

## Usage

### For students

1. Scan the QR code shown at startup (or open the tunnel URL on a phone).
2. Enter the 4-part full Arabic name and student ID.
3. If geofencing is on, allow location when prompted.
4. Tap **تسجيل الحضور**. A green confirmation appears.
5. The same device can edit the record any time before the session ends.

### For the professor (admin)

Open `http://localhost:8000/admin` on the host machine (or the admin URL printed at startup if remote admin was enabled).

| Button | Action |
|--------|--------|
| Download CSV | Exports and downloads the current session's CSV |
| Export snapshot | Writes a CSV to `exports/` without downloading |
| Reset for new take | Clears device locks so everyone can re-submit (records are kept) |
| New subject… | Exports current session, clears all records, starts a new session |

The dashboard auto-refreshes every 2 s and shows:
- Live submission / student / merge counts
- The 15 most recent submissions
- A merge log flagging any same-device overwrites for cheating review

Press **Ctrl+C** to stop the server; a final CSV is exported automatically on shutdown.

---

## Project structure

```
.
├── main.py            # Launcher: CLI prompts, tunnel setup, QR codes, uvicorn
├── app.py             # FastAPI application (all endpoints)
├── state.py           # In-memory state: Config and Store dataclasses
├── run.py             # Cross-platform bootstrap (venv + deps + cloudflared)
├── run.bat            # Windows double-click launcher
├── run.sh             # Linux/macOS launcher
├── requirements.txt   # Python dependencies
├── roster.csv.example # Example roster format
├── static/
│   ├── index.html     # Student submission form (RTL Arabic)
│   ├── admin.html     # Admin dashboard
│   └── login.html     # Admin login (shown when a password is set)
└── exports/           # CSV output (created on first run)
    ├── <session>_Raw.csv
    └── <session>_Audited.csv   # only when geofencing is on
```

---

## How it works

### Architecture

Three Python files handle everything — no database, no migrations, no build pipeline.

**`state.py`** holds two process-wide singletons:

- `Config` — session metadata, feature flags, and secrets. Set at startup by `main.py`; never written to disk.
- `Store` — five in-memory structures:
  - `records` — the master list of attendance records (append-only during a session)
  - `rid_index` — `rid → record` dict for O(1) lookup
  - `client_to_rid` — `deviceId / cookie-UUID → rid` (browser identity)
  - `id_to_rid` — `student ID → rid` (authoritative dedup key)
  - `ip_to_rids` — `IP → [rid, …]` (CGNAT-aware, multiple rids per IP)

**`app.py`** is the FastAPI application:

- `/api/init` (POST) — one round-trip on page load; returns session info, page token, and the student's existing record if any.
- `/submit` (POST) — create-or-edit. The resolve → dedup → write block contains **no `await`**, which is the atomicity guarantee: the single-threaded event loop cannot interleave two submissions mid-block.
- `/admin/*` — live state, reset, export, download. Protected by `_check_admin()`.

**`main.py`** is the launcher only: CLI prompts, `cloudflared` tunnels, QR code generation, then `uvicorn.run(app, workers=1)`.

### Identity and deduplication

A submission is matched to an existing record in priority order:

1. **deviceId** (localStorage) or **cookie UUID** — same browser, strongest signal.
2. **IP + GPS proximity** (≤ 3 m) — catches a browser-switch on the same physical phone. Without GPS this path is skipped to avoid merging multiple students sharing a mobile carrier NAT.
3. **Student ID** — used after a "Reset for new take" (device locks cleared but records kept), so the student updates their existing record rather than creating a duplicate.

A new record is created only when no match is found.

### Cloudflare Quick Tunnels

The server binds to `localhost:8000`. Each Cloudflare tunnel is a local `cloudflared` process that proxies an HTTPS URL (e.g. `https://xxx.trycloudflare.com`) to that port over HTTP/2. No Cloudflare account is needed. Two tunnels are opened by default, splitting the class across them to multiply the ~200-concurrent-connection per-tunnel cap.

### GPS audit (when geofencing is on)

Location is **not** checked in real time. Instead, every student's GPS coordinate is stored and, at export time, the median of all coordinates is computed (the lecture hall centre — robust to a minority of remote cheaters). Anyone farther than `audit_radius_km` (configurable at startup, default 0.5 km) is flagged in `_Audited.csv`. Additional flags: shared IP, duplicate GPS location (likely same phone), and zero accuracy (possible spoofed coordinate).

### Security

- **Page token** — HMAC-signed token issued by `/api/init`, valid ~90 s. `/submit` rejects any request without one, blocking bare `curl` scripts.
- **Per-device throttle** — 15 submits per 20 s per deviceId. Terminal on hit (client does not retry). Keyed on device, not IP, so CGNAT groups are not penalised.
- **Per-IP throttle** — secondary 300 new-records per 60 s per real TCP peer, catching bots that rotate deviceId.
- **Admin login throttle** — 5 attempts per 60 s per IP.
- **Admin password** — SHA-256(salt + password), constant-time compare. Salt and hash live in process memory only.
- **IP validation** — forwarding headers (`CF-Connecting-IP`, `X-Forwarded-For`) are only trusted when the direct TCP peer is loopback (i.e. the cloudflared process), preventing LAN clients from spoofing their IP.
- **XSS protection** — all server-supplied values interpolated into admin dashboard HTML are escaped via a `textContent`-based helper.
- **Security headers** — `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`, and a `Content-Security-Policy` are set on every response.

### Export format

**`<session>_Raw.csv`** — one row per student:

| Column | Description |
|--------|-------------|
| Name | Arabic full name |
| ID | Student ID |
| Submitted_At | First submission timestamp |
| Last_Updated | Timestamp of last edit (blank if never edited) |
| Latitude | GPS latitude (blank if geofence off) |
| Longitude | GPS longitude |
| Accuracy_m | GPS accuracy radius in metres |
| IP | Client IP address |

**`<session>_Audited.csv`** — same columns plus:

| Column | Description |
|--------|-------------|
| Distance_km | Distance from median class location |
| SameIP_Count | Number of different student IDs from this IP |
| Status | `Valid`, `SUSPECT: …`, or `FLAGGED: …` |

---

## Design constraints

- **`workers=1` is mandatory.** Multiple workers = multiple processes = split in-memory state = broken dedup.
- **No `await` inside the submit critical section.** The atomicity guarantee depends on cooperative multitasking. Adding an `await` inside the resolve → dedup → write block breaks it.
- **No persistent storage.** All state lives in process memory. A server restart starts a fresh session (the previous session's CSV is exported on shutdown).
