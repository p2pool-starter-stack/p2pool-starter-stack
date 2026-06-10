#!/usr/bin/env python3
"""
Controllable fake monerod for the integration mini-stack (issue #54, tier 3).

Speaks just enough of monerod's `get_info` RPC for the dashboard's MoneroClient to read it,
plus a `/control` endpoint to drive its state from a test. Lets us reproduce the whole Monero
side of the runtime state machine — syncing %, synced, unreachable, pruned/full DB size —
deterministically, with no real chain.

Run standalone (in the docker mini-stack):
    python3 fake_monerod.py --port 18081

Drive it:
    curl -s localhost:18081/control -d '{"mode":"syncing","height":1500,"target_height":3000}'
    curl -s localhost:18081/control -d '{"mode":"down"}'
    curl -s localhost:18081/get_info

Use in-process (the contract test):
    with FakeMonerod() as m:
        m.set(mode="syncing", height=1500, target_height=3000)
        ...point a real MoneroClient at m.url...
"""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# mode ∈ {"synced", "syncing", "down"}. height/target_height/database_size are the figures
# get_info returns; the client derives sync %/DB size from them (MoneroClient.get_sync_status).
DEFAULT_STATE = {
    "mode": "synced",
    "height": 3_000_000,
    "target_height": 3_000_000,
    "database_size": 85 * 10**9,
}


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):  # keep the test output clean
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") != "/get_info":
            self._send(404, {"status": "NOT_FOUND"})
            return
        st = self.server.state
        # "down" → unreachable: monerod's RPC not answering. A non-200 makes MoneroClient
        # treat the node as unreachable (get_info returns None), which is what we want.
        if st["mode"] == "down":
            self._send(503, {"status": "BUSY"})
            return
        # "busy" → RPC answers HTTP 200 but reports a non-OK status (e.g. mid-reorg). The
        # client must distrust the heights and treat it as unreachable, not as synced.
        if st["mode"] == "busy":
            self._send(200, {"status": "BUSY", "height": st["height"],
                             "target_height": st["target_height"]})
            return
        if st["mode"] == "syncing":
            payload = {
                "status": "OK",
                "synchronized": False,
                "height": st["height"],
                "target_height": st["target_height"],
                "database_size": st["database_size"],
            }
        else:  # synced — monerod reports synchronized and target_height 0 once caught up
            payload = {
                "status": "OK",
                "synchronized": True,
                "height": st["height"],
                "target_height": 0,
                "database_size": st["database_size"],
            }
        self._send(200, payload)

    def do_POST(self):
        if self.path.rstrip("/") != "/control":
            self._send(404, {"status": "NOT_FOUND"})
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "bad json"})
            return
        self.server.state.update(data)
        self._send(200, self.server.state)


class _Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, state):
        super().__init__(addr, _Handler)
        self.state = state


class FakeMonerod:
    """Context manager that runs the fake on an ephemeral port in a background thread."""

    def __init__(self, port=0, host="127.0.0.1", **state):
        self.state = {**DEFAULT_STATE, **state}
        self._srv = _Server((host, port), self.state)
        self.host, self.port = self._srv.server_address

    @property
    def url(self):
        return f"http://{self.host}:{self.port}"

    def set(self, **kwargs):
        self.state.update(kwargs)

    def __enter__(self):
        self._thread = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_exc):
        self._srv.shutdown()
        self._srv.server_close()


def main():
    ap = argparse.ArgumentParser(description="Controllable fake monerod")
    ap.add_argument("--port", type=int, default=18081)
    ap.add_argument("--host", default="0.0.0.0")  # noqa: S104 — test-only container
    ap.add_argument("--mode", default="synced", choices=["synced", "syncing", "down"],
                    help="initial state (the mini-stack boots 'syncing' to exercise the hold)")
    args = ap.parse_args()
    state = dict(DEFAULT_STATE, mode=args.mode)
    # "syncing" needs height < target_height to read as syncing (else it looks caught up).
    if args.mode == "syncing" and state["height"] >= state["target_height"]:
        state["height"], state["target_height"] = 1_500_000, 3_000_000
    srv = _Server((args.host, args.port), state)
    print(f"fake-monerod listening on {args.host}:{args.port} (mode={args.mode})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
