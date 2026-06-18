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
    session = FakeSession(
        response=FakeResponse(200, {"kind": "proxy", "hashrate": {"total": [10]}})
    )
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
    assert len(session.calls) > 1  # tried multiple auth combinations against the validated IP


async def test_exceptions_are_swallowed():
    session = FakeSession(exc=OSError("connection refused"))
    client = XMRigWorkerClient(session)
    assert await client.get_stats("10.0.0.1", "rig1") == {}


# --- SSRF guard (#122) -------------------------------------------------------------------------
# The dashboard runs network_mode: host and the worker name/ip is fully miner-controlled via
# stratum. A worker name must NEVER become an outbound request host, and worker IPs pointing at our
# own infrastructure / host-local services must never be probed.


@pytest.mark.parametrize(
    "ip,name,why",
    [
        ("127.0.0.1", "rig", "loopback / host-local services"),
        ("::1", "rig", "IPv6 loopback"),
        ("172.28.0.30", "rig", "docker bridge — the read-only socket proxy"),
        ("172.28.0.29", "rig", "docker bridge — xmrig-proxy itself"),
        ("169.254.169.254", "rig", "link-local cloud-metadata endpoint"),
        ("0.0.0.0", "rig", "unspecified"),
        ("255.255.255.255", "rig", "reserved broadcast"),
        ("not-an-ip", "rig", "garbage, not an address"),
        ("", "127.0.0.1", "name is an internal IP string — must never become a host"),
        ("", "172.28.0.30", "name is the socket proxy — must never become a host"),
        ("", "evil.example.com", "name is a hostname — must never become a host"),
    ],
)
async def test_ssrf_targets_are_never_probed(ip, name, why):
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    client = XMRigWorkerClient(session)
    assert await client.get_stats(ip, name) == {}, why
    assert session.calls == [], f"issued a request despite {why}"


@pytest.mark.parametrize(
    "ip",
    [
        "192.168.1.50",  # LAN miner
        "10.0.0.1",  # LAN miner
        "172.16.5.5",  # LAN miner outside the docker bridge
        "8.8.8.8",  # public miner
        "10.0.0.1:54321",  # "ip:port" form is tolerated
    ],
)
async def test_real_miner_ip_is_probed(ip):
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    client = XMRigWorkerClient(session)
    result = await client.get_stats(ip, "rig")
    assert result == {"ok": True}
    host = ip.split(":")[0]
    assert session.calls[0][0] == f"http://{host}:8080/1/summary"


async def test_name_is_used_as_bearer_never_as_host():
    # With a valid IP, the stripped name is offered back as the miner's access token — but every
    # request still targets the validated IP, never the name.
    session = FakeSession(response=FakeResponse(404))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "rig1+worker")
    assert all("10.0.0.1" in url for url, _ in session.calls)
    assert not any("rig1" in url for url, _ in session.calls)  # name never becomes a host
    bearers = [h.get("Authorization") for _, h in session.calls if h]
    assert "Bearer rig1" in bearers  # '+'-suffix stripped, used as token


async def test_long_name_token_is_capped():
    session = FakeSession(response=FakeResponse(404))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "A" * 500)
    bearers = [h["Authorization"] for _, h in session.calls if h and "Authorization" in h]
    assert any(b == "Bearer " + "A" * 128 for b in bearers)
