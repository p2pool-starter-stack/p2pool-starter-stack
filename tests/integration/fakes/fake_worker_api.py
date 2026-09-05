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

# Sentinel: `control=None` is a real wire value (the fresh-rig case), so it cannot double as "no
# override given".
_UNSET = object()

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

# Every key here is one the real producer emits, and the set is pinned against RigForge's own
# committed wire fixture by `test_fake_matches_the_vendored_wire_contract` — see contract/v1/. The
# VALUES are deliberately ours and deliberately not the fixture's: the fixture is a normalized,
# hardware-independent capture whose numeric fields are mostly null, which would exercise the
# consumers' default-everything path and nothing else. So the fixture pins the SHAPE and this pins
# realistic content. Units match the real feed: H/s, W, °C, MT/s.
#
# `msr`/`smt` are strings and not booleans because that is what the producer sends ("ok"/"fail"/
# "none"; the SMT control value or null). Nothing in the dashboard reads either one — they are here
# so the shape guard has the whole block to compare, not because a consumer depends on them.
_RIGFORGE_BLOCK = {
    "version": "1.16.0",
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
        "hugepages_1g": 0,
        "governor": "performance",
        "msr": "ok",
        "smt": "on",
        "xmp": True,
        "ram": {"channels": 2, "modules": 2, "mts": 6000, "rated_mts": 6000},
        "firmware": {"vendor": "ASUS", "board": "ProArt X670E"},
        "clock_pct_of_boost": 98,
        "throttling": False,
    },
    "watchdog": {
        "mode": "enabled",
        "thermal_hold": False,
        "temp_c": 62,
        "max_temp_c": 85,
        "resumes_below_c": 80,
        "strikes": 0,
    },
    # The rig's EFFECTIVE writable config (rigforge#253), what Worker Inspect prefills from (#1235).
    # Exactly the six writable keys. `pools[].pass` is the {"__secret__": true} marker: since the
    # ref PROVENANCE names, the producer serves a STORED pool password as that marker and omits the
    # key when none is stored (rigforge#415), so a contract-shaped body still never carries a
    # credential. The credential-strip defence is proven at tier 1 against a deliberately hostile
    # body and not here; testing it here too would be the same behaviour at two tiers.
    "config": {
        "pools": [{"url": "itest-proxy:3333", "pass": {"__secret__": True}}],
        "DONATION": 1,
        "autotune": "disabled",
        "watchdog": "enabled",
        "watchdog_interval_min": 5,
        "max_temp_c": 85,
    },
    # Where that config came from, in the rig's own words (rigforge#254, consumed by #1345).
    "config_meta": {
        "revision": "50c51399833d2a28",
        "changed_at": "2026-08-24T09:15:00Z",
        "source": "control",
        "last_change_id": "7777777777777777",
    },
    # The rig's last control outcome, mirrored into this same read feed (#579, rigforge#346).
    "control": {
        "change_id": "7777777777777777",
        "status": "rolled_back",
        "reason": "miner did not return to a live hashrate; rolled back and live",
    },
}


def enriched_body(miner_down=False, control=_UNSET):
    """The bytes the api-server ships: the XMRig summary + `rigforge`, or the miner-down body.

    ``control`` overrides ``rigforge.control``. Pass ``None`` for the fresh-rig wire shape: the key
    is still served, with a null value, because the producer's jq falls back to a literal ``null``
    when no control change has ever been recorded — it does not omit the key.
    """
    block = dict(_RIGFORGE_BLOCK)
    if control is not _UNSET:
        block["control"] = control
    if miner_down:
        # XMRig keys drop; only the RigForge block serves, flagged unreachable (rigforge#99). The
        # whole block still serves on this path — config/config_meta/control included.
        return {"rigforge": {**block, "xmrig_api": "unreachable"}}
    return {**_XMRIG_SUMMARY, "rigforge": block}


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
            self._send(200, enriched_body(cfg["miner_down"], cfg["control"]))

    return _Handler


class _Server(ThreadingHTTPServer):
    daemon_threads = True


class FakeWorkerApi:
    """Context manager running the fake on an ephemeral loopback port in a background thread.

    ``auth`` ∈ {none, name, token}; ``name``/``token`` are the expected bearer values for those
    modes. ``miner_down`` serves the up-but-miner-unreachable body.
    """

    def __init__(
        self,
        auth="none",
        name="rig1",
        token="",
        miner_down=False,
        host="127.0.0.1",
        control=_UNSET,
    ):
        self.cfg = {
            "auth": auth,
            "name": name,
            "token": token,
            "miner_down": miner_down,
            "control": control,
        }
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
    cfg = {
        "auth": args.auth,
        "name": args.name,
        "token": args.token,
        "miner_down": args.miner_down,
        "control": _UNSET,
    }
    srv = _Server((args.host, args.port), _make_handler(cfg))
    print(f"fake-worker-api on {args.host}:{args.port} (auth={args.auth})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
