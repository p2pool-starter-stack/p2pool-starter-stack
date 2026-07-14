"""Controllable fake RigForge worker API for the worker ↔ dashboard contract test (#209).

Serves the enriched ``/1/summary`` a RigForge rig exposes on its ``api_port`` (rigforge#99 / #235):
the whole XMRig ``/1/summary`` object plus one added ``rigforge`` key. The point of the tier-2
contract test is to run the REAL ``XMRigWorkerClient`` against this over a real socket, so a drift in
either the auth handshake or the enriched-feed shape goes red here instead of only on a live rig.

Auth mirrors the verified producer contract (rigforge origin/main @ v1.7.0):
  - ``none``  — open, unauthenticated (the stock RigForge worker API).
  - ``name``  — ``Authorization: Bearer <stratum name>`` (xmrig access-token == the rig's name).
  - ``token`` — ``Authorization: Bearer <shared token>``.
A missing/mismatched bearer in name/token mode is a 401 (never echoes the expected value).

Set ``miner_down=True`` to serve the "RigForge up, XMRig unreachable" body — the ``rigforge`` block
alone with ``xmrig_api: "unreachable"`` and no XMRig keys, which the UI shows as up-but-miner-down.

Stdlib only (shares the dashboard image), so it also runs as ``__main__`` for a mini-stack container.
Units on the wire match the real feed: H/s, W, °C, MT/s.
"""

import argparse
import hmac
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# A compact but real-shaped enriched /1/summary. The XMRig keys are a trimmed but valid subset (the
# dashboard reads hashrate/connection from the proxy, not here); the `rigforge` block carries every
# field parse_rigforge() reads, with the producer's real names and units.
_XMRIG_SUMMARY = {
    "id": "itest-worker",
    "worker_id": "rig1",
    "version": "6.24.0",
    "hashrate": {"total": [5100.0, 5090.0, 5000.0], "highest": 5200.0},
    "connection": {"pool": "itest-proxy:3333", "uptime": 3600, "accepted": 42, "rejected": 0},
}

_RIGFORGE_BLOCK = {
    "version": "1.7.0",
    "xmrig_version": "6.24.0",
    "xmrig_commit": "abcdef0",
    "tune": {
        "applied": True,
        "target": "perf",
        "last_best_hs": 5200.0,
        "candidates_tried": 4,
        "autotune": {"enabled": True, "target": "perf", "schedule": "weekly", "next": "Sun 03:00"},
    },
    "power": {"watts": 142.0, "hs_per_watt": 35.9},
    "health": {
        "service_active": True,
        "hugepages_total": 1280,
        "governor": "performance",
        "msr": True,
        "smt": True,
        "xmp": True,
        "firmware": {"vendor": "ASUS", "board": "ProArt X670E"},
        "clock_pct_of_boost": 98,
        "throttling": False,
    },
    "watchdog": {"mode": "enabled", "thermal_hold": False, "temp_c": 62, "max_temp_c": 85},
}


def enriched_body(miner_down=False):
    """The bytes the api-server ships: the XMRig summary + `rigforge`, or the miner-down body."""
    if miner_down:
        # XMRig keys drop; only the RigForge block serves, flagged unreachable (rigforge#99).
        return {"rigforge": {**_RIGFORGE_BLOCK, "xmrig_api": "unreachable"}}
    return {**_XMRIG_SUMMARY, "rigforge": dict(_RIGFORGE_BLOCK)}


def _make_handler(cfg):
    class _Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):  # keep test output clean
            pass

        def _send(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _authed(self):
            mode = cfg["auth"]
            if mode == "none":
                return True
            expected = cfg["name"] if mode == "name" else cfg["token"]
            got = (self.headers.get("Authorization") or "").strip()
            # Constant-time compare, like the real producer; never echo the expected value.
            return bool(expected) and hmac.compare_digest(
                got.encode(), (f"Bearer {expected}").encode()
            )

        def do_GET(self):
            # RigForge maps both /1/summary and /2/summary to the same precomputed body.
            if self.path.split("?", 1)[0] not in ("/1/summary", "/2/summary"):
                return self._send(404, {"error": "not found"})
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            self._send(200, enriched_body(cfg["miner_down"]))

    return _Handler


class _Server(ThreadingHTTPServer):
    daemon_threads = True


class FakeWorkerApi:
    """Context manager running the fake on an ephemeral loopback port in a background thread.

    ``auth`` ∈ {none, name, token}; ``name``/``token`` are the expected bearer values for those
    modes. ``miner_down`` serves the up-but-miner-unreachable body.
    """

    def __init__(self, auth="none", name="rig1", token="", miner_down=False, host="127.0.0.1"):
        self.cfg = {"auth": auth, "name": name, "token": token, "miner_down": miner_down}
        self._srv = _Server((host, 0), _make_handler(self.cfg))
        self.host, self.port = self._srv.server_address

    def set(self, **kwargs):
        self.cfg.update(kwargs)

    def __enter__(self):
        self._thread = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_exc):
        self._srv.shutdown()
        self._srv.server_close()


def main():
    ap = argparse.ArgumentParser(description="Controllable fake RigForge worker API (#209)")
    ap.add_argument("--port", type=int, default=8081)
    ap.add_argument("--host", default="0.0.0.0")  # noqa: S104 — test-only container
    ap.add_argument("--auth", default="none", choices=["none", "name", "token"])
    ap.add_argument("--name", default="rig1", help="expected stratum name for --auth name")
    ap.add_argument("--token", default="", help="expected bearer token for --auth token")
    ap.add_argument("--miner-down", action="store_true", help="serve the up-but-miner-down body")
    args = ap.parse_args()
    cfg = {"auth": args.auth, "name": args.name, "token": args.token, "miner_down": args.miner_down}
    srv = _Server((args.host, args.port), _make_handler(cfg))
    print(f"fake-worker-api on {args.host}:{args.port} (auth={args.auth})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
