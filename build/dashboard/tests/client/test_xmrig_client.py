import pytest

from mining_dashboard.client import xmrig_client as xc
from mining_dashboard.client.xmrig_client import XMRigWorkerClient


class FakeResponse:
    def __init__(self, status, payload=None):
        self.status = status
        self._payload = payload if payload is not None else {}

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


# --- One probe, derived from config (no auto-detection fallback) -------------------------------


async def test_success_returns_payload_with_api_ok_and_single_call():
    session = FakeSession(
        response=FakeResponse(200, {"kind": "proxy", "hashrate": {"total": [10]}})
    )
    client = XMRigWorkerClient(session)
    result = await client.get_stats("10.0.0.1", "rig1")
    assert result == {"kind": "proxy", "hashrate": {"total": [10]}, "api_ok": True}
    assert len(session.calls) == 1  # exactly one probe — never multiple auth combinations
    assert session.calls[0][0] == "http://10.0.0.1:8080/1/summary"


async def test_default_auth_is_none_no_authorization_header():
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "rig1")
    _, headers = session.calls[0]
    assert "Authorization" not in (headers or {})  # default mode is no-auth


async def test_failure_status_returns_api_ok_false_single_call():
    session = FakeSession(response=FakeResponse(401))
    client = XMRigWorkerClient(session)
    result = await client.get_stats("10.0.0.1", "rig1")
    assert result == {"api_ok": False}
    assert len(session.calls) == 1  # no retry with a different credential


async def test_exception_returns_api_ok_false():
    session = FakeSession(exc=OSError("connection refused"))
    client = XMRigWorkerClient(session)
    assert await client.get_stats("10.0.0.1", "rig1") == {"api_ok": False}


async def test_non_dict_200_body_is_a_failure():
    session = FakeSession(response=FakeResponse(200, ["not", "a", "dict"]))
    client = XMRigWorkerClient(session)
    assert await client.get_stats("10.0.0.1", "rig1") == {"api_ok": False}


# --- Auth modes (the "rest defined through config") --------------------------------------------


async def test_auth_name_uses_worker_name_as_bearer(monkeypatch):
    monkeypatch.setattr(xc, "XMRIG_API_AUTH", "name")
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "rig1+worker")
    _, headers = session.calls[0]
    assert headers["Authorization"] == "Bearer rig1"  # '+'-suffix stripped, name as token


async def test_auth_token_uses_shared_token_as_bearer(monkeypatch):
    monkeypatch.setattr(xc, "XMRIG_API_AUTH", "token")
    monkeypatch.setattr(xc, "XMRIG_API_TOKEN", "s3cr3t")
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "rig1")
    _, headers = session.calls[0]
    assert headers["Authorization"] == "Bearer s3cr3t"


async def test_auth_token_without_token_sends_no_header(monkeypatch):
    monkeypatch.setattr(xc, "XMRIG_API_AUTH", "token")
    monkeypatch.setattr(xc, "XMRIG_API_TOKEN", "")
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "rig1")
    _, headers = session.calls[0]
    assert "Authorization" not in (headers or {})


async def test_custom_port_is_used(monkeypatch):
    monkeypatch.setattr(xc, "XMRIG_API_PORT", 18088)
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "rig1")
    assert session.calls[0][0] == "http://10.0.0.1:18088/1/summary"


# --- Failure is surfaced once per worker, not every poll ---------------------------------------


async def test_repeated_failures_warn_once_then_dedup(monkeypatch, caplog):
    # Freeze the clock so the dedup window never elapses between calls.
    monkeypatch.setattr(xc.time, "monotonic", lambda: 1000.0)
    session = FakeSession(response=FakeResponse(401))
    client = XMRigWorkerClient(session)
    with caplog.at_level("WARNING", logger="WorkerClient"):
        for _ in range(5):
            await client.get_stats("10.0.0.1", "rig1")
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert len(warnings) == 1  # one worker, one warning per interval
    assert "rig1" in warnings[0].getMessage()
    assert "10.0.0.1" in warnings[0].getMessage()


