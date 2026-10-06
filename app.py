"""
app.py
------
Starlette app: student create/edit endpoints, admin endpoints, and the lifespan
hook that exports CSVs (raw + GPS-audited) on shutdown.
"""

import asyncio
import csv
import hashlib
import hmac
import ipaddress
import math
import os
import re
import shutil
import time as _time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from statistics import median

# Plain Starlette, not FastAPI: no pydantic, so nothing needs compiling
# (pydantic-core is Rust, and Termux/Android has no prebuilt wheels for it).
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import (JSONResponse, FileResponse, HTMLResponse,
                                 RedirectResponse, Response)
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles

from state import config, store, admin_lock

ID_RE = re.compile(r"^[0-9]{1,20}$")   # ASCII only; normalize_digits() runs first
ARABIC_WORD_RE = re.compile(r"^[؀-ۿ]+$")
MIN_NAME_PARTS = 4
COOKIE_NAME = "att_token"
DEVICE_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")

HERE = os.path.dirname(os.path.abspath(__file__))
EXPORT_DIR = os.path.join(HERE, "exports")
os.makedirs(EXPORT_DIR, exist_ok=True)


# Arabic-Indic (٠-٩) and Persian (۰-۹) digits -> ASCII, so IDs typed on an
# Arabic keyboard validate and match the roster.
_DIGITS = {**{0x0660 + i: str(i) for i in range(10)}, **{0x06F0 + i: str(i) for i in range(10)}}


def normalize_digits(s: str) -> str:
    return s.translate(_DIGITS)


def valid_id(s: str) -> bool:
    return bool(ID_RE.match(s))


def valid_name(s: str):
    parts = s.split()
    if len(parts) < MIN_NAME_PARTS:
        return False, s
    if any(not ARABIC_WORD_RE.match(p) for p in parts):
        return False, s
    if len(" ".join(parts)) > 100:
        return False, s
    return True, " ".join(parts)


def haversine_km(lat1, lng1, lat2, lng2) -> float:
    R = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(a))


# Arabic spelling variants students type interchangeably (أ/إ/آ/ا, ة/ه, ى/ي),
# plus tatweel and diacritics, are folded before names are compared.
_AR_FOLD = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا",
                          "ة": "ه", "ى": "ي", "ـ": None})
_AR_MARKS = re.compile(r"[\u064B-\u0652\u0670]")


def name_key(name: str) -> str:
    """Comparison form of a name: folds spelling variants, ignores diacritics."""
    return " ".join(_AR_MARKS.sub("", name).translate(_AR_FOLD).split())


def edit_kind(old_id, old_name, new_id, new_name) -> str:
    same_id = old_id == new_id
    same_name = name_key(old_name) == name_key(new_name)
    if same_id and same_name:
        return "same student"
    if same_name:
        return "ID corrected"
    if same_id:
        return "name corrected"
    return "different student"


def _is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def maps_link(lat, lng) -> str:
    if _is_num(lat) and _is_num(lng):
        return f"https://www.google.com/maps?q={lat:.6f},{lng:.6f}"
    return ""


def device_tag(device_id: str) -> str:
    """Short, non-reversible label so the export can show 'same browser'."""
    return hashlib.sha256(device_id.encode()).hexdigest()[:8]


def hall_center(rows):
    """Median of all GPS points: robust to a minority of remote cheaters."""
    pts = [(r["lat"], r["lng"]) for r in rows if _is_num(r.get("lat")) and _is_num(r.get("lng"))]
    if not pts:
        return None, None
    return median(p[0] for p in pts), median(p[1] for p in pts)


def _cell(v) -> str:
    """Neutralise spreadsheet formulas (=, +, -, @) in free-text CSV cells."""
    v = "" if v is None else str(v)
    return "'" + v if v[:1] in ("=", "+", "-", "@", "\t", "\r") else v


# ---------------------------------------------------------------------------
# Export, three files per session:
#   _Raw.csv      every submission in order: creates, edits, refused ID
#                 conflicts, with the values an edit replaced. Nothing is lost.
#   _Final.csv    one row per student (current values) + shared-IP columns.
#   _Audited.csv  Final + distance from the hall + status (geofence only).
# ---------------------------------------------------------------------------

def _shared_ip_ids(rows):
    by_ip = {}
    for r in rows:
        if r.get("ip"):
            by_ip.setdefault(r["ip"], []).append(r["id"])
    return lambda r: [i for i in by_ip.get(r.get("ip"), []) if i != r["id"]]


def _same_name_ids(rows):
    by_name = {}
    for r in rows:
        by_name.setdefault(name_key(r["name"]), []).append(r["id"])
    return lambda r: [i for i in by_name.get(name_key(r["name"]), []) if i != r["id"]]


