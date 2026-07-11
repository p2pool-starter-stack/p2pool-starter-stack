#!/usr/bin/env python3
"""
Controllable fake minotari_console_wallet gRPC for Tari payout confirmation (#462, tier 2/3).

Implements just the one streaming method the dashboard's TariWalletClient calls —
GetCompletedTransactions — against the project's own vendored Wallet protobuf stubs, so the real
client talks to it unchanged (the client uses an insecure channel, matching the real wallet's
unauthenticated gRPC). A small HTTP `/control` side-channel sets the canned transaction list.

Run standalone (in the docker mini-stack):
    python3 fake_tari_wallet.py --grpc-port 18143 --control-port 18153

Use in-process (the contract test) via start_server().
"""

import argparse
import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import grpc

from mining_dashboard.client.tari.generated import wallet_pb2, wallet_pb2_grpc

# state["transactions"] is a list of dicts, each a TransactionInfo's fields.
DEFAULT_STATE = {"transactions": []}


class FakeWallet(wallet_pb2_grpc.WalletServicer):
    def __init__(self, state):
        self.state = state

    async def GetCompletedTransactions(self, request, context):
        for t in self.state["transactions"]:
            info = wallet_pb2.TransactionInfo(
                tx_id=int(t.get("tx_id", 0)),
                amount=int(t.get("amount", 0)),
                status=int(t.get("status", 13)),  # COINBASE_CONFIRMED
                direction=int(t.get("direction", 1)),  # INBOUND
                timestamp=int(t.get("timestamp", 0)),
                mined_in_block_height=int(t.get("mined_in_block_height", 0)),
                is_cancelled=bool(t.get("is_cancelled", False)),
            )
            yield wallet_pb2.GetCompletedTransactionsResponse(transaction=info)


async def start_server(port, state, host="127.0.0.1"):
    """Start a gRPC server on `host:port` (port 0 = ephemeral). Returns (server, bound_port).

    Loopback for the in-process contract test; the standalone container passes 0.0.0.0 so the
    dashboard can reach it across the docker network."""
    server = grpc.aio.server()
    wallet_pb2_grpc.add_WalletServicer_to_server(FakeWallet(state), server)
    bound = server.add_insecure_port(f"{host}:{port}")
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
        self.server.state["transactions"] = data.get("transactions", [])
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
    server, _ = await start_server(args.grpc_port, state, host="0.0.0.0")  # noqa: S104 — test container
    ctrl = _ControlServer(("0.0.0.0", args.control_port), state)  # noqa: S104 — test-only
    threading.Thread(target=ctrl.serve_forever, daemon=True).start()
    print(
        f"fake-tari-wallet gRPC on :{args.grpc_port}, control on :{args.control_port}",
        flush=True,
    )
    await server.wait_for_termination()


def main():
    ap = argparse.ArgumentParser(description="Controllable fake minotari console wallet")
    ap.add_argument("--grpc-port", type=int, default=18143)
    ap.add_argument("--control-port", type=int, default=18153)
    args = ap.parse_args()
    asyncio.run(_main_async(args, dict(DEFAULT_STATE)))


if __name__ == "__main__":
    main()
