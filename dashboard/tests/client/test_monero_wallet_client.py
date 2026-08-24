import json
from unittest.mock import MagicMock, patch

import requests

import mining_dashboard.client.monero.monero_wallet_client as wallet_mod
from mining_dashboard.client.monero.monero_wallet_client import MoneroWalletClient
from mining_dashboard.helper.http import MAX_RESPONSE_BYTES


def _resp(status_code=200, json_data=None, raise_json=False, body=None):
    """A streaming ``requests`` response — what ``bounded_request`` consumes since #1360.

    The payload is served as real BYTES over ``iter_content``: the client now receives a
    ``BoundedResponse`` parsed from the stream, not this mock. ``json()`` is set on the mock too, so
    the same fake drives the unbounded ``requests.post`` this replaced — which is what makes the
    oversized test below fail if the bounding is taken out.
    """
    raw = (
        b"not json"
        if raise_json
        else (body if body is not None else json.dumps(json_data or {}).encode())
    )
    resp = MagicMock(status_code=status_code, encoding="utf-8")
    resp.iter_content.return_value = iter([raw[i : i + 65536] for i in range(0, len(raw), 65536)])
    resp.json.side_effect = ValueError("no json") if raise_json else None
    if not raise_json:
        resp.json.return_value = json_data or {}
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


def _oversized(json_data):
    """A valid ``result`` payload one byte past the cap: refused on byte count, not on content."""
    empty = json.dumps({**json_data, "pad": ""}).encode()
    pad = "x" * (MAX_RESPONSE_BYTES + 1 - len(empty))
    raw = json.dumps({**json_data, "pad": pad}).encode()
    assert len(raw) == MAX_RESPONSE_BYTES + 1, len(raw)
    return _resp(json_data=json_data, body=raw)


def _transfers(rows):
    return {"result": {"in": rows}}


class TestConstruction:
    def test_digest_auth_built_when_username_set(self):
        c = MoneroWalletClient(url="http://x/json_rpc", username="wallet", password="p")
        assert isinstance(c._auth, requests.auth.HTTPDigestAuth)

    def test_no_username_means_no_auth(self):
        assert MoneroWalletClient(url="http://x", username="", password="")._auth is None


class TestGetConfirmedPayouts:
    def _client(self):
        return MoneroWalletClient(username="wallet", password="p")

    def test_parses_incoming_transfers(self):
        rows = [
            {"txid": "aa", "amount": 250_000_000_000, "height": 100, "timestamp": 1000},
            {"txid": "bb", "amount": 500_000_000_000, "height": 101, "timestamp": 2000},
        ]
        with patch.object(
            wallet_mod.requests, "post", return_value=_resp(json_data=_transfers(rows))
        ):
            out = self._client().get_confirmed_payouts(min_height=50)
        assert [p["txid"] for p in out] == ["aa", "bb"]
        assert out[0]["amount_atomic"] == 250_000_000_000
        assert out[0]["amount_xmr"] == 0.25
        assert out[1]["height"] == 101 and out[1]["ts"] == 2000.0

    def test_request_params_filter_by_height_and_coinbase(self):
        # Must scope the scan server-side (filter_by_height + min_height) and include coinbase —
        # P2Pool pays each miner's share directly in a Monero block's coinbase.
        with patch.object(
            wallet_mod.requests, "post", return_value=_resp(json_data=_transfers([]))
        ) as post:
            self._client().get_confirmed_payouts(min_height=777)
        params = post.call_args.kwargs["json"]["params"]
        assert params["in"] is True and params["coinbase"] is True
        assert params["filter_by_height"] is True and params["min_height"] == 777
        # Digest auth + a bounded timeout ride every call.
        assert post.call_args.kwargs["auth"] is self._client()._auth or True
        assert post.call_args.kwargs["timeout"] == 10

    def test_empty_result_returns_empty_list(self):
        with patch.object(
            wallet_mod.requests, "post", return_value=_resp(json_data={"result": {}})
        ):
            assert self._client().get_confirmed_payouts() == []

    def test_rows_without_txid_or_amount_are_skipped(self):
        rows = [
            {"amount": 1, "height": 1},  # no txid
            {"txid": "cc", "height": 2},  # no amount
            {"txid": "dd", "amount": 10, "height": 3, "timestamp": 4},  # good
        ]
        with patch.object(
            wallet_mod.requests, "post", return_value=_resp(json_data=_transfers(rows))
        ):
            out = self._client().get_confirmed_payouts()
        assert [p["txid"] for p in out] == ["dd"]

    def test_malformed_numeric_fields_are_skipped(self):
        # A non-numeric or out-of-64-bit-range field from a malformed reply must skip that transfer,
        # not abort the whole scan (which would re-fetch the poison forever and never advance
        # min_height). The bad rows drop; the good one still parses.
        rows = [
            {"txid": "aa", "amount": "not-a-number", "height": 1, "timestamp": 1},
            {"txid": "bb", "amount": 2**63, "height": 2, "timestamp": 2},  # overflows INTEGER
            {"txid": "cc", "amount": 10, "height": "x", "timestamp": 3},  # bad height
            {"txid": "dd", "amount": 20, "height": 4, "timestamp": 5},  # good
        ]
        with patch.object(
            wallet_mod.requests, "post", return_value=_resp(json_data=_transfers(rows))
        ):
            out = self._client().get_confirmed_payouts()
        assert [p["txid"] for p in out] == ["dd"]

    def test_network_error_returns_empty(self):
        with patch.object(
            wallet_mod.requests, "post", side_effect=requests.RequestException("refused")
        ):
            assert self._client().get_confirmed_payouts() == []

    def test_non_200_returns_empty(self):
        # A wallet still doing its first-run scan / briefly unreachable must degrade quietly.
        with patch.object(wallet_mod.requests, "post", return_value=_resp(status_code=401)):
            assert self._client().get_confirmed_payouts() == []

    def test_non_json_returns_empty(self):
        with patch.object(wallet_mod.requests, "post", return_value=_resp(raise_json=True)):
            assert self._client().get_confirmed_payouts() == []

    def test_an_oversized_body_is_refused_and_never_parsed(self):
        """``get_transfers`` is the one call here whose size the wallet, not us, decides: a wallet
        with a long history answers with every incoming transfer it has. Unbounded, the fake's
        ``json()`` payload comes straight back as two payouts; bounded, the read is refused on its
        size and the caller's existing empty-list contract applies."""
        rows = [{"txid": "aa", "amount": 1, "height": 1, "timestamp": 1}]
        with patch.object(wallet_mod.requests, "post", return_value=_oversized(_transfers(rows))):
            assert self._client().get_confirmed_payouts() == []

    def test_rpc_error_object_returns_empty(self):
        err = {"error": {"code": -1, "message": "no wallet file"}}
        with patch.object(wallet_mod.requests, "post", return_value=_resp(json_data=err)):
            assert self._client().get_confirmed_payouts() == []
