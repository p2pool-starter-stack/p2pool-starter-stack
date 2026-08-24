import struct
from unittest.mock import AsyncMock, MagicMock, patch

import mining_dashboard.collector.logs as logs
from mining_dashboard.helper.http import MAX_RESPONSE_BYTES


def _cap_for(tail):
    """The cap the collector derives for a given ``tail`` — read from the module, never restated,
    so this cannot drift into asserting a number the code no longer uses."""
    return logs._log_cap(tail)


async def _fetch(resp, tail=None):
    session = MagicMock()
    session.get.return_value = _AsyncCM(resp)
    with patch.object(logs.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
        return await logs.fetch_docker_logs("monerod", tail=tail)


def _frame(text, stream=1):
    """Build one Docker multiplexed-stream frame: 8-byte header + payload."""
    payload = text.encode()
    return struct.pack(">B", stream) + b"\x00\x00\x00" + struct.pack(">I", len(payload)) + payload


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
    def __init__(self, status, data=b"", chunk=1024):
        self.status = status
        self._data = data
        self.content = _Stream(data, chunk)

    async def read(self):
        """Kept, though the collector no longer calls it (#1360): it is what the unbounded read
        used, so the oversized tests below go red if the bounding is removed rather than passing
        against a fake that only models the new shape."""
        return self._data


class TestParseDockerStream:
    def test_parses_multiple_frames(self):
        data = _frame("line one") + _frame("line two", stream=2)
        assert logs._parse_docker_stream(data) == ["line one", "line two"]

    def test_skips_blank_lines(self):
        assert logs._parse_docker_stream(_frame("   ")) == []

    def test_truncated_frame_breaks_cleanly(self):
        assert logs._parse_docker_stream(b"\x01\x00\x00") == []


class TestFetchDockerLogs:
    async def test_success(self):
        resp = _FakeResp(200, _frame("hello"))
        session = MagicMock()
        session.get.return_value = _AsyncCM(resp)
        with patch.object(logs.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
            out = await logs.fetch_docker_logs("monerod")
        assert out == ["hello"]

    async def test_non_200_returns_error(self):
        session = MagicMock()
        session.get.return_value = _AsyncCM(_FakeResp(404))
        with patch.object(logs.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
            out = await logs.fetch_docker_logs("monerod")
        assert out[0].startswith("Error")

    async def test_connection_error_handled(self):
        with patch.object(logs.aiohttp, "ClientSession", side_effect=OSError("refused")):
            out = await logs.fetch_docker_logs("monerod")
        assert "Connection to Docker Proxy failed" in out[0]

    async def test_an_oversized_log_body_is_refused(self):
        """Container logs carry miner-supplied strings — worker names, pool messages — so "our own
        daemon serves it" is not the question (#1360). Unbounded, the whole frame is read and
        parsed; bounded, the read is refused and the existing failure string is returned."""
        cap = _cap_for(logs.LOG_TAIL_LINES)
        out = await _fetch(_FakeResp(200, _frame("x" * (cap + 1)), chunk=65536))
        assert out == ["Error: Connection to Docker Proxy failed."]

    async def test_the_cap_scales_with_the_operator_s_tail_setting(self):
        """``tail`` bounds LINES, never bytes, and it is operator-configurable. A FLAT cap would
        refuse a legitimate large-tail config — the worse of the two failure modes, because it
        presents as the daemon being broken rather than as a refusal."""
        body = "y" * (2 * 1024 * 1024)
        assert len(body) > _cap_for(1)  # refused at tail=1 ...
        assert len(body) < _cap_for(1000)  # ... and accepted at tail=1000
        assert await _fetch(_FakeResp(200, _frame(body), chunk=65536), tail=1000) == [body]
        assert await _fetch(_FakeResp(200, _frame(body), chunk=65536), tail=1) == [
            "Error: Connection to Docker Proxy failed."
        ]

    async def test_a_completely_full_tail_window_is_accepted_headers_and_all(self):
        """The maximally packed legitimate case — ``tail`` frames each carrying a full 16 KiB
        payload — is the exact case the derived ceiling exists to admit, and it was refused (#1360).

        ``bounded_read`` counts RAW stream bytes, so the real weight of a full window is
        ``tail * (16384 + 8)``: Docker prefixes every frame with an 8-byte header. A cap of
        ``tail * 16384`` is short by ``tail * 8`` and cuts the window off just before its end.

        ``tail=64`` is the smallest value that demonstrates it, because below it the 1 MiB floor
        dominates and hides the shortfall: at 64, ``64 * 16384`` is exactly the floor, so the header
        bytes are the whole of the difference. Against the pre-fix cap this body is one frame's
        header too large and the collector returns the connection-failure string instead of logs."""
        tail = 64
        raw = b"".join(_frame("z" * logs._LOG_BYTES_PER_LINE) for _ in range(tail))
        assert len(raw) == tail * (logs._LOG_BYTES_PER_LINE + logs._LOG_FRAME_HEADER)
        assert len(raw) > max(MAX_RESPONSE_BYTES, tail * logs._LOG_BYTES_PER_LINE)  # pre-fix: over
        assert len(raw) <= _cap_for(tail)  # post-fix: admitted, and only just
        out = await _fetch(_FakeResp(200, raw, chunk=65536), tail=tail)
        assert out == ["z" * logs._LOG_BYTES_PER_LINE] * tail

    async def test_a_body_split_across_many_reads_is_still_read_whole(self):
        """The regression a single ``read(cap)`` would cause: aiohttp's read is SHORT, so a body
        arriving in pieces would come back truncated and a healthy daemon would look broken."""
        out = await _fetch(_FakeResp(200, _frame("hello there"), chunk=3))
        assert out == ["hello there"]


class TestRemoteSyncStatus:
    async def _patch_file(self, content):
        return patch.object(logs.aiofiles, "open", return_value=_AsyncCM(_FakeFile(content)))

    async def test_syncing(self):
        with patch.object(
            logs.aiofiles,
            "open",
            return_value=_AsyncCM(_FakeFile('{"height": 50, "target_height": 100}')),
        ):
            status = await logs._get_remote_monero_sync_status()
        assert status == {"is_syncing": True, "current": 50, "target": 100, "percent": 50}

    async def test_synced(self):
        with patch.object(
            logs.aiofiles,
            "open",
            return_value=_AsyncCM(_FakeFile('{"height": 100, "target_height": 100}')),
        ):
            assert await logs._get_remote_monero_sync_status() == {"is_syncing": False}

    async def test_file_not_found(self):
        with patch.object(logs.aiofiles, "open", side_effect=FileNotFoundError):
            assert await logs._get_remote_monero_sync_status() == {"is_syncing": False}

    async def test_bad_json(self):
        with patch.object(logs.aiofiles, "open", return_value=_AsyncCM(_FakeFile("{bad"))):
            assert await logs._get_remote_monero_sync_status() == {"is_syncing": False}


class TestLogSyncStatus:
    """Log-scraping fallback path (`_get_monero_sync_status_from_logs`)."""

    async def test_new_format_top_block_candidate(self):
        with patch.object(
            logs,
            "get_monero_logs",
            AsyncMock(return_value=["top block candidate: 100 -> 200 [node]"]),
        ):
            status = await logs._get_monero_sync_status_from_logs()
        assert status["is_syncing"] is True
        assert status["current"] == 100 and status["target"] == 200
        assert status["percent"] == 50

    async def test_old_synced_format(self):
        with patch.object(
            logs, "get_monero_logs", AsyncMock(return_value=["Synced 50/100 (50%, ...)"])
        ):
            assert (await logs._get_monero_sync_status_from_logs())["percent"] == 50

    async def test_already_synchronized(self):
        with patch.object(
            logs,
            "get_monero_logs",
            AsyncMock(return_value=["You are now synchronized with the network"]),
        ):
            assert await logs._get_monero_sync_status_from_logs() == {"is_syncing": False}

    async def test_error_logs(self):
        with patch.object(logs, "get_monero_logs", AsyncMock(return_value=["Error: nope"])):
            assert await logs._get_monero_sync_status_from_logs() == {"is_syncing": False}


class TestLocalSyncStatus:
    """Orchestrator: prefer the get_info RPC, fall back to log scraping when unreachable."""

    async def test_rpc_result_used_when_available(self):
        # RPC returns a status → use it directly (flagged reachable), never touch the logs.
        rpc_status = {"is_syncing": True, "current": 10, "target": 20, "percent": 50}
        with (
            patch.object(logs._monero_client, "get_sync_status", return_value=rpc_status),
            patch.object(logs, "get_monero_logs", AsyncMock()) as mock_logs,
        ):
            status = await logs._get_local_monero_sync_status()
        assert status["is_syncing"] is True and status["percent"] == 50
        assert status["reachable"] is True
        mock_logs.assert_not_called()

    async def test_falls_back_to_logs_when_rpc_unreachable(self):
        # RPC returns None (node unreachable / creds absent) → scrape logs, flagged not
        # reachable so the down-detector can act (Issue #31).
        with (
            patch.object(logs._monero_client, "get_sync_status", return_value=None),
            patch.object(
                logs, "get_monero_logs", AsyncMock(return_value=["Synced 50/100 (50%, ...)"])
            ),
        ):
            status = await logs._get_local_monero_sync_status()
        assert status["is_syncing"] is True and status["percent"] == 50
        assert status["reachable"] is False


class TestDispatch:
    async def test_local_when_default_host(self):
        with (
            patch.object(logs, "MONERO_NODE_HOST", "172.28.0.26"),
            patch.object(
                logs, "_get_local_monero_sync_status", AsyncMock(return_value={"is_syncing": True})
            ),
        ):
            assert (await logs.get_monero_sync_status())["is_syncing"] is True

    async def test_remote_when_other_host(self):
        with (
            patch.object(logs, "MONERO_NODE_HOST", "10.0.0.9"),
            patch.object(
                logs,
                "_get_remote_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False}),
            ),
        ):
            # Remote node is reported reachable so reject-workers no-ops for it (Issue #31).
            assert await logs.get_monero_sync_status() == {"is_syncing": False, "reachable": True}


class _FakeFile:
    def __init__(self, content):
        self._content = content

    async def read(self):
        return self._content
