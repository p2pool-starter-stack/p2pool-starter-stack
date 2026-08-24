import logging
from unittest.mock import MagicMock, patch

import mining_dashboard.client.docker.docker_control as dc_mod
from mining_dashboard.client.docker.docker_control import DockerControl
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
    def __init__(self, status, text="", chunk=1024):
        self.status = status
        self._text = text
        self.content = _Stream(text.encode(), chunk)

    async def text(self):
        """Kept, though ``_post`` no longer calls it (#1360): it is what the unbounded read used,
        so the oversized test below goes red if the bounding is removed."""
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

    async def test_error_status_returns_false(self, caplog):
        session = _session_returning(_FakeResp(403, "forbidden"))
        c = DockerControl(proxy_url="tcp://h:2375")
        with caplog.at_level(logging.ERROR):
            with patch.object(dc_mod.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
                assert await c.stop("xmrig-proxy") is False
        # The bounded read still delivers a real error body — the point of #1360 is a ceiling on
        # it, not the loss of the one thing that says WHY the container refused to stop.
        assert "forbidden" in caplog.text

    async def test_an_oversized_error_body_is_refused(self, caplog):
        """The 200-char slice in the log line only ever trimmed what was PRINTED — the whole body
        was buffered first, so an error response was the one unbounded read here (#1360). Both
        versions return False, so the distinguishing evidence is the log: unbounded, the body
        reaches it; bounded, a size refusal does."""
        session = _session_returning(_FakeResp(403, "z" * (MAX_RESPONSE_BYTES + 1), chunk=65536))
        c = DockerControl(proxy_url="tcp://h:2375")
        with caplog.at_level(logging.ERROR):
            with patch.object(dc_mod.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
                assert await c.stop("xmrig-proxy") is False
        assert "exceeded" in caplog.text
        assert "zzz" not in caplog.text

    async def test_connection_error_returns_false(self):
        c = DockerControl(proxy_url="tcp://h:2375")
        with patch.object(dc_mod.aiohttp, "ClientSession", side_effect=OSError("refused")):
            assert await c.start("xmrig-proxy") is False
