from unittest.mock import AsyncMock, MagicMock, patch

import mining_dashboard.client.tari.tari_wallet_client as wallet_mod
from mining_dashboard.client.tari.tari_wallet_client import TariWalletClient


def _tx(
    tx_id=1,
    amount=250_000,
    height=100,
    ts=1000,
    direction=1,  # INBOUND
    status=13,  # COINBASE_CONFIRMED
    is_cancelled=False,
):
    """A stand-in TransactionInfo with only the fields the client reads."""
    t = MagicMock()
    t.tx_id = tx_id
    t.amount = amount
    t.mined_in_block_height = height
    t.timestamp = ts
    t.direction = direction
    t.status = status
    t.is_cancelled = is_cancelled
    return t


def _stream(*txs):
    """An async iterator of GetCompletedTransactionsResponse-like objects, as the streaming RPC
    returns. The stub call itself returns this iterator (not a coroutine)."""

    async def _gen(request, **_kwargs):  # accepts timeout=... from the client call
        for t in txs:
            resp = MagicMock()
            resp.transaction = t
            yield resp

    return _gen


def _client_with_stub(*txs):
    client = TariWalletClient()
    stub = MagicMock()
    stub.GetCompletedTransactions = _stream(*txs)
    client._channel = MagicMock()
    client._channel.close = AsyncMock()
    client._stub = stub  # _ensure_channel returns this since _channel is set
    return client, stub


class TestConstruction:
    def test_defaults_to_config_address(self):
        c = TariWalletClient()
        assert c.grpc_address and c._channel is None

    def test_ensure_channel_builds_stub_once(self):
        # A fresh client lazily opens a channel + stub; a second call reuses them. The channel
        # factory is mocked so no real gRPC connection (or event loop) is needed.
        c = TariWalletClient(grpc_address="127.0.0.1:18143")
        with patch.object(wallet_mod.grpc.aio, "insecure_channel", return_value=MagicMock()) as mk:
            stub1 = c._ensure_channel()
            assert stub1 is not None and c._channel is not None
            assert c._ensure_channel() is stub1  # no second channel
        assert mk.call_count == 1

    async def test_close_drops_the_channel(self):
        c = TariWalletClient()
        c._channel = MagicMock()
        c._channel.close = AsyncMock()
        c._stub = MagicMock()
        await c.close()
        assert c._channel is None and c._stub is None


class TestGetConfirmedPayouts:
    async def test_parses_confirmed_inbound_payouts(self):
        client, _ = _client_with_stub(
            _tx(tx_id=11, amount=250_000, height=100, ts=1000),
            _tx(tx_id=22, amount=500_000, height=101, ts=2000),
        )
        out = await client.get_confirmed_payouts(min_height=0)
        assert [p["txid"] for p in out] == ["11", "22"]
        assert out[0]["amount_atomic"] == 250_000
        assert out[0]["amount_xtm"] == 0.25  # 250_000 µT / 1e6
        assert out[1]["height"] == 101 and out[1]["ts"] == 2000.0

    async def test_min_height_filters_below_the_tip(self):
        client, _ = _client_with_stub(
            _tx(tx_id=1, height=100),
            _tx(tx_id=2, height=300),
        )
        out = await client.get_confirmed_payouts(min_height=200)
        assert [p["txid"] for p in out] == ["2"]

    async def test_unmined_transactions_are_skipped(self):
        # A payout is confirmed only once mined into a block (height > 0). A pending tx (height 0)
        # must not be recorded — it isn't ground truth yet.
        client, _ = _client_with_stub(_tx(tx_id=1, height=0), _tx(tx_id=2, height=5))
        out = await client.get_confirmed_payouts()
        assert [p["txid"] for p in out] == ["2"]

    async def test_cancelled_transactions_are_skipped(self):
        client, _ = _client_with_stub(_tx(tx_id=1, is_cancelled=True), _tx(tx_id=2))
        out = await client.get_confirmed_payouts()
        assert [p["txid"] for p in out] == ["2"]

    async def test_outbound_non_coinbase_is_skipped(self):
        # An OUTBOUND transfer that isn't a coinbase status is not an incoming payout.
        client, _ = _client_with_stub(
            _tx(tx_id=1, direction=2, status=0),  # OUTBOUND, plain
            _tx(tx_id=2, direction=1),  # INBOUND
        )
        out = await client.get_confirmed_payouts()
        assert [p["txid"] for p in out] == ["2"]

    async def test_coinbase_status_counts_even_if_direction_unknown(self):
        # A coinbase reported with an UNKNOWN direction still counts via the coinbase-status set.
        client, _ = _client_with_stub(_tx(tx_id=9, direction=0, status=5))
        out = await client.get_confirmed_payouts()
        assert [p["txid"] for p in out] == ["9"]

    async def test_non_numeric_field_is_skipped_not_aborting_scan(self):
        # A field that can't be coerced to a number raises in the parse block; skip that row, keep
        # scanning (the good one still parses).
        client, _ = _client_with_stub(
            _tx(tx_id=1, amount="not-a-number", height=10),
            _tx(tx_id=2, amount=20, height=11),
        )
        out = await client.get_confirmed_payouts()
        assert [p["txid"] for p in out] == ["2"]

    async def test_out_of_range_amount_is_skipped_not_aborting_scan(self):
        # A poison amount (>= 2**63) must skip just that row, not abort the whole scan — otherwise
        # min_height never advances and the bad row is re-fetched forever (#381 hardening).
        client, _ = _client_with_stub(
            _tx(tx_id=1, amount=2**63, height=10),  # overflows INTEGER
            _tx(tx_id=2, amount=42, height=11),  # good
        )
        out = await client.get_confirmed_payouts()
        assert [p["txid"] for p in out] == ["2"]

    async def test_grpc_error_returns_empty(self):
        client = TariWalletClient()

        def _boom(request, timeout=None):
            raise RuntimeError("channel down")

        stub = MagicMock()
        stub.GetCompletedTransactions = _boom
        client._channel = MagicMock()
        client._channel.close = AsyncMock()
        client._stub = stub
        assert await client.get_confirmed_payouts() == []
        # The channel is reset so the next call reconnects.
        assert client._channel is None

    async def test_no_transactions_reads_empty(self):
        client, _ = _client_with_stub()
        assert await client.get_confirmed_payouts() == []
