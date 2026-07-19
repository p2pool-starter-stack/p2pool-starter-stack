from types import SimpleNamespace

import mining_dashboard.service.alert_service as alert_mod
from mining_dashboard.config.config import TELEGRAM_EVENTS
from mining_dashboard.service.alert_service import AlertService
from mining_dashboard.service.worker_presence import WorkerPresenceMonitor


def test_every_alert_event_has_a_config_toggle():
    # The canonical event set (AlertService.EVT_*) must line up 1:1 with the per-event toggles in
    # config.py TELEGRAM_EVENTS — so adding an alert but forgetting its toggle (or vice versa) fails
    # here instead of silently shipping an un-toggleable / dead event. The config-surface side
    # (config.reference.json, docker-compose.yml, pithead render) is guarded in tests/stack/run.sh.
    evt_values = {v for k, v in vars(AlertService).items() if k.startswith("EVT_")}
    assert evt_values == set(TELEGRAM_EVENTS)


class _FakeNotifier:
    """Stand-in transport: records sends, lets tests gate which events are 'enabled'."""

    def __init__(self, enabled=True, allow=None):
        self.enabled = enabled
        self._allow = allow  # None => every event allowed
        self.sent = []
        self.sent_events = []

    def event_enabled(self, event):
        if not self.enabled:
            return False
        return True if self._allow is None else event in self._allow

    def send(self, text, event=""):
        self.sent.append(text)
        self.sent_events.append(event)
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
    db_reset_seq=0,
    db_reset_detail=None,
    xvb_enabled=False,
    shares_in_window=0,
    clearnet_active=False,
    xvb_registration_state="",
    update_available=False,
    low_hr_warning=False,
    hugepages_reserved=True,
    low_ram=False,
    observed_wallet="",
    reject_rate_1h=None,
    blocks_found_total=0,
    block_height=0,
    containers=None,
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
        db_reset_seq=db_reset_seq,
        db_reset_detail=db_reset_detail,
        xvb_enabled=xvb_enabled,
        shares_in_window=shares_in_window,
        clearnet_active=clearnet_active,
        xvb_registration_state=xvb_registration_state,
        update_available=update_available,
        low_hr_warning=low_hr_warning,
        hugepages_reserved=hugepages_reserved,
        low_ram=low_ram,
        observed_wallet=observed_wallet,
        reject_rate_1h=reject_rate_1h,
        blocks_found_total=blocks_found_total,
        block_height=block_height,
        containers=containers,
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


def _kv_store():
    """A dict-backed stand-in for StateManager's kv_store (#375)."""
    store = {}
    return store, store.get, lambda k, v: store.__setitem__(k, str(v))


_W_A = "4A" + "a" * 93
_W_B = "4B" + "b" * 93


class TestWalletChanged:
    def test_first_observation_seeds_silently(self):
        store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        assert _ev(svc, observed_wallet=_W_A) == []
        assert store["payout_wallet"] == _W_A

    def test_change_fires_once_then_rearms(self):
        store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        _ev(svc, observed_wallet=_W_A)  # seed
        alerts = _ev(svc, observed_wallet=_W_B)
        assert _keys(alerts) == [AlertService.EVT_WALLET_CHANGED]
        # Steady state on the new wallet is silent; a further change fires again (re-armed).
        assert _ev(svc, observed_wallet=_W_B) == []
        assert _keys(_ev(svc, observed_wallet=_W_A)) == [AlertService.EVT_WALLET_CHANGED]

    def test_alert_truncates_addresses_to_8_chars(self):
        _store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        _ev(svc, observed_wallet=_W_A)
        _, text = _ev(svc, observed_wallet=_W_B)[0]
        assert _W_A[:8] in text and _W_B[:8] in text
        # The full addresses must never reach Telegram (chat logs live on Telegram's servers).
        assert _W_A not in text and _W_B not in text

    def test_change_persists_new_baseline_and_ts(self):
        store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        _ev(svc, observed_wallet=_W_A)
        _ev(svc, observed_wallet=_W_B)
        assert store["payout_wallet"] == _W_B
        assert store["payout_wallet_prev8"] == _W_A[:8]
        assert float(store["payout_wallet_changed_ts"]) > 0

    def test_empty_or_unknown_observation_noops(self):
        # p2pool reports no wallet while restarting — that must neither fire nor re-seed.
        store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        _ev(svc, observed_wallet=_W_A)
        assert _ev(svc, observed_wallet="") == []
        assert _ev(svc, observed_wallet="Unknown") == []
        assert store["payout_wallet"] == _W_A

    def test_baseline_survives_restart(self):
        # `apply` recreates the dashboard container; the kv baseline (not AlertService memory)
        # must carry across, so a wallet swapped during the recreate still trips the alert.
        store, get, put = _kv_store()
        _ev(_svc(kv_get=get, kv_set=put), observed_wallet=_W_A)  # seed, then "restart"
        svc2 = _svc(kv_get=get, kv_set=put)  # fresh service, same storage
        assert _ev(svc2, observed_wallet=_W_A) == []  # unchanged wallet stays silent
        assert _keys(_ev(svc2, observed_wallet=_W_B)) == [AlertService.EVT_WALLET_CHANGED]

    def test_without_kv_hooks_is_noop(self):
        # Default construction (no storage injected) leaves the tripwire off rather than crashing.
        assert _ev(_svc(), observed_wallet=_W_A) == []


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


