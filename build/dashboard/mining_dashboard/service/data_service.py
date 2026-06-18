import asyncio
import logging
import os
import time
from aiohttp import ClientSession

from mining_dashboard.config.config import (
    UPDATE_INTERVAL,
    TARI_REQUIRED,
    REJECT_WORKERS_CONTAINER,
    SYNC_GATE_CONTAINERS,
    ENABLE_XVB,
    WORKER_FALLOFF_SEC,
    CHECK_FOR_UPDATES,
    GITHUB_RELEASES_API,
    UPDATE_CHECK_INTERVAL,
    XVB_TOR_PROXY,
    MONERO_CLEARNET_SYNC,
    TARI_CLEARNET_SYNC,
    CLEARNET_STATE_DIR,
)
from mining_dashboard.service.update_checker import GitHubReleaseClient, UpdateChecker
from mining_dashboard.client.xmrig_client import XMRigWorkerClient
from mining_dashboard.client.tari.tari_client import TariClient
from mining_dashboard.client.docker.docker_control import DockerControl
from mining_dashboard.service.clearnet_sync import ClearnetSyncSupervisor
from mining_dashboard.collector.pools import (
    get_p2pool_stats,
    get_network_stats,
    get_stratum_stats,
    get_tari_stats,
)
from mining_dashboard.collector.logs import get_monero_sync_status
from mining_dashboard.collector.system import (
    get_disk_usage,
    get_hugepages_status,
    get_memory_usage,
    get_load_average,
    get_cpu_usage,
)
from mining_dashboard.service.node_health import NodeHealthMonitor

logger = logging.getLogger("DataService")

# xmrig-proxy 6.x /workers rows are positional arrays; name the fields we read so the
# normalization below isn't a wall of magic indices. A row has >= _PX_MIN_FIELDS entries.
_PX_NAME = 0
_PX_IP = 1
_PX_CONNECTIONS = 2  # active connections; 0 means a stale/disconnected worker
_PX_ACCEPTED = 3  # accepted shares (cumulative)
_PX_REJECTED = 4  # rejected shares (cumulative)
_PX_INVALID = 5  # invalid shares (cumulative)
_PX_LAST_SHARE_MS = 7  # epoch ms of the last accepted share
_PX_HR_1M = 8  # 1-minute hashrate, kH/s
_PX_HR_10M = 9  # 10-minute hashrate, kH/s
_PX_HR_1H = 10  # 1-hour hashrate, kH/s   (#168)
_PX_HR_12H = 11  # 12-hour hashrate, kH/s  (#168)
_PX_HR_24H = 12  # 24-hour hashrate, kH/s  (#168)
_PX_MIN_FIELDS = 13

# xmrig-proxy reports hashrate in kH/s; the dashboard works in H/s.
_KHS_TO_HS = 1000


def _parse_proxy_list_worker(w):
    """Parse one xmrig-proxy 6.x positional row into a worker dict.

    Online/offline is derived from the active connection count, not mere presence —
    xmrig-proxy keeps a worker in /workers with a decaying hashrate after it disconnects,
    so a stopped miner would otherwise stay green and inflate the total. The proxy lacks a
    10s window, so the 1-minute rate backs both h10 and h60; the 10-minute rate is h15.
    """
    # Uptime starts at 0 here: WorkerLifecycle fills it with the real connection uptime
    # (now - connected_since) for online workers, and the direct miner API overrides it when
    # reachable. The old "seconds since last share" fallback was misleading both ways — it climbed
    # forever for a disconnected worker (read like uptime, was downtime) and read near-zero for a
    # healthy rig whose direct API was just unreachable (#169).
    return {
        "name": w[_PX_NAME],
        "ip": w[_PX_IP],
        "status": "online" if w[_PX_CONNECTIONS] > 0 else "offline",
        "h10": w[_PX_HR_1M] * _KHS_TO_HS,
        "h60": w[_PX_HR_1M] * _KHS_TO_HS,
        "h15": w[_PX_HR_10M] * _KHS_TO_HS,
        # All five native proxy windows for the chart's averaging-window toggle (#168). 1m/10m back
        # the existing h10/h60/h15 keys above; 1h/12h/24h are new and read straight from the row.
        "h1h": w[_PX_HR_1H] * _KHS_TO_HS,
        "h12h": w[_PX_HR_12H] * _KHS_TO_HS,
        "h24h": w[_PX_HR_24H] * _KHS_TO_HS,
        "uptime": 0,
        # Per-worker share health (Issue #82) — collected here, surfaced in the Workers table.
        "accepted": w[_PX_ACCEPTED] or 0,
        "rejected": w[_PX_REJECTED] or 0,
        "invalid": w[_PX_INVALID] or 0,
    }


