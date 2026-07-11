#!/usr/bin/env python3
"""
Controllable fake monero-wallet-rpc for the payout-confirmation feature (#381, tier 2/3).

Speaks just enough of monero-wallet-rpc's `get_transfers` JSON-RPC for the dashboard's
MoneroWalletClient to read confirmed incoming payouts, plus a `/control` endpoint to set the
canned transfer list from a test. Lets us prove the real client parses the wire format and honors
`min_height` without a real chain or wallet.

Run standalone (in the docker mini-stack):
    python3 fake_wallet_rpc.py --port 18082

Use in-process (the contract test):
    with FakeWalletRpc(transfers=[...]) as w:
        ...point a real MoneroWalletClient at w.url...
"""

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


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

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "bad json"})
            return
        # /control sets the canned transfer list (drives the docker mini-stack over the network).
        if self.path.rstrip("/") == "/control":
            self.server.state["transfers"] = req.get("transfers", [])
            self._send(200, self.server.state)
            return
        # Everything else is JSON-RPC on /json_rpc.
        method = req.get("method")
        if method == "get_version":
            self._send(200, {"jsonrpc": "2.0", "id": "0", "result": {"version": 65558}})
            return
        if method == "get_transfers":
            params = req.get("params") or {}
            min_height = int(params.get("min_height", 0) or 0)
            rows = [
                t for t in self.server.state["transfers"] if int(t.get("height", 0)) >= min_height
            ]
            self._send(200, {"jsonrpc": "2.0", "id": "0", "result": {"in": rows}})
            return
        self._send(200, {"jsonrpc": "2.0", "id": "0", "error": {"code": -32601, "message": method}})


class _Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, state):
        super().__init__(addr, _Handler)
        self.state = state


class FakeWalletRpc:
    """Context manager that runs the fake on an ephemeral port in a background thread."""

    def __init__(self, port=0, host="127.0.0.1", transfers=None):
        self.state = {"transfers": list(transfers or [])}
        self._srv = _Server((host, port), self.state)
        self.host, self.port = self._srv.server_address

    @property
    def url(self):
        return f"http://{self.host}:{self.port}/json_rpc"

    def set(self, transfers):
        self.state["transfers"] = list(transfers)

    def __enter__(self):
        self._thread = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_exc):
        self._srv.shutdown()
        self._srv.server_close()


def main():
    ap = argparse.ArgumentParser(description="Controllable fake monero-wallet-rpc")
    ap.add_argument("--port", type=int, default=18082)
    ap.add_argument("--host", default="0.0.0.0")  # noqa: S104 — test-only container
    args = ap.parse_args()
    srv = _Server((args.host, args.port), {"transfers": []})
    print(f"fake-wallet-rpc listening on {args.host}:{args.port}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