class TestDbReset:
    """One-shot DB-reset alert (#489): fires once when the corrupt-DB auto-heal bumps the counter."""

    def test_fires_once_on_increment(self):
        svc = _svc()
        assert _ev(svc, db_reset_seq=0) == []  # seed silently
        alerts = _ev(svc, db_reset_seq=1, db_reset_detail={"quarantine": "/data/x.corrupt-Z"})
        assert _keys(alerts) == [AlertService.EVT_DB_RESET]
        _, text = alerts[0]
        assert "reset" in text and "/data/x.corrupt-Z" in text
        assert _ev(svc, db_reset_seq=1) == []  # same seq -> no repeat

    def test_seed_nonzero_does_not_replay(self):
        # A restart after a prior reset (counter already >0) must not re-alert.
        svc = _svc()
        assert _ev(svc, db_reset_seq=5) == []


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

    def test_benign_transition_is_silent(self):
        # A change that isn't into invalid/failing (nor recovering from one) doesn't alert.
        svc = _svc()
        _ev(svc, xvb_enabled=True, xvb_registration_state="registered")  # seed
        assert _ev(svc, xvb_enabled=True, xvb_registration_state="") == []


class TestNewRelease:
    def test_fires_once_on_rising_edge(self):
        svc = _svc()
        assert _ev(svc, update_available=False) == []  # seed
        assert _keys(_ev(svc, update_available=True)) == [AlertService.EVT_NEW_RELEASE]
        assert _ev(svc, update_available=True) == []  # no repeat while still available


class TestHashrateLow:
    def test_warns_then_recovers(self):
        svc = _svc()
        assert _ev(svc, low_hr_warning=False) == []  # seed
        assert _keys(_ev(svc, low_hr_warning=True)) == [AlertService.EVT_HASHRATE_LOW]
        assert _ev(svc, low_hr_warning=True) == []  # no repeat
        _, text = _ev(svc, low_hr_warning=False)[0]
        assert "back above" in text


class TestRejectRateEdges:
    """#116: trailing-1h reject rate (from the persisted share deltas) crossing REJECT_ALERT_PCT."""

    def test_fires_once_then_recovers(self):
        svc = _svc()
        assert _ev(svc, reject_rate_1h=1.0) == []  # seed silently
        assert _keys(_ev(svc, reject_rate_1h=8.0)) == [AlertService.EVT_HIGH_REJECT_RATE]
        assert _ev(svc, reject_rate_1h=9.5) == []  # still high, no repeat
        _, text = _ev(svc, reject_rate_1h=0.5)[0]  # -> recovered
        assert "back to normal" in text

    def test_seed_high_does_not_replay(self):
        # Already-high at startup must not fire (restart semantics, like the other edges).
        svc = _svc()
        assert _ev(svc, reject_rate_1h=50.0) == []

    def test_none_is_no_verdict_and_resets_baseline(self):
        # No shares in the window (proxy idle/held) -> quiet, and resumed mining seeds fresh
        # rather than firing a recovery for a state that never alerted.
        svc = _svc()
        assert _ev(svc, reject_rate_1h=9.0) == []  # seed high
        assert _ev(svc, reject_rate_1h=None) == []  # proxy went idle
        assert _ev(svc, reject_rate_1h=0.5) == []  # re-seed, no stale "recovered"
        assert _keys(_ev(svc, reject_rate_1h=6.0)) == [AlertService.EVT_HIGH_REJECT_RATE]

    def test_threshold_boundary(self):
        svc = _svc()
        assert _ev(svc, reject_rate_1h=0.0) == []  # seed ok
        assert _ev(svc, reject_rate_1h=4.99) == []  # below the 5% threshold
        assert _keys(_ev(svc, reject_rate_1h=5.0)) == [AlertService.EVT_HIGH_REJECT_RATE]