def _parse_legacy_dict_worker(w):
    """Parse one legacy dict-format xmrig-proxy worker into a worker dict."""
    hr = w.get("hashrate", [0, 0, 0])
    return {
        "name": w.get("id", "Unknown"),
        "ip": w.get("ip", "0.0.0.0"),
        "status": "online",
        "h10": hr[0] if len(hr) > 0 else 0,
        "h60": hr[1] if len(hr) > 1 else 0,
        "h15": hr[2] if len(hr) > 2 else 0,
        # The legacy dict shape carries only 10s/60s/15m, so the longer windows fall back to its
        # longest available average (#168) rather than reading zero; this format is a rare fallback.
        "h1h": hr[2] if len(hr) > 2 else (hr[-1] if hr else 0),
        "h12h": hr[2] if len(hr) > 2 else (hr[-1] if hr else 0),
        "h24h": hr[2] if len(hr) > 2 else (hr[-1] if hr else 0),
        "uptime": w.get("uptime", 0),
        # Share health (Issue #82); the legacy shape rarely carries these, so default to 0.
        "accepted": w.get("accepted", 0),
        "rejected": w.get("rejected", 0),
        "invalid": w.get("invalid", 0),
    }


def _normalize_proxy_workers(proxy_data):
    """Normalize an xmrig-proxy ``/workers`` payload into a uniform worker list.

    Dispatches each entry to the right parser for the two shapes the proxy emits — the 6.x
    positional-list format and the legacy dict format — and drops anything that matches
    neither (e.g. a truncated row). Returns ``[]`` for a missing/empty payload.
    """
    if not proxy_data or "workers" not in proxy_data:
        return []

    workers = []
    for w in proxy_data["workers"]:
        if isinstance(w, list) and len(w) >= _PX_MIN_FIELDS:
            workers.append(_parse_proxy_list_worker(w))
        elif isinstance(w, dict):
            workers.append(_parse_legacy_dict_worker(w))
    return workers


def _parse_proxy_summary(summary_data):
    """Extract the pool-wide share-health totals from an xmrig-proxy ``/summary`` payload (#82).

    The ``results`` block carries the proxy's cumulative accepted/rejected/invalid/expired share
    counts to the upstream pool, plus ``best`` (a list of best difficulties found, highest first).
    Returns a flat dict of just the fields the dashboard surfaces, and ``{}`` for a missing or
    malformed payload. ``{}`` is the "no usable data" signal — callers must route through
    ``_merge_proxy_summary`` to keep the last-good totals rather than blanking the panel (#141).
    """
    if not isinstance(summary_data, dict):
        return {}
    results = summary_data.get("results", {}) or {}
    best = results.get("best", []) or []
    return {
        "accepted": results.get("accepted", 0) or 0,
        "rejected": results.get("rejected", 0) or 0,
        "invalid": results.get("invalid", 0) or 0,
        "expired": results.get("expired", 0) or 0,
        "best": best[0] if best else 0,
    }


def _merge_proxy_summary(last_good, summary_data):
    """Parse a proxy ``/summary`` payload but KEEP the last-good totals on a malformed one (#141).

    The share-health panel is designed so a bad poll leaves the last good value in place — but that
    only holds if we refuse to overwrite with an empty parse. ``_parse_proxy_summary`` returns ``{}``
    for any non-dict / garbage body (which doesn't *raise*, so the caller's ``try/except`` can't
    catch it); adopting that ``{}`` is exactly what blanked the accepted/rejected/invalid/best panel.
    A *valid* summary that genuinely reports zeros is a non-empty (truthy) dict and is adopted
    normally — only an unusable ``{}`` parse falls back to ``last_good``.
    """
    parsed = _parse_proxy_summary(summary_data)
    return parsed if parsed else last_good


