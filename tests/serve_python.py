"""
Start the Python attendance server in a fixed test configuration, for
tests/scenarios.py. Not for real sessions (use run.py).

    python tests/serve_python.py --port 8765 [--no-password] [--export-dir DIR]

Test configuration: geofence on, audit radius 0.5 km, admin password "pw"
(unless --no-password), course "Scenario".
"""

import argparse
import hashlib
import os
import secrets
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8765)
ap.add_argument("--no-password", action="store_true")
ap.add_argument("--export-dir")
ap.add_argument("--roster", help="roster CSV/TXT to enforce")
args = ap.parse_args()

import app as app_module  # noqa: E402
from state import config  # noqa: E402

if args.export_dir:
    os.makedirs(args.export_dir, exist_ok=True)
    app_module.EXPORT_DIR = args.export_dir

config.course_name = "Scenario"
config.page_secret = secrets.token_hex(16)
config.geofence = True
config.audit_radius_km = 0.5
if args.roster:
    with open(args.roster, encoding="utf-8-sig") as f:
        config.roster = app_module.parse_roster(f.read())
if not args.no_password:
    config.admin_pw_salt = "salt"
    config.admin_pw_hash = hashlib.sha256(b"salt" + b"pw").hexdigest()

import uvicorn  # noqa: E402

server = uvicorn.Server(uvicorn.Config(app_module.app, host="127.0.0.1", port=args.port,
                                       workers=1, log_level="warning"))
config.request_shutdown = lambda: setattr(server, "should_exit", True)
server.run()
