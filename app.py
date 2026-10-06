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
                                 RedirectResponse)
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles

from state import config, store, admin_lock

ID_RE = re.compile(r"^\d{1,20}$")
ARABIC_WORD_RE = re.compile(r"^[؀-ۿ]+$")
MIN_NAME_PARTS = 4
COOKIE_NAME = "att_token"

HERE = os.path.dirname(os.path.abspath(__file__))
EXPORT_DIR = os.path.join(HERE, "exports")
os.makedirs(EXPORT_DIR, exist_ok=True)


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


# ---------------------------------------------------------------------------
# Export: Raw CSV (all records) + Audited CSV (GPS outliers flagged) if geofence on.
# ---------------------------------------------------------------------------

def _write_csv(rows, base, reason="export"):
    """
    Synchronous CSV writer. Call via asyncio.to_thread in async contexts so disk
    I/O does not block the event loop while students are still submitting.
    """
    raw_path = os.path.join(EXPORT_DIR, f"{base}_Raw.csv")
    with open(raw_path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["Name", "ID", "Submitted_At", "Last_Updated",
                    "Latitude", "Longitude", "Accuracy_m", "IP"])
        for r in rows:
            w.writerow([
                r["name"], r["id"],
                r["timestamp"],
                r.get("edited_at") or "",
                r.get("lat", ""), r.get("lng", ""),
                "" if r.get("acc") is None else round(r["acc"]),
                r.get("ip", ""),
            ])
    print(f"\n[export:{reason}] {len(rows)} records -> {raw_path}")

    audit_path = None
    if config.geofence:
        audit_path = _audit_csv(rows, base)
    return raw_path, audit_path


