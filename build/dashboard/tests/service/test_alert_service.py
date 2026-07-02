from mining_dashboard.service.alert_service import AlertService
from mining_dashboard.service.worker_presence import WorkerPresenceMonitor


class _FakeNotifier:
    """Stand-in transport: records sends, lets tests gate which events are 'enabled'."""

    def __init__(self, enabled=True, allow=None):
        self.enabled = enabled
        self._allow = allow  # None => every event allowed
        self.sent = []

    def event_enabled(self, event):
        if not self.enabled:
            return False
        return True if self._allow is None else event in self._allow

    def send(self, text):
        self.sent.append(text)
        return True


def _svc(notifier=None, announce_online=True, **kw):
    notifier = notifier if notifier is not None else _FakeNotifier()
    kw.setdefault("worker_monitor", WorkerPresenceMonitor(offline_after=300, recovery_after=120))
    kw.setdefault("host_label", "")
    svc = AlertService(notifier=notifier, **kw)
    # The one-shot "stack online" ping fires on the first evaluate; mark it already sent so it
    # doesn't perturb the per-signal tests. TestStackOnline opts out to exercise it.
    if announce_online:
        svc._announced_online = True
    return svc


def _ev(
    svc,
    *,
    monero_down=False,
    tari_down=False,
    tari_required=True,
    miner_released=True,
    workers=(),
    workers_expected=False,
    disk_percent=0,
    db_healthy=True,
    xvb_enabled=False,
    shares_in_window=0,
    clearnet_active=False,
    xvb_registration_state="",
    update_available=False,
    now=0,
):
    return svc.evaluate(
        monero_down=monero_down,
        tari_down=tari_down,
        tari_required=tari_required,
        miner_released=miner_released,
        workers=list(workers),
        workers_expected=workers_expected,
        disk_percent=disk_percent,
        db_healthy=db_healthy,
        xvb_enabled=xvb_enabled,
        shares_in_window=shares_in_window,
        clearnet_active=clearnet_active,
        xvb_registration_state=xvb_registration_state,
        update_available=update_available,
        now=now,
    )


def _keys(alerts):
    return [k for k, _ in alerts]


def _on(*names):
    """Worker rows the proxy reports online."""
    return [{"name": n, "status": "online"} for n in names]


def _down(*names):
    """Worker rows still listed but disconnected — the DOWN state the dashboard shows."""
    return [{"name": n, "status": "offline"} for n in names]


class TestNodeEdges:
    def test_first_cycle_seeds_baseline_silently(self):
        svc = _svc()
        # Already-down at startup must not replay as a fresh alert (restart semantics).
        assert _ev(svc, monero_down=True) == []

    def test_down_then_recovered(self):
        svc = _svc()
        _ev(svc, monero_down=False)  # seed
        assert _keys(_ev(svc, monero_down=True)) == [AlertService.EVT_NODE_DOWN]
        assert _ev(svc, monero_down=True) == []  # no repeat while still down
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
        _ev(svc, tari_down=True, tari_required=False)  # silently tracked
        assert _ev(svc, tari_down=True, tari_required=True) == []
        # ...but a genuine recovery from there still fires.
        assert _keys(_ev(svc, tari_down=False, tari_required=True)) == [
            AlertService.EVT_NODE_RECOVERED
        ]

    def test_required_tari_alerts(self):
        svc = _svc()
        _ev(svc, tari_down=False, tari_required=True)
        _, text = _ev(svc, tari_down=True, tari_required=True)[0]
        assert "Tari" in text


class TestSyncFinished:
    def test_fires_once_when_gate_opens(self):
        svc = _svc()
        _ev(svc, miner_released=False)  # seed: still syncing
        assert _keys(_ev(svc, miner_released=True)) == [AlertService.EVT_SYNC_FINISHED]
        assert _ev(svc, miner_released=True) == []  # one-shot

    def test_no_alert_on_restart_after_sync(self):
        svc = _svc()
        # First observation is already-released (restart after sync) -> baseline, no alert.
        assert _ev(svc, miner_released=True) == []


