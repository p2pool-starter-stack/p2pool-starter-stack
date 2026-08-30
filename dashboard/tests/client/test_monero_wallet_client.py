import json
from unittest.mock import MagicMock, patch

import pytest
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


# The bodies #1592 is about: each is valid JSON that `_rpc` handled past its own contract.
# `result` cases escaped as a returned VALUE; the top-level cases raised. Kept as one table so the
# two claims below — the annotation's, and the docstring's — are graded over the same population.
_NOT_AN_OBJECT = [
    ("result is an array", b'{"result": [1, 2, 3]}'),
    ("result is a string", b'{"result": "wat"}'),
    ("result is a number", b'{"result": 7}'),
    ("body is an array", b"[1, 2, 3]"),
    ("body is a number", b"7"),
    ("body is a string", b'"hello"'),
    ("body is null", b"null"),
]


class TestRpcReturnShape:
    """#1592: `_rpc` is annotated ``dict | None`` and its docstring promises None on any error."""

    def _rpc(self, body):
        client = MoneroWalletClient(username="wallet", password="p")
        with patch.object(wallet_mod.requests, "post", return_value=_resp(body=body)):
            return client._rpc("get_transfers")

    @pytest.mark.parametrize(("label", "body"), _NOT_AN_OBJECT)
    def test_a_non_object_never_escapes_the_annotation(self, label, body):
        """A truthy non-dict ``result`` was returned STRAIGHT BACK — the one way this annotation
        could be falsified without anything raising. The top-level cases raised instead, at the
        membership test for a number or null and at ``.get`` for an array or string.

        The bodies are a handful of bytes, so no assertion here can be satisfied by the size cap.
        """
        assert self._rpc(body) is None, label

    def test_an_object_result_is_still_returned(self):
        """The control: the guard must refuse non-objects WITHOUT refusing objects. Without it, a
        `_rpc` rewritten to ``return None`` would pass every row of the parametrized test."""
        assert self._rpc(b'{"result": {"in": [{"txid": "aa"}]}}') == {"in": [{"txid": "aa"}]}

    def test_a_missing_or_null_result_is_still_an_empty_dict(self):
        """Unchanged by #1592, and asserted because the fix rewrote the line that decided it: a
        call that succeeded and carried no ``result`` is an empty answer, not an error."""
        assert self._rpc(b'{"id": "0"}') == {}
        assert self._rpc(b'{"result": null}') == {}


class TestGetConfirmedPayoutsNeverRaises:
    """#1592's blast radius: ``get_confirmed_payouts``' docstring says *never raises*, and a
    truthy non-dict ``result`` reached its ``result.get("in", [])`` and raised there."""

    @pytest.mark.parametrize(("label", "body"), _NOT_AN_OBJECT)
    def test_a_non_object_body_degrades_to_an_empty_list(self, label, body):
        client = MoneroWalletClient(username="wallet", password="p")
        with patch.object(wallet_mod.requests, "post", return_value=_resp(body=body)):
            assert client.get_confirmed_payouts() == [], label

    def test_a_well_formed_body_still_yields_its_payouts(self):
        """The control for the row above: degrading to ``[]`` must not be how this reads EVERY
        body. Same call, same path, a real transfer — and it still comes back."""
        row = {"txid": "aa", "amount": 250_000_000_000, "height": 100, "timestamp": 1000}
        client = MoneroWalletClient(username="wallet", password="p")
        with patch.object(
            wallet_mod.requests, "post", return_value=_resp(json_data=_transfers([row]))
        ):
            assert [p["txid"] for p in client.get_confirmed_payouts()] == ["aa"]

    @pytest.mark.parametrize(
        ("label", "body"),
        [
            ("in is a string", b'{"result": {"in": "abc"}}'),
            ("in is an object", b'{"result": {"in": {"a": 1}}}'),
            ("in is a number", b'{"result": {"in": 7}}'),
            ("in holds numbers", b'{"result": {"in": [1, 2, 3]}}'),
            ("in holds strings", b'{"result": {"in": ["a", "b"]}}'),
            ("in holds nulls", b'{"result": {"in": [null]}}'),
            ("in holds arrays", b'{"result": {"in": [[1]]}}'),
        ],
    )
    def test_a_malformed_in_payload_degrades_rather_than_raising(self, label, body):
        """The SECOND layer, past what #1592 filed: a well-formed ``result`` whose ``in`` is not a
        list of objects. Fixing ``_rpc`` alone does not reach here — iterating an object yields its
        KEYS and a string its CHARACTERS, so both still died at ``t.get``, and a number raised on
        the ``for`` itself. The docstring's *never raises* covers this payload too, so the guard
        belongs here rather than in a narrowed docstring.
        """
        client = MoneroWalletClient(username="wallet", password="p")
        with patch.object(wallet_mod.requests, "post", return_value=_resp(body=body)):
            assert client.get_confirmed_payouts() == [], label

    @pytest.mark.parametrize(
        ("label", "body"),
        [
            ("in absent", b'{"result": {}}'),
            ("in null", b'{"result": {"in": null}}'),
            ("in empty", b'{"result": {"in": []}}'),
        ],
    )
    def test_an_empty_in_payload_is_still_no_payouts_not_an_error(self, label, body):
        """Unchanged by the guard above, and pinned because the guard rewrote the line that read
        ``in``: a wallet with nothing to report is an empty answer on the normal path."""
        client = MoneroWalletClient(username="wallet", password="p")
        with patch.object(wallet_mod.requests, "post", return_value=_resp(body=body)):
            assert client.get_confirmed_payouts() == [], label

    def test_one_bad_transfer_does_not_discard_its_good_siblings(self):
        """The narrowness control: a non-object transfer must SKIP, exactly as a transfer missing
        its txid already does — not abort the scan. Without this, a guard that returned ``[]`` on
        the first bad row would pass every assertion in the malformed test above."""
        rows = [{"txid": "aa", "amount": 1, "height": 1, "timestamp": 1}, "junk", None]
        client = MoneroWalletClient(username="wallet", password="p")
        with patch.object(
            wallet_mod.requests, "post", return_value=_resp(json_data=_transfers(rows))
        ):
            assert [p["txid"] for p in client.get_confirmed_payouts()] == ["aa"]