class TestBlockEdges:
    """#336: block-found / payout-found off p2pool's cumulative totalBlocksFound counter."""

    def test_first_observation_seeds_silently(self):
        # A dashboard restart must not replay the last block.
        svc = _svc()
        assert _ev(svc, blocks_found_total=7, block_height=3_000_000) == []
        assert _ev(svc, blocks_found_total=7, block_height=3_000_000) == []  # steady -> quiet

    def test_block_without_share_alerts_block_only(self):
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        alerts = _ev(svc, blocks_found_total=8, block_height=3_000_123, shares_in_window=0)
        assert _keys(alerts) == [AlertService.EVT_BLOCK_FOUND]
        assert "3,000,123" in alerts[0][1]

    def test_block_with_share_also_alerts_payout(self):
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        alerts = _ev(svc, blocks_found_total=8, block_height=3_000_123, shares_in_window=3)
        assert _keys(alerts) == [AlertService.EVT_BLOCK_FOUND, AlertService.EVT_PAYOUT_FOUND]
        assert "3 PPLNS share(s)" in alerts[1][1]

    def test_counter_backwards_rebaselines_silently(self):
        # p2pool restart: the counter resets, the next observation seeds the new baseline
        # silently (two-step), and the next real find from there still fires.
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        assert _ev(svc, blocks_found_total=0) == []  # backwards -> arm rebaseline
        assert _ev(svc, blocks_found_total=0) == []  # next observation seeds silently
        assert _keys(_ev(svc, blocks_found_total=1, block_height=3_000_200)) == [
            AlertService.EVT_BLOCK_FOUND
        ]

    def test_transient_stats_blank_does_not_fire(self):
        # A partially-written stats file reads 0 for one poll, then restores the real counter.
        # The 7→0→7 round trip must stay silent — the restored 7 is not "found 7 blocks".
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        assert _ev(svc, blocks_found_total=0) == []  # blank -> arm rebaseline
        assert _ev(svc, blocks_found_total=7) == []  # restore seeds silently
        # Normal edge behavior resumes: the next genuine find fires once.
        assert _keys(_ev(svc, blocks_found_total=8, block_height=3_000_400)) == [
            AlertService.EVT_BLOCK_FOUND
        ]

    def test_burst_alerts_once_with_the_count(self):
        svc = _svc()
        _ev(svc, blocks_found_total=7)  # seed
        alerts = _ev(svc, blocks_found_total=10, block_height=3_000_300)
        assert _keys(alerts) == [AlertService.EVT_BLOCK_FOUND]
        assert "3 Monero blocks" in alerts[0][1]

    def test_good_news_is_not_an_incident(self):
        svc = _svc()
        _ev(svc, blocks_found_total=7)
        _ev(svc, blocks_found_total=8, shares_in_window=2)
        assert svc.drain_incidents() == {}


class _StubContainerMonitor:
    """Scripted ContainerHealthMonitor stand-in: the debounce logic has its own unit tests
    (test_container_health.py); here we only prove the edge → event/message mapping."""

    def __init__(self, edges=()):
        self.edges = list(edges)
        self.fed = []

    def update(self, states, now=None):
        self.fed.append(states)
        return self.edges


