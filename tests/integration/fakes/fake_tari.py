#!/usr/bin/env python3
"""
Controllable fake Tari base node for the integration mini-stack (issue #54, tier 3).

Implements just the two BaseNode gRPC methods the dashboard's TariClient calls — GetTipInfo
and GetSyncProgress — against the project's own vendored protobuf stubs, so the real client
talks to it unchanged (the client uses an insecure channel, so there's no auth to fake). A
small HTTP `/control` side-channel drives its state.

Run standalone (in the docker mini-stack):
    python3 fake_tari.py --grpc-port 18142 --control-port 18152

Drive it:
    curl -s localhost:18152/control -d '{"mode":"syncing","height":500,"target_height":2000}'
    curl -s localhost:18152/control -d '{"mode":"down"}'

Use in-process (the contract test) via start_server().
"""
import argparse
import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import grpc

from mining_dashboard.client.tari.generated import base_node_pb2 as bn
from mining_dashboard.client.tari.generated import base_node_pb2_grpc as bn_grpc

# mode ∈ {"synced", "syncing", "down"}.
DEFAULT_STATE = {"mode": "synced", "height": 2_000_000, "target_height": 2_000_000}


class FakeBaseNode(bn_grpc.BaseNodeServicer):
    def __init__(self, state):
        self.state = state

    async def GetTipInfo(self, request, context):
        st = self.state
        if st["mode"] == "down":
            await context.abort(grpc.StatusCode.UNAVAILABLE, "fake node down")
        resp = bn.TipInfoResponse()
        resp.metadata.best_block_height = st["height"]
        # initial_sync_achieved is the authoritative "fully synced" flag the client trusts.
        resp.initial_sync_achieved = st["mode"] == "synced"
        return resp

    async def GetSyncProgress(self, request, context):
        st = self.state
        if st["mode"] == "down":
            await context.abort(grpc.StatusCode.UNAVAILABLE, "fake node down")
        resp = bn.SyncProgressResponse()
        resp.local_height = st["height"]
        resp.tip_height = st["target_height"]
        return resp


async def start_server(port, state):
    """Start a gRPC server on `port` (0 = ephemeral). Returns (server, bound_port)."""
    server = grpc.aio.server()
    bn_grpc.add_BaseNodeServicer_to_server(FakeBaseNode(state), server)
    bound = server.add_insecure_port(f"127.0.0.1:{port}")
    await server.start()
    return server, bound


# --- standalone HTTP control side-channel (docker mini-stack only) ----------
class _ControlHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        if self.path.rstrip("/") != "/control":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return
        self.server.state.update(data)
        body = json.dumps(self.server.state).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


class _ControlServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, state):
        super().__init__(addr, _ControlHandler)
        self.state = state


async def _main_async(args, state):
    server, _ = await start_server(args.grpc_port, state)
    ctrl = _ControlServer(("0.0.0.0", args.control_port), state)  # noqa: S104 — test-only
    threading.Thread(target=ctrl.serve_forever, daemon=True).start()
    print(
        f"fake-tari gRPC on :{args.grpc_port}, control on :{args.control_port}",
        flush=True,
    )
    await server.wait_for_termination()


def main():
    ap = argparse.ArgumentParser(description="Controllable fake Tari base node")
    ap.add_argument("--grpc-port", type=int, default=18142)
    ap.add_argument("--control-port", type=int, default=18152)
    ap.add_argument("--mode", default="synced", choices=["synced", "syncing", "down"],
                    help="initial state (the mini-stack boots 'syncing' to exercise the hold)")
    args = ap.parse_args()
    state = dict(DEFAULT_STATE, mode=args.mode)
    if args.mode == "syncing" and state["height"] >= state["target_height"]:
        state["height"], state["target_height"] = 1_000_000, 2_000_000
    try:
        asyncio.run(_main_async(args, state))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
