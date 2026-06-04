import pytest

from mining_dashboard.service.alert_service import AlertService
from mining_dashboard.service.worker_presence import WorkerPresenceMonitor


class _FakeNotifier:
    """Stand-in transport: records sends, lets tests gate which events are 'enabled'."""
    def __init__(self, enabled=True, allow=None):
        self.enabled = enabled
        self._allow = allow          # None => every event allowed
        self.sent = []

    def event_enabled(self, event):
        if not self.enabled:
            return False
        return True if self._allow is None else event in self._allow

    def send(self, text):
        self.sent.append(text)
        return True


def _svc(notifier=None, **kw):
    notifier = notifier if notifier is not None else _FakeNotifier()
    kw.setdefault("worker_monitor", WorkerPresenceMonitor(offline_after=300, recovery_after=120))
    kw.setdefault("host_label", "")
    return AlertService(notifier=notifier, **kw)


def _ev(svc, *, monero_down=False, tari_down=False, tari_required=True,
        miner_released=True, online_workers=(), workers_expected=False, now=0):
    return svc.evaluate(
        monero_down=monero_down, tari_down=tari_down, tari_required=tari_required,
        miner_released=miner_released, online_workers=list(online_workers),
        workers_expected=workers_expected, now=now)


def _keys(alerts):
    return [k for k, _ in alerts]


class TestNodeEdges:
    def test_first_cycle_seeds_baseline_silently(self):
        svc = _svc()
        # Already-down at startup must not replay as a fresh alert (restart semantics).
        assert _ev(svc, monero_down=True) == []

    def test_down_then_recovered(self):
        svc = _svc()
        _ev(svc, monero_down=False)                       # seed
        assert _keys(_ev(svc, monero_down=True)) == [AlertService.EVT_NODE_DOWN]
        assert _ev(svc, monero_down=True) == []           # no repeat while still down
        assert _keys(_ev(svc, monero_down=False)) == [AlertService.EVT_NODE_RECOVERED]

    def test_node_text_names_the_chain(self):
        svc = _svc()
        _ev(svc, monero_down=False)
        _, text = _ev(svc, monero_down=True)[0]
        assert "Monero" in text


class TestTariGating:
    def test_non_blocking_tari_does_not_alert(self):
        svc = _svc()
        _ev(svc, tari_down=False, tari_required=False)
        assert _ev(svc, tari_down=True, tari_required=False) == []

    def test_no_stale_edge_when_tari_becomes_required(self):
        # Tari went down while non-blocking (no alert). Re-marking it required must not then
        # replay a down edge for a state we never alerted on.
        svc = _svc()
        _ev(svc, tari_down=False, tari_required=False)
        _ev(svc, tari_down=True, tari_required=False)     # silently tracked
        assert _ev(svc, tari_down=True, tari_required=True) == []
        # ...but a genuine recovery from there still fires.
        assert _keys(_ev(svc, tari_down=False, tari_required=True)) == [AlertService.EVT_NODE_RECOVERED]

    def test_required_tari_alerts(self):
        svc = _svc()
        _ev(svc, tari_down=False, tari_required=True)
        _, text = _ev(svc, tari_down=True, tari_required=True)[0]
        assert "Tari" in text


class TestSyncFinished:
    def test_fires_once_when_gate_opens(self):
        svc = _svc()
        _ev(svc, miner_released=False)                    # seed: still syncing
        assert _keys(_ev(svc, miner_released=True)) == [AlertService.EVT_SYNC_FINISHED]
        assert _ev(svc, miner_released=True) == []        # one-shot

    def test_no_alert_on_restart_after_sync(self):
        svc = _svc()
        # First observation is already-released (restart after sync) -> baseline, no alert.
        assert _ev(svc, miner_released=True) == []


class TestWorkerEdges:
    def test_offline_then_recovered(self):
        svc = _svc()
        assert _ev(svc, online_workers=["rig-1"], workers_expected=True, now=0) == []
        assert _ev(svc, online_workers=[], workers_expected=True, now=0) == []
        assert _keys(_ev(svc, online_workers=[], workers_expected=True, now=300)) == \
            [AlertService.EVT_WORKER_OFFLINE]
        _ev(svc, online_workers=["rig-1"], workers_expected=True, now=300)
        assert _keys(_ev(svc, online_workers=["rig-1"], workers_expected=True, now=420)) == \
            [AlertService.EVT_WORKER_RECOVERED]

    def test_not_expected_resets_and_silences(self):
        svc = _svc()
        _ev(svc, online_workers=["rig-1"], workers_expected=True, now=0)
        _ev(svc, online_workers=[], workers_expected=True, now=0)
        _ev(svc, online_workers=[], workers_expected=True, now=300)   # rig-1 now offline
        # Proxy intentionally stopped (sync hold / failover): reset, no alert.
        assert _ev(svc, online_workers=[], workers_expected=False, now=330) == []
        # Re-admission re-baselines silently — no spurious "recovered".
        assert _ev(svc, online_workers=["rig-1"], workers_expected=True, now=360) == []


class TestEventFiltering:
    def test_disabled_events_are_dropped(self):
        svc = _svc(notifier=_FakeNotifier(allow={AlertService.EVT_NODE_DOWN}))
        _ev(svc, online_workers=["rig-1"], workers_expected=True, now=0)
        _ev(svc, online_workers=[], workers_expected=True, now=0)
        # worker_offline is computed but filtered out because it's not in the allow-set.
        assert _ev(svc, online_workers=[], workers_expected=True, now=300) == []


class TestHostLabel:
    def test_prefixes_when_set(self):
        svc = _svc(host_label="box.lan")
        _ev(svc, monero_down=False)
        _, text = _ev(svc, monero_down=True)[0]
        assert text.startswith("[box.lan] ")

    def test_placeholder_host_is_not_prefixed(self):
        svc = _svc(host_label="Unknown Host")
        _ev(svc, monero_down=False)
        _, text = _ev(svc, monero_down=True)[0]
        assert not text.startswith("[")


class TestProcess:
    async def test_disabled_notifier_is_noop(self):
        notifier = _FakeNotifier(enabled=False)
        svc = _svc(notifier=notifier)
        out = await svc.process(monero_down=True, tari_down=False, tari_required=True,
                                miner_released=True, online_workers=[], workers_expected=False)
        assert out == []
        assert notifier.sent == []

    async def test_enabled_notifier_dispatches(self):
        notifier = _FakeNotifier()
        svc = _svc(notifier=notifier)
        # seed
        await svc.process(monero_down=False, tari_down=False, tari_required=True,
                          miner_released=True, online_workers=[], workers_expected=False)
        out = await svc.process(monero_down=True, tari_down=False, tari_required=True,
                                miner_released=True, online_workers=[], workers_expected=False)
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        assert len(notifier.sent) == 1 and "DOWN" in notifier.sent[0]
