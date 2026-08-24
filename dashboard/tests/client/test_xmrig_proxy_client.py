import json
from unittest.mock import MagicMock

import pytest
import requests

from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient
from mining_dashboard.helper.http import MAX_RESPONSE_BYTES, ResponseTooLarge


@pytest.fixture
def client():
    c = XMRigProxyClient(host="127.0.0.1", port=3344, access_token="secret")
    c.session = MagicMock()
    return c


def _resp(json_data=None, status_code=200, body=None, chunk=None):
    """A streaming ``requests`` response, i.e. what ``bounded_request`` actually consumes (#1360).

    ``json_data`` is served as real BYTES over ``iter_content`` — the client now gets a
    ``BoundedResponse`` built from the stream, so a mocked ``.json()`` would never be consulted.
    It is ALSO set on the mock, so the same fake drives the unbounded ``self.session.get(...)``
    this replaced: that is what lets the oversized tests below go red if the bounding is removed.
    """
    raw = body if body is not None else json.dumps(json_data or {}).encode()
    size = chunk or max(len(raw), 1)
    r = MagicMock(status_code=status_code, encoding="utf-8")
    r.iter_content.return_value = iter([raw[i : i + size] for i in range(0, len(raw), size)])
    r.json.return_value = json_data or {}
    r.content = raw
    r.raise_for_status.return_value = None
    r.__enter__.return_value = r
    r.__exit__.return_value = False
    return r


def _oversized(json_data):
    """A body of exactly ``cap + 1`` bytes that is otherwise a perfectly good payload.

    Exactly one byte past is deliberate: it pins the boundary rather than clearing it by a mile,
    so a cap applied with the wrong comparison shows up here."""
    empty = json.dumps({**json_data, "pad": ""}).encode()
    pad = "x" * (MAX_RESPONSE_BYTES + 1 - len(empty))
    raw = json.dumps({**json_data, "pad": pad}).encode()
    assert len(raw) == MAX_RESPONSE_BYTES + 1, len(raw)
    return _resp(json_data=json_data, body=raw, chunk=65536)


def test_auth_header_set():
    c = XMRigProxyClient(access_token="tok")
    assert c.session.headers["Authorization"] == "Bearer tok"


def test_get_summary(client):
    client.session.get.return_value = _resp({"version": "6.x"})
    assert client.get_summary() == {"version": "6.x"}
    assert client.session.get.call_args[0][0].endswith("/1/summary")


def test_get_workers(client):
    client.session.get.return_value = _resp({"workers": []})
    assert client.get_workers() == {"workers": []}


def test_get_config(client):
    client.session.get.return_value = _resp({"pools": []})
    assert client.get_config() == {"pools": []}


def test_update_config_returns_json(client):
    client.session.put.return_value = _resp({"ok": True})
    assert client.update_config({"donate-level": 1}) == {"ok": True}
    assert client.session.put.call_args.kwargs["json"] == {"donate-level": 1}


def test_update_config_204_returns_empty(client):
    client.session.put.return_value = _resp(status_code=204, body=b"")
    assert client.update_config({"x": 1}) == {}


def test_get_summary_raises_on_http_error(client):
    # The cap is applied to the BODY; the status contract is unchanged, and a 5xx still surfaces as
    # a RequestException so the caller's existing handling applies.
    client.session.get.return_value = _resp(status_code=500)
    with pytest.raises(requests.RequestException):
        client.get_summary()


def test_reads_go_through_the_client_s_own_session(client):
    """The retry adapter is mounted on ``self.session`` (see the test below), so bounding the read
    must not quietly fall back to module-level ``requests`` — that would drop the adapter and the
    connection pool on the two calls made every state-loop cycle."""
    client.session.get.return_value = _resp({"version": "6.x"})
    client.get_summary()
    assert client.session.get.called
    # Streamed, so the body is never buffered whole by requests before we can refuse it.
    assert client.session.get.call_args.kwargs["stream"] is True


@pytest.mark.parametrize("call", ["get_summary", "get_workers", "get_config"])
def test_an_oversized_read_is_refused(client, call):
    """xmrig-proxy is our own container, but ``/1/summary`` and ``/1/workers`` are assembled from
    what MINERS advertise to it — the #1347 boundary, one hop back. The payload here is valid JSON
    the unbounded read would have returned happily; the refusal is on the byte count alone."""
    client.session.get.return_value = _oversized({"version": "6.x"})
    with pytest.raises(ResponseTooLarge):
        getattr(client, call)()


def test_an_oversized_config_write_response_is_refused(client):
    # The PUT response is the same surface: xmrig-proxy echoes the accepted config back.
    client.session.put.return_value = _oversized({"ok": True})
    with pytest.raises(ResponseTooLarge):
        client.update_config({"donate-level": 1})


def test_connect_failures_are_never_retried():
    """A held miner (first sync) means the proxy is legitimately DOWN, and the state loop calls
    this client twice per cycle. Connect retries burned ~7s of backoff per call, so every
    dashboard update — and the first page paint — crawled for the whole sync. Refused/no-route
    must answer immediately; retries are for a running proxy's transient 5xx hiccups."""
    client = XMRigProxyClient("127.0.0.1", 3344)
    retry = client.session.get_adapter("http://x/").max_retries
    assert retry.connect == 0
    assert retry.total == 3
