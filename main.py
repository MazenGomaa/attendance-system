"""
main.py
-------
Launcher: CLI prompt, IP detect, N Cloudflare Quick Tunnels (load splitting),
QR codes, then uvicorn in-process (workers=1) so the in-memory store lives for
the whole session. On Ctrl+C the lifespan hook in app.py exports the CSVs.

Windows-safe: finds cloudflared on PATH or next to this script; no killall/fuser.
"""

import os
import re
import hashlib
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from datetime import datetime
import ipaddress

import qrcode
import uvicorn

from state import config
from app import app

PORT = int(os.environ.get("PORT", "8000"))


def detect_local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def _find_cloudflared():
    # PATH first: on Termux that's the pkg build, which resolves DNS correctly.
    p = shutil.which("cloudflared")
    if p:
        return p
    here = os.path.dirname(os.path.abspath(__file__))
    for name in ("cloudflared.exe", "cloudflared"):
        cand = os.path.join(here, name)
        if os.path.isfile(cand):
            return cand
    return None


def start_tunnels(port: int, count: int, timeout: float = 30.0):
    """
    Launch `count` Cloudflare Quick Tunnels at the same local server. Each gets
    its own trycloudflare URL; spreading students across them multiplies the
    ~200-in-flight Quick-Tunnel cap (2 tunnels ~= 400 concurrent). Returns
    (procs, urls).
    """
    exe = _find_cloudflared()
    if exe is None:
        print("[tunnel] cloudflared not found on PATH or next to main.py — "
              "LAN-only. Install it for mobile-data clients.")
        return [], []

    # Skip api.trycloudflare.com: it's the endpoint cloudflared calls to *request*
    # a tunnel, and it shows up in the error line when that request fails.
    pat = re.compile(r"https://(?!api\.)[-\w]+\.trycloudflare\.com")
    procs, holders = [], []

    for i in range(count):
        proc = subprocess.Popen(
            # --protocol http2 forces the edge connection over TCP/443 instead of
            # QUIC/UDP (port 7844). Many institutional/Wi-Fi networks block or
            # throttle that UDP, which makes Quick Tunnels assign a URL but never
            # connect -> Cloudflare error 1033. http2 avoids that entirely.
            [exe, "tunnel", "--protocol", "http2",
             "--url", f"http://localhost:{port}"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        holder = {"url": "", "err": ""}

        def reader(p=proc, h=holder):
            for line in p.stdout:
                m = pat.search(line)
                if m and not h["url"]:
                    h["url"] = m.group(0)
                elif " ERR " in line or "failed" in line:
                    h["err"] = line.strip()

        threading.Thread(target=reader, daemon=True).start()
        procs.append(proc)
        holders.append(holder)
        print(f"[tunnel] starting Quick Tunnel {i + 1}/{count}...")

    deadline = time.time() + timeout
    while time.time() < deadline and any(not h["url"] for h in holders):
        time.sleep(0.3)

    urls = [h["url"] for h in holders if h["url"]]
    if len(urls) < count:
        print(f"[tunnel] got {len(urls)}/{count} URLs (others timed out).")
        errs = {h["err"] for h in holders if not h["url"] and h["err"]}
        for e in errs:
            print(f"[tunnel] cloudflared said: {e}")
        if any("[::1]:53" in e for e in errs):
            print("[tunnel] DNS lookup failed. On Termux, use Termux's own build:\n"
                  "           pkg install cloudflared\n"
                  "         and delete the downloaded 'cloudflared' file next to main.py.")
    return procs, urls


def save_qr(url: str, label: str):
    qr = qrcode.QRCode(border=2, box_size=10)
    qr.add_data(url)
    qr.make(fit=True)
    print(f"\n=== {label} ===\n{url}")
    qr.print_ascii(invert=True)
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, f"qr_{label.lower().replace(' ', '_')}.png")
    try:
        try:
            qr.make_image().save(path)
        except ImportError:
            # Lean install (e.g. Termux) has no Pillow: use pure-Python pypng.
            from qrcode.image.pure import PyPNGImage
            qr.make_image(image_factory=PyPNGImage).save(path)
    except ImportError:
        print("[qr] PNG not saved (neither Pillow nor pypng installed) — "
              "scan the QR above or share the URL.")
        path = None
    except Exception:
        path = None
    return path


def open_file(path):
    if not path:
        return
    try:
        if sys.platform.startswith("darwin"):
            subprocess.Popen(["open", path])
        elif os.name == "nt":
            os.startfile(path)  # type: ignore[attr-defined]
        else:
            subprocess.Popen(["xdg-open", path])
    except Exception:
        webbrowser.open("file://" + path)


def load_roster():
    here = os.path.dirname(os.path.abspath(__file__))
    for fname in ("roster.csv", "roster.txt"):
        path = os.path.join(here, fname)
        if os.path.isfile(path):
            ids = set()
            with open(path, encoding="utf-8-sig") as f:
                for line in f:
                    tok = line.strip().split(",")[0].strip()
                    if tok.isdigit():
                        ids.add(tok.lstrip("0") or "0")
            print(f"[roster] {len(ids)} IDs loaded from {fname} — only these accepted.")
            return ids
    print("[roster] no roster file found — any numeric ID is accepted.")
    return set()


def detect_admin_cidrs():
    """
    Find the server's own PRIVATE IPs (Tailscale 100.64/10, or a hotspot/LAN like
    192.168.x / 172.16-31.x / 10.x) and return a /24 (or the tailnet range) for
    each, so a second device you control on the same private network can open the
    admin page. We never include public IPs.
    """
    cidrs, ips = [], []
    try:
        host = socket.gethostname()
        for info in socket.getaddrinfo(host, None):
            ips.append(info[4][0])
    except Exception:
        pass
    # also the primary outbound IP
    try:
        ips.append(detect_local_ip())
    except Exception:
        pass
    seen = set()
    for ip in ips:
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if not addr.is_private or addr.version != 4 or ip in seen:
            continue
        seen.add(ip)
        if ipaddress.ip_address(ip) in ipaddress.ip_network("100.64.0.0/10"):
            cidrs.append("100.64.0.0/10")          # whole tailnet is yours
        else:
            cidrs.append(str(ipaddress.ip_network(ip + "/24", strict=False)))
    return sorted(set(cidrs)), sorted(seen)


def main():
    print("=" * 60)
    print(" Attendance Management System")
    print("=" * 60)

    course = input("Course / subject name: ").strip() or "Session"
    geo = input("Require location access + GPS audit at export? [y/N]: ").strip().lower()
    try:
        ntun = int(input("How many Cloudflare tunnels to open (1-4, more = more "
                         "concurrent capacity) [2]: ").strip() or "2")
    except ValueError:
        ntun = 2
    ntun = max(1, min(ntun, 4))

    remote = input("Allow opening the Admin page from another device on the SAME\n"
                   "private network (Tailscale / your phone hotspot)? [y/N]: ").strip().lower()
    import getpass
    pw = getpass.getpass("Set an admin password (blank = no password, local/"
                         "trusted-network access only): ").strip()

    config.course_name = course
    config.started_at = datetime.now()
    config.page_secret = secrets.token_hex(16)     # signs short-lived page tokens
    if pw:
        config.admin_pw_salt = secrets.token_hex(8)
        config.admin_pw_hash = hashlib.sha256((config.admin_pw_salt + pw).encode()).hexdigest()
    config.port = PORT
    config.local_ip = detect_local_ip()
    config.geofence = (geo == "y")
    if config.geofence:
        try:
            rad = float(input("GPS audit radius in km — flag anyone farther than this\n"
                              "from where most students are [0.5]: ").strip() or "0.5")
            config.audit_radius_km = max(0.05, rad)
        except ValueError:
            config.audit_radius_km = 0.5
    config.ip_tracking = False
    config.tunnel_count = ntun
    config.roster = load_roster()

    admin_ips = []
    if remote == "y":
        config.admin_cidrs, admin_ips = detect_admin_cidrs()
        for cidr in config.admin_cidrs:
            try:
                net = ipaddress.ip_network(cidr, strict=False)
                if net.num_addresses > 2:
                    print(f"[admin] WARNING: trusting {net.num_addresses - 2} other "
                          f"addresses on {cidr}. Set a password if this is a shared network.")
            except ValueError:
                pass

    procs, urls = start_tunnels(PORT, ntun)
    config.tunnel_urls = urls
    # With more than one tunnel we keep students split across origins for load,
    # so disable the single-origin redirect.
    config.force_single_origin = (len(urls) <= 1)

    local_url = f"http://{config.local_ip}:{PORT}"
    print("\n" + "=" * 60)
    print(f" Session : {config.session_id()}")
    print(f" Local   : {local_url}")
    for i, u in enumerate(urls, 1):
        print(f" Tunnel {i}: {u}")
    print(f" Admin   : http://localhost:{PORT}/admin   (this machine)")
    if config.admin_pw_hash:
        print("           🔒 password set — required from phone/tunnel; works anywhere.")
    if config.admin_cidrs and admin_ips:
        for aip in admin_ips:
            print(f"           http://{aip}:{PORT}/admin   (from your other device)")
        print(f"           trusted admin networks: {', '.join(config.admin_cidrs)}")
    if config.geofence:
        print(" Geofence: ON — students must allow location; GPS audit runs at export.")
    print("=" * 60)

    if urls:
        # Project one QR per tunnel; split the class across them (e.g. by seating
        # side) so each tunnel carries part of the load.
        for i, u in enumerate(urls, 1):
            img = save_qr(u, f"Student URL {i}")
            open_file(img)
    else:
        img = save_qr(local_url, "Student URL (LAN)")
        open_file(img)

    server = uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=PORT, workers=1,
                                           log_level="warning"))
    # Lets the admin page's "End session" button stop the server cleanly on every
    # OS (same path as Ctrl+C: the lifespan hook exports, then we land in finally).
    config.request_shutdown = lambda: setattr(server, "should_exit", True)
    try:
        server.run()
    finally:
        for p in procs:
            try:
                p.terminate()
            except Exception:
                pass
        if shutil.which("termux-wake-unlock"):
            # Let the phone sleep normally again (pairs with termux-wake-lock).
            subprocess.run(["termux-wake-unlock"], check=False)
        print("\n[session] ended — server and tunnels stopped. CSVs are in "
              f"{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'exports')}")


if __name__ == "__main__":
    main()