class TestContainerEdges:
    """#337: container crash-loop / stuck-unhealthy / recovered off the read-proxy inspects."""

    def test_crash_loop_message_names_the_container(self):
        svc = _svc(container_monitor=_StubContainerMonitor([("p2pool", "crash_loop")]))
        alerts = _ev(svc, containers={})
        assert _keys(alerts) == [AlertService.EVT_CONTAINER_UNHEALTHY]
        assert "p2pool" in alerts[0][1] and "docker logs p2pool" in alerts[0][1]

    def test_unhealthy_and_recovered_messages(self):
        svc = _svc(
            container_monitor=_StubContainerMonitor(
                [("monerod", "unhealthy"), ("tari", "recovered")]
            )
        )
        alerts = _ev(svc, containers={})
        assert _keys(alerts) == [AlertService.EVT_CONTAINER_UNHEALTHY] * 2
        assert "monerod" in alerts[0][1] and "unhealthy" in alerts[0][1]
        assert "tari" in alerts[1][1] and "recovered" in alerts[1][1]

    def test_problem_edges_are_incidents_recovery_is_not(self):
        svc = _svc(
            container_monitor=_StubContainerMonitor(
                [("p2pool", "crash_loop"), ("monerod", "unhealthy"), ("tari", "recovered")]
            )
        )
        _ev(svc, containers={})
        assert svc.drain_incidents() == {"container_unhealthy": 2}

    def test_none_is_no_data_and_skips_the_monitor(self):
        # containers=None (collector skipped) is no verdict — the monitor isn't fed, so its
        # streak state stays put rather than aging on missing data.
        monitor = _StubContainerMonitor([("p2pool", "crash_loop")])
        svc = _svc(container_monitor=monitor)
        assert _ev(svc, containers=None) == []
        assert monitor.fed == []

    def test_toggle_off_filters_every_edge(self):
        svc = _svc(
            notifier=_FakeNotifier(allow=set()),
            container_monitor=_StubContainerMonitor([("p2pool", "crash_loop")]),
        )
        assert _ev(svc, containers={}) == []

    def test_real_monitor_wiring_uses_now(self):
        # End-to-end through evaluate() with the real monitor: a restarting container on two
        # consecutive cycles is a crash-loop edge; the injected `now` drives its clock.
        svc = _svc()
        s = {"restart_count": 0, "restarting": True, "health": None, "running": True}
        assert _ev(svc, containers={"tari": {**s, "restarting": False}}, now=0) == []  # seed
        assert _ev(svc, containers={"tari": s}, now=30) == []
        assert _keys(_ev(svc, containers={"tari": s}, now=60)) == [
            AlertService.EVT_CONTAINER_UNHEALTHY
        ]