def _write_raw(log, base):
    path = os.path.join(EXPORT_DIR, f"{base}_Raw.csv")
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["Seq", "Time", "Action", "Match", "Record", "Name", "ID",
                    "Prev_Name", "Prev_ID", "Latitude", "Longitude", "Accuracy_m",
                    "Maps_Link", "IP", "Device", "Note"])
        for e in log:
            w.writerow([
                e["seq"], e["time"], e["action"], e["match"], (e["rid"] or "")[:8],
                _cell(e["name"]), _cell(e["id"]),
                _cell(e.get("prev_name")), _cell(e.get("prev_id")),
                "" if e["lat"] is None else e["lat"], "" if e["lng"] is None else e["lng"],
                "" if e["acc"] is None else round(e["acc"]),
                maps_link(e["lat"], e["lng"]), e["ip"], e["device"], _cell(e.get("note")),
            ])
    return path


def _write_final(rows, log, base):
    path = os.path.join(EXPORT_DIR, f"{base}_Final.csv")
    same_ip, same_name = _shared_ip_ids(rows), _same_name_ids(rows)
    edits = {}
    for e in log:
        if e["action"] == "updated":
            edits[e["rid"]] = edits.get(e["rid"], 0) + 1
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["Name", "ID", "Submitted_At", "Last_Updated", "Edits",
                    "Latitude", "Longitude", "Accuracy_m", "Maps_Link",
                    "IP", "SameIP_Count", "SameIP_IDs", "SameName_IDs"])
        for r in rows:
            ips, names = same_ip(r), same_name(r)
            w.writerow([
                _cell(r["name"]), _cell(r["id"]), r["timestamp"], r.get("edited_at") or "",
                edits.get(r["rid"], 0),
                "" if r.get("lat") is None else r["lat"],
                "" if r.get("lng") is None else r["lng"],
                "" if r.get("acc") is None else round(r["acc"]),
                maps_link(r.get("lat"), r.get("lng")),
                r.get("ip", ""), len(ips) + 1, " ".join(ips), " ".join(names),
            ])
    return path


def _write_csv(rows, log, base, reason="export"):
    """
    Synchronous CSV writer. Call via asyncio.to_thread in async contexts so disk
    I/O does not block the event loop while students are still submitting.
    Returns (final_path, audit_path_or_None); the Raw log is written alongside.
    """
    raw_path = _write_raw(log, base)
    final_path = _write_final(rows, log, base)
    print(f"\n[export:{reason}] {len(rows)} students, {len(log)} submissions -> "
          f"{os.path.basename(final_path)}, {os.path.basename(raw_path)}")

    audit_path = None
    if config.geofence:
        audit_path = _audit_csv(rows, base)
    return final_path, audit_path


def export_csv(reason: str = "shutdown"):
    """Snapshot current records and write CSVs synchronously (for shutdown path)."""
    with admin_lock:
        rows = list(store.records)
        log = list(store.log)
    base = config.session_id()
    return _write_csv(rows, log, base, reason)


def _audit_csv(rows, base):
    """
    SWARM AUDIT + DEVICE-SHARING DETECTION.

    1) Location: the lecture hall is the MEDIAN of all coordinates (robust to a
       minority of remote cheaters). Flag anyone beyond config.audit_radius_km.
    2) Same-device detection: multiple submissions (different IDs) from ONE IP
       suggest someone registering absent friends. Flagged, not auto-rejected,
       because students on mobile data can legitimately share a carrier/CGNAT IP.
    """
    audit_path = os.path.join(EXPORT_DIR, f"{base}_Audited.csv")
    same_ip, same_name = _shared_ip_ids(rows), _same_name_ids(rows)
    hall_lat, hall_lng = hall_center(rows)

    # Spatial grid for O(n) near-duplicate GPS detection (was O(n²)).
    # Each cell is ~8 m; we check the 3×3 neighbourhood so no pair is missed.
    _CELL_DEG = 0.008 / 111.0   # 8 m expressed in degrees
    gps_grid: dict = {}
    for r in rows:
        if _is_num(r.get("lat")):
            gx = int(r["lat"] / _CELL_DEG)
            gy = int(r["lng"] / _CELL_DEG)
            gps_grid.setdefault((gx, gy), []).append(r)

    def near_duplicate_gps(r):
        """True if a *different* student's record sits within ~8 m (likely same phone)."""
        if not _is_num(r.get("lat")):
            return False
        gx = int(r["lat"] / _CELL_DEG)
        gy = int(r["lng"] / _CELL_DEG)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for o in gps_grid.get((gx + dx, gy + dy), []):
                    if o is r or o["id"] == r["id"]:
                        continue
                    if haversine_km(r["lat"], r["lng"], o["lat"], o["lng"]) * 1000 <= 8:
                        return True
        return False

    flagged = 0
    with open(audit_path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["Name", "ID", "Submitted_At", "Last_Updated",
                    "Latitude", "Longitude", "Accuracy_m", "Maps_Link",
                    "Distance_km", "IP", "SameIP_Count", "SameIP_IDs", "Status"])
        for r in rows:
            ip = r.get("ip") or "unknown"
            ips = same_ip(r)
            lat, lng = r.get("lat"), r.get("lng")
            acc = r.get("acc")
            notes = []

            if _is_num(lat) and hall_lat is not None:
                d = haversine_km(hall_lat, hall_lng, lat, lng)
                dist = round(d, 3)
                if d > config.audit_radius_km:
                    notes.append("Out of bounds")
            else:
                dist = ""
                notes.append("No GPS")

            if ips:
                notes.append(f"shared IP x{len(ips) + 1}")
            if near_duplicate_gps(r):
                notes.append("duplicate location")
            if same_name(r):
                notes.append("same name as ID " + "/".join(same_name(r)))
            if _is_num(lat) and (acc is None or acc == 0):
                notes.append("no accuracy (possible spoof)")

            if notes:
                status = ("FLAGGED: " if ("Out of bounds" in notes or "No GPS" in notes)
                          else "SUSPECT: ") + ", ".join(notes)
                flagged += 1
            else:
                status = "Valid"

            w.writerow([
                _cell(r["name"]), _cell(r["id"]),
                r["timestamp"], r.get("edited_at") or "",
                lat if lat is not None else "", lng if lng is not None else "",
                "" if acc is None else round(acc), maps_link(lat, lng),
                dist, ip, len(ips) + 1, " ".join(ips), status,
            ])

    center = f"~({hall_lat:.5f}, {hall_lng:.5f})" if hall_lat is not None else "n/a (no GPS)"
    print(f"[audit] hall center {center} | radius {config.audit_radius_km} km | "
          f"flagged {flagged}/{len(rows)} -> {audit_path}")
    return audit_path