class TestWorkerEdges:
    def test_offline_then_recovered(self):
        # Offline is driven by the DOWN status the dashboard shows, not by the rig vanishing.
        svc = _svc()
        assert _ev(svc, workers=_on("rig-1"), workers_expected=True, now=0) == []
        assert _ev(svc, workers=_down("rig-1"), workers_expected=True, now=0) == []
        assert _keys(_ev(svc, workers=_down("rig-1"), workers_expected=True, now=300)) == [
            AlertService.EVT_WORKER_OFFLINE
        ]
        _ev(svc, workers=_on("rig-1"), workers_expected=True, now=300)
        assert _keys(_ev(svc, workers=_on("rig-1"), workers_expected=True, now=420)) == [
            AlertService.EVT_WORKER_RECOVERED
        ]

    def test_not_expected_resets_and_silences(self):
        svc = _svc()
        _ev(svc, workers=_on("rig-1"), workers_expected=True, now=0)
        _ev(svc, workers=_down("rig-1"), workers_expected=True, now=0)
        _ev(svc, workers=_down("rig-1"), workers_expected=True, now=300)  # rig-1 now offline
        # Proxy intentionally stopped (sync hold / failover): reset, no alert.
        assert _ev(svc, workers=[], workers_expected=False, now=330) == []
        # Re-admission re-baselines silently — no spurious "recovered".
        assert _ev(svc, workers=_on("rig-1"), workers_expected=True, now=360) == []


class TestWorkerMembership:
    def test_joined_after_baseline(self):
        svc = _svc()
        _ev(svc, workers=_on("rig-1"), workers_expected=True)  # prime
        assert _keys(_ev(svc, workers=_on("rig-1", "rig-2"), workers_expected=True)) == [
            AlertService.EVT_WORKER_JOINED
        ]

    def test_left_when_rig_drops_off_the_table(self):
        svc = _svc()
        _ev(svc, workers=_on("rig-1", "rig-2"), workers_expected=True)  # prime
        assert _keys(_ev(svc, workers=_on("rig-1"), workers_expected=True)) == [
            AlertService.EVT_WORKER_LEFT
        ]


class TestDiskEdges:
    def test_warn_then_critical_then_recover(self):
        svc = _svc()
        assert _ev(svc, disk_percent=40) == []  # seed silently
        assert _keys(_ev(svc, disk_percent=88)) == [AlertService.EVT_DISK_SPACE]  # -> warn
        assert _ev(svc, disk_percent=90) == []  # still warn, no repeat
        assert _keys(_ev(svc, disk_percent=97)) == [AlertService.EVT_DISK_SPACE]  # -> critical
        _, text = _ev(svc, disk_percent=40)[0]  # -> recovered
        assert "healthy" in text

    def test_seed_high_does_not_replay(self):
        svc = _svc()
        # Already-full at startup must not fire (restart semantics).
        assert _ev(svc, disk_percent=99) == []


class TestDbEdges:
    def test_unhealthy_then_recovered(self):
        svc = _svc()
        assert _ev(svc, db_healthy=True) == []  # seed
        assert _keys(_ev(svc, db_healthy=False)) == [AlertService.EVT_DB_UNHEALTHY]
        assert _ev(svc, db_healthy=False) == []  # no repeat
        _, text = _ev(svc, db_healthy=True)[0]
        assert "recovered" in text


