"""The #1233 bounded out-of-cycle worker refresh: fires on a worker-upgrade result meaning the rig
rebuilt, never on one meaning it didn't, and gives up cleanly within its attempt cap.

Mutation-kill notes:
  - dropping the ``entry.get("ip")`` guard would try to probe a worker with no address — the
    "no ip -> no-op" test kills that.
  - inverting ``_UPGRADE_REFRESH_STATUSES`` membership (or the ``in`` to ``not in``) would fire the
    refresh on a rejected/failed upgrade, or skip a genuinely successful one — the paired
    "fires on applied/accepted" / "does not fire on rejected/failed/rolled_back/throttled/noop"
    tests kill either direction.
  - removing the attempt cap (or the sleep-then-probe ordering) would spin forever on a rig that
    never reports the target version — the "gives up after N attempts" test bounds the call count.
  - dropping the version-match early exit would burn every attempt even after a match lands —
    the "stops on first matching version" test asserts the call count stops short of the cap.
"""

from unittest.mock import AsyncMock

import pytest

from mining_dashboard.service import worker_refresh


async def _fake_sleep(_):
    return None


class FakeWorkerClient:
    def __init__(self, versions):
        # One scripted /1/summary-shaped response per call; extra calls repeat the last one.
        self._versions = list(versions)
        self.calls = []

    async def get_stats(self, ip, name):
        self.calls.append((ip, name))
        version = self._versions.pop(0) if self._versions else self._versions_last()
        if version is None:
            return {}
        return {"rigforge": {"version": version}}

    def _versions_last(self):
        return None


class TestRefreshWorkerAfterUpgrade:
    async def test_no_ip_is_a_noop(self):
        data = {"workers": [{"name": "rig1"}]}
        client = FakeWorkerClient(["1.12.0"])
        ok = await worker_refresh.refresh_worker_after_upgrade(
            data, "rig1", "v1.12.0", worker_client=client, sleep=_fake_sleep
        )
        assert ok is False
        assert client.calls == []

    async def test_unknown_worker_is_a_noop(self):
        data = {"workers": [{"name": "other", "ip": "10.0.0.5"}]}
        client = FakeWorkerClient(["1.12.0"])
        ok = await worker_refresh.refresh_worker_after_upgrade(
            data, "rig1", "v1.12.0", worker_client=client, sleep=_fake_sleep
        )
        assert ok is False
        assert client.calls == []

    async def test_stops_on_first_matching_version(self):
        entry = {"name": "rig1", "ip": "10.0.0.5"}
        data = {"workers": [entry]}
        client = FakeWorkerClient(["1.11.0", "1.12.0", "1.12.0", "1.12.0"])
        ok = await worker_refresh.refresh_worker_after_upgrade(
            data, "rig1", "v1.12.0", worker_client=client, attempts=6, sleep=_fake_sleep
        )
        assert ok is True
        assert len(client.calls) == 2  # one stale read, then the match — not all 6 attempts
        assert entry["rigforge"]["version"] == "1.12.0"

    async def test_gives_up_after_attempts_when_version_never_matches(self):
        entry = {"name": "rig1", "ip": "10.0.0.5"}
        data = {"workers": [entry]}
        client = FakeWorkerClient(["1.11.0", "1.11.0", "1.11.0"])
        ok = await worker_refresh.refresh_worker_after_upgrade(
            data, "rig1", "v1.12.0", worker_client=client, attempts=3, sleep=_fake_sleep
        )
        assert ok is False
        assert len(client.calls) == 3  # bounded, not unbounded
        assert entry["rigforge"]["version"] == "1.11.0"  # last reachable read still merged

    async def test_unreachable_probe_is_tolerated_and_retried(self):
        entry = {"name": "rig1", "ip": "10.0.0.5"}
        data = {"workers": [entry]}

        class FlakyClient:
            def __init__(self):
                self.calls = 0

            async def get_stats(self, ip, name):
                self.calls += 1
                if self.calls == 1:
                    raise TimeoutError("no route to host")
                return {"rigforge": {"version": "1.12.0"}}

        client = FlakyClient()
        ok = await worker_refresh.refresh_worker_after_upgrade(
            data, "rig1", "v1.12.0", worker_client=client, attempts=3, sleep=_fake_sleep
        )
        assert ok is True
        assert client.calls == 2

    async def test_reachable_but_no_rigforge_block_is_tolerated_and_retried(self):
        # A reachable read that isn't from a RigForge rig (or reports nothing yet) parses to
        # `None` — must keep polling, not treat a plain-xmrig response as a terminal failure.
        entry = {"name": "rig1", "ip": "10.0.0.5"}
        data = {"workers": [entry]}
        client = FakeWorkerClient([None, "1.12.0"])
        ok = await worker_refresh.refresh_worker_after_upgrade(
            data, "rig1", "v1.12.0", worker_client=client, attempts=3, sleep=_fake_sleep
        )
        assert ok is True
        assert len(client.calls) == 2


class TestMaybeRefreshAfterUpgrade:
    """The gate deciding WHICH worker-upgrade terminal results deserve the refresh above."""

    async def test_fires_on_applied(self, monkeypatch):
        called = AsyncMock(return_value=True)
        monkeypatch.setattr(worker_refresh, "refresh_worker_after_upgrade", called)
        await worker_refresh.maybe_refresh_after_upgrade(
            {}, "rig1", "v1.0.0", {"status": "applied"}
        )
        called.assert_awaited_once()

    async def test_fires_on_accepted(self, monkeypatch):
        called = AsyncMock(return_value=True)
        monkeypatch.setattr(worker_refresh, "refresh_worker_after_upgrade", called)
        await worker_refresh.maybe_refresh_after_upgrade(
            {}, "rig1", "v1.0.0", {"status": "accepted"}
        )
        called.assert_awaited_once()

    @pytest.mark.parametrize("status", ["rejected", "failed", "rolled_back", "throttled", "noop"])
    async def test_does_not_fire_on_non_success(self, monkeypatch, status):
        called = AsyncMock(return_value=True)
        monkeypatch.setattr(worker_refresh, "refresh_worker_after_upgrade", called)
        await worker_refresh.maybe_refresh_after_upgrade({}, "rig1", "v1.0.0", {"status": status})
        called.assert_not_awaited()

    async def test_uses_the_hosts_reported_version_over_the_proposal(self, monkeypatch):
        # The host re-derives the real tag (control_upgrade); res["version"] is the authoritative
        # one, not the client's original proposal — a regression that swapped the args back to the
        # proposal would still pass every OTHER test here, so this pins the argument explicitly.
        called = AsyncMock(return_value=True)
        monkeypatch.setattr(worker_refresh, "refresh_worker_after_upgrade", called)
        await worker_refresh.maybe_refresh_after_upgrade(
            {}, "rig1", "v1.0.0", {"status": "applied", "version": "v1.2.0"}
        )
        called.assert_awaited_once_with({}, "rig1", "v1.2.0")