@asynccontextmanager
async def lifespan(app: Starlette):
    print(f"[lifespan] session '{config.session_id()}' started")
    yield
    try:
        await asyncio.to_thread(export_csv, "shutdown")
    except Exception as e:
        # Last-resort: dump records to stdout so nothing is lost even on PermissionError
        # (e.g., Windows file lock when the CSV is open in Excel).
        print(f"[export:shutdown] ERROR writing CSV: {e}")
        for r in store.records:
            print(r)


_routes = []


def _route(path: str, method: str):
    """Collect handlers for the Starlette() constructor at the bottom of the file."""
    def deco(fn):
        _routes.append(Route(path, fn, methods=[method]))
        return fn
    return deco


MAX_BODY = 16 * 1024   # largest legitimate POST is a few hundred bytes
ADMIN_HEADER = "x-requested-with"   # admin.js/login.js send "att-admin"


class _BodyLimit:
    """
    Cap POST bodies at MAX_BODY by counting bytes as they arrive, so it works
    whether the client (or the tunnel in between) sends Content-Length or
    chunked encoding. The body is tiny, so it's buffered and replayed to the app.
    """
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST":
            return await self.app(scope, receive, send)
        too_big = JSONResponse({"ok": False, "error": "request too large"}, status_code=413)
        for k, v in scope["headers"]:
            if k == b"content-length" and v.isdigit() and int(v) > MAX_BODY:
                return await too_big(scope, receive, send)
        chunks, size = [], 0
        while True:
            msg = await receive()
            if msg["type"] == "http.disconnect":
                return
            chunk = msg.get("body", b"")
            size += len(chunk)
            if size > MAX_BODY:
                return await too_big(scope, receive, send)
            chunks.append(chunk)
            if not msg.get("more_body"):
                break
        body, replayed = b"".join(chunks), False

        async def replay():
            nonlocal replayed
            if not replayed:
                replayed = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()

        await self.app(scope, replay, send)


