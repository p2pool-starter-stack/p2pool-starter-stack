import logging

import requests
from requests.auth import HTTPDigestAuth

from mining_dashboard.config.config import (
    MONERO_WALLET_RPC_URL,
    WALLET_RPC_PASSWORD,
    WALLET_RPC_USERNAME,
)

logger = logging.getLogger("MoneroWalletClient")

# Monero amounts are reported in atomic units (piconero); 1 XMR = 1e12 atomic.
ATOMIC_PER_XMR = 1_000_000_000_000


class MoneroWalletClient:
    """
    Reads confirmed incoming payouts from a view-only ``monero-wallet-rpc`` (#381).

    The stack runs monero-wallet-rpc generated from the operator's PRIVATE VIEW KEY (empty spend
    key) against the LOCAL monerod — it can SCAN but never spend. This client polls
    ``get_transfers {"in": true}`` on a slow cadence to confirm that P2Pool coinbase payouts
    actually landed in the wallet, the only ground truth (the earnings figure elsewhere is an
    estimate).

    monero-wallet-rpc runs with ``--rpc-login``, so calls use HTTP digest auth. Synchronous
    (requests + HTTPDigestAuth); the async data loop calls it via ``asyncio.to_thread``, mirroring
    :class:`MoneroClient`. Every failure mode returns ``None`` / ``[]`` so a wallet still doing its
    first-run scan (or briefly unreachable) degrades the feature quietly rather than raising.
    """

    def __init__(
        self,
        url=MONERO_WALLET_RPC_URL,
        username=WALLET_RPC_USERNAME,
        password=WALLET_RPC_PASSWORD,
        timeout=10,
    ):
        self.url = url
        # No creds → send unauthenticated; the request simply fails and the caller degrades.
        self._auth = HTTPDigestAuth(username, password) if username else None
        self.timeout = timeout

    def _rpc(self, method, params=None):
        """POST one JSON-RPC call; return the ``result`` dict, or None on any error."""
        payload = {"jsonrpc": "2.0", "id": "0", "method": method, "params": params or {}}
        try:
            resp = requests.post(self.url, json=payload, auth=self._auth, timeout=self.timeout)
        except requests.RequestException as e:
            logger.warning(f"wallet-rpc {method} unreachable at {self.url}: {e}")
            return None
        if resp.status_code != 200:
            logger.warning(f"wallet-rpc {method} returned HTTP {resp.status_code}")
            return None
        try:
            data = resp.json()
        except ValueError:
            logger.error(f"wallet-rpc {method} returned a non-JSON body")
            return None
        # monero-wallet-rpc reports errors as a top-level "error" object, not an HTTP status.
        if "error" in data and data["error"]:
            logger.warning(f"wallet-rpc {method} error: {data['error']}")
            return None
        return data.get("result") or {}

    def get_confirmed_payouts(self, min_height=0):
        """Return confirmed incoming transfers at or above ``min_height`` as normalized dicts.

        Seeds ``min_height`` from the highest payout already stored so a restart re-fetches only
        the tip (and idempotent storage drops the overlap) rather than replaying history. Each row
        is ``{"txid", "height", "ts", "amount_atomic", "amount_xmr"}``; the caller records atomic
        and converts to XMR only at the display edge. Returns ``[]`` when the wallet is still
        scanning, unreachable, or has no transfers — never raises.

        ``coinbase: true`` includes the P2Pool coinbase payouts (each miner's PPLNS share is paid
        directly in a Monero block's coinbase). ``filter_by_height`` + ``min_height`` bound the
        scan server-side. Coinbase outputs unlock only after 60 blocks; we record on CONFIRMATION
        (in a block), not on unlock, so a still-locked payout is captured once and never re-alerted.
        """
        result = self._rpc(
            "get_transfers",
            {
                "in": True,
                "coinbase": True,
                "filter_by_height": True,
                "min_height": int(min_height or 0),
            },
        )
        if result is None:
            return []
        payouts = []
        for t in result.get("in", []) or []:
            txid = t.get("txid")
            amount = t.get("amount")
            if not txid or amount is None:
                continue  # a transfer with no txid/amount is unusable — skip rather than store junk
            amount_atomic = int(amount)
            payouts.append(
                {
                    "txid": txid,
                    "height": int(t.get("height", 0) or 0),
                    "ts": float(t.get("timestamp", 0) or 0),
                    "amount_atomic": amount_atomic,
                    "amount_xmr": amount_atomic / ATOMIC_PER_XMR,
                }
            )
        return payouts