def _merge_direct_stats(workers, results, active_pool_port):
    """Augment proxy-derived workers with direct-API stats (uptime + hashrate).

    ``results`` is the per-worker output of the direct worker API, positionally aligned
    with ``workers``. xmrig-proxy ``/1/summary`` reports kH/s while an xmrig miner reports
    H/s; the ``kind`` field distinguishes them so we scale to H/s. If the direct API is
    unreachable (falsy ``extra_stats``) the worker keeps its proxy-derived hashrate/uptime
    and stays online — the proxy already confirmed it's connected and submitting shares —
    rather than dropping out of the hashrate total and reading zero (Fixes #28). Each
    worker is tagged with ``active_pool`` for the UI badge.
    """
    final_workers = []
    for w, extra_stats in zip(workers, results):
        if extra_stats:
            w["uptime"] = extra_stats.get("uptime", w["uptime"])

            is_proxy = extra_stats.get("kind") == "proxy"
            hr_scale = _KHS_TO_HS if is_proxy else 1

            hr_total = extra_stats.get("hashrate", {}).get("total", [])
            if isinstance(hr_total, list) and len(hr_total) >= 3:
                w["h10"] = (hr_total[0] or 0) * hr_scale
                w["h60"] = (hr_total[1] or 0) * hr_scale
                w["h15"] = (hr_total[2] or 0) * hr_scale

        w["active_pool"] = active_pool_port
        final_workers.append(w)
    return final_workers


def _aggregate_hashrate(workers):
    """Total live hashrate across online workers, as ``(total_h15, total_h10)``.

    The headline figure prefers the 15m average, falling back to 60s then 10s when a
    longer window hasn't accumulated yet (Priority: 15m > 60s > 10s). Offline workers
    contribute nothing.
    """
    total_hr = 0
    total_h10 = 0
    for w in workers:
        if w.get("status") == "online":
            w_hr = w.get("h15", 0)
            if w_hr == 0:
                w_hr = w.get("h60", 0)
            if w_hr == 0:
                w_hr = w.get("h10", 0)
            total_hr += w_hr
            total_h10 += w.get("h10", 0)
    return total_hr, total_h10


# Averaging window -> the per-worker key that holds that window's rate. 10m is the headline series
# (total_hr above), so it isn't recomputed here; the other four feed the chart's window toggle (#168).
_WINDOW_WORKER_KEYS = {"1m": "h10", "1h": "h1h", "12h": "h12h", "24h": "h24h"}


def _aggregate_window_hashrates(workers):
    """Total live hashrate per averaging window across online workers (#168), keyed by window.

    Unlike the headline ``_aggregate_hashrate``, this does NOT fall back between windows — each
    window is its own honest sum, so a window that hasn't accumulated yet (notably 12h/24h on a
    freshly started rig) reads low until it fills. Offline workers contribute nothing.
    """
    totals = {win: 0 for win in _WINDOW_WORKER_KEYS}
    for w in workers:
        if w.get("status") == "online":
            for win, src in _WINDOW_WORKER_KEYS.items():
                totals[win] += w.get(src, 0) or 0
    return totals


def _shares_to_record(last_known_total, current_total):
    """How many P2Pool shares to record this poll, plus the new baseline, from the previous and
    current cumulative ``shares_found`` counters. P2Pool's stratum reports a CUMULATIVE counter and
    the dashboard polls every UPDATE_INTERVAL, so a burst between polls would otherwise be collapsed
    to one. Re-baselines WITHOUT backfilling on the first poll (``last_known`` is None) or a p2pool
    restart (the counter went backwards). Returns ``(count, new_baseline)`` (#129)."""
    if last_known_total is None or current_total < last_known_total:
        return 0, current_total
    if current_total > last_known_total:
        return current_total - last_known_total, current_total
    return 0, last_known_total


