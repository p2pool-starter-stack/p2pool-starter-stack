from unittest.mock import MagicMock

import pytest

from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient


@pytest.fixture
def client():
    c = XMRigProxyClient(host="127.0.0.1", port=3344, access_token="secret")
    c.session = MagicMock()
    return c


def _resp(json_data=None, status_code=200, content=b"x"):
    r = MagicMock()
    r.json.return_value = json_data or {}
    r.status_code = status_code
    r.content = content
    r.raise_for_status.return_value = None
    return r


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
    client.session.put.return_value = _resp(status_code=204, content=b"")
    assert client.update_config({"x": 1}) == {}


def test_get_summary_raises_on_http_error(client):
    resp = _resp()
    resp.raise_for_status.side_effect = RuntimeError("500")
    client.session.get.return_value = resp
    with pytest.raises(RuntimeError):
        client.get_summary()


def test_connect_failures_are_never_retried():
    """A held miner (first sync) means the proxy is legitimately DOWN, and the state loop calls
    this client twice per cycle. Connect retries burned ~7s of backoff per call, so every
    dashboard update — and the first page paint — crawled for the whole sync. Refused/no-route
    must answer immediately; retries are for a running proxy's transient 5xx hiccups."""
    client = XMRigProxyClient("127.0.0.1", 3344)
    retry = client.session.get_adapter("http://x/").max_retries
    assert retry.connect == 0
    assert retry.total == 3