class _SecurityHeaders(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if request.method == "POST":
            # CSRF: a cross-site page can't set a custom header without a CORS
            # preflight, which this server never approves.
            if (request.url.path.startswith("/admin")
                    and request.headers.get(ADMIN_HEADER) != "att-admin"):
                return JSONResponse({"ok": False, "error": "forbidden"}, status_code=403)
        resp = await call_next(request)
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["X-Frame-Options"] = "DENY"
        resp.headers["Referrer-Policy"] = "same-origin"
        resp.headers["Permissions-Policy"] = "geolocation=(self), camera=(), microphone=()"
        resp.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; connect-src 'self'; object-src 'none'; "
            "base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        )
        if not request.url.path.startswith("/static"):
            resp.headers["Cache-Control"] = "no-store"
        return resp


def real_peer_ip(request: Request) -> str:
    """The actual TCP peer address, ignoring forwarding headers."""
    return request.client.host if request.client else "unknown"


def client_ip(request: Request) -> str:
    """
    The student's public IP. Forwarding headers (CF-Connecting-IP, X-Forwarded-For)
    are only trusted when the direct TCP peer is loopback — i.e. the request arrived
    through the local cloudflared process, not directly from a LAN client. This
    prevents LAN students from spoofing their apparent IP via forged headers.
    The returned value is always a valid IP string or 'unknown'.
    """
    peer = real_peer_ip(request)
    if peer in ("127.0.0.1", "::1"):
        for header in ("cf-connecting-ip", "x-forwarded-for"):
            raw = request.headers.get(header, "").split(",")[0].strip()
            if raw:
                try:
                    ipaddress.ip_address(raw)
                    return raw
                except ValueError:
                    pass
    try:
        ipaddress.ip_address(peer)
        return peer
    except ValueError:
        return "unknown"


def reject(msg: str, status: int = 409):
    return JSONResponse({"ok": False, "error": msg}, status_code=status)


# --- Page token: proves submit came from a real page load (anti-curl). ---
_TOKEN_PERIOD = 30


def issue_page_token() -> str:
    bucket = int(_time.time()) // _TOKEN_PERIOD
    return hmac.new(config.page_secret.encode(), str(bucket).encode(),
                    hashlib.sha256).hexdigest()[:16]


def valid_page_token(tok: str) -> bool:
    if not tok or not config.page_secret:
        return False
    now = int(_time.time())
    for b in (now // _TOKEN_PERIOD, now // _TOKEN_PERIOD - 1, now // _TOKEN_PERIOD - 2):
        good = hmac.new(config.page_secret.encode(), str(b).encode(),
                        hashlib.sha256).hexdigest()[:16]
        if hmac.compare_digest(tok, good):
            return True
    return False


# --- Per-device throttle (CGNAT-safe: keyed on device, not IP). ---
_throttle: dict = {}


def _prune(table: dict, window: float, now: float, cap: int = 5000):
    """Drop expired keys once a table grows large (bots rotating ids/IPs)."""
    if len(table) > cap:
        for k in [k for k, v in table.items() if not v or now - v[-1] >= window]:
            del table[k]


def throttled(device_id: str) -> bool:
    now = _time.monotonic()
    _prune(_throttle, config.throttle_window, now)
    hits = [t for t in _throttle.get(device_id, []) if now - t < config.throttle_window]
    hits.append(now)
    _throttle[device_id] = hits
    return len(hits) > config.throttle_n


# --- Per-real-peer-IP throttle for new-record creation.
# Secondary defence against scripts that rotate deviceId to bypass the device throttle.
# Limit is generous (300/60s) to accommodate CGNAT groups; a bot still can't flood
# the server at 5+ req/s sustained from a single IP.
_ip_throttle: dict = {}
_IP_NEW_LIMIT = 300
_IP_WINDOW = 60.0


def ip_new_throttled(peer: str) -> bool:
    now = _time.monotonic()
    _prune(_ip_throttle, _IP_WINDOW, now)
    hits = [t for t in _ip_throttle.get(peer, []) if now - t < _IP_WINDOW]
    hits.append(now)
    _ip_throttle[peer] = hits
    return len(hits) > _IP_NEW_LIMIT


# --- Admin login throttle (5 attempts / 60 s per TCP peer). ---
_login_throttle: dict = {}
_LOGIN_MAX = 5
_LOGIN_WINDOW = 60.0


def login_throttled(peer: str) -> bool:
    now = _time.monotonic()
    _prune(_login_throttle, _LOGIN_WINDOW, now)
    hits = [t for t in _login_throttle.get(peer, []) if now - t < _LOGIN_WINDOW]
    hits.append(now)
    _login_throttle[peer] = hits
    return len(hits) > _LOGIN_MAX


def resolve_by_device(device_id: str, token: str):
    """Strong browser-local identity only (deviceId / cookie). Used for prefill."""
    if device_id and device_id in store.client_to_rid:
        return store.client_to_rid[device_id]
    if token and token in store.client_to_rid:
        return store.client_to_rid[token]
    return None


def _log(action, match, rid, name, sid, prev, lat, lng, acc, ip, device_id, now, note=""):
    """Append to the Raw history. Call only inside the submit critical section."""
    store.log.append({
        "seq": len(store.log) + 1, "time": now, "action": action, "match": match,
        "rid": rid, "name": name, "id": sid,
        "prev_name": prev["name"] if prev else "", "prev_id": prev["id"] if prev else "",
        "lat": lat, "lng": lng, "acc": acc, "ip": ip,
        "device": device_tag(device_id), "note": note,
    })


def _event(kind, now, old_id, old_name, new_id, new_name, ip, dist=None):
    store.events.append({"time": now, "old_id": old_id, "old_name": old_name,
                         "new_id": new_id, "new_name": new_name, "ip": ip,
                         "dist_m": dist, "kind": kind})


@_route("/", "GET")
async def index(request: Request):
    if (config.force_single_origin and len(config.tunnel_urls) == 1):
        host = request.headers.get("host", "")
        turl = config.tunnel_urls[0]
        thost = turl.split("://", 1)[-1].split("/", 1)[0]
        if thost and thost not in host:
            return RedirectResponse(turl, status_code=307)
    return FileResponse(os.path.join(HERE, "static", "index.html"))


@_route("/favicon.ico", "GET")
async def favicon(request: Request):
    return Response(status_code=204)


@_route("/api/init", "POST")
async def init(request: Request):
    """
    One round-trip on page load: returns session info, a fresh page token, and
    this device's existing record (for prefill/edit) if any.
    """
    try:
        data = await request.json()
    except Exception:
        data = {}
    device_id = str(data.get("deviceId", "")).strip()
    token = request.cookies.get(COOKIE_NAME, "")
    rid = resolve_by_device(device_id, token)
    rec = store.get(rid) if rid else None
    return JSONResponse({"course": config.course_name, "count": len(store.records),
                         "geofence": config.geofence, "page_token": issue_page_token(),
                         "record": ({"name": rec["name"], "id": rec["id"]} if rec else None)})


@_route("/submit", "POST")
async def submit(request: Request):
    """
    CREATE-OR-EDIT. The resolve+dedup+mutation block below has no await inside,
    so the single-threaded event loop cannot interleave two submissions mid-block.
    """
    if config.ended:
        return reject("انتهى تسجيل الحضور / Attendance is closed", 410)
    try:
        if request.headers.get("content-type", "").startswith("application/json"):
            data = await request.json()
        else:
            data = dict(await request.form())
    except Exception:
        return reject("Bad request payload", 400)

    sid = normalize_digits(str(data.get("id", "")).strip())
    raw_name = str(data.get("name", "")).strip()
    device_id = str(data.get("deviceId", "")).strip()
    if not DEVICE_RE.match(device_id):
        device_id = uuid.uuid4().hex   # missing or malformed: treat as a new browser

    if config.page_secret and not valid_page_token(str(data.get("page_token", "")).strip()):
        return JSONResponse({"ok": False, "code": "token",
                             "error": "افتح الصفحة من جديد وأعد المحاولة / "
                                      "Please reload the page and try again"}, status_code=403)
    if throttled(device_id):
        return JSONResponse({"ok": False, "retry": False,
                             "error": "محاولات كثيرة بسرعة — انتظر قليلًا / "
                                      "Too many attempts, slow down"}, status_code=429)

    if not valid_id(sid):
        return reject("رقم الطالب غير صالح / Invalid student ID", 422)

    # Normalize ID for roster lookup: strip leading zeros so "007123" matches "7123".
    if config.roster and (sid.lstrip("0") or "0") not in config.roster:
        return reject("رقم الطالب غير مدرج في قائمة الطلاب / "
                      "This ID is not on the class list", 403)

    ok_name, name = valid_name(raw_name)
    if not ok_name:
        return reject("ادخل الاسم الرباعي بالعربية (٤ مقاطع على الأقل) / "
                      "Enter your full 4-part Arabic name", 422)

    lat = lng = acc = None
    if config.geofence:
        try:
            lat = float(data.get("lat"))
            lng = float(data.get("lng"))
        except (TypeError, ValueError):
            return reject("يجب السماح بالوصول إلى الموقع لتسجيل الحضور / "
                          "Location access is required to submit", 403)
        if not (math.isfinite(lat) and math.isfinite(lng)
                and -90 <= lat <= 90 and -180 <= lng <= 180):
            return reject("إحداثيات غير صالحة / Invalid location coordinates", 422)
        try:
            acc = float(data.get("accuracy") or 0)
            if not math.isfinite(acc) or acc < 0:
                acc = 0.0
        except (TypeError, ValueError):
            acc = 0.0

    ip = client_ip(request)
    peer = real_peer_ip(request)
    token = request.cookies.get(COOKIE_NAME) or uuid.uuid4().hex
    now = datetime.now().isoformat(timespec="seconds")
    is_https = request.headers.get("x-forwarded-proto") == "https"

    # ===================== ATOMIC CRITICAL SECTION =====================
    # No await inside this block — the event loop serialises concurrent submissions.

    # Identity is the browser (deviceId / cookie) only. A shared IP or nearby GPS
    # is never used to pick a record: phones on one carrier/tower share an IP and
    # indoor GPS often reports the same spot, so that silently overwrote
    # classmates. Those cases are flagged in the export instead.
    existing_rid = resolve_by_device(device_id, token)
    match_method = "device"
    if existing_rid is not None and store.get(existing_rid) is None:
        # Stale index entry — purge it and fall through to create a new record.
        store.client_to_rid.pop(device_id, None)
        store.client_to_rid.pop(token, None)
        existing_rid = None

    # A different browser re-submitting an existing ID: accept it as the same
    # student only if the name matches too (switched browser, or returned after
    # a device reset). Otherwise refuse instead of overwriting someone else.
    if existing_rid is None and sid in store.id_to_rid:
        owner = store.get(store.id_to_rid[sid])
        if owner is not None:
            if name_key(owner["name"]) != name_key(name):
                _log("refused", "ID in use", owner["rid"], name, sid, owner,
                     lat, lng, acc, ip, device_id, now,
                     note="ID already registered with a different name")
                _event("refused: ID in use", now, owner["id"], owner["name"],
                       sid, name, ip)
                return reject("رقم الطالب مسجّل بالفعل باسم آخر — إذا كان رقمك فراجع المحاضر / "
                              "This ID is already registered under another name. "
                              "If it is yours, tell the instructor.", 409)
            existing_rid, match_method = owner["rid"], "same ID + name"

    if existing_rid is not None:
        rec = store.get(existing_rid)
        old_id, old_name = rec["id"], rec["name"]
        old_lat, old_lng = rec.get("lat"), rec.get("lng")
        if sid != rec["id"]:
            owner = store.id_to_rid.get(sid)
            if owner is not None and owner != existing_rid:
                _log("refused", "ID in use", existing_rid, name, sid, rec,
                     lat, lng, acc, ip, device_id, now,
                     note="tried to change to an ID another student registered")
                _event("refused: ID in use", now, old_id, old_name, sid, name, ip)
                return reject("رقم الطالب مستخدم من جهاز آخر / "
                              "This ID is already used on another device", 409)
            store.id_to_rid.pop(rec["id"], None)
            store.id_to_rid[sid] = existing_rid
        if rec.get("ip") != ip:
            store.drop_ip(rec.get("ip"), existing_rid)
            store.add_ip(ip, existing_rid)
        rec["name"], rec["id"], rec["edited_at"] = name, sid, now
        rec["ip"] = ip
        if lat is not None:
            rec["lat"], rec["lng"], rec["acc"] = lat, lng, acc
        store.client_to_rid[device_id] = existing_rid
        store.client_to_rid[token] = existing_rid
        dist = None
        if _is_num(old_lat) and _is_num(lat):
            dist = round(haversine_km(old_lat, old_lng, lat, lng) * 1000)
        kind = edit_kind(old_id, old_name, sid, name)
        _log("updated", match_method, existing_rid, name, sid,
             {"name": old_name, "id": old_id}, lat, lng, acc, ip, device_id, now, note=kind)
        _event(kind, now, old_id, old_name, sid, name, ip, dist)
        resp = JSONResponse({"ok": True, "mode": "updated",
                             "message": "تم تحديث بياناتك / Your entry was updated"})
        resp.set_cookie(COOKIE_NAME, token, max_age=43200, httponly=True,
                        samesite="lax", secure=is_https)
        return resp

    # New-record path — apply secondary IP throttle before committing.
    if ip_new_throttled(peer):
        return JSONResponse({"ok": False, "retry": True,
                             "error": "الخادم مشغول — انتظر قليلًا / "
                                      "Server busy, try again shortly"}, status_code=429)
    if config.ip_tracking and ip in store.seen_ips:
        _log("refused", "IP already used", None, name, sid, None,
             lat, lng, acc, ip, device_id, now)
        return reject("تم التسجيل من هذه الشبكة مسبقًا / Already submitted from this network", 409)

    rid = uuid.uuid4().hex
    rec = {"rid": rid, "name": name, "id": sid, "timestamp": now,
           "edited_at": None, "lat": lat, "lng": lng, "acc": acc, "ip": ip}
    store.add_record(rec)
    store.client_to_rid[device_id] = rid
    store.client_to_rid[token] = rid
    store.id_to_rid[sid] = rid
    shared = [store.get(r)["id"] for r in store.ip_to_rids.get(ip, []) if store.get(r)]
    store.add_ip(ip, rid)
    if config.ip_tracking:
        store.seen_ips.add(ip)
    _log("created", "new", rid, name, sid, None, lat, lng, acc, ip, device_id, now,
         note=("same IP as " + " ".join(shared)) if shared else "")
    # =================== END ATOMIC CRITICAL SECTION ===================

    resp = JSONResponse({"ok": True, "mode": "created",
                         "message": "تم تسجيل الحضور / Attendance recorded"})
    resp.set_cookie(COOKIE_NAME, token, max_age=43200, httponly=True,
                    samesite="lax", secure=is_https)
    return resp


def _hash_pw(pw: str) -> str:
    return hashlib.sha256((config.admin_pw_salt + pw).encode()).hexdigest()


def _pw_ok(pw: str) -> bool:
    if not config.admin_pw_hash:
        return False
    return hmac.compare_digest(_hash_pw(pw or ""), config.admin_pw_hash)


def admin_session_cookie() -> str:
    """Bearer value proving a successful password login (HMAC of the session)."""
    return hmac.new(config.page_secret.encode(), b"admin-session",
                    hashlib.sha256).hexdigest()[:32]


def _check_admin(request: Request) -> bool:
    """
    Admin access granted if EITHER:
      A) a valid password is presented via X-Admin-Pw header or att_admin cookie, OR
      B) no password is set AND the request comes from loopback/trusted-CIDR
         without any forwarding header (so it cannot be a tunnel request).
    Note: the ?pw= query param is intentionally not supported — it would log the
    password in server logs, CDN logs, and browser history.
    """
    supplied = request.headers.get("x-admin-pw")
    if supplied is not None and _pw_ok(supplied):
        return True
    if config.admin_pw_hash:
        cookie = request.cookies.get("att_admin")
        if cookie and hmac.compare_digest(cookie, admin_session_cookie()):
            return True
        return False

    # Path B: no password configured — loopback or trusted private network only.
    forwarded = (request.headers.get("cf-connecting-ip")
                 or request.headers.get("x-forwarded-for"))
    if forwarded:
        return False
    # DNS rebinding: a malicious site can point its own domain at 127.0.0.1 and
    # read this page from the host's browser. Only accept an IP literal or
    # localhost as the Host, which a rebinding domain can never be.
    host = request.url.hostname or ""
    if host != "localhost":
        try:
            ipaddress.ip_address(host.strip("[]"))
        except ValueError:
            return False
    peer = request.client.host if request.client else ""
    if peer in ("127.0.0.1", "::1", "localhost"):
        return True
    try:
        ip = ipaddress.ip_address(peer)
    except ValueError:
        return False
    for cidr in config.admin_cidrs:
        try:
            if ip in ipaddress.ip_network(cidr, strict=False):
                return True
        except ValueError:
            continue
    return False


@_route("/admin/login", "POST")
async def admin_login(request: Request):
    """Verify password; on success set an HttpOnly login cookie."""
    peer = real_peer_ip(request)
    if login_throttled(peer):
        return JSONResponse({"ok": False, "error": "Too many attempts — try later"},
                            status_code=429)
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not config.admin_pw_hash:
        return JSONResponse({"ok": True, "no_password": True})
    if _pw_ok(str(body.get("pw", ""))):
        is_https = request.headers.get("x-forwarded-proto") == "https"
        resp = JSONResponse({"ok": True})
        resp.set_cookie("att_admin", admin_session_cookie(),
                        httponly=True, samesite="strict", max_age=43200,
                        secure=is_https)
        return resp
    return JSONResponse({"ok": False, "error": "wrong password"}, status_code=401)


@_route("/admin", "GET")
async def admin_page(request: Request):
    if not _check_admin(request):
        if config.admin_pw_hash:
            return FileResponse(os.path.join(HERE, "static", "login.html"))
        return HTMLResponse("<h2>Admin is available only on the host machine or a "
                            "device on the same private network — not through the "
                            "public link.</h2>", status_code=403)
    return FileResponse(os.path.join(HERE, "static", "admin.html"))


@_route("/admin/state", "GET")
async def admin_state(request: Request):
    if not _check_admin(request):
        return reject("unauthorized", 401)
    rows = store.records
    hall_lat, hall_lng = hall_center(rows) if config.geofence else (None, None)

    def dist_km(r):
        if hall_lat is None or not _is_num(r.get("lat")):
            return None
        return haversine_km(hall_lat, hall_lng, r["lat"], r["lng"])

    out_of_bounds = sum(1 for r in rows
                        if (d := dist_km(r)) is not None and d > config.audit_radius_km)
    shared_ip = sum(len(v) for v in store.ip_to_rids.values() if len(v) > 1)
    recent = []
    for r in rows[-30:][::-1]:
        d = dist_km(r)
        recent.append({"name": r["name"], "id": r["id"], "timestamp": r["timestamp"],
                       "edited": bool(r.get("edited_at")),
                       "gps": _is_num(r.get("lat")),
                       "dist_m": None if d is None else round(d * 1000),
                       "out": d is not None and d > config.audit_radius_km,
                       "shared_ip": len(store.ip_to_rids.get(r.get("ip"), [])) > 1})
    return JSONResponse({"course": config.course_name, "session_id": config.session_id(),
                         "count": len(rows), "devices": len(store.id_to_rid),
                         "ip_tracking": config.ip_tracking, "geofence": config.geofence,
                         "audit_radius_km": config.audit_radius_km,
                         "out_of_bounds": out_of_bounds, "shared_ip": shared_ip,
                         "submissions": len(store.log),
                         "merges": store.events[-30:][::-1], "recent": recent})


@_route("/admin/reset-devices", "POST")
async def admin_reset_devices(request: Request):
    if not _check_admin(request):
        return reject("unauthorized", 401)
    with admin_lock:
        store.clear_devices()
        _throttle.clear()
        _ip_throttle.clear()
    return JSONResponse({"ok": True, "message": "Device locks cleared; cookies reset for a new take"})


@_route("/admin/new-session", "POST")
async def admin_new_session(request: Request):
    if not _check_admin(request):
        return reject("unauthorized", 401)
    try:
        body = await request.json()
    except Exception:
        body = {}
    new_name = str(body.get("course", "")).strip()

    # Atomically snapshot + clear so any record submitted between the snapshot
    # and the clear is not silently dropped (data loss race in the old code).
    with admin_lock:
        rows = list(store.records)
        log = list(store.log)
        old_base = config.session_id()   # capture before started_at changes
        store.clear_all()
        _throttle.clear()
        _ip_throttle.clear()
        if new_name:
            config.course_name = new_name
        config.started_at = datetime.now()

    # Write the CSV from the snapshot outside the lock so /submit is not blocked.
    try:
        final, audit = await asyncio.to_thread(_write_csv, rows, log, old_base, "new-session")
        exported = os.path.basename(final)
    except Exception as e:
        print(f"[export:new-session] ERROR: {e}")
        exported = "(export failed)"

    return JSONResponse({"ok": True, "exported": exported,
                         "course": config.course_name, "session_id": config.session_id()})


@_route("/admin/export", "POST")
async def admin_export(request: Request):
    if not _check_admin(request):
        return reject("unauthorized", 401)
    try:
        final, audit = await asyncio.to_thread(export_csv, "manual")
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e)}, status_code=500)
    return JSONResponse({"ok": True, "final": os.path.basename(final),
                         "raw": os.path.basename(final).replace("_Final.csv", "_Raw.csv"),
                         "audited": os.path.basename(audit) if audit else None})


