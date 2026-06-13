"""Tests for the clearnet→Tor auto-transition supervisor (#183/#234)."""
import os
from unittest.mock import MagicMock, AsyncMock

from mining_dashboard.service.clearnet_sync import ClearnetSyncSupervisor


def make_supervisor(tmp_path, *, stop=True, start=True, events=None):
    dc = MagicMock()
    dc.stop = AsyncMock(return_value=stop)
    dc.start = AsyncMock(return_value=start)
    cb = None
    if events is not None:
        cb = lambda name, ok: events.append((name, ok))  # noqa: E731
    sup = ClearnetSyncSupervisor(str(tmp_path), dc, on_transition=cb)
    return sup, dc


class TestClearnetSyncSupervisor:
    async def test_flag_off_is_noop(self, tmp_path):
        sup, dc = make_supervisor(tmp_path)
        exposed = await sup.maybe_transition("monero", "monerod", flag_on=False, synced=True)
        assert exposed is False
        dc.stop.assert_not_called()
        dc.start.assert_not_called()
        assert not os.path.exists(sup.marker_path("monero"))

    async def test_syncing_reports_exposed_without_acting(self, tmp_path):
        sup, dc = make_supervisor(tmp_path)
        exposed = await sup.maybe_transition("monero", "monerod", flag_on=True, synced=False)
        assert exposed is True  # still on clearnet — banner should show
        dc.stop.assert_not_called()
        assert not os.path.exists(sup.marker_path("monero"))

    async def test_synced_writes_marker_and_restarts_onto_tor(self, tmp_path):
        events = []
        sup, dc = make_supervisor(tmp_path, events=events)
        exposed = await sup.maybe_transition("monero", "monerod", flag_on=True, synced=True)
        assert exposed is False  # transitioned → no longer exposed
        assert os.path.exists(sup.marker_path("monero"))  # persistent marker written
        dc.stop.assert_awaited_once_with("monerod")
        dc.start.assert_awaited_once_with("monerod")
        assert events == [("monero", True)]

    async def test_marker_written_before_restart(self, tmp_path):
        """The marker must exist before the container is restarted, so the new container is
        guaranteed to render Tor even if the dashboard dies mid-flip."""
        sup, dc = make_supervisor(tmp_path)
        seen = {}
        async def record_stop(container, *a, **k):
            seen["marker_at_stop"] = os.path.exists(sup.marker_path("monero"))
            return True
        dc.stop = AsyncMock(side_effect=record_stop)
        await sup.maybe_transition("monero", "monerod", flag_on=True, synced=True)
        assert seen["marker_at_stop"] is True

    async def test_already_transitioned_is_idempotent(self, tmp_path):
        sup, dc = make_supervisor(tmp_path)
        await sup.maybe_transition("monero", "monerod", flag_on=True, synced=True)
        dc.stop.reset_mock(); dc.start.reset_mock()
        # Second call: already flipped this run → no further restarts.
        exposed = await sup.maybe_transition("monero", "monerod", flag_on=True, synced=True)
        assert exposed is False
        dc.stop.assert_not_called()
        dc.start.assert_not_called()

    async def test_preexisting_marker_never_touches_container(self, tmp_path):
        # A marker present at startup = a PRIOR run already transitioned; the container came up
        # Tor-only via the entrypoint, so the supervisor must leave it alone.
        (tmp_path / "tari.synced").write_text("done\n")
        sup, dc = make_supervisor(tmp_path)
        exposed = await sup.maybe_transition("tari", "tari", flag_on=True, synced=True)
        assert exposed is False
        dc.stop.assert_not_called()
        dc.start.assert_not_called()

    async def test_failed_restart_retries_next_cycle(self, tmp_path):
        # Fail-safe: a failed restart must NOT be treated as done — it retries, never silently
        # leaving the node on clearnet.
        events = []
        sup, dc = make_supervisor(tmp_path, stop=False, events=events)
        exposed = await sup.maybe_transition("monero", "monerod", flag_on=True, synced=True)
        assert exposed is True  # still exposed — flip did not complete
        assert os.path.exists(sup.marker_path("monero"))  # but the marker is persisted
        assert events == [("monero", False)]
        # Next cycle, the restart succeeds → it completes.
        dc.stop = AsyncMock(return_value=True)
        dc.start = AsyncMock(return_value=True)
        exposed = await sup.maybe_transition("monero", "monerod", flag_on=True, synced=True)
        assert exposed is False
        dc.start.assert_awaited_once_with("monerod")

    async def test_per_chain_independent(self, tmp_path):
        sup, dc = make_supervisor(tmp_path)
        # Monero synced → transitions; Tari still syncing → stays exposed, untouched.
        m = await sup.maybe_transition("monero", "monerod", flag_on=True, synced=True)
        t = await sup.maybe_transition("tari", "tari", flag_on=True, synced=False)
        assert m is False and t is True
        assert os.path.exists(sup.marker_path("monero"))
        assert not os.path.exists(sup.marker_path("tari"))
        dc.stop.assert_awaited_once_with("monerod")

    async def test_marker_write_failure_does_not_restart(self, tmp_path):
        # If the marker can't be persisted (e.g. read-only dir), DON'T restart — a restart without
        # the marker would just re-render clearnet and a reboot would re-expose the node. Stay
        # exposed and retry, so we never end up "on Tor in memory but clearnet on disk".
        sup, dc = make_supervisor(tmp_path)
        sup._write_marker = MagicMock(return_value=False)
        exposed = await sup.maybe_transition("monero", "monerod", flag_on=True, synced=True)
        assert exposed is True
        dc.stop.assert_not_called()
        dc.start.assert_not_called()