def export_csv(reason: str = "shutdown"):
    """Snapshot current records and write CSVs synchronously (for shutdown path)."""
    with admin_lock:
        rows = list(store.records)
    base = config.session_id()
    return _write_csv(rows, base, reason)


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

    # Per-IP submission counts (browser-switch detector).
    ip_ids = {}
    for r in rows:
        ip = r.get("ip") or "unknown"
        ip_ids.setdefault(ip, set()).add(r["id"])
    ip_count = {ip: len(ids) for ip, ids in ip_ids.items()}

    # Median hall centre (robust to remote cheaters being a minority).
    pts = [(r["lat"], r["lng"]) for r in rows
           if isinstance(r.get("lat"), (int, float)) and isinstance(r.get("lng"), (int, float))]
    hall_lat = median(p[0] for p in pts) if pts else None
    hall_lng = median(p[1] for p in pts) if pts else None

    # Spatial grid for O(n) near-duplicate GPS detection (was O(n²)).
    # Each cell is ~8 m; we check the 3×3 neighbourhood so no pair is missed.
    _CELL_DEG = 0.008 / 111.0   # 8 m expressed in degrees
    gps_grid: dict = {}
    for r in rows:
        if isinstance(r.get("lat"), (int, float)):
            gx = int(r["lat"] / _CELL_DEG)
            gy = int(r["lng"] / _CELL_DEG)
            gps_grid.setdefault((gx, gy), []).append(r)

    def near_duplicate_gps(r):
        """True if a *different* student's record sits within ~8 m (likely same phone)."""
        if not isinstance(r.get("lat"), (int, float)):
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
                    "Latitude", "Longitude", "Accuracy_m",
                    "Distance_km", "IP", "SameIP_Count", "Status"])
        for r in rows:
            ip = r.get("ip") or "unknown"
            n_ip = ip_count.get(ip, 1)
            lat, lng = r.get("lat"), r.get("lng")
            acc = r.get("acc")
            notes = []

            if isinstance(lat, (int, float)) and hall_lat is not None:
                d = haversine_km(hall_lat, hall_lng, lat, lng)
                dist = round(d, 3)
                if d > config.audit_radius_km:
                    notes.append("Out of bounds")
            else:
                dist = ""
                notes.append("No GPS")

            if n_ip > 1:
                notes.append(f"shared IP x{n_ip}")
            if near_duplicate_gps(r):
                notes.append("duplicate location")
            if isinstance(lat, (int, float)) and (acc is None or acc == 0):
                notes.append("no accuracy (possible spoof)")

            if notes:
                status = ("FLAGGED: " if ("Out of bounds" in notes or "No GPS" in notes)
                          else "SUSPECT: ") + ", ".join(notes)
                flagged += 1
            else:
                status = "Valid"

            w.writerow([
                r["name"], r["id"],
                r["timestamp"], r.get("edited_at") or "",
                lat if lat is not None else "", lng if lng is not None else "",
                "" if acc is None else round(acc),
                dist, ip, n_ip, status,
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


class _SecurityHeaders(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        resp = await call_next(request)
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["X-Frame-Options"] = "DENY"
        resp.headers["Referrer-Policy"] = "same-origin"
        resp.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline'; img-src 'self' data:;"
        )
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


def throttled(device_id: str) -> bool:
    now = _time.monotonic()
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


def resolve_for_submit(device_id: str, token: str, ip: str, lat, lng):
    """
    Identity resolution for a submission:
      1. deviceId / cookie  -> same browser, definitely same device (strongest signal).
      2. IP + GPS proximity -> different browser on the SAME physical phone, confirmed
         by being within ip_merge_radius_m (default 3 m — same hand, not adjacent seat).
         Without GPS we cannot safely distinguish 50 students sharing a carrier NAT,
         so we return (None, None) and let each get their own record.
    """
    rid = resolve_by_device(device_id, token)
    if rid is not None:
        return rid, "device"
    if config.ip_identity and ip and config.geofence and isinstance(lat, (int, float)):
        candidates = [store.get(r) for r in store.ip_to_rids.get(ip, [])]
        candidates = [r for r in candidates if r]
        for r in candidates:
            if isinstance(r.get("lat"), (int, float)) and \
               haversine_km(lat, lng, r["lat"], r["lng"]) * 1000 <= config.ip_merge_radius_m:
                return r["rid"], "ip_gps"
    return None, None


@_route("/", "GET")
async def index(request: Request):
    if (config.force_single_origin and len(config.tunnel_urls) == 1):
        host = request.headers.get("host", "")
        turl = config.tunnel_urls[0]
        thost = turl.split("://", 1)[-1].split("/", 1)[0]
        if thost and thost not in host:
            return RedirectResponse(turl, status_code=307)
    return FileResponse(os.path.join(HERE, "static", "index.html"))


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
    try:
        if request.headers.get("content-type", "").startswith("application/json"):
            data = await request.json()
        else:
            data = dict(await request.form())
    except Exception:
        return reject("Bad request payload", 400)

    sid = str(data.get("id", "")).strip()
    raw_name = str(data.get("name", "")).strip()
    device_id = str(data.get("deviceId", "")).strip() or uuid.uuid4().hex

    if config.page_secret and not valid_page_token(str(data.get("page_token", "")).strip()):
        return reject("افتح الصفحة من جديد وأعد المحاولة / "
                      "Please reload the page and try again", 403)
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

    existing_rid, match_method = resolve_for_submit(device_id, token, ip, lat, lng)

    # After a device-reset, client_to_rid is cleared but id_to_rid is rebuilt from
    # surviving records (see Store.clear_devices). Match by student ID here so the
    # student updates their existing record rather than creating a duplicate.
    if existing_rid is None and sid in store.id_to_rid:
        existing_rid = store.id_to_rid[sid]
        match_method = "id_match"

    if existing_rid is not None:
        rec = store.get(existing_rid)
        if rec is None:
            # Stale index entry — purge it and fall through to create a new record.
            store.client_to_rid.pop(device_id, None)
            store.client_to_rid.pop(token, None)
            existing_rid = None
        else:
            old_id, old_name = rec["id"], rec["name"]
            old_lat, old_lng = rec.get("lat"), rec.get("lng")
            if sid != rec["id"]:
                owner = store.id_to_rid.get(sid)
                if owner is not None and owner != existing_rid:
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
            # Log ALL edits (not just IP-based ones) so the full audit trail is preserved.
            dist = None
            if isinstance(old_lat, (int, float)) and isinstance(lat, (int, float)):
                dist = round(haversine_km(old_lat, old_lng, lat, lng) * 1000)
            store.events.append({
                "time": now, "old_id": old_id, "old_name": old_name,
                "new_id": sid, "new_name": name, "ip": ip,
                "method": match_method, "dist_m": dist,
                "same_student": (old_id == sid),
            })
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
        return reject("تم التسجيل من هذه الشبكة مسبقًا / Already submitted from this network", 409)

    rid = uuid.uuid4().hex
    rec = {"rid": rid, "name": name, "id": sid, "timestamp": now,
           "edited_at": None, "lat": lat, "lng": lng, "acc": acc, "ip": ip}
    store.add_record(rec)
    store.client_to_rid[device_id] = rid
    store.client_to_rid[token] = rid
    store.id_to_rid[sid] = rid
    store.add_ip(ip, rid)
    if config.ip_tracking:
        store.seen_ips.add(ip)
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
                        httponly=True, samesite="lax", max_age=43200,
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
    recent = [{"name": r["name"], "id": r["id"], "timestamp": r["timestamp"],
               "edited": bool(r.get("edited_at")),
               "gps": isinstance(r.get("lat"), (int, float))}
              for r in store.records[-15:][::-1]]
    return JSONResponse({"course": config.course_name, "session_id": config.session_id(),
                         "count": len(store.records), "devices": len(store.id_to_rid),
                         "ip_tracking": config.ip_tracking, "geofence": config.geofence,
                         "audit_radius_km": config.audit_radius_km,
                         "merges": store.events[-20:][::-1], "recent": recent})


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
        old_base = config.session_id()   # capture before started_at changes
        store.clear_all()
        _throttle.clear()
        _ip_throttle.clear()
        if new_name:
            config.course_name = new_name
        config.started_at = datetime.now()

    # Write the CSV from the snapshot outside the lock so /submit is not blocked.
    try:
        raw, audit = await asyncio.to_thread(_write_csv, rows, old_base, "new-session")
        exported = os.path.basename(raw)
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
        raw, audit = await asyncio.to_thread(export_csv, "manual")
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e)}, status_code=500)
    return JSONResponse({"ok": True, "raw": os.path.basename(raw),
                         "audited": os.path.basename(audit) if audit else None})


@_route("/admin/download", "GET")
async def admin_download(request: Request):
    if not _check_admin(request):
        return reject("unauthorized", 401)
    try:
        raw, audit = await asyncio.to_thread(export_csv, "download")
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e)}, status_code=500)
    path = audit or raw
    return FileResponse(path, filename=os.path.basename(path), media_type="text/csv")


app = Starlette(
    routes=_routes + [Mount("/static", StaticFiles(directory=os.path.join(HERE, "static")),
                            name="static")],
    middleware=[Middleware(_SecurityHeaders)],
    lifespan=lifespan,
)