class WorkerLifecycle:
    """Dashboard-side per-worker connection tracking for the "Workers Alive" table (#169 / #182).

    The xmrig-proxy ``/workers`` row has no connect-time field, and the proxy keeps a disconnected
    worker around with a decaying hashrate — so the proxy alone can neither report true uptime nor
    make a dead row leave. This keeps, per worker name:

    - ``connected_since`` — when it last transitioned to online; reset on disconnect. An online
      worker with no real (direct-API) uptime gets ``now - connected_since``, a true,
      monotonically-increasing uptime instead of the misleading seconds-since-last-share (#169).
      A reconnect restarts it. Workers whose direct API IS reachable keep their real miner uptime
      (any positive value is left untouched).
    - ``last_active`` — the last time it was seen online. An offline worker falls off the table once
      it's been inactive longer than ``falloff_sec`` (#182); a reconnect re-adds it. Operates purely
      on the live proxy-sourced worker list.

    Pure given (workers, now) plus its accumulated state, so it unit-tests without the data loop.
    Mutates each surviving online worker's ``uptime`` in place and returns the filtered list.
    """

    def __init__(self, falloff_sec):
        self.falloff_sec = falloff_sec
        self._state = {}  # name -> {"connected_since": float | None, "last_active": float}

    def update(self, workers, now):
        live = []
        seen = set()
        for w in workers:
            name = w.get("name")
            seen.add(name)
            st = self._state.setdefault(name, {"connected_since": None, "last_active": 0.0})
            if w.get("status") == "online":
                if st["connected_since"] is None:  # new connection or a reconnect
                    st["connected_since"] = now
                st["last_active"] = now
                if not w.get("uptime"):  # no real (direct-API) uptime → track it
                    w["uptime"] = int(now - st["connected_since"])
                live.append(w)
            else:
                st["connected_since"] = None  # disconnected — uptime restarts on reconnect
                if st["last_active"] == 0.0:
                    st["last_active"] = now  # first seen already offline
                if now - st["last_active"] <= self.falloff_sec:
                    live.append(w)  # recently-offline rows stay (shown as DOWN)
                # else: fall off — drop the ghost row
        # Forget ONLY workers the proxy no longer reports at all. A worker that has aged out of the
        # live table but is STILL reported (offline) must be KEPT in state so its `last_active`
        # (when it actually went offline) is preserved. Dropping it here was a falloff regression
        # (#182): xmrig-proxy keeps a disconnected worker in /workers for hours, so the next poll
        # re-created it with last_active=now, resetting the 1h clock — the ghost reappeared as DOWN
        # forever, flickering off for a single cycle each hour instead of truly falling off. Keeping
        # it does NOT block a fresh reconnect: going online resets connected_since/last_active anyway.
        self._state = {n: s for n, s in self._state.items() if n in seen}
        return live