async def test_recovery_then_failure_warns_again(monkeypatch, caplog):
    monkeypatch.setattr(xc.time, "monotonic", lambda: 1000.0)
    fail = FakeSession(response=FakeResponse(401))
    client = XMRigWorkerClient(fail)
    with caplog.at_level("WARNING", logger="WorkerClient"):
        await client.get_stats("10.0.0.1", "rig1")  # warns
        # A success clears the dedup state...
        client.session = FakeSession(response=FakeResponse(200, {"ok": True}))
        await client.get_stats("10.0.0.1", "rig1")
        # ...so the next failure warns again even within the interval.
        client.session = fail
        await client.get_stats("10.0.0.1", "rig1")  # warns again
    assert len([r for r in caplog.records if r.levelname == "WARNING"]) == 2


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
    # A skipped target returns {} (api_ok unset = "unknown", not a failure) and issues no request.
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
    assert result == {"ok": True, "api_ok": True}
    host = ip.split(":")[0]
    assert session.calls[0][0] == f"http://{host}:8080/1/summary"


async def test_name_is_used_as_bearer_never_as_host(monkeypatch):
    # Under name-auth, the stripped name is offered back as the miner's access token — but the
    # request still targets the validated IP, never the name.
    monkeypatch.setattr(xc, "XMRIG_API_AUTH", "name")
    session = FakeSession(response=FakeResponse(404))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "rig1+worker")
    assert all("10.0.0.1" in url for url, _ in session.calls)
    assert not any("rig1" in url for url, _ in session.calls)  # name never becomes a host
    bearers = [h.get("Authorization") for _, h in session.calls if h]
    assert "Bearer rig1" in bearers  # '+'-suffix stripped, used as token


async def test_long_name_token_is_capped(monkeypatch):
    monkeypatch.setattr(xc, "XMRIG_API_AUTH", "name")
    session = FakeSession(response=FakeResponse(404))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "A" * 500)
    bearers = [h["Authorization"] for _, h in session.calls if h and "Authorization" in h]
    assert any(b == "Bearer " + "A" * 128 for b in bearers)


# --- Per-worker endpoint descriptors (#172) ------------------------------------------------------
# dashboard.workers[] entries override the fleet defaults per rig. Merge rule: per-worker field >
# fleet default > inherit. Matched by stratum name first, then by connecting IP against an
# operator-set host; a per-worker token implies token-auth for that worker only.


def _with_overrides(monkeypatch, entries):
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", entries)


