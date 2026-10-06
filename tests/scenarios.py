"""
Black-box scenario tests for an attendance server, over plain HTTP.

The same checks run against the Python server (tests/serve_python.py) and the
Dart server in the Flutter app (flutter_app/bin/serve.dart), so the two stay
behaviourally identical. Standard library only.

    python tests/scenarios.py --base http://127.0.0.1:8765 [--mode password|nopassword]

Expects the server's test configuration: geofence on, audit radius 0.5 km,
admin password "pw" (mode "password") or none (mode "nopassword").
Students arrive "through the tunnel": requests come from loopback with a
CF-Connecting-IP header, which the server trusts only from loopback.
"""

import argparse
import csv
import http.cookiejar
import io
import json
import sys
import urllib.error
import urllib.request

HALL = (30.0444, 31.2357)
NAMES = {
    "mohamed": "محمد احمد علي حسن",
    "mohamed_hamza": "محمد أحمد علي حسن",   # same name, أ/ا spelling variant
    "sara": "سارة محمود علي حسن",
    "khaled": "خالد يوسف عمر احمد",
    "omar": "عمر خالد يوسف احمد",
}

failures = 0


def check(label, cond, extra=""):
    global failures
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else f"  -> {extra}"))
    if not cond:
        failures += 1


class Client:
    """One browser: its own cookie jar, arriving from `ip` via the tunnel."""

    def __init__(self, base, ip=None, host=None):
        self.base = base
        self.ip = ip
        self.host = host
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar),
            _NoRedirect())

    def request(self, method, path, body=None, headers=None, raw=None):
        h = {}
        if self.ip:
            h["CF-Connecting-IP"] = self.ip
            h["X-Forwarded-Proto"] = "https"
        if self.host:
            h["Host"] = self.host
        if body is not None:
            raw = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        h.update(headers or {})
        req = urllib.request.Request(self.base + path, data=raw, method=method, headers=h)
        try:
            with self.opener.open(req, timeout=15) as r:
                return Resp(r.status, r.read(), dict(r.headers))
        except urllib.error.HTTPError as e:
            return Resp(e.code, e.read(), dict(e.headers))

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.request("POST", path, body=body, **kw)

    def admin_post(self, path, body=None):
        return self.post(path, body if body is not None else {},
                         headers={"X-Requested-With": "att-admin"})

    # ---- student flow ----
    def token(self, dev):
        return self.post("/api/init", {"deviceId": dev}).json()["page_token"]

    def submit(self, dev, sid, name, lat=HALL[0], lng=HALL[1]):
        return self.post("/submit", {"id": sid, "name": name, "deviceId": dev,
                                     "page_token": self.token(dev),
                                     "lat": lat, "lng": lng, "accuracy": 20})


class Resp:
    def __init__(self, status, body, headers):
        self.status = status
        self.body = body
        self.headers = {k.lower(): v for k, v in headers.items()}

    @property
    def text(self):
        return self.body.decode("utf-8", "replace")

    def json(self):
        try:
            return json.loads(self.body)
        except ValueError:
            return {}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


def rows(resp):
    return list(csv.DictReader(io.StringIO(resp.body.decode("utf-8-sig"))))