class TestIncidentLog:
    def test_tallies_problems_and_drains(self):
        svc = _svc()
        _ev(svc, monero_down=False)  # seed
        _ev(svc, monero_down=True)  # +node_down
        _ev(svc, db_healthy=True)  # seed
        _ev(svc, db_healthy=False)  # +db_unhealthy
        _ev(svc, disk_percent=50)  # seed
        _ev(svc, disk_percent=97)  # +disk_space (critical)
        assert svc.drain_incidents() == {
            "node_down": 1,
            "db_unhealthy": 1,
            "disk_space": 1,
        }
        assert svc.drain_incidents() == {}  # drained → reset

    def test_recoveries_are_not_incidents(self):
        svc = _svc()
        _ev(svc, monero_down=False)
        _ev(svc, monero_down=True)  # +1
        _ev(svc, monero_down=False)  # recovery — not counted
        assert svc.drain_incidents() == {"node_down": 1}

    def test_worker_offline_counts_once(self):
        svc = _svc()
        _ev(svc, workers=_on("r"), workers_expected=True, now=0)  # prime
        _ev(svc, workers=_down("r"), workers_expected=True, now=0)  # DOWN streak
        _ev(svc, workers=_down("r"), workers_expected=True, now=300)  # offline → incident
        _ev(svc, workers=_on("r"), workers_expected=True, now=300)  # back online
        _ev(svc, workers=_on("r"), workers_expected=True, now=420)  # recovered — not counted
        assert svc.drain_incidents() == {"worker_offline": 1}


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

    async def test_disabled_notifier_still_persists_wallet_baseline(self):
        # The payout-wallet tripwire (#375) must work on a Telegram-less stack — the default.
        # The dashboard's 72h banner reads the kv keys, so the baseline seed + change record
        # must persist every cycle; only the Telegram message stays notifier-gated.
        store, get, put = _kv_store()
        svc = _svc(notifier=_FakeNotifier(enabled=False), kv_get=get, kv_set=put)
        signals = dict(
            monero_down=False,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        await svc.process(observed_wallet=_W_A, **signals)  # seed
        assert store["payout_wallet"] == _W_A
        out = await svc.process(observed_wallet=_W_B, **signals)  # tamper
        assert out == [] and svc.notifier.sent == []  # no Telegram — but the kv record lands
        assert store["payout_wallet"] == _W_B
        assert store["payout_wallet_prev8"] == _W_A[:8]
        assert float(store["payout_wallet_changed_ts"]) > 0

    async def test_disabled_path_swallows_wallet_baseline_error(self):
        # A broken kv store must not break the data loop, Telegram on or off.
        def boom(_k, _v=None):
            raise RuntimeError("kv down")

        svc = _svc(notifier=_FakeNotifier(enabled=False), kv_get=boom, kv_set=boom)
        out = await svc.process(
            monero_down=False,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
            observed_wallet=_W_A,
        )
        assert out == []

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

    async def test_process_swallows_evaluate_error(self, monkeypatch):
        # A bug in evaluate() must never break the data loop — process() catches, logs, returns [].
        svc = _svc(notifier=_FakeNotifier())

        def boom(**_kw):
            raise RuntimeError("kaboom")

        monkeypatch.setattr(svc, "evaluate", boom)
        out = await svc.process(
            monero_down=True,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        assert out == []


_PROCESS_SIGNALS = dict(
    tari_down=False,
    tari_required=True,
    miner_released=True,
    workers=[],
    workers_expected=False,
)


class TestSinkFanout:
    """Multi-sink dispatch (#380): every alert reaches every sink that carries its event."""

    async def test_alert_reaches_every_sink(self):
        tg, hook = _FakeNotifier(), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        await svc.process(monero_down=False, **_PROCESS_SIGNALS)  # seed
        out = await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        for sink in (tg, hook):
            assert len(sink.sent) == 1 and "DOWN" in sink.sent[0]
            assert sink.sent_events == [AlertService.EVT_NODE_DOWN]

    async def test_telegram_disabled_webhook_still_delivers(self):
        # A webhook-only stack (Telegram unconfigured) must still alert — `enabled` is any-sink.
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        assert svc.enabled is True
        await svc.process(monero_down=False, **_PROCESS_SIGNALS)
        out = await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        assert tg.sent == [] and len(hook.sent) == 1

    async def test_per_event_toggle_silences_only_that_sink(self):
        # Telegram's node_down toggled off silences Telegram; the webhook (no per-event
        # toggles) still gets the alert.
        tg, hook = _FakeNotifier(allow=set()), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        await svc.process(monero_down=False, **_PROCESS_SIGNALS)
        out = await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        assert tg.sent == [] and len(hook.sent) == 1

    async def test_all_sinks_disabled_is_noop(self):
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier(enabled=False)
        svc = _svc(notifier=tg, sinks=[tg, hook])
        assert svc.enabled is False
        await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        out = await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        assert out == [] and tg.sent == [] and hook.sent == []

    async def test_degradation_alert_fans_out(self):
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        text = await svc.degradation_alert("loss", 0.5)
        assert text and tg.sent == []
        assert hook.sent == [text]
        assert hook.sent_events == [AlertService.EVT_HASHRATE_LOSS]

    async def test_payout_confirmed_alert_fans_out(self):
        # #381: fans to every sink that carries payout_confirmed, carries the chain + short txid,
        # and formats atomic→XMR. Telegram off, webhook on → only the webhook receives it.
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        text = await svc.payout_confirmed_alert("monero", 250_000_000_000, "abcdef1234567890")
        assert text and tg.sent == []
        assert hook.sent == [text]
        assert hook.sent_events == [AlertService.EVT_PAYOUT_CONFIRMED]
        assert "0.250000" in text and "MONERO" in text and "abcdef12" in text
        # The full txid is never put in the message — only the 8-char prefix.
        assert "abcdef1234567890" not in text

    async def test_payout_confirmed_alert_noop_when_toggled_off(self):
        # Event toggled off on the only sink → no send, returns None (the caller still records it).
        hook = _FakeNotifier(allow=set())  # enabled transport, but no events allowed
        svc = _svc(notifier=hook, sinks=[hook])
        assert await svc.payout_confirmed_alert("monero", 1, "tx") is None
        assert hook.sent == []

    async def test_payout_confirmed_alert_tari_uses_microtari_divisor(self):
        # #462: the shared alert must format Tari amounts as microTari (÷1e6), not piconero (÷1e12).
        # 250_000 µT = 0.25 XTM; the label reads TARI.
        hook = _FakeNotifier()
        svc = _svc(notifier=hook, sinks=[hook])
        text = await svc.payout_confirmed_alert("tari", 250_000, "abcdef1234567890")
        assert text and "0.250000" in text and "TARI" in text and "abcdef12" in text
        assert "abcdef1234567890" not in text  # only the 8-char prefix, never the full txid

    async def test_raffle_win_alert_fans_out(self):
        # Fans to every sink carrying raffle_win, with the round type and the credited hashrate
        # formatted like the dashboard. Telegram off, webhook on → only the webhook receives it.
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        text = await svc.raffle_win_alert("donor_whale", 4.2e6)
        assert text and tg.sent == []
        assert hook.sent == [text]
        assert hook.sent_events == [AlertService.EVT_RAFFLE_WIN]
        assert "donor_whale" in text and "4.20 MH/s" in text

    async def test_raffle_win_alert_noop_when_toggled_off(self):
        hook = _FakeNotifier(allow=set())  # enabled transport, but no events allowed
        svc = _svc(notifier=hook, sinks=[hook])
        assert await svc.raffle_win_alert("donor", 1000.0) is None
        assert hook.sent == []

    async def test_default_sinks_are_just_the_notifier(self):
        # No webhook/ntfy config in the test env → the sink list is exactly [notifier], so the
        # default stack's behaviour is unchanged.
        tg = _FakeNotifier()
        svc = _svc(notifier=tg)
        assert svc.sinks == [tg]


def _fake_localtime(hour, minute, yday=100, year=2026):
    """A time.localtime stand-in with just the fields maybe_daily_summary reads."""
    return lambda _now: SimpleNamespace(tm_year=year, tm_yday=yday, tm_hour=hour, tm_min=minute)


def _daily_svc(daily_time="08:00", notifier=None):
    notifier = notifier if notifier is not None else _FakeNotifier()
    return AlertService(
        notifier=notifier,
        worker_monitor=WorkerPresenceMonitor(),
        host_label="",
        daily_time=daily_time,
    )


class TestDailySummary:
    async def test_fires_at_target_once_per_day(self, monkeypatch):
        n = _FakeNotifier()
        svc = _daily_svc(notifier=n)
        prov = lambda: "digest"  # noqa: E731
        # Before the target time → nothing.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(7, 59))
        assert await svc.maybe_daily_summary(0, prov) is None
        # At the target → fires once.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0))
        assert await svc.maybe_daily_summary(0, prov) == "digest"
        assert n.sent == ["digest"]
        # Later the same day → no repeat.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(9, 30))
        assert await svc.maybe_daily_summary(0, prov) is None
        # Next day at the target → fires again.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0, yday=101))
        assert await svc.maybe_daily_summary(0, prov) == "digest"
        assert n.sent == ["digest", "digest"]

    async def test_late_start_waits_for_next_day(self, monkeypatch):
        svc = _daily_svc()
        prov = lambda: "digest"  # noqa: E731
        # First observation is already past 08:00 → don't replay today.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(10, 0))
        assert await svc.maybe_daily_summary(0, prov) is None
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(23, 0))
        assert await svc.maybe_daily_summary(0, prov) is None
        # Next day at 08:00 → fires.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0, yday=101))
        assert await svc.maybe_daily_summary(0, prov) == "digest"

    async def test_malformed_time_disables(self, monkeypatch):
        svc = _daily_svc(daily_time="not-a-time")
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0))
        assert await svc.maybe_daily_summary(0, lambda: "x") is None

    def test_out_of_range_time_parses_to_none(self):
        # Well-formed HH:MM but out of the 24h/60m range must disable the digest, not wrap around to a
        # bogus fire time — "25:00" would otherwise never match localtime and silently never fire.
        for bad in ("25:00", "12:60", "12", "-1:00"):
            assert alert_mod._parse_hhmm(bad) is None, bad

    async def test_gated_off_by_event_toggle(self, monkeypatch):
        # daily_summary not in the allow-set → the notifier reports it disabled.
        svc = _daily_svc(notifier=_FakeNotifier(allow=set()))
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0))
        assert await svc.maybe_daily_summary(0, lambda: "x") is None

    async def test_provider_error_is_swallowed_and_marks_day_done(self, monkeypatch):
        n = _FakeNotifier()
        svc = _daily_svc(notifier=n)

        def boom():
            raise RuntimeError("bad build")

        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 0))
        assert await svc.maybe_daily_summary(0, boom) is None
        assert n.sent == []
        # Marked done for today even though the build failed → no retry storm.
        monkeypatch.setattr(alert_mod.time, "localtime", _fake_localtime(8, 5))
        assert await svc.maybe_daily_summary(0, lambda: "digest") is None