def downloads_dir():
    """Phone/PC Downloads folder, or None. On Termux it exists only after
    `termux-setup-storage` has been run once."""
    for d in (os.path.expanduser("~/storage/downloads"), os.path.expanduser("~/Downloads")):
        if os.path.isdir(d):
            return d
    return None


def _copy_exports(paths):
    dest = downloads_dir()
    if dest is None:
        return None, []
    copied = []
    for p in paths:
        try:
            shutil.copy2(p, dest)
            copied.append(os.path.basename(p))
        except OSError as e:
            print(f"[end-session] could not copy {p}: {e}")
    return dest, copied


@_route("/admin/end-session", "POST")
async def admin_end_session(request: Request):
    """
    Close attendance from the admin page: refuse new submissions, export all
    CSVs, copy them to Downloads, then stop the server (and with it the tunnels).
    """
    if not _check_admin(request):
        return reject("unauthorized", 401)
    config.ended = True   # from here on /submit refuses; no await before this line
    try:
        final, audit = await asyncio.to_thread(export_csv, "end-session")
    except Exception as e:
        config.ended = False   # nothing saved: keep the session open
        return JSONResponse({"ok": False, "error": f"export failed: {e}"}, status_code=500)
    files = [final, final.replace("_Final.csv", "_Raw.csv")] + ([audit] if audit else [])
    dest, copied = await asyncio.to_thread(_copy_exports, files)
    if dest:
        print(f"[end-session] copied {len(copied)} file(s) to {dest}")
    stopping = config.request_shutdown is not None
    if stopping:
        # Give the response a moment to reach the browser before shutting down.
        asyncio.get_running_loop().call_later(1.0, config.request_shutdown)
    return JSONResponse({"ok": True, "files": [os.path.basename(f) for f in files],
                         "exports_dir": EXPORT_DIR, "copied_to": dest, "copied": copied,
                         "stopping": stopping})


@_route("/admin/download", "GET")
async def admin_download(request: Request):
    """?file=final (default) | raw | audited (falls back to final without geofence)"""
    if not _check_admin(request):
        return reject("unauthorized", 401)
    kind = request.query_params.get("file", "final")
    if kind not in ("final", "raw", "audited"):
        return reject("unknown file", 400)
    try:
        final, audit = await asyncio.to_thread(export_csv, "download")
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e)}, status_code=500)
    if kind == "raw":
        path = final.replace("_Final.csv", "_Raw.csv")
    elif kind == "audited":
        path = audit or final
    else:
        path = final
    return FileResponse(path, filename=os.path.basename(path), media_type="text/csv")


app = Starlette(
    routes=_routes + [Mount("/static", StaticFiles(directory=os.path.join(HERE, "static")),
                            name="static")],
    middleware=[Middleware(_BodyLimit), Middleware(_SecurityHeaders)],
    lifespan=lifespan,
)
