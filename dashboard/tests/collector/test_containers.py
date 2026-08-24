import json
from unittest.mock import MagicMock, patch

import mining_dashboard.collector.containers as containers
from mining_dashboard.helper.http import MAX_RESPONSE_BYTES


class _AsyncCM:
    def __init__(self, value):
        self._value = value

    async def __aenter__(self):
        return self._value

    async def __aexit__(self, *exc):
        return False


class _Stream:
    """An aiohttp ``StreamReader``. ``read(n)`` is a SHORT read — it hands back what is buffered,
    never necessarily ``n`` bytes — and modelling that is the whole point: a bounded read written as
    a single ``read(cap)`` passes a fake that returns everything at once, then truncates any real
    body that arrives split across TCP reads. Same idiom as tests/client/test_summary_size_cap.py."""

    def __init__(self, raw, chunk=1024):
        self._raw, self._pos, self._chunk = raw, 0, chunk
        self.bytes_read = 0

    async def read(self, n=-1):
        end = len(self._raw) if n < 0 else min(len(self._raw), self._pos + min(n, self._chunk))
        chunk, self._pos = self._raw[self._pos : end], end
        self.bytes_read += len(chunk)
        return chunk


class _FakeResp:
    def __init__(self, status, payload=None, chunk=1024):
        self.status = status
        self._payload = payload or {}
        self.content = _Stream(json.dumps(self._payload).encode(), chunk)

    async def json(self):
        """Kept, though the collector no longer calls it (#1360): it is what the unbounded
        ``await response.json()`` used, so the oversized test below goes red if bounding is
        removed rather than quietly passing on a fake that models only the new shape."""
        return self._payload


def _inspect(running=True, restarting=False, restart_count=0, health=None):
    """A trimmed `GET /containers/<id>/json` payload — the fields the collector reads."""
    state = {"Running": running, "Restarting": restarting}
    if health is not None:
        state["Health"] = {"Status": health}
    return {"State": state, "RestartCount": restart_count}


def _session(responses):
    """A fake aiohttp session whose GETs return `responses` in order."""
    session = MagicMock()
    session.get.side_effect = [_AsyncCM(r) for r in responses]
    return session


class TestGetContainerHealth:
    async def test_parses_inspect_payload(self):
        # One healthy-with-healthcheck container; the other 8 names 404 (not on this host).
        responses = [_FakeResp(200, _inspect(restart_count=2, health="unhealthy"))] + [
            _FakeResp(404)
        ] * (len(containers.MONITORED_CONTAINERS) - 1)
        with patch.object(
            containers.aiohttp, "ClientSession", return_value=_AsyncCM(_session(responses))
        ):
            out = await containers.get_container_health()
        assert out == {
            "tor": {
                "running": True,
                "restarting": False,
                "restart_count": 2,
                "health": "unhealthy",
            }
        }

    async def test_no_healthcheck_maps_to_none(self):
        # State.Health absent (no healthcheck) => health None — "no signal", never "unhealthy".
        responses = [_FakeResp(200, _inspect())] + [_FakeResp(404)] * (
            len(containers.MONITORED_CONTAINERS) - 1
        )
        with patch.object(
            containers.aiohttp, "ClientSession", return_value=_AsyncCM(_session(responses))
        ):
            out = await containers.get_container_health()
        assert out["tor"]["health"] is None

    async def test_missing_container_is_skipped(self):
        # Remote mode / profile off: every name 404s → empty dict, no raise.
        responses = [_FakeResp(404)] * len(containers.MONITORED_CONTAINERS)
        with patch.object(
            containers.aiohttp, "ClientSession", return_value=_AsyncCM(_session(responses))
        ):
            assert await containers.get_container_health() == {}

    async def test_per_container_error_skips_only_that_name(self):
        # One inspect blowing up must not lose the rest of the sweep.
        session = MagicMock()
        effects = [OSError("refused")] + [
            _AsyncCM(_FakeResp(200, _inspect()))
            for _ in range(len(containers.MONITORED_CONTAINERS) - 1)
        ]
        session.get.side_effect = effects
        with patch.object(containers.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
            out = await containers.get_container_health()
        assert "tor" not in out
        assert len(out) == len(containers.MONITORED_CONTAINERS) - 1

    async def test_proxy_down_returns_empty(self):
        # Proxy unreachable entirely → {} and no raise (the data loop must keep running).
        with patch.object(containers.aiohttp, "ClientSession", side_effect=OSError("refused")):
            assert await containers.get_container_health() == {}

    async def test_an_oversized_inspect_skips_only_that_container(self):
        """Lowest trust class of the #1360 set — the payload shape comes from our own compose file
        — but a proxy answering with an unbounded body must cost one container, not buffer the
        whole thing into the state loop. Unbounded, ``json()`` hands back a valid payload and `tor`
        appears; bounded, the read is refused and the per-container ``continue`` skips it."""
        pad = "x" * MAX_RESPONSE_BYTES
        responses = [_FakeResp(200, {**_inspect(health="healthy"), "pad": pad}, chunk=65536)] + [
            _FakeResp(404)
        ] * (len(containers.MONITORED_CONTAINERS) - 1)
        with patch.object(
            containers.aiohttp, "ClientSession", return_value=_AsyncCM(_session(responses))
        ):
            out = await containers.get_container_health()
        assert out == {}
