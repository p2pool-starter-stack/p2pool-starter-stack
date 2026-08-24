import json
from unittest.mock import MagicMock, patch

import requests

import mining_dashboard.client.monero.monero_client as monero_mod
from mining_dashboard.client.monero.monero_client import MoneroClient
from mining_dashboard.helper.http import MAX_RESPONSE_BYTES


def _resp(status_code=200, json_data=None, raise_json=False, body=None):
    """A streaming ``requests`` response — what ``bounded_get`` consumes since #1360.

    The payload is served as real BYTES over ``iter_content``, because the client now receives a
    ``BoundedResponse`` parsed from the stream rather than this mock. ``json()`` is still set on the
    mock so the same fake also drives the unbounded ``requests.get`` this replaced; that is what
    makes the oversized test below fail if the bounding is taken out.
    """
    raw = body if body is not None else json.dumps(json_data or {}).encode()
    if raise_json:
        raw = b"not json"
    resp = MagicMock(status_code=status_code, encoding="utf-8")
    resp.iter_content.return_value = iter([raw[i : i + 65536] for i in range(0, len(raw), 65536)])
    resp.json.side_effect = ValueError("no json") if raise_json else None
    if not raise_json:
        resp.json.return_value = json_data or {}
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


def _oversized(json_data):
    """A valid payload one byte past the cap: the refusal is on byte count, not on content."""
    empty = json.dumps({**json_data, "pad": ""}).encode()
    pad = "x" * (MAX_RESPONSE_BYTES + 1 - len(empty))
    raw = json.dumps({**json_data, "pad": pad}).encode()
    assert len(raw) == MAX_RESPONSE_BYTES + 1, len(raw)
    return _resp(json_data=json_data, body=raw)


class TestGetInfo:
    def test_url_and_digest_auth_built(self):
        client = MoneroClient(url="http://127.0.0.1:18081/", username="u", password="p")
        assert client.url == "http://127.0.0.1:18081/get_info"
        assert isinstance(client._auth, requests.auth.HTTPDigestAuth)

    def test_no_username_means_no_auth(self):
        assert MoneroClient(url="http://x:18081", username="", password="")._auth is None

    def test_success_returns_payload(self):
        client = MoneroClient(username="u", password="p")
        data = {"status": "OK", "height": 5, "target_height": 10}
        with patch.object(
            monero_mod.requests, "get", return_value=_resp(json_data=data)
        ) as mock_get:
            assert client.get_info() == data
        # Digest auth and a bounded timeout are passed through on every call.
        assert mock_get.call_args.kwargs["timeout"] == client.timeout
        assert mock_get.call_args.kwargs["auth"] is client._auth

    def test_network_error_returns_none(self):
        client = MoneroClient(username="u", password="p")
        with patch.object(
            monero_mod.requests, "get", side_effect=requests.RequestException("refused")
        ):
            assert client.get_info() is None

    def test_non_200_returns_none(self):
        client = MoneroClient(username="u", password="p")
        with patch.object(monero_mod.requests, "get", return_value=_resp(status_code=401)):
            assert client.get_info() is None

    def test_non_json_returns_none(self):
        client = MoneroClient(username="u", password="p")
        with patch.object(monero_mod.requests, "get", return_value=_resp(raise_json=True)):
            assert client.get_info() is None

    def test_an_oversized_body_is_refused_and_never_parsed(self):
        """A *remote* monerod (#183) is someone else's server on someone else's network, so the
        #660 "internal" exemption never fitted it. The fake's ``json()`` returns a perfectly good
        payload — unbounded, ``get_info`` hands that straight back; bounded, the body is refused on
        its size before anything parses it, and the caller's existing None contract applies."""
        client = MoneroClient(username="u", password="p")
        with patch.object(
            monero_mod.requests, "get", return_value=_oversized({"status": "OK", "height": 5})
        ):
            assert client.get_info() is None

    def test_busy_status_returns_none(self):
        client = MoneroClient(username="u", password="p")
        with patch.object(
            monero_mod.requests, "get", return_value=_resp(json_data={"status": "BUSY"})
        ):
            assert client.get_info() is None


class TestGetSyncStatus:
    def _client_with_info(self, info):
        client = MoneroClient(username="u", password="p")
        client.get_info = MagicMock(return_value=info)
        return client

    def test_syncing(self):
        client = self._client_with_info(
            {"status": "OK", "height": 50, "target_height": 100, "database_size": 85_000_000_000}
        )
        assert client.get_sync_status() == {
            "is_syncing": True,
            "current": 50,
            "target": 100,
            "percent": 50,
            "db_size": 85_000_000_000,
            "synchronized": False,
        }

    def test_synced_via_flag(self):
        # `synchronized` is authoritative even if heights look mid-sync.
        client = self._client_with_info(
            {
                "status": "OK",
                "synchronized": True,
                "height": 90,
                "target_height": 100,
                "database_size": 200_000_000_000,
            }
        )
        assert client.get_sync_status() == {
            "is_syncing": False,
            "db_size": 200_000_000_000,
            "synchronized": True,
        }

    def test_synced_via_zero_target(self):
        # Synced monerod reports target_height: 0.
        client = self._client_with_info({"status": "OK", "height": 100, "target_height": 0})
        assert client.get_sync_status() == {
            "is_syncing": False,
            "db_size": 0,
            "synchronized": False,
        }

    def test_synced_when_height_reaches_target(self):
        client = self._client_with_info({"status": "OK", "height": 100, "target_height": 100})
        assert client.get_sync_status() == {
            "is_syncing": False,
            "db_size": 0,
            "synchronized": False,
        }

    def test_stranded_node_reads_synced_but_carries_the_false_flag(self):
        # The #972 strand: after a tor restart a peerless monerod can report target_height 0
        # (stale) with synchronized false — the height math calls it "synced", so the raw
        # `synchronized` passthrough is the ONLY signal the peer-loss detector gets.
        client = self._client_with_info(
            {"status": "OK", "synchronized": False, "height": 100, "target_height": 0}
        )
        status = client.get_sync_status()
        assert status["is_syncing"] is False
        assert status["synchronized"] is False

    def test_unreachable_returns_none(self):
        client = self._client_with_info(None)
        assert client.get_sync_status() is None
