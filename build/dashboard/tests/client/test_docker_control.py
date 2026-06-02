from unittest.mock import patch, MagicMock

import mining_dashboard.client.docker.docker_control as dc_mod
from mining_dashboard.client.docker.docker_control import DockerControl


class _AsyncCM:
    def __init__(self, value):
        self._value = value

    async def __aenter__(self):
        return self._value

    async def __aexit__(self, *exc):
        return False


class _FakeResp:
    def __init__(self, status, text=""):
        self.status = status
        self._text = text

    async def text(self):
        return self._text


def _session_returning(resp):
    """A mock aiohttp session whose .post(...) yields `resp` as an async context manager."""
    session = MagicMock()
    session.post.return_value = _AsyncCM(resp)
    return session


class TestUrl:
    def test_tcp_scheme_rewritten_to_http(self):
        c = DockerControl(proxy_url="tcp://172.28.0.30:2375")
        assert c.base_url == "http://172.28.0.30:2375"


class TestStopStart:
    async def test_stop_success_204(self):
        session = _session_returning(_FakeResp(204))
        c = DockerControl(proxy_url="tcp://h:2375")
        with patch.object(dc_mod.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
            assert await c.stop("xmrig-proxy") is True
        # Hits the stop endpoint with a stop-timeout param.
        url = session.post.call_args.args[0]
        assert url == "http://h:2375/containers/xmrig-proxy/stop"
        assert session.post.call_args.kwargs["params"] == {"t": 10}

    async def test_already_stopped_304_is_success(self):
        session = _session_returning(_FakeResp(304))
        c = DockerControl(proxy_url="tcp://h:2375")
        with patch.object(dc_mod.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
            assert await c.stop("xmrig-proxy") is True

    async def test_start_success(self):
        session = _session_returning(_FakeResp(204))
        c = DockerControl(proxy_url="tcp://h:2375")
        with patch.object(dc_mod.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
            assert await c.start("xmrig-proxy") is True
        assert session.post.call_args.args[0] == "http://h:2375/containers/xmrig-proxy/start"

    async def test_error_status_returns_false(self):
        session = _session_returning(_FakeResp(403, "forbidden"))
        c = DockerControl(proxy_url="tcp://h:2375")
        with patch.object(dc_mod.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
            assert await c.stop("xmrig-proxy") is False

    async def test_connection_error_returns_false(self):
        c = DockerControl(proxy_url="tcp://h:2375")
        with patch.object(dc_mod.aiohttp, "ClientSession", side_effect=OSError("refused")):
            assert await c.start("xmrig-proxy") is False