class TestHostAdvisories:
    """Persistent host-perf advisories (#104): unlike the transient edges, these fire on the FIRST
    observation of the problem (a stable bad box would never 'transition'), stay quiet while it
    persists, and — for HugePages — clear when fixed. They are not tallied as daily incidents."""

    def test_hugepages_not_reserved_fires_once_then_recovers(self):
        svc = _svc()
        # First cycle already bad → fires (not seed-silent).
        assert _keys(_ev(svc, hugepages_reserved=False)) == [AlertService.EVT_HUGEPAGES]
        # Persists → silent.
        assert _keys(_ev(svc, hugepages_reserved=False)) == []
        # Reboot applied HugePages → one recovery edge.
        assert _keys(_ev(svc, hugepages_reserved=True)) == [AlertService.EVT_HUGEPAGES]
        assert _keys(_ev(svc, hugepages_reserved=True)) == []

    def test_healthy_hugepages_never_fires(self):
        svc = _svc()
        assert _keys(_ev(svc, hugepages_reserved=True)) == []
        assert _keys(_ev(svc, hugepages_reserved=True)) == []

    def test_low_ram_fires_once_no_recovery(self):
        svc = _svc()
        assert _keys(_ev(svc, low_ram=True)) == [AlertService.EVT_LOW_RAM]
        assert _keys(_ev(svc, low_ram=True)) == []  # persists, silent
        # RAM "recovering" (unlikely at runtime) is silent — no false good-news ping.
        assert _keys(_ev(svc, low_ram=False)) == []

    def test_advisories_not_counted_as_incidents(self):
        # Static host facts shouldn't inflate the daily incident roll-up (#342).
        svc = _svc()
        _ev(svc, hugepages_reserved=False, low_ram=True)
        assert svc.drain_incidents() == {}

    def test_gated_off_by_toggle(self):
        svc = _svc(notifier=_FakeNotifier(allow={AlertService.EVT_NODE_DOWN}))
        assert _keys(_ev(svc, hugepages_reserved=False, low_ram=True)) == []