async def test_override_port_beats_fleet_default(monkeypatch):
    _with_overrides(monkeypatch, [{"name": "rig1", "port": 18088}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    await XMRigWorkerClient(session).get_stats("10.0.0.1", "rig1")
    assert session.calls[0][0] == "http://10.0.0.1:18088/1/summary"


async def test_unlisted_worker_inherits_fleet_defaults(monkeypatch):
    _with_overrides(monkeypatch, [{"name": "rig1", "port": 18088, "token": "t0"}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    await XMRigWorkerClient(session).get_stats("10.0.0.2", "other")
    url, headers = session.calls[0]
    assert url == "http://10.0.0.2:8080/1/summary"
    assert "Authorization" not in (headers or {})


async def test_override_host_beats_connecting_ip(monkeypatch):
    # host solves NAT / multi-homed / API-on-another-interface: operator-set in config.json.
    _with_overrides(monkeypatch, [{"name": "rig1", "host": "worker-lan.local"}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    await XMRigWorkerClient(session).get_stats("10.0.0.1", "rig1")
    assert session.calls[0][0] == "http://worker-lan.local:8080/1/summary"


async def test_override_token_implies_token_auth_for_that_worker_only(monkeypatch):
    # Fleet mode stays "none", yet the listed rig gets its own bearer.
    _with_overrides(monkeypatch, [{"name": "rig1", "token": "per-rig-secret"}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    client = XMRigWorkerClient(session)
    await client.get_stats("10.0.0.1", "rig1")
    await client.get_stats("10.0.0.2", "rig2")
    assert session.calls[0][1]["Authorization"] == "Bearer per-rig-secret"
    assert "Authorization" not in (session.calls[1][1] or {})


async def test_override_token_beats_fleet_name_auth(monkeypatch):
    monkeypatch.setattr(xc, "XMRIG_API_AUTH", "name")
    _with_overrides(monkeypatch, [{"name": "rig1", "token": "per-rig-secret"}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    await XMRigWorkerClient(session).get_stats("10.0.0.1", "rig1+cpu")
    assert session.calls[0][1]["Authorization"] == "Bearer per-rig-secret"


async def test_match_is_by_stratum_name_before_plus_suffix(monkeypatch):
    _with_overrides(monkeypatch, [{"name": "rig1", "port": 18088}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    await XMRigWorkerClient(session).get_stats("10.0.0.1", "rig1+cpu")
    assert session.calls[0][0] == "http://10.0.0.1:18088/1/summary"


async def test_name_miss_falls_back_to_ip_match_on_operator_host(monkeypatch):
    # The rig renamed itself but still connects from the operator-declared address.
    _with_overrides(monkeypatch, [{"name": "rig1", "host": "10.0.0.7", "port": 18088}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    await XMRigWorkerClient(session).get_stats("10.0.0.7", "renamed")
    assert session.calls[0][0] == "http://10.0.0.7:18088/1/summary"


async def test_name_match_wins_over_ip_match(monkeypatch):
    _with_overrides(
        monkeypatch,
        [
            {"name": "rig1", "host": "10.0.0.7", "port": 1111},
            {"name": "rig2", "port": 2222},
        ],
    )
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    # rig2 connects from rig1's declared address: its own name entry applies, not the IP match.
    await XMRigWorkerClient(session).get_stats("10.0.0.7", "rig2")
    assert session.calls[0][0] == "http://10.0.0.7:2222/1/summary"


# --- SSRF guard × overrides (#122/#172) ----------------------------------------------------------
# A per-worker token must never travel to a host the dashboard did not either validate as the
# rig's own external address or receive from the OPERATOR's config.json. A miner-advertised
# name/ip can never redirect a token-bearing probe.


async def test_token_never_sent_when_ip_fails_the_guard(monkeypatch):
    # Entry has a token but no pinned host; the claimed ip is our own infrastructure. No probe,
    # no token on the wire.
    _with_overrides(monkeypatch, [{"name": "rig1", "token": "s3cr3t"}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    assert await XMRigWorkerClient(session).get_stats("172.28.0.30", "rig1") == {}
    assert session.calls == []


async def test_operator_host_is_probed_even_when_ip_is_unusable(monkeypatch):
    # A NAT'd rig can surface with an unusable connecting address; the operator-set host is the
    # probe target regardless — it comes from config.json, never from the miner (#122).
    _with_overrides(monkeypatch, [{"name": "rig1", "host": "192.168.7.9", "token": "s3cr3t"}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    result = await XMRigWorkerClient(session).get_stats("", "rig1")
    assert result == {"ok": True, "api_ok": True}
    url, headers = session.calls[0]
    assert url == "http://192.168.7.9:8080/1/summary"
    assert headers["Authorization"] == "Bearer s3cr3t"


async def test_spoofed_name_cannot_redirect_the_token_to_the_miner_ip_when_host_pinned(
    monkeypatch,
):
    # An imposter claims a listed rig's name from its own address: with the host pinned, the
    # probe (and the token) still goes only to the operator's address.
    _with_overrides(monkeypatch, [{"name": "rig1", "host": "192.168.7.9", "token": "s3cr3t"}])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    await XMRigWorkerClient(session).get_stats("8.8.8.8", "rig1")
    assert session.calls[0][0] == "http://192.168.7.9:8080/1/summary"