class TestXvbShareEdges:
    def test_no_share_then_restored(self):
        svc = _svc()
        assert _ev(svc, xvb_enabled=True, shares_in_window=3) == []  # seed: has a share
        assert _keys(_ev(svc, xvb_enabled=True, shares_in_window=0)) == [
            AlertService.EVT_XVB_NO_SHARE
        ]
        assert _ev(svc, xvb_enabled=True, shares_in_window=0) == []  # no repeat
        _, text = _ev(svc, xvb_enabled=True, shares_in_window=1)[0]  # restored
        assert "restored" in text

    def test_silent_while_xvb_disabled(self):
        svc = _svc()
        # XvB off → the share gate doesn't apply, even with zero shares.
        assert _ev(svc, xvb_enabled=False, shares_in_window=0) == []
        # Turning XvB on re-seeds silently (no stale replay), then alerts on a real loss.
        assert _ev(svc, xvb_enabled=True, shares_in_window=2) == []
        assert _keys(_ev(svc, xvb_enabled=True, shares_in_window=0)) == [
            AlertService.EVT_XVB_NO_SHARE
        ]


class TestClearnetEdges:
    def test_exposed_then_reverted(self):
        svc = _svc()
        assert _ev(svc, clearnet_active=False) == []  # seed
        assert _keys(_ev(svc, clearnet_active=True)) == [AlertService.EVT_CLEARNET_EXPOSED]
        assert _ev(svc, clearnet_active=True) == []  # no repeat
        _, text = _ev(svc, clearnet_active=False)[0]
        assert "Tor-only" in text


class TestStackOnline:
    def test_online_fires_once_on_first_cycle(self):
        svc = _svc(announce_online=False)
        assert _keys(_ev(svc)) == [AlertService.EVT_STACK_ONLINE]
        assert _ev(svc) == []  # one-shot — not on later cycles

    def test_online_text_is_friendly(self):
        svc = _svc(announce_online=False)
        _, text = _ev(svc)[0]
        assert "online" in text.lower()


class TestXvbRegistration:
    def test_invalid_then_recovered(self):
        svc = _svc()
        assert _ev(svc, xvb_enabled=True, xvb_registration_state="registered") == []  # seed
        assert _keys(_ev(svc, xvb_enabled=True, xvb_registration_state="invalid")) == [
            AlertService.EVT_XVB_REGISTRATION
        ]
        assert _keys(_ev(svc, xvb_enabled=True, xvb_registration_state="registered")) == [
            AlertService.EVT_XVB_REGISTRATION
        ]

    def test_failing_alerts(self):
        svc = _svc()
        _ev(svc, xvb_enabled=True, xvb_registration_state="registered")
        _, text = _ev(svc, xvb_enabled=True, xvb_registration_state="failing")[0]
        assert "failing" in text.lower()

    def test_silent_while_disabled(self):
        svc = _svc()
        assert _ev(svc, xvb_enabled=False, xvb_registration_state="invalid") == []


class TestNewRelease:
    def test_fires_once_on_rising_edge(self):
        svc = _svc()
        assert _ev(svc, update_available=False) == []  # seed
        assert _keys(_ev(svc, update_available=True)) == [AlertService.EVT_NEW_RELEASE]
        assert _ev(svc, update_available=True) == []  # no repeat while still available


class TestEventFiltering:
    def test_disabled_events_are_dropped(self):
        svc = _svc(notifier=_FakeNotifier(allow={AlertService.EVT_NODE_DOWN}))
        _ev(svc, workers=_on("rig-1"), workers_expected=True, now=0)
        _ev(svc, workers=_down("rig-1"), workers_expected=True, now=0)
        # worker_offline is computed but filtered out because it's not in the allow-set.
        assert _ev(svc, workers=_down("rig-1"), workers_expected=True, now=300) == []


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
        out = await svc.process(
            monero_down=True,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        assert out == []
        assert notifier.sent == []

    async def test_enabled_notifier_dispatches(self):
        notifier = _FakeNotifier()
        svc = _svc(notifier=notifier)
        # seed
        await svc.process(
            monero_down=False,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        out = await svc.process(
            monero_down=True,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        assert len(notifier.sent) == 1 and "DOWN" in notifier.sent[0]
