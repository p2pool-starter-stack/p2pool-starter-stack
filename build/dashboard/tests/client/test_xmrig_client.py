import pytest

from mining_dashboard.client.xmrig_client import XMRigWorkerClient


class FakeResponse:
    def __init__(self, status, payload=None):
        self.status = status
        self._payload = payload or {}

    async def json(self):
        return self._payload


class FakeGet:
    """Mimics the async context manager returned by aiohttp ClientSession.get()."""
    def __init__(self, response=None, exc=None):
        self._response = response
        self._exc = exc

    async def __aenter__(self):
        if self._exc:
            raise self._exc
        return self._response

    async def __aexit__(self, *exc):
        return False


class FakeSession:
    def __init__(self, response=None, exc=None):
        self._response = response
        self._exc = exc
        self.calls = []

    def get(self, url, headers=None, timeout=None):
        self.calls.append((url, headers))
        return FakeGet(self._response, self._exc)


async def test_first_success_returns_payload_and_short_circuits():
    session = FakeSession(response=FakeResponse(200, {"kind": "proxy", "hashrate": {"total": [10]}}))
    client = XMRigWorkerClient(session)
    result = await client.get_stats("10.0.0.1", "rig1")
    assert result == {"kind": "proxy", "hashrate": {"total": [10]}}
    assert len(session.calls) == 1  # stopped after the first 200
    assert session.calls[0][0] == "http://10.0.0.1:8080/1/summary"


async def test_all_attempts_fail_returns_empty():
    session = FakeSession(response=FakeResponse(500))
    client = XMRigWorkerClient(session)
    result = await client.get_stats("10.0.0.1", "rig1")
    assert result == {}
    assert len(session.calls) > 1  # tried multiple host/auth combinations


async def test_exceptions_are_swallowed():
    session = FakeSession(exc=OSError("connection refused"))
    client = XMRigWorkerClient(session)
    assert await client.get_stats("10.0.0.1", "rig1") == {}


async def test_zero_ip_skipped_uses_name_host():
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    client = XMRigWorkerClient(session)
    await client.get_stats("0.0.0.0", "rig1")
    # 0.0.0.0 is skipped; first host tried is the name token
    assert session.calls[0][0].startswith("http://rig1:")


async def test_name_token_strips_plus_suffix():
    session = FakeSession(response=FakeResponse(404))
    client = XMRigWorkerClient(session)
    await client.get_stats("", "rig1+worker")
    # name_token is "rig1" (text before '+'); appears in the attempted hosts
    assert any("rig1" in url and "worker" not in url for url, _ in session.calls)