class TestDegradationAlert:
    """The #99 hashrate-loss / recovery push. The DegradationMonitor owns the debounce; this only
    formats + sends, tallies the loss as an incident, and honours the event toggle."""

    async def test_loss_sends_and_records_incident(self):
        n = _FakeNotifier()
        svc = _svc(notifier=n)
        text = await svc.degradation_alert("loss", 0.62)
        assert "62%" in text and "dropped" in text.lower()
        assert n.sent == [text]
        assert svc.drain_incidents() == {AlertService.EVT_HASHRATE_LOSS: 1}

    async def test_recovery_sends_no_incident(self):
        n = _FakeNotifier()
        svc = _svc(notifier=n)
        text = await svc.degradation_alert("recovered", 0.0)
        assert "recovered" in text.lower()
        assert n.sent == [text]
        assert svc.drain_incidents() == {}  # recovery is not an incident

    async def test_gated_off_still_records_loss(self):
        # Toggle off suppresses the message but the incident is still tallied for the daily log.
        n = _FakeNotifier(allow=set())
        svc = _svc(notifier=n)
        assert await svc.degradation_alert("loss", 0.5) is None
        assert n.sent == []
        assert svc.drain_incidents() == {AlertService.EVT_HASHRATE_LOSS: 1}


class TestTorHealAlert:
    """The #424 self-heal note. Once per outage, sent only after the heal restored the very path
    Telegram rides — so it has no per-event toggle, only the notifier's master switch."""

    async def test_sends_when_notifier_on(self):
        n = _FakeNotifier()
        svc = _svc(notifier=n)
        text = await svc.tor_heal_alert("tor restarted; egress recovered")
        assert text is not None and "tor restarted" in text
        assert n.sent == [text]

    async def test_silent_when_notifier_off(self):
        n = _FakeNotifier(enabled=False)
        svc = _svc(notifier=n)
        assert await svc.tor_heal_alert("tor restarted") is None
        assert n.sent == []
