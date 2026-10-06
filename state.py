"""
state.py
--------
Process-wide shared state for the attendance server.

ONE process / ONE event loop (uvicorn workers=1) is required: all dedup and
storage live in these in-memory objects.
"""

import threading
from datetime import datetime
from dataclasses import dataclass, field


@dataclass
class Config:
    course_name: str = "Session"
    started_at: datetime = field(default_factory=datetime.now)
    ip_tracking: bool = False
    port: int = 8000
    local_ip: str = "127.0.0.1"
    tunnel_urls: list = field(default_factory=list)
    tunnel_count: int = 2
    force_single_origin: bool = True
    roster: set = field(default_factory=set)
    geofence: bool = False
    audit_radius_km: float = 2.0
    page_secret: str = ""
    throttle_n: int = 15
    throttle_window: int = 20
    admin_cidrs: list = field(default_factory=list)
    admin_pw_hash: str = ""
    admin_pw_salt: str = ""

    @property
    def tunnel_url(self) -> str:
        return self.tunnel_urls[0] if self.tunnel_urls else ""

    def session_id(self) -> str:
        # Include microseconds so two back-to-back new-sessions never share a filename.
        stamp = self.started_at.strftime("%Y-%m-%d_%H-%M-%S_%f")
        safe = "".join(c if c.isalnum() or c in " -_" else "_"
                       for c in self.course_name).strip().replace(" ", "_")
        return f"{safe or 'Session'}_{stamp}"


@dataclass
class Store:
    records: list = field(default_factory=list)
    rid_index: dict = field(default_factory=dict)   # rid -> record dict (O(1) lookup)
    client_to_rid: dict = field(default_factory=dict)
    id_to_rid: dict = field(default_factory=dict)
    ip_to_rids: dict = field(default_factory=dict)
    seen_ips: set = field(default_factory=set)
    events: list = field(default_factory=list)      # edits + refused ID conflicts (admin view)
    # Append-only history of every accepted or identity-refused submission.
    # Records are edited in place; this is what the Raw CSV exports, so nothing
    # an edit replaced is ever lost.
    log: list = field(default_factory=list)

    def get(self, rid):
        return self.rid_index.get(rid)

    def add_record(self, r):
        """Append a record and register it in the O(1) rid index."""
        self.records.append(r)
        self.rid_index[r["rid"]] = r

    def add_ip(self, ip, rid):
        if ip:
            self.ip_to_rids.setdefault(ip, [])
            if rid not in self.ip_to_rids[ip]:
                self.ip_to_rids[ip].append(rid)

    def drop_ip(self, ip, rid):
        if ip and ip in self.ip_to_rids and rid in self.ip_to_rids[ip]:
            self.ip_to_rids[ip].remove(rid)
            if not self.ip_to_rids[ip]:
                self.ip_to_rids.pop(ip, None)

    def clear_devices(self):
        """Clear browser identity links; rebuild ID and IP indices from surviving
        records so a student who re-submits after a reset updates their existing
        record rather than creating a duplicate."""
        self.client_to_rid.clear()
        self.seen_ips.clear()
        self.id_to_rid.clear()
        self.ip_to_rids.clear()
        for r in self.records:
            self.id_to_rid[r["id"]] = r["rid"]
            if r.get("ip"):
                self.add_ip(r["ip"], r["rid"])

    def clear_all(self):
        self.records.clear()
        self.rid_index.clear()
        self.events.clear()
        self.log.clear()
        self.client_to_rid.clear()
        self.id_to_rid.clear()
        self.ip_to_rids.clear()
        self.seen_ips.clear()


config = Config()
store = Store()
admin_lock = threading.Lock()