def run_password_mode(base):
    # 1) Two students, same carrier IP, same indoor spot -> both kept
    a, b = Client(base, "41.1.1.1"), Client(base, "41.1.1.1")
    a.submit("dev-aaaaaaaa", "1001", NAMES["mohamed"])
    r = b.submit("dev-bbbbbbbb", "1002", NAMES["sara"])
    check("same IP + spot: second student created, not merged",
          r.json().get("mode") == "created", r.text)

    # 2) ID typo fixed from the same phone -> 'ID corrected'
    r = a.submit("dev-aaaaaaaa", "1009", NAMES["mohamed"])
    check("ID fix from same device updates", r.json().get("mode") == "updated", r.text)

    # 3) Another phone types someone else's ID with another name -> refused
    c = Client(base, "41.2.2.2")
    r = c.submit("dev-cccccccc", "1002", NAMES["khaled"])
    check("other phone + taken ID + other name -> 409", r.status == 409, r.text)

    # 4) Same student from a new browser -> accepted; spelling variant too
    d = Client(base, "41.3.3.3")
    r = d.submit("dev-dddddddd", "1002", NAMES["sara"])
    check("same ID + same name from new browser -> update", r.json().get("mode") == "updated", r.text)
    e = Client(base, "41.3.3.3")
    r = e.submit("dev-eeeeeeee", "1009", NAMES["mohamed_hamza"])
    check("name spelling variant (أحمد/احمد) accepted", r.json().get("mode") == "updated", r.text)

    # 5) Prefill: the original browser sees its (edited) record
    r = a.post("/api/init", {"deviceId": "dev-aaaaaaaa"})
    rec = r.json().get("record") or {}
    check("init prefills the device's record", rec.get("id") == "1009", r.text)

    # 6) Far-away student -> out of bounds
    f = Client(base, "41.4.4.4")
    f.submit("dev-ffffffff", "1003", NAMES["omar"], lat=30.10, lng=31.30)

    # 7) Validation
    g = Client(base, "41.5.5.5")
    check("invalid ID -> 422", g.submit("dev-gggggggg", "12a", NAMES["omar"]).status == 422)
    check("non-Arabic name -> 422", g.submit("dev-gggggggg", "1004", "John Smith Doe Roe").status == 422)
    check("3-part name -> 422", g.submit("dev-gggggggg", "1004", "محمد احمد علي").status == 422)
    r = g.post("/submit", {"id": "1004", "name": NAMES["omar"], "deviceId": "dev-gggggggg",
                           "page_token": g.token("dev-gggggggg")})
    check("geofence on, no location -> 403", r.status == 403, r.text)
    r = g.post("/submit", {"id": "1004", "name": NAMES["omar"], "deviceId": "dev-gggggggg",
                           "page_token": "bad", "lat": 30, "lng": 31})
    check("bad page token -> 403 code=token", r.status == 403 and r.json().get("code") == "token", r.text)

    # 7b) Arabic-keyboard digits are stored as ASCII (and count as a new student)
    h = Client(base, "41.6.6.6")
    r = h.submit("dev-hhhhhhhh", "١٠٠٥", NAMES["khaled"])
    check("Arabic-Indic digit ID accepted", r.json().get("mode") == "created", r.text)
    r = h.post("/api/init", {"deviceId": "dev-hhhhhhhh"})
    check("Arabic-Indic digits stored as ASCII", (r.json().get("record") or {}).get("id") == "1005", r.text)

    # 8) Admin auth + CSRF
    adm = Client(base)
    check("admin POST without header -> 403",
          adm.post("/admin/login", {"pw": "pw"}).status == 403)
    check("admin state without login -> 401", adm.get("/admin/state").status == 401)
    check("wrong password -> 401", adm.admin_post("/admin/login", {"pw": "nope"}).status == 401)
    r = adm.admin_post("/admin/login", {"pw": "pw"})
    check("admin login", r.status == 200, r.text)
    st = adm.get("/admin/state").json()
    check("state: 4 students", st.get("count") == 4, st.get("count"))
    check("state: out_of_bounds == 1", st.get("out_of_bounds") == 1, st.get("out_of_bounds"))
    check("state: shared_ip >= 2", st.get("shared_ip", 0) >= 2, st.get("shared_ip"))
    far = [x for x in st.get("recent", []) if x.get("id") == "1003"]
    check("state: far student out, distance in metres",
          bool(far) and far[0]["out"] and far[0]["dist_m"] > 5000, far)
    kinds = [m.get("kind") for m in st.get("merges", [])]
    check("state: edit kinds recorded",
          "ID corrected" in kinds and "refused: ID in use" in kinds, kinds)
    check("admin export without header -> 403", adm.post("/admin/export", {}).status == 403)
    r = adm.admin_post("/admin/export")
    check("admin export", r.status == 200 and r.json().get("ok"), r.text)

    # 9) CSV contents
    raw = rows(adm.get("/admin/download?file=raw"))
    fin = rows(adm.get("/admin/download?file=final"))
    aud = rows(adm.get("/admin/download?file=audited"))
    actions = [(x["Action"], x["ID"]) for x in raw]
    check("Raw: every submission incl. refused (8)", len(raw) == 8, actions)
    check("Raw: keeps the overwritten typo ID", any(x["Prev_ID"] == "1001" for x in raw), actions)
    check("Raw: refused row present", any(x["Action"] == "refused" for x in raw), actions)
    check("Final: one row per student (4)", len(fin) == 4, len(fin))
    sara = [x for x in fin if x["ID"] == "1002"]
    check("Final: shared-IP columns", bool(sara) and sara[0]["SameIP_IDs"] != "", sara)
    check("Maps link in every file",
          all(f and f[0]["Maps_Link"].startswith("https://www.google.com/maps?q=") for f in (raw, fin, aud)))
    check("Audited: far student flagged out of bounds",
          any(x["ID"] == "1003" and "Out of bounds" in x["Status"] for x in aud))
    check("download bad kind -> 400", adm.get("/admin/download?file=../x").status == 400)

    # 10) Security headers, limits, static
    r = adm.get("/")
    csp = r.headers.get("content-security-policy", "")
    check("CSP: scripts self only, no framing",
          "script-src 'self';" in csp and "frame-ancestors 'none'" in csp, csp)
    check("X-Frame-Options DENY", r.headers.get("x-frame-options") == "DENY")
    check("student page loads external JS", '<script src="/static/index.js">' in r.text)
    check("static JS served", adm.get("/static/index.js").status == 200)
    check("favicon -> 204", adm.get("/favicon.ico").status == 204)
    check("unknown path -> 404", adm.get("/nope").status == 404)
    check("oversized body -> 413",
          adm.post("/submit", raw=b"x" * 20000, headers={"Content-Type": "application/json"}).status == 413)
    check("malformed deviceId harmless", adm.post("/api/init", {"deviceId": "<script>" * 20}).status == 200)

    # 11) Reset devices: records kept, the same student can re-submit
    check("reset-devices", adm.admin_post("/admin/reset-devices").status == 200)
    r = a.submit("dev-aaaaaaaa", "1009", NAMES["mohamed"])
    check("after reset: same ID + name updates (no duplicate)",
          r.json().get("mode") == "updated", r.text)
    check("after reset: still 4 students", adm.get("/admin/state").json().get("count") == 4)

    # 12) End session: closes attendance (server then shuts down)
    r = adm.admin_post("/admin/end-session")
    check("end-session", r.status == 200 and r.json().get("ok"), r.text)
    try:
        r = Client(base, "41.9.9.9").post("/submit", {"id": "1", "name": NAMES["omar"],
                                                       "deviceId": "dev-zzzzzzzz"})
        check("submit after end -> 410 (or server already down)", r.status == 410, r.status)
    except OSError:
        check("submit after end -> 410 (or server already down)", True)


def run_nopassword_mode(base):
    lo = Client(base)
    check("no-pw admin via 127.0.0.1 -> 200", lo.get("/admin/state").status == 200)
    check("no-pw admin via localhost Host -> 200",
          Client(base, host="localhost:8765").get("/admin/state").status == 200)
    check("no-pw admin via rebinding domain -> 401",
          Client(base, host="evil.example:8765").get("/admin/state").status == 401)
    check("no-pw admin through tunnel (forwarded) -> 401",
          Client(base, ip="41.1.1.1").get("/admin/state").status == 401)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8765")
    ap.add_argument("--mode", choices=["password", "nopassword"], default="password")
    args = ap.parse_args()
    (run_password_mode if args.mode == "password" else run_nopassword_mode)(args.base)
    print(f"\nFAILURES: {failures}")
    sys.exit(1 if failures else 0)
