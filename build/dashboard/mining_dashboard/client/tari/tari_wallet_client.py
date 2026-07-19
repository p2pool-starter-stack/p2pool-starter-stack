import logging

import grpc

from mining_dashboard.config.config import TARI_WALLET_GRPC_ADDRESS
from mining_dashboard.service.earnings import MICRO_PER_XTM

logger = logging.getLogger("TariWalletClient")

from .generated import wallet_pb2, wallet_pb2_grpc

# A payout is "confirmed" the moment it is mined into a block (mined_in_block_height > 0), NOT when
# the coinbase matures — mirrors #381's Monero rule so a payout is recorded/alerted exactly once.
# The direction/status gate is generous on purpose: p2pool's Tari coinbase is a one-sided output to
# wallet_payment_address, and which enum a view-only wallet reports it under
# (COINBASE_CONFIRMED vs ONE_SIDED_CONFIRMED vs a plain INBOUND) is the one item pinned to tier-4
# (the live bench). Keeping the accept-set here isolated means tightening it after that check is a one-line
# change. Enum values are the wallet.proto constants (TransactionStatus / TransactionDirection).
_DIRECTION_INBOUND = 1  # TRANSACTION_DIRECTION_INBOUND
_COINBASE_STATUSES = frozenset(
    {
        5,  # TRANSACTION_STATUS_COINBASE
        6,  # TRANSACTION_STATUS_MINED_CONFIRMED
        9,  # TRANSACTION_STATUS_ONE_SIDED_CONFIRMED
        13,  # TRANSACTION_STATUS_COINBASE_CONFIRMED
    }
)


class TariWalletClient:
    """
    Reads confirmed incoming payouts from a view-only ``minotari_console_wallet`` (#462).

    The Tari sibling of :class:`MoneroWalletClient` (#381). The stack runs a view-only console
    wallet — created from the operator's PRIVATE VIEW KEY + PUBLIC SPEND KEY — against the LOCAL
    Tari node; it can SCAN but never spend. This client streams ``GetCompletedTransactions`` on a
    slow cadence to confirm a Tari merge-mine coinbase actually landed (solo merge-mining pays the
    whole block reward at once, ~72 days apart at prod hashrate, so a confirmed payout is a rare,
    large event worth an alert).

    Async (grpc.aio), mirroring :class:`TariClient`; the wallet gRPC is unauthenticated (insecure
    channel), same as the base node. Every failure mode returns ``[]`` so a wallet still doing its
    first-run scan (or briefly unreachable) degrades the feature quietly rather than raising.

    ``get_confirmed_payouts`` delegates the scan to ``_scan_completed_transactions``; if tier-4
    shows the coinbase surfaces only via ``GetBalance``/``GetUnspentAmounts`` and not the completed-
    transactions stream, swapping the scan source is a one-method change here.
    """

    def __init__(self, grpc_address=TARI_WALLET_GRPC_ADDRESS, timeout=15):
        self.grpc_address = grpc_address
        self.timeout = timeout
        self._channel = None
        self._stub = None

    def _ensure_channel(self):
        if self._channel is None:
            self._channel = grpc.aio.insecure_channel(self.grpc_address)
            self._stub = wallet_pb2_grpc.WalletStub(self._channel)
        return self._stub

    async def _reset_channel(self):
        """Drop the gRPC channel so the next call reconnects (used after errors)."""
        if self._channel:
            await self._channel.close()
        self._channel = None
        self._stub = None

    async def get_confirmed_payouts(self, min_height=0):
        """Return confirmed incoming payouts at or above ``min_height`` as normalized dicts.

        The caller seeds ``min_height`` from the highest stored Tari payout height, so a restart
        re-scans only the tip (idempotent storage drops the overlap). Each row is
        ``{"txid", "height", "ts", "amount_atomic", "amount_xtm"}`` — ``amount_atomic`` is native
        microTari, kept in the shared ``payouts`` table's atomic column and converted to XTM only at
        the display/alert edge. Returns ``[]`` when the wallet is still scanning, unreachable, or has
        no payouts — never raises."""
        try:
            stub = self._ensure_channel()
            transactions = await self._scan_completed_transactions(stub)
        except Exception as e:  # noqa: BLE001 — any gRPC/scan failure degrades to a quiet no-op
            logger.warning(f"Tari wallet gRPC unreachable at {self.grpc_address}: {e}")
            await self._reset_channel()
            return []
        return self._normalize(transactions, int(min_height or 0))

    async def _scan_completed_transactions(self, stub):
        """Collect the wallet's completed transactions from the server-streaming RPC.

        Isolated so the scan SOURCE is a single seam: the tier-4-gated fallback (GetBalance /
        GetUnspentAmounts) replaces just this method if the coinbase turns out not to surface here."""
        request = wallet_pb2.GetCompletedTransactionsRequest()
        out = []
        async for response in stub.GetCompletedTransactions(request, timeout=self.timeout):
            out.append(response.transaction)
        return out

    def _normalize(self, transactions, min_height):
        """Filter to confirmed inbound payouts at/above ``min_height`` and normalize to dicts.

        A malformed field (non-numeric / out of signed-64 range) skips just that transfer rather
        than aborting the whole scan — otherwise a single poison row would re-fetch forever and
        never let ``min_height`` advance (the #381 poller-hardening fix). The 64-bit bound also
        keeps the storage layer's INTEGER insert from raising OverflowError."""
        payouts = []
        for t in transactions:
            if getattr(t, "is_cancelled", False):
                continue
            # A confirmed payout is one mined into a block and coming IN to us. The direction/status
            # gate is deliberately generous (see module note) — tier-4 tightens it.
            direction = getattr(t, "direction", 0)
            status = getattr(t, "status", 0)
            if direction != _DIRECTION_INBOUND and status not in _COINBASE_STATUSES:
                continue
            try:
                height = int(getattr(t, "mined_in_block_height", 0) or 0)
                amount_atomic = int(getattr(t, "amount", 0) or 0)
                ts = float(getattr(t, "timestamp", 0) or 0)
                txid = str(getattr(t, "tx_id", "") or "")
            except (ValueError, TypeError):
                continue
            if not txid or height <= 0 or height < min_height:
                continue  # not mined yet, or below the tip we already stored
            if not 0 <= amount_atomic < 2**63:
                continue
            payouts.append(
                {
                    "txid": txid,
                    "height": height,
                    "ts": ts,
                    "amount_atomic": amount_atomic,
                    "amount_xtm": amount_atomic / MICRO_PER_XTM,
                }
            )
        return payouts

    async def close(self):
        if self._channel:
            await self._channel.close()
            self._channel = None
            self._stub = None
