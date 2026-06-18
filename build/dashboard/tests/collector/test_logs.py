import struct
from unittest.mock import patch, AsyncMock, MagicMock

import pytest

import mining_dashboard.collector.logs as logs


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


class _FakeResp:
    def __init__(self, status, data=b""):
        self.status = status
        self._data = data

    async def read(self):
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