class DataService:
    """
    Core service responsible for aggregating mining statistics from various sources
    (Local collectors, XMRig Proxy, Tari Node, etc.) and maintaining the application state.
    """

    def __init__(self, state_manager, proxy_client, xvb_client):
        self.state_manager = state_manager
        self.proxy_client = proxy_client
        self.xvb_client = xvb_client
        # Per-worker connection tracking for true uptime (#169) + stale-row fall-off (#182).
        self._lifecycle = WorkerLifecycle(WORKER_FALLOFF_SEC)
        # New-release check (#224): off unless dashboard.check_for_updates is set. Routed over the
        # bridge Tor SOCKS (reusing XVB_TOR_PROXY) so it can't reveal the host IP to GitHub.
        self.update_checker = UpdateChecker(
            GitHubReleaseClient(GITHUB_RELEASES_API, XVB_TOR_PROXY),
            (os.environ.get("PITHEAD_VERSION") or "").strip(),
            enabled=CHECK_FOR_UPDATES,
            interval=UPDATE_CHECK_INTERVAL,
        )

        self.latest_data = {
            "workers": [],
            "proxy_summary": {},
            "total_live_h15": 0,
            "total_live_h10": 0,
            "pool": {"p2p": {}, "pool": {}},
            "network": {},
            "system": {},
            "tari": {},
            "stratum": {},
            "monero_sync": {},
            "tari_sync": {},
            "global_sync": False,
            "tari_syncing_passive": False,
            "workers_rejected": False,
            "miner_released": False,
            "miner_held": False,
            "timestamp": 0,
        }

        # Node-down detection + optional worker rejection (Issue #31).
        self.docker_control = DockerControl()
        self.monero_health = NodeHealthMonitor()
        self.tari_health = NodeHealthMonitor()
        # Auto-transition a clearnet initial-sync node back to Tor once it's synced (#234). Reuses
        # the same docker control proxy as the #31 failover (start/stop only). on_transition surfaces
        # the event into the snapshot so the UI/status can reflect "switched back to Tor".
        self.clearnet_supervisor = ClearnetSyncSupervisor(
            CLEARNET_STATE_DIR,
            self.docker_control,
            on_transition=self._on_clearnet_transition,
        )
        # Per-chain "currently exposed on clearnet" flags, surfaced in the snapshot for the UI/banner.
        self.clearnet_sync_state = {"monero": False, "tari": False, "active": False}
        # True while we've stopped the proxy to reject workers. Persisted in the snapshot so
        # a dashboard restart mid-outage still readmits workers once the node recovers.
        self.workers_rejected = False

        # Hold the miner (p2pool + xmrig-proxy) until the required chain(s) finish syncing
        # (Issue #35). One-way latch: `miner_released` flips True the first time the gate is
        # satisfied, and we never re-hold after that (a later node blip is #31's job, which
        # stops only xmrig-proxy so p2pool keeps its sidechain position). Persisted so a
        # restart mid-sync keeps holding, and a restart after release doesn't re-stop a
        # running, mining stack. `miner_held` is transient UI/log state, not persisted.
        self.miner_released = False
        self.miner_held = False

        # Restore persistent state from DB to prevent empty dashboard on service restart
        loaded_snapshot = self.state_manager.load_snapshot()
        if loaded_snapshot and isinstance(loaded_snapshot, dict):
            self.latest_data.update(loaded_snapshot)
            self.workers_rejected = bool(self.latest_data.get("workers_rejected", False))
            self.miner_released = bool(self.latest_data.get("miner_released", False))

    async def _apply_worker_rejection(self, monero_down, tari_down):
        """
        Reject workers (stop the proxy) when a node we care about is DOWN so miners fail over
        to their backup pools; readmit them (start the proxy) once those nodes are confirmed
        healthy.

        monerod is required to mine, so a monerod outage always rejects. Tari is only merge-
        mining gravy: a Tari outage rejects only when `TARI_REQUIRED` (dashboard.tari_required),
        so a non-blocking Tari can go down without kicking miners off Monero. Only acts on
        transitions (tracked by `workers_rejected`), and Docker treats a repeat stop/start as
        already-done (HTTP 304), so it's safe every cycle.
        """
        should_reject = monero_down or (tari_down and TARI_REQUIRED)

        if should_reject and not self.workers_rejected:
            logger.warning(
                f"Required node unreachable — stopping {REJECT_WORKERS_CONTAINER} so workers "
                f"fail over to their backup pools."
            )
            if await self.docker_control.stop(REJECT_WORKERS_CONTAINER):
                self.workers_rejected = True
            return

        # Readmit only once every node we reject on is confirmed healthy (not merely 'not
        # down'), so a dashboard restart mid-outage doesn't bring workers back to a still-down
        # stack. Tari's health is ignored when it's non-blocking.
        recovered = self.monero_health.healthy and ((not TARI_REQUIRED) or self.tari_health.healthy)
        if self.workers_rejected and recovered:
            logger.info(
                f"Required nodes recovered — starting {REJECT_WORKERS_CONTAINER} to readmit workers."
            )
            if await self.docker_control.start(REJECT_WORKERS_CONTAINER):
                self.workers_rejected = False

    async def _apply_sync_gate(self, gate_satisfied):
        """
        Hold p2pool + xmrig-proxy stopped until the required chain(s) have fully synced once,
        then start them (Issue #35). Keeps p2pool from flooding Tari's logs with merge-mining
        junk during the long initial sync, when it can't usefully mine anyway.

        `gate_satisfied` is True once monerod is synced AND Tari is synced-or-non-blocking — so
        a non-blocking Tari (dashboard.tari_required:false) releases the miner as soon as
        monerod is ready and lets Tari finish in the background.

        One-way latch: once released we never re-hold, so this can't fight #31 (a transient
        node-down later stops only xmrig-proxy and keeps p2pool on the sidechain — that's #31's
        job, gated behind `miner_released` by the caller). While holding we re-assert the stop
        every cycle (quietly), so a `docker compose up` mid-sync — which would restart the held
        containers — is undone within a cycle.

        `gate_satisfied` must be derived from the *raw* per-node sync signals (RPC/gRPC), not
        the network-height UI override: that override is fed by p2pool's own stats file, so
        while p2pool is held it would read 0 and falsely report Monero as syncing forever.
        """
        if self.miner_released:
            return

        if gate_satisfied:
            ok = True
            for container in SYNC_GATE_CONTAINERS:
                ok = (await self.docker_control.start(container)) and ok
            if ok:
                self.miner_released = True
                self.miner_held = False
                logger.info(
                    f"Required chain(s) synced — starting {', '.join(SYNC_GATE_CONTAINERS)}; mining can begin."
                )
            # On a partial-start failure leave the latch closed so the next cycle retries.
            return

        # Still syncing: keep the miner held. Log the human-facing notice only on the first
        # cycle of a hold; the per-cycle re-assert stops are quiet to avoid flooding the log.
        for container in SYNC_GATE_CONTAINERS:
            await self.docker_control.stop(container, quiet=self.miner_held)
        if not self.miner_held:
            self.miner_held = True
            logger.info(
                f"Required chain(s) still syncing — holding {', '.join(SYNC_GATE_CONTAINERS)} "
                f"until synced."
            )

    def _on_clearnet_transition(self, name, ok):
        """Called by the supervisor after a clearnet→Tor flip attempt (#234)."""
        if ok:
            logger.info("%s returned to Tor after its clearnet initial sync (#234).", name)
        else:
            logger.warning(
                "%s clearnet→Tor switch did not complete this cycle — will retry (#234).", name
            )

    async def run(self):
        """
        Main execution loop: Aggregates statistics from local collectors and external APIs.
        Updates the `latest_data` state and persists historical metrics to the database.
        """
        logger.info("Service Started: Data Collection Loop")

        iteration_count = 0

        async with ClientSession() as session:
            worker_client = XMRigWorkerClient(session)
            tari_client = TariClient(session)

            # P2Pool shares are recorded from the cumulative shares_found counter (#129); None until
            # the first poll baselines it, so we never backfill the whole historical count on startup
            # or re-record what the DB already loaded.
            last_known_shares_total = None

            while True:
                try:
                    # 1. Collect Local Statistics (High Frequency Polling)
                    stratum_raw, _ = get_stratum_stats()

                    # 2. Fetch Worker Statistics from XMRig Proxy + normalize the payload.
                    proxy_workers = []
                    try:
                        proxy_data = await asyncio.to_thread(self.proxy_client.get_workers)
                        proxy_workers = _normalize_proxy_workers(proxy_data)
                    except Exception as e:
                        logger.error(f"Proxy Data Fetch Error: {e}")

                    # 2b. Fetch the proxy /summary for pool-wide share totals (Issue #82). Kept
                    # separate from the workers fetch so one failing doesn't blank the other; a bad
                    # poll leaves the last good summary in latest_data — including a malformed body
                    # that returns (not raises), which _merge_proxy_summary guards against (#141).
                    proxy_summary = self.latest_data.get("proxy_summary", {})
                    try:
                        summary_data = await asyncio.to_thread(self.proxy_client.get_summary)
                        proxy_summary = _merge_proxy_summary(proxy_summary, summary_data)
                    except Exception as e:
                        logger.error(f"Proxy Summary Fetch Error: {e}")

                    # 3. Augment with Direct Worker Stats (Uptime, Hashrate) via Local API
                    tasks = [worker_client.get_stats(w["ip"], w["name"]) for w in proxy_workers]
                    worker_results = await asyncio.gather(*tasks)

                    current_mode = self.state_manager.get_xvb_stats().get("current_mode", "P2POOL")
                    # Determine active pool port for UI badges based on current Algo mode
                    active_pool_port = "3344" if "XVB" in current_mode else "3333"
                    final_workers = _merge_direct_stats(
                        proxy_workers, worker_results, active_pool_port
                    )
                    # 3b. Track per-worker connection lifecycle: fill true uptime for online workers
                    # (#169) and drop stale offline rows past the fall-off window (#182).
                    final_workers = self._lifecycle.update(final_workers, time.time())

                    # 4. Calculate Aggregates (Priority: 15m > 60s > 10s)
                    total_hr, total_h10 = _aggregate_hashrate(final_workers)

                    # 5. Fetch Network & Sync Status
                    network_stats = get_network_stats()
                    tari_stats = get_tari_stats()
                    p2pool_stats = get_p2pool_stats()

                    # Record P2Pool shares from the CUMULATIVE shares_found counter, not just
                    # last_share_time: at 30s polls a burst of shares advances the timestamp only
                    # once, dropping the extras. Record the delta as N distinct shares (#129).
                    current_share_ts = p2pool_stats["pool"].get("last_share_time", 0)
                    current_shares_total = p2pool_stats["pool"].get("shares_found", 0)
                    new_shares, last_known_shares_total = _shares_to_record(
                        last_known_shares_total, current_shares_total
                    )
                    if new_shares > 0 and current_share_ts > 0:
                        difficulty = p2pool_stats["pool"].get("difficulty", 0)
                        await asyncio.to_thread(
                            self.state_manager.add_shares, new_shares, current_share_ts, difficulty
                        )

                    monero_sync = await get_monero_sync_status()
                    tari_sync = await tari_client.get_sync_status()

                    # Raw per-node "fully synced" signals for the sync gate (Issue #35),
                    # captured BEFORE the network-height UI override below. A node counts as
                    # synced only when it's reachable AND not syncing — an unreachable node
                    # reports is_syncing=False too, and we must not mistake that for synced
                    # (that's what #31's node-down handling is for). Reading the raw signal
                    # also avoids a deadlock: the height override is fed by p2pool's stats
                    # file, which reads 0 while p2pool is held — falsely "syncing" forever.
                    monero_synced = monero_sync.get("reachable", True) and not monero_sync.get(
                        "is_syncing", False
                    )
                    tari_synced = tari_sync.get("reachable", True) and not tari_sync.get(
                        "is_syncing", False
                    )

                    # Auto-transition a clearnet initial-sync node back to Tor once it's synced
                    # (#234). Reuses the synced signals above; the supervisor writes a persistent
                    # marker + restarts the daemon (which then comes up Tor-only). Returns whether
                    # each chain is still EXPOSED on clearnet, for the UI banner.
                    monero_clearnet_exposed = await self.clearnet_supervisor.maybe_transition(
                        "monero", "monerod", MONERO_CLEARNET_SYNC, monero_synced
                    )
                    tari_clearnet_exposed = await self.clearnet_supervisor.maybe_transition(
                        "tari", "tari", TARI_CLEARNET_SYNC, tari_synced
                    )
                    self.clearnet_sync_state = {
                        "monero": monero_clearnet_exposed,
                        "tari": tari_clearnet_exposed,
                        "active": monero_clearnet_exposed or tari_clearnet_exposed,
                    }

                    # Determine effective Tari status for UI display
                    tari_active = tari_stats.get("active", False)
                    tari_status_str = (
                        tari_stats.get("status", "Waiting...") if tari_active else "Waiting..."
                    )

                    # Apply Sync Logic Overrides
                    # 1. Monero Sync Check
                    if network_stats.get("height", 0) == 0:
                        monero_sync["is_syncing"] = True
                        if "percent" not in monero_sync:
                            monero_sync.update({"percent": 0, "current": 0, "target": 1})

                    # 2. Global Sync Logic. monerod always drives the full-screen Sync Mode;
                    # Tari does so only when it's required (Issue #51). A non-blocking Tari
                    # (dashboard.tari_required:false) keeps the operational view and surfaces
                    # its progress in the Tari panel instead of hijacking the whole dashboard.
                    is_monero_syncing = monero_sync.get("is_syncing", False)
                    is_tari_syncing = tari_sync.get("is_syncing", False)
                    global_sync = is_monero_syncing or (is_tari_syncing and TARI_REQUIRED)
                    # True when Tari is syncing but we're staying in the operational view — the
                    # UI shows a "Tari syncing" indicator rather than the takeover screen.
                    tari_syncing_passive = is_tari_syncing and not global_sync

                    if global_sync:
                        if not is_monero_syncing and "percent" not in monero_sync:
                            h = network_stats.get("height", 1)
                            monero_sync.update({"percent": 100, "current": h, "target": h})
                        if not is_tari_syncing and "percent" not in tari_sync:
                            h = tari_stats.get("height", 0)
                            tari_sync.update({"percent": 100, "current": h, "target": h})

                    # 3. Node-down detection + worker rejection (Issue #31). Debounce each
                    # node's live reachability into a stable DOWN flag; monerod-down always
                    # rejects, Tari-down rejects only when required (handled in the helper).
                    monero_down = self.monero_health.update(monero_sync.get("reachable", True))
                    tari_down = self.tari_health.update(tari_sync.get("reachable", True))
                    monero_sync["down"] = monero_down
                    tari_sync["down"] = tari_down

                    # 4. Sync gate (Issue #35): hold p2pool + xmrig-proxy until the required
                    # chain(s) first sync, then release. monerod must be synced; Tari must be
                    # synced too unless it's non-blocking. #31's runtime failover only applies
                    # once released — before that there are no workers to fail over, and it
                    # keeps the two features from both driving xmrig-proxy.
                    await self._apply_sync_gate(
                        monero_synced and (tari_synced or not TARI_REQUIRED)
                    )
                    if self.miner_released:
                        await self._apply_worker_rejection(monero_down, tari_down)

                    # Fetch fresh shares list to populate UI
                    shares_list = await asyncio.to_thread(self.state_manager.get_shares)

                    self.latest_data.update(
                        {
                            "workers": final_workers,
                            "proxy_summary": proxy_summary,
                            "shares": shares_list,
                            "total_live_h15": total_hr,
                            "total_live_h10": total_h10,
                            "pool": p2pool_stats,
                            "network": network_stats,
                            "tari": tari_stats,
                            "monero_sync": monero_sync,
                            "tari_sync": tari_sync,
                            "global_sync": global_sync,
                            "tari_syncing_passive": tari_syncing_passive,
                            "workers_rejected": self.workers_rejected,
                            "miner_released": self.miner_released,
                            "miner_held": self.miner_held,
                            "clearnet_sync": self.clearnet_sync_state,
                            "system": {
                                "disk": get_disk_usage(),
                                "hugepages": get_hugepages_status(),
                                "memory": get_memory_usage(),
                                "load": get_load_average(),
                                "cpu_percent": get_cpu_usage(),
                            },
                            "stratum": stratum_raw,
                            "timestamp": time.time(),
                        }
                    )

                    # 6. Persist Historical Data
                    is_xvb = "XVB" in current_mode
                    p2pool_hr = 0 if is_xvb else total_hr
                    xvb_hr = total_hr if is_xvb else 0

                    # Per-window splits for the chart's averaging-window toggle (#168). At any poll the
                    # algo routes the whole total to one pool, so each window's total goes entirely to
                    # the same band as the headline (10m is persisted as the base total_hr above).
                    window_totals = _aggregate_window_hashrates(final_workers)
                    window_splits = {
                        win: ((0, total) if is_xvb else (total, 0))
                        for win, total in window_totals.items()
                    }

                    await asyncio.to_thread(
                        self.state_manager.update_history,
                        total_hr,
                        p2pool_hr,
                        xvb_hr,
                        window_splits,
                    )

                    # Create a lightweight snapshot (exclude shares entirely as they are safely in DB)
                    snapshot_data = self.latest_data.copy()
                    snapshot_data.pop("shares", None)
                    await asyncio.to_thread(self.state_manager.save_snapshot, snapshot_data)

                    # 7. External XvB stats sync over Tor (#163), throttled to every 10th iteration,
                    # and ONLY when XvB is enabled — disabling XvB must stop the egress entirely.
                    if ENABLE_XVB and iteration_count % 10 == 0:
                        real_xvb_stats = await asyncio.to_thread(self.xvb_client.get_stats)
                        if real_xvb_stats:
                            await asyncio.to_thread(
                                self.state_manager.update_xvb_stats, **real_xvb_stats
                            )
                            logger.info(
                                f"External Sync: XvB Stats Updated (1h={real_xvb_stats['avg_1h']:.0f} H/s)"
                            )

                    # 8. New-release check over Tor (#224) — ONLY when explicitly enabled (default off,
                    # so the appliance never phones GitHub unbidden). The checker self-throttles to
                    # hourly and returns the cached result; surfaced as state.update for the header badge.
                    if self.update_checker.enabled:
                        self.latest_data["update"] = await asyncio.to_thread(
                            self.update_checker.maybe_check, time.time()
                        )

                    iteration_count += 1
                except Exception as e:
                    logger.error(f"Data Collection Error: {e}")
                await asyncio.sleep(UPDATE_INTERVAL)
