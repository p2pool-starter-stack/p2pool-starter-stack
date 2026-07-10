from unittest.mock import MagicMock, patch

import mining_dashboard.collector.containers as containers


class _AsyncCM:
    def __init__(self, value):
        self._value = value

    async def __aenter__(self):
        return self._value

    async def __aexit__(self, *exc):
        return False


class _FakeResp:
    def __init__(self, status, payload=None):
        self.status = status
        self._payload = payload or {}

    async def json(self):
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
