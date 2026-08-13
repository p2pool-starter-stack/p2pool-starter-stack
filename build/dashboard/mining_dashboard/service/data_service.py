import asyncio
import json
import logging
import os
import time
import uuid
from datetime import UTC, datetime

from aiohttp import ClientSession

from mining_dashboard.client.docker.docker_control import DockerControl
from mining_dashboard.client.monero.monero_wallet_client import MoneroWalletClient
from mining_dashboard.client.tari.tari_client import TariClient
from mining_dashboard.client.tari.tari_wallet_client import TariWalletClient
from mining_dashboard.client.xmrig_client import (
    XMRigWorkerClient,
    parse_rigforge,
    parse_worker_control_status,
)
from mining_dashboard.client.xvb_client import (
    REG_INVALID,
    REG_NOT_ELIGIBLE,
    REG_OK,
)
from mining_dashboard.collector.containers import get_container_health
from mining_dashboard.collector.logs import get_monero_sync_status
from mining_dashboard.collector.pools import (
    get_network_stats,
    get_p2pool_stats,
    get_stratum_stats,
    get_tari_stats,
)
from mining_dashboard.collector.system import (
    get_cpu_avx2,
    get_cpu_usage,
    get_disk_usage,
    get_hugepages_status,
    get_load_average,
    get_memory_usage,
)
from mining_dashboard.config import config
from mining_dashboard.config.config import (
    CHECK_FOR_UPDATES,
    CLEARNET_STATE_DIR,
    DASHBOARD_ENERGY,
    DASHBOARD_FAIL_CLOSED,
    ENABLE_XVB,
    GITHUB_RELEASES_API,
    GITHUB_RIGFORGE_RELEASES_API,
    HASHRATE_DROP_MINUTES,
    HASHRATE_DROP_THRESHOLD_PCT,
    HOST_IP,
    LOW_RAM_GB,
    MONERO_CLEARNET_SYNC,
    MONERO_WALLET_ADDRESS,
    PAYOUT_CONFIRM_ENABLED,
    REJECT_WORKERS_CONTAINER,
    SYNC_GATE_CONTAINERS,
    TARI_CLEARNET_SYNC,
    TARI_PAYOUT_CONFIRM_ENABLED,
    TARI_REQUIRED,
    TOR_SOCKS_PROXY,
    UPDATE_CHECK_INTERVAL,
    UPDATE_INTERVAL,
    WORKER_FALLOFF_SEC,
    XVB_REGISTER_INTERVAL_S,
)
from mining_dashboard.helper.utils import (
    DEFAULT_PPLNS_WINDOW,
    effective_hashrate,
    format_hashrate,
    get_tier_info,
    pplns_block_time,
    shares_in_pplns_window,
)
from mining_dashboard.service import audit_service
from mining_dashboard.service.alert_service import AlertService
from mining_dashboard.service.clearnet_sync import ClearnetSyncSupervisor
from mining_dashboard.service.control_service import (
    SECRET_PATHS,
    SECRET_SENTINEL,
    _get,
    _set,
    env_key_config_paths,
)
from mining_dashboard.service.degradation import DegradationMonitor
from mining_dashboard.service.healthchecks import HealthchecksClient
from mining_dashboard.service.metrics import build_metrics, share_reject_pct
from mining_dashboard.service.node_health import NodeHealthMonitor
from mining_dashboard.service.price_feed import CoinGeckoClient, PriceFeed
from mining_dashboard.service.telegram_commands import format_daily_summary
from mining_dashboard.service.tor_heal import TorEgressHealer
from mining_dashboard.service.update_checker import GitHubReleaseClient, UpdateChecker

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

# Consecutive XvB-registration failures (while never yet registered) before we raise the dashboard
# "registration failing" warning (#263). A couple of transient blips during the normal first-share
# window shouldn't alarm; a configured-but-refusing endpoint should. At one attempt per 10th poll
# (~5 min) this is ~15 min of sustained failure.
_XVB_REGISTER_FAIL_ALERT = 3

# v1.7 telemetry backbone (#196 Wave-0) capture cadences. All wall-clock gated (`time.time() -
# last >= N`), NOT `iteration_count % k` — the latter silently changes cadence if UPDATE_INTERVAL
# is ever reconfigured.
_XVB_HISTORY_CAPTURE_SEC = 300  # ~5 min
_HOURLY_CAPTURE_SEC = 3600  # disk_growth + network_history
_WORKER_HISTORY_CAPTURE_SEC = 300  # ~5 min

# XvB's public winners file updates once per hourly round and covers ~4 days, so a 30-min re-read
# can never miss a win outright. But the in-round hold (#769) reacts only when the mirror runs, so
# a win landing at the wrong phase went undetected — and unprotected — for up to 30 min (#892).
# The gate is therefore adaptive (_xvb_winners_gate_sec): 30-min baseline, dropping to the fast
# cadence in exactly the windows where detection latency costs money. Wall-clock gated like the
# capture cadences above.
_XVB_WINNERS_SYNC_SEC = 1800
_XVB_WINNERS_SYNC_FAST_SEC = 150
# The fast windows: the credited 1h average within 25% above the current tier threshold (the band
# the controller deliberately rides, #769's threshold + cushion — where a won round is one
# steering step from sagging out), or a recorded win younger than 90 min (rounds run ~an hour, so
# one may still be live).
_XVB_WINNERS_MARGIN = 0.25
_XVB_WIN_FRESH_S = 5400

# Per-worker flood cap on NEW rig-edit audit rows (#724). The enriched worker feed is
# unauthenticated LAN input, so a rogue device presenting as a worker can report a fresh random
# change_id every poll — each a distinct, permanent audit_events row (#530's deterministic id only
# collapses REPEATS of one change_id, never distinct ones). At most _RIG_EDIT_CAP_PER_HOUR genuine
# rig-edit rows per worker per rolling hour; beyond that, rows are dropped and a single
# rate-limited marker is recorded + logged. A real fleet edits a rig a handful of times an hour at
# most, so a legitimate cadence never trips it — only a flood does.
_RIG_EDIT_CAP_PER_HOUR = 12
_RIG_EDIT_WINDOW_SEC = 3600


def _xvb_winners_gate_sec(avg_1h, avg_24h, tiers, last_win_ts, now):
    """Seconds the winners mirror must wait between fetches — the adaptive gate (#892).

    Fast (150 s) in the sensitive window: the wallet credited at a tier (the LOWER of the 1h/24h
    averages, the raffle's qualifying rule, #157) with the 1h average within 25% above that
    tier's threshold — the band the controller holds it in, where a win the dashboard hasn't
    seen yet is one downward step from termination — or a recorded win younger than 90 min (a
    won round may still be live). 30-min baseline everywhere else. The caller only runs while
    XvB is enabled, so a disabled stack never fetches at all.

    Extra Tor load, honestly: the fast gate admits at most 24 fetches/h vs 2/h at baseline, and
    the every-10th-poll outer throttle caps it at ~12/h at the default 30 s UPDATE_INTERVAL —
    only while the sensitive window holds. Win-detection latency in that window falls from up
    to 30 min to the first eligible poll past the gate: ~5 min at the default interval, 2.5 min
    at the gate's own floor. This is the detection half of #892; the other half — steering off
    the credited average's projected trajectory instead of its current reading — remains open.
    """
    _, threshold = get_tier_info(min(avg_1h, avg_24h), tiers)
    if threshold > 0 and avg_1h <= threshold * (1 + _XVB_WINNERS_MARGIN):
        return _XVB_WINNERS_SYNC_FAST_SEC
    if last_win_ts > 0 and now - last_win_ts < _XVB_WIN_FRESH_S:
        return _XVB_WINNERS_SYNC_FAST_SEC
    return _XVB_WINNERS_SYNC_SEC


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
    worker is tagged with ``active_pool`` for the UI badge, and with ``api_ok`` (True/False) when
    the worker API was probed so the UI can flag a worker whose direct API is misconfigured /
    unreachable — distinct from a worker that's simply offline.
    """
    final_workers = []
    for w, extra_stats in zip(workers, results, strict=False):
        # api_ok: True (probe succeeded), False (probe failed — surfaced, not swallowed), or unset
        # (worker we deliberately didn't probe, e.g. an internal/invalid IP per the SSRF guard).
        api_ok = extra_stats.get("api_ok") if extra_stats else None
        if api_ok is not None:
            w["api_ok"] = api_ok

        # RigForge enriched feed (#235): a superset /1/summary carries an extra `rigforge` block.
        # Present only for RigForge rigs whose descriptor port points at the enriched feed; a
        # plain-xmrig rig parses to None and gets no chips. A miner-down enriched body has no XMRig
        # keys, so this rides in even when api_ok can't confirm live hashrate.
        rf = parse_rigforge(extra_stats) if extra_stats else None
        if rf is not None:
            w["rigforge"] = rf

        if api_ok:  # only a successful probe carries uptime + per-miner hashrate
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
            total_hr += effective_hashrate(w)
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


# The four cumulative share counters the proxy /summary carries and the share_stats series stores.
_SHARE_STAT_KEYS = ("accepted", "rejected", "invalid", "expired")


def _summary_deltas(last_totals, current_totals):
    """Per-poll share-health deltas from two consecutive cumulative proxy /summary totals (#116).

    Both args are dicts keyed by ``_SHARE_STAT_KEYS``. Returns ``(deltas, new_baseline)`` where
    ``deltas`` is None — record nothing — on the first poll (``last_totals`` is None: re-baseline,
    never backfill), when ANY counter went backwards (proxy restart: segment break, never a
    negative delta), or when nothing advanced (``_merge_proxy_summary`` repeats last-good totals
    on a bad poll, and an idle proxy submits nothing — don't write empty rows every cycle)."""
    if last_totals is None or any(current_totals[k] < last_totals[k] for k in _SHARE_STAT_KEYS):
        return None, current_totals
    deltas = {k: current_totals[k] - last_totals[k] for k in _SHARE_STAT_KEYS}
    if not any(deltas.values()):
        return None, current_totals
    return deltas, current_totals


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


def _iso_now():
    """UTC now, formatted to match the #33 audit writer's own ``ts`` (``control_audit`` in
    ``pithead``) — same string shape both sources write, so the audit_events table sorts and
    groups by hour/day/month with a plain string-prefix slice, no parsing needed at read time."""
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _flatten_config_keys(cfg, out, prefix=""):
    """Fill ``out`` with ``{dotted.path: leaf_value}`` for every leaf in nested dict ``cfg``. Only
    ever used to compare/NAME keys (see ``_diff_config_keys``) — a leaf value is compared for
    equality, never rendered; the source, ``config.HOST_CONFIG_PATH``, is already the host's
    pre-masked copy (#440), so no secret is present to leak even here.

    The masked secret sentinel (``control_service.SECRET_SENTINEL``, ``{"__secret__": True}``) is
    treated as an opaque LEAF, not descended into — otherwise a secret being set/cleared would
    name a synthetic ``...password.__secret__`` path instead of the real setting."""
    if not isinstance(cfg, dict):
        return
    for k, v in cfg.items():
        path = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict) and v != SECRET_SENTINEL:
            _flatten_config_keys(v, out, path)
        else:
            out[path] = v


def _diff_config_keys(old, new):
    """Dotted config-key paths added, removed, or changed between two config snapshots (#530),
    sorted. Names only — the values feed only an equality check and are never returned, matching
    the #33 audit contract (key names, never values)."""
    old_flat, new_flat = {}, {}
    _flatten_config_keys(old, old_flat)
    _flatten_config_keys(new, new_flat)
    changed = set(old_flat) ^ set(new_flat)  # added or removed entirely
    changed |= {k for k in old_flat.keys() & new_flat.keys() if old_flat[k] != new_flat[k]}
    return sorted(changed)


def _parse_audit_ts(ts):
    """Parse a #33 audit-log ``ts`` string (``%Y-%m-%dT%H:%M:%SZ``) to epoch seconds, or None for
    anything else — a malformed/garbage ts (already length-capped and charset-stripped by
    ``audit_service._clean``) must never crash the out-of-band watcher, just fail to "explain" a
    change (the safe direction: an unparsable commit ts causes a spurious host-edit row, not a
    swallowed one)."""
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC).timestamp()
    except (TypeError, ValueError):
        return None


def _read_host_config():
    """The masked config.json (``config.HOST_CONFIG_PATH``, #440), or None if the mount isn't
    ready / isn't valid JSON yet. A plain blocking function — ``_watch_host_config`` runs it via
    ``asyncio.to_thread`` rather than opening the file directly in an ``async def``.

    The mount is the host's PRE-MASKED copy already (docker-compose bind-mounts
    ``control/masked/config.json``; the raw config.json never enters the container). We still
    re-apply the SECRET_PATHS mask here — exactly the defense-in-depth pass ``control_service.
    read_config`` runs — so a host-side masking regression can never leave a raw secret VALUE
    resident in ``self._last_host_config`` across polls. The diff only ever compares/names keys,
    but this keeps the one long-lived config dict secret-free regardless."""
    try:
        with open(config.HOST_CONFIG_PATH) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return None
    for path in SECRET_PATHS:
        found, value = _get(cfg, path)
        if found and value:
            _set(cfg, path, dict(SECRET_SENTINEL))
    return cfg


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
        # bridge Tor SOCKS (reusing TOR_SOCKS_PROXY) so it can't reveal the host IP to GitHub.
        self.update_checker = UpdateChecker(
            GitHubReleaseClient(GITHUB_RELEASES_API, TOR_SOCKS_PROXY),
            (os.environ.get("PITHEAD_VERSION") or "").strip(),
            enabled=CHECK_FOR_UPDATES,
            interval=UPDATE_CHECK_INTERVAL,
        )
        # RigForge latest-release check (#596): the same flag, throttle and Tor route, pointed at
        # the RigForge repo. ONE fleet-wide fetch — the per-worker "rig is behind" verdict is
        # derived at the render seam from each rig's live reported version, never stored (#664).
        self.rigforge_update_checker = UpdateChecker(
            GitHubReleaseClient(GITHUB_RIGFORGE_RELEASES_API, TOR_SOCKS_PROXY),
            None,
            enabled=CHECK_FOR_UPDATES,
            interval=UPDATE_CHECK_INTERVAL,
        )
        # Live XMR/XTM price feed (#520's auto half): off unless dashboard.energy.price_feed is
        # set. Same Tor SOCKS route as the update check — CoinGecko only ever sees a Tor exit.
        self.price_feed = PriceFeed(
            CoinGeckoClient(DASHBOARD_ENERGY["currency"], TOR_SOCKS_PROXY),
            enabled=DASHBOARD_ENERGY["price_feed"],
        )
        # Share-health delta baseline (#116): the previous poll's cumulative proxy /summary
        # totals; None until the first poll seeds it (and again after a counter reset).
        self._last_share_totals = None
        # v1.7 telemetry backbone (#196 Wave-0) capture-cadence state — see the _*_CAPTURE_SEC
        # constants above. `_last_blocks_found` baselines the cumulative pool blocks_found
        # counter (reused via `_shares_to_record`, same re-baseline-on-restart contract as
        # shares); the `_last_*` wall-clock stamps start at 0.0 so each series captures on its
        # first eligible poll.
        self._last_blocks_found = None
        self._last_xvb_history_write = 0.0
        self._last_hourly_capture = 0.0
        self._last_worker_capture = 0.0
        # Out-of-band audit watcher (#530): the last config.json snapshot this poll loop read
        # (None until the first poll baselines it — never diff against nothing, same "re-baseline,
        # never backfill" contract as every other watcher here) and the wall-clock of that read, so
        # a later change can be checked against control.log entries that landed AFTER it.
        self._last_host_config = None
        self._last_host_check = 0.0
        # (worker, change_id) pairs already recorded as a rig-edit this run, so a rig that keeps
        # reporting the same terminal change_id in its /status mirror every poll is flagged ONCE,
        # not on every ~30s cycle. In-memory only: the deterministic audit-row id below is what
        # actually bounds the table across restarts (INSERT OR IGNORE); this just skips the
        # redundant DB work in the steady state. Bounded by the count of distinct real rig edits.
        self._flagged_rig_changes = set()
        # Per-worker fixed-window flood cap on NEW rig-edit rows (#724): {worker: (window_start,
        # count)}. Distinct change_ids clear #530's deterministic-id dedup, so a rogue rig can
        # spam a permanent audit row every poll; this bounds them to _RIG_EDIT_CAP_PER_HOUR per
        # worker per hour. In-memory like _flagged_rig_changes — a restart resets the window, which
        # at worst grants one extra window's budget, still bounded per wall-hour.
        # ponytail: a rogue device rotating the worker NAME each poll sidesteps a per-worker cap;
        # that's the broader unauth-feed vector (#235), out of scope here — cap keyed on worker per
        # the issue, so one rogue rig can't crowd genuine rig-edit history out.
        self._rig_edit_window = {}
        # XvB raffle-winners mirror: wall-clock of the last successful winners-file read. Starts
        # at 0.0 so the first eligible poll reads it; NOT stamped on a failed fetch, so a failure
        # retries on the next 10th poll instead of waiting out the 30-min gate.
        self._last_xvb_winners_sync = 0.0
        # XvB raffle auto-registration (#263): wall-clock of the last successful register() call,
        # None until the wallet is first entered. Drives the daily re-register cadence below.
        self._xvb_last_registered = None
        # Consecutive transient register() failures while never-yet-registered (drives the "failing"
        # badge), and a latch that stops retrying once the endpoint calls the wallet invalid — a
        # permanent error that won't fix itself on retry (#263).
        self._xvb_register_failures = 0
        self._xvb_invalid_wallet = False

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
            "fail_closed_held": False,
            "timestamp": 0,
        }

        # Node-down detection + optional worker rejection (Issue #31).
        self.docker_control = DockerControl()
        self.monero_health = NodeHealthMonitor()
        self.tari_health = NodeHealthMonitor()

        # Healthchecks.io dead-man's switch (Issue #79). Disabled by default — when off this is
        # a no-op. When on, each cycle pings a unique URL; the alert fires externally on the
        # *absence* of a ping, so it survives a host death the in-stack notifier can't report.
        self.healthchecks = HealthchecksClient.from_config()

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

        # Notifications-only Telegram alerter (Issue #121). Consumes the loop's existing edges
        # (node down/recovered, sync gate open) plus a debounced per-worker presence tracker.
        # Disabled unless telegram.enabled + bot_token + chat_id are configured, so this is a
        # cheap no-op for the default stack. The payout-wallet tripwire baseline (#375) is backed
        # by the SQLite kv_store, not AlertService memory — `apply` recreates this container, and
        # an in-memory baseline would silently re-seed to a tampered wallet.
        self.alert_service = AlertService(
            kv_get=self.state_manager.get_kv, kv_set=self.state_manager.set_kv
        )
        # On-chain payout confirmation (#381): a view-only wallet-rpc client, polled on the slow
        # cadence below. Only constructed when the feature is on (view key set on a local node);
        # off, this stays None and no payout polling ever runs.
        self.wallet_client = MoneroWalletClient() if PAYOUT_CONFIRM_ENABLED else None
        # Tari on-chain payout confirmation (#462): a view-only console-wallet gRPC client, polled on
        # the same slow cadence. Only constructed when the Tari feature is on (tari view key set on a
        # local Tari node); off, this stays None and no Tari payout polling ever runs.
        self.tari_wallet_client = TariWalletClient() if TARI_PAYOUT_CONFIRM_ENABLED else None
        # Tor guard self-heal (#424), opt-in via tor.auto_heal — a no-op (no probes, no
        # restarts) unless enabled. Reuses the #31 docker-control proxy (start/stop only)
        # to restart tor when clearnet egress is stuck on a failing guard; the recovery
        # note rides the Telegram notifier, which works again exactly when the heal worked.
        self.tor_healer = TorEgressHealer(
            self.docker_control, notify=self.alert_service.tor_heal_alert
        )
        # Hashrate-degradation detector (Issue #99): flags a sustained total-hashrate drop and its
        # recovery. Runs every cycle (cheap, self-contained EMA baseline) so it can mark the chart
        # even with Telegram off; a loss also drives a hashrate_loss alert.
        self.degradation = DegradationMonitor(
            threshold_frac=HASHRATE_DROP_THRESHOLD_PCT / 100,
            sustained_sec=HASHRATE_DROP_MINUTES * 60,
        )
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

        # Opt-in fail-closed miner hold on an UNRECOVERABLE health failure (#490), dashboard.
        # fail_closed, default false — see `_apply_fail_closed_gate`. Transient like `miner_held`,
        # not persisted: a restart re-derives it from the current health signals.
        self.fail_closed_held = False

        # Restore persistent state from DB to prevent empty dashboard on service restart
        loaded_snapshot = self.state_manager.load_snapshot()
        if loaded_snapshot and isinstance(loaded_snapshot, dict):
            # Derived state must not outlive its inputs across a restart (#664): `update` is a
            # pure function of (running version, latest tag), and the running version may have
            # JUST changed — the very upgrade the restored badge advertised. The checker
            # recomputes it on its own cadence; never resurrect the pre-upgrade banner.
            loaded_snapshot.pop("update", None)
            # Same rule for the fleet-wide RigForge release (#596): with the flag now off, a
            # restored `rigforge_release` would keep serving stale per-worker badges until the
            # first poll cycle. The checker re-fetches on its cadence; drop it on restore.
            loaded_snapshot.pop("rigforge_release", None)
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

    async def _stop_gate_containers(self, quiet):
        """Stop every ``SYNC_GATE_CONTAINERS`` container; shared by the #35 sync gate and the
        #490 fail-closed gate, the two holds that stop the same container set."""
        for container in SYNC_GATE_CONTAINERS:
            await self.docker_control.stop(container, quiet=quiet)

    async def _start_gate_containers(self):
        """Start every ``SYNC_GATE_CONTAINERS`` container; True only if every start succeeded."""
        ok = True
        for container in SYNC_GATE_CONTAINERS:
            ok = (await self.docker_control.start(container)) and ok
        return ok

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
            if await self._start_gate_containers():
                self.miner_released = True
                self.miner_held = False
                logger.info(
                    f"Required chain(s) synced — starting {', '.join(SYNC_GATE_CONTAINERS)}; mining can begin."
                )
            # On a partial-start failure leave the latch closed so the next cycle retries.
            return

        # Still syncing: keep the miner held. Log the human-facing notice only on the first
        # cycle of a hold; the per-cycle re-assert stops are quiet to avoid flooding the log.
        await self._stop_gate_containers(quiet=self.miner_held)
        if not self.miner_held:
            self.miner_held = True
            logger.info(
                f"Required chain(s) still syncing — holding {', '.join(SYNC_GATE_CONTAINERS)} "
                f"until synced."
            )

    async def _apply_fail_closed_gate(self, unrecoverable):
        """
        Opt-in (`dashboard.fail_closed`, default False) miner hold on an UNRECOVERABLE health
        failure (#490) — reuses the #35 sync gate's own mechanism (stop/start
        ``SYNC_GATE_CONTAINERS`` through ``docker_control``) rather than a new hold path.

        "Unrecoverable" is scoped narrowly by the caller to genuine, non-transient failures: a DB
        whose auto-heal rebuild itself failed (``StateManager.is_db_unrecoverable``), or the
        dashboard container itself crash-looping / stuck unhealthy past the #337 debounce
        (``AlertService.containers.is_confirmed_bad("dashboard")`` — a debounce-CONFIRMED verdict,
        never a first-sighting seed). A transient write blip, a slow query, a single failed
        external fetch, or a container merely reported unhealthy on one poll is never
        "unrecoverable" — those already alert (#131/#337) and must never gate; a false positive
        here idles the fleet and costs revenue.

        Unlike the sync gate's one-way latch, this re-checks every cycle and releases once
        ``unrecoverable`` clears — the failures it watches (disk full, a crash-looping container)
        are the kind an operator fixes without a full stack restart, and the miner should resume
        on its own once they do. Only engages once the sync gate has actually released the miner;
        holding before that is already #35's job.

        Default False is alert-only: `dashboard.fail_closed` off means these same signals keep
        alerting (unchanged) but this method is a no-op, so a cosmetic dashboard fault never idles
        the fleet — the mining datapath (xmrig-proxy -> p2pool -> monerod) is independent of the
        dashboard by design.
        """
        if not DASHBOARD_FAIL_CLOSED or not self.miner_released:
            return

        if unrecoverable:
            await self._stop_gate_containers(quiet=self.fail_closed_held)
            if not self.fail_closed_held:
                self.fail_closed_held = True
                logger.error(
                    f"Unrecoverable health failure with dashboard.fail_closed enabled — holding "
                    f"{', '.join(SYNC_GATE_CONTAINERS)} until it clears."
                )
            return

        if self.fail_closed_held and await self._start_gate_containers():
            self.fail_closed_held = False
            logger.info(
                f"Unrecoverable health failure cleared — starting "
                f"{', '.join(SYNC_GATE_CONTAINERS)}; mining can resume."
            )
        # On a partial-start failure stay held so the next cycle retries.

    async def _sync_xvb_stats(self):
        """
        Fetch XvB's reported averages (avg_1h/avg_24h/fail_count) over Tor and persist them.

        A failed fetch (Tor timeout, 5xx) returns None — we write NOTHING in that case, leaving the
        last-good values AND ``last_update`` frozen. That frozen ``last_update`` is exactly what the
        controller and dashboard read to detect a stale feed and stop steering off a dead number
        (#311). So "no write on failure" is a correctness precondition, not just an optimisation —
        if this ever started stamping on failure, the staleness guard would silently never trigger.

        The caller already gated on ENABLE_XVB + the 10th-iteration throttle.
        """
        real_xvb_stats = await asyncio.to_thread(self.xvb_client.get_stats)
        if not real_xvb_stats:
            return  # fetch failed — keep the last reading + last_update frozen so #311 can detect it
        await asyncio.to_thread(self.state_manager.update_xvb_stats, **real_xvb_stats)
        logger.info(f"External Sync: XvB Stats Updated (1h={real_xvb_stats['avg_1h']:.0f} H/s)")

        # v1.7 telemetry backbone (#196 Wave-0): persist the XvB scalars as a time series, wall-
        # clock gated to ~5 min so a change to UPDATE_INTERVAL (which also throttles how often
        # this method is even called) can't silently change the capture cadence.
        now = time.time()
        if now - self._last_xvb_history_write >= _XVB_HISTORY_CAPTURE_SEC:
            xvb = await asyncio.to_thread(self.state_manager.get_xvb_stats)
            await asyncio.to_thread(
                self.state_manager.add_xvb_history,
                now,
                avg_1h=xvb.get("avg_1h", 0.0),
                avg_24h=xvb.get("avg_24h", 0.0),
                fail_count=xvb.get("fail_count", 0),
                donation_fraction=xvb.get("donation_fraction", 0.0),
                mode=xvb.get("current_mode", ""),
            )
            self._last_xvb_history_write = now

    async def _sync_xvb_reward_estimates(self):
        """
        Fetch XvB's published per-tier expected rewards over Tor and cache them (#118).

        Same "no write on failure" contract as ``_sync_xvb_stats``: a failed/unparseable fetch
        returns None, we write NOTHING, and the cached ``last_update`` stays frozen so the dashboard
        detects a stale feed (``xvb_stats_are_stale``) and shows "estimate unavailable" rather than a
        stale-implied-fresh number. Runs off the main data loop (to_thread), on the same 10th-poll
        throttle as the stats sync, so a slow xmrvsbeast.com never blocks live metrics.
        """
        estimates = await asyncio.to_thread(self.xvb_client.get_reward_estimates)
        if not estimates:
            return  # fetch failed / unparseable — keep the last-good estimates + last_update frozen
        await asyncio.to_thread(self.state_manager.set_xvb_reward_estimates, estimates)
        logger.info(f"External Sync: XvB Reward Estimates Updated ({len(estimates)} tiers)")

    async def _sync_xvb_winners(self):
        """
        Mirror XvB's public raffle-winners file into the ``raffle_wins`` table.

        This is the only place raffle WINS are visible — the stats endpoint reports only
        fail_count — so the dashboard reads XvB's published winners log, keeps our wallet's rows
        (matched by XvB's masked form), and persists them idempotently. Each genuinely NEW win
        (add_raffle_wins' insert contract) is announced once in the dashboard log; the chart and
        the XvB card read the table.

        Same "no write on failure" contract as the other XvB syncs: a failed fetch returns None,
        nothing is written, and the gate is NOT stamped so the next 10th poll retries.

        The gate is adaptive (#892): ``_xvb_winners_gate_sec`` picks the fast cadence while a
        won round is plausibly live or at stake, the 30-min baseline otherwise.
        """
        now = time.time()
        xvb = self.state_manager.get_xvb_stats()
        recent_wins = await asyncio.to_thread(
            self.state_manager.get_raffle_wins, now - _XVB_WIN_FRESH_S
        )
        gate = _xvb_winners_gate_sec(
            xvb.get("avg_1h", 0) or 0,
            xvb.get("avg_24h", 0) or 0,
            self.state_manager.get_tiers(),
            max((w.get("ts", 0) or 0 for w in recent_wins), default=0.0),
            now,
        )
        if now - self._last_xvb_winners_sync < gate:
            return
        result = await asyncio.to_thread(self.xvb_client.get_recent_wins)
        if result is None:
            return  # fetch failed — retry next eligible poll; don't stamp the gate
        self._last_xvb_winners_sync = now
        # Same fetched body, second parse (#866/#872): the all-rounds aggregate that makes win
        # odds and realized-reward figures computable. Written only when it parsed to something,
        # so a format change degrades to stale (detectable) rather than an empty-implied-fresh.
        if (result.get("round_stats") or {}).get("types"):
            await asyncio.to_thread(self.state_manager.set_xvb_round_stats, result["round_stats"])
        new_wins = await asyncio.to_thread(self.state_manager.add_raffle_wins, result["wins"])
        for win in new_wins:
            logger.info(
                f"XvB raffle WIN: {win['tier']} round won at "
                f"{format_hashrate(win['hashrate'])} credited (height {win['height']}) 🎉"
            )
            # One Telegram/webhook alert per genuinely new win — add_raffle_wins' idempotent
            # insert contract is what makes this fire-once, same as payout_confirmed.
            await self.alert_service.raffle_win_alert(win["tier"], win["hashrate"])

    async def _maybe_register_xvb(self, shares, p2pool_stats):
        """
        Auto-enter the wallet into the XvB raffle once it's eligible (#263).

        Mining to the XvB pool doesn't enter a wallet — it must be registered against the operator's
        endpoint, which only takes effect once the wallet has a share in the P2Pool PPLNS window. So
        we gate on a PPLNS share existing (same window math as the dashboard/algo) and skip silently
        until then, retrying on the next poll. After the first success we re-register on a daily
        cadence (XVB_REGISTER_INTERVAL_S): registration is idempotent, and re-running picks up the
        operator's newer security-token behaviour and re-enters a long-offline miner cleanly.

        The caller already gated on ENABLE_XVB + the 10th-iteration throttle. Edge cases are handled
        from the endpoint's real contract (see XvbClient.register): "already registered" is the
        idempotent steady state (success); an invalid wallet is permanent (latch + warn, stop
        retrying); transient errors escalate to a "failing" badge only after a few attempts.
        register() routes over Tor.
        """
        # Nothing to do if registration is disabled (XVB_SUBMIT_URL off) or the wallet was already
        # rejected as permanently invalid — both are terminal for this process, skip quietly.
        if not self.xvb_client.submit_url or self._xvb_invalid_wallet:
            return

        # PPLNS-share check — mirrors metrics/algo: a share counts if it's within pplns_window
        # blocks (30s/block on Nano, else 10s) of now.
        pool_type = p2pool_stats.get("p2p", {}).get("type", "Main")
        pplns_window = p2pool_stats.get("pool", {}).get("pplns_window", DEFAULT_PPLNS_WINDOW)
        block_time = pplns_block_time(pool_type)
        if shares_in_pplns_window(shares, pplns_window, block_time) == 0:
            return  # no eligible share yet — the endpoint would no-op, so don't call it

        now = time.time()
        if self._xvb_last_registered is not None and (
            now - self._xvb_last_registered < XVB_REGISTER_INTERVAL_S
        ):
            return  # already registered recently; next re-register isn't due yet

        status = await asyncio.to_thread(self.xvb_client.register)

        if status == REG_OK:
            # Fresh registration OR the idempotent "already registered" steady state — either way the
            # wallet is in the raffle. Stamp it and clear the transient-failure counter.
            self._xvb_last_registered = now
            self._xvb_register_failures = 0
            await asyncio.to_thread(
                self.state_manager.update_xvb_stats,
                registered_at=now,
                registration_state="registered",
            )
            logger.info("External Sync: Registered wallet with XvB raffle ✓")
        elif status == REG_INVALID:
            # Permanent: the endpoint won't accept this wallet, and it won't change on retry. Latch
            # off, warn once, and surface it — don't hammer the endpoint every poll.
            self._xvb_invalid_wallet = True
            logger.warning(
                "XvB registration rejected MONERO_WALLET_ADDRESS as invalid — auto-registration "
                "disabled. The XvB raffle needs a standard primary Monero address (4…). (#263)"
            )
            await asyncio.to_thread(
                self.state_manager.update_xvb_stats, registration_state="invalid"
            )
        elif status == REG_NOT_ELIGIBLE:
            # The share we see locally hasn't propagated to XvB yet — not a failure, just retry next
            # poll. Don't count it toward the "failing" escalation.
            return
        else:
            # Transient (network / 5xx / unrecognised). register() already logged specifics. Only
            # escalate to a dashboard warning once it's *persistently* failing AND we've never
            # succeeded — a blip while the first share propagates shouldn't alarm. (A failed daily
            # re-register after a prior success keeps the "registered ✓"; we're still entered.)
            self._xvb_register_failures += 1
            if (
                self._xvb_last_registered is None
                and self._xvb_register_failures >= _XVB_REGISTER_FAIL_ALERT
            ):
                await asyncio.to_thread(
                    self.state_manager.update_xvb_stats, registration_state="failing"
                )

    async def _sync_prices(self):
        """Refresh the live XMR/XTM prices (#520) into ``latest_data["prices"]`` — a no-op with the
        feed off. The PriceFeed self-throttles and keeps its last good result, so calling this every
        poll is safe; ``build_energy`` swaps the result in for the static config prices."""
        if self.price_feed.enabled:
            self.latest_data["prices"] = await asyncio.to_thread(
                self.price_feed.maybe_fetch, time.time()
            )

    async def _sync_payouts(self):
        """Confirm on-chain payouts from the view-only wallet-rpc (#381), throttled by the caller.

        Seeds the query from the highest stored Monero payout height, so a restart re-scans only
        the tip; ``add_payouts`` is idempotent on ``(chain, txid)``, so the overlap is dropped and
        nothing replays. Every genuinely-new confirmed payout fires exactly one ``payout_confirmed``
        alert. A wallet still doing its first-run scan (or briefly unreachable) returns ``[]`` — a
        quiet no-op, no error. chain="monero" here; the Tari sibling (#462) reuses the same table."""
        chain = "monero"
        min_height = await asyncio.to_thread(self.state_manager.get_payout_max_height, chain)
        payouts = await asyncio.to_thread(self.wallet_client.get_confirmed_payouts, min_height)
        if not payouts:
            return
        new_rows = await asyncio.to_thread(self.state_manager.add_payouts, chain, payouts)
        for r in new_rows:
            logger.info(
                "Payout confirmed on-chain: %.6f XMR (tx %s…) at height %d (#381)",
                r["amount_atomic"] / 1e12,
                r["txid"][:8],
                r["height"],
            )
            await self.alert_service.payout_confirmed_alert(chain, r["amount_atomic"], r["txid"])

    async def _sync_tari_payouts(self):
        """Confirm Tari on-chain payouts from the view-only console wallet (#462), throttled by the
        caller — the Tari sibling of ``_sync_payouts``.

        Identical shape: seed from the highest stored Tari payout height, stream new confirmed
        payouts, persist to the shared ``payouts`` table with chain="tari" (idempotent on
        ``(chain, txid)`` so a restart replays nothing), and fire one ``payout_confirmed`` alert per
        genuinely-new payout. ``amount_atomic`` is microTari here; the shared alert divides by the
        Tari divisor. The Tari client is async (grpc.aio), so it's awaited directly rather than via
        ``asyncio.to_thread``. An empty/unreachable scan is a quiet no-op."""
        chain = "tari"
        min_height = await asyncio.to_thread(self.state_manager.get_payout_max_height, chain)
        payouts = await self.tari_wallet_client.get_confirmed_payouts(min_height)
        if not payouts:
            return
        new_rows = await asyncio.to_thread(self.state_manager.add_payouts, chain, payouts)
        for r in new_rows:
            logger.info(
                "Tari payout confirmed on-chain: %.6f XTM (tx %s…) at height %d (#462)",
                r["amount_atomic"] / 1e6,
                r["txid"][:8],
                r["height"],
            )
            await self.alert_service.payout_confirmed_alert(chain, r["amount_atomic"], r["txid"])

    async def _record_audit_event(self, source, actor, action, status, keys, event_id=None):
        """Write one out-of-band audit row (#530), through the SAME sanitizer #33's own audit
        trail is served through (``audit_service._clean``) — defense in depth: ``actor``/``keys``
        here are already schema-shaped (a validated worker name, dotted config-key paths), but
        every field the Security panel serves gets the identical whitelist treatment regardless of
        source, so a future caller can't accidentally skip it.

        ``event_id`` lets a caller supply a DETERMINISTIC row id so ``INSERT OR IGNORE`` collapses
        repeat reports of the SAME event to one row (rig-edit: a rig re-reports its last change_id
        every poll). A host-edit passes None — each detection is a genuinely distinct event, so a
        random id is right there."""
        await asyncio.to_thread(
            self.state_manager.add_audit_event,
            id=event_id or f"{source}-{uuid.uuid4()}",
            ts=_iso_now(),
            source=audit_service._clean(source, 16),
            actor=audit_service._clean(actor, 64),
            action=audit_service._clean(action, 16),
            status=audit_service._clean(status, 32),
            keys=audit_service._clean(keys, 400),
        )

    async def _watch_host_config(self):
        """Out-of-band HOST-EDIT detection (#530): config.json changed without a matching
        control-channel commit.

        Reads the same pre-masked copy the control channel itself prefills from
        (``config.HOST_CONFIG_PATH``, #440 — already secret-free) each poll and diffs it against
        the previous poll's snapshot. A changed key is "explained" — and stays quiet — only when
        the #33 audit trail shows a ``commit``/``applied`` entry that both landed AFTER the last
        time this watcher looked AND actually touched that key (the entry's env-var names are
        bridged to config paths via ``env_key_config_paths``). Correlating by key, not merely by
        time, is what stops a legit dashboard commit of key A from swallowing a concurrent
        host-side hand-edit of key B. Any changed key no fresh commit covers (a hand-edit, a
        `pithead apply` run outside the dashboard) is recorded as a ``host-edit`` audit row naming
        the unexplained keys. First poll only baselines (no control
        log exists yet to compare against, and every other watcher in this loop shares that
        never-backfill contract). No-op with the control channel off — there is neither a masked
        config mount nor an audit trail to compare against."""
        if not config.DASHBOARD_CONTROL_ENABLED:
            return
        current = await asyncio.to_thread(_read_host_config)
        if current is None:
            return  # mount not ready yet — quiet no-op, the next poll retries
        now = time.time()
        if self._last_host_config is None:
            self._last_host_config, self._last_host_check = current, now
            return
        changed_keys = _diff_config_keys(self._last_host_config, current)
        if changed_keys:
            # The audit log's ts is whole-second (_iso_now/control_audit both write
            # "%Y-%m-%dT%H:%M:%SZ"), while `_last_host_check` is a sub-second time.time() — a
            # commit landed in the SAME wall-clock second as the baseline poll would otherwise
            # floor below it and be missed. One second of grace absorbs that truncation.
            # ponytail: ≤1s correlation window — a control-channel commit up to 1s before the last
            # poll could "explain" (suppress) an unrelated hand-edit detected in this poll. The
            # honest ceiling of a timestamp correlation; tighten to id-based ("commits seen since
            # last poll") only if a real false-negative shows up. Pinned by
            # test_explained_window_is_at_most_one_second.
            since = self._last_host_check - 1
            # Correlate BY KEY, not just by time: a commit only "explains" the keys it actually
            # touched. Fold every fresh commit's env-var names into the config paths they cover
            # (env_key_config_paths bridges the audit log's env names to config.json paths), then
            # record only the changed keys NO recent commit covers — the genuine out-of-band edits
            # this watcher exists to catch. A concurrent dashboard commit of key A + a host
            # hand-edit of key B no longer swallows B.
            explained_paths = set()
            for e in audit_service.recent_changes():
                if (
                    e.get("action") == "commit"
                    and e.get("status") == "applied"
                    and (ts := _parse_audit_ts(e.get("ts"))) is not None
                    and ts >= since
                ):
                    for env_key in (e.get("keys") or "").split():
                        explained_paths.update(env_key_config_paths(env_key))
            # ponytail: env-var granularity — a var fed by >1 config path (e.g. P2POOL_FLAGS <-
            # p2pool.pool + p2pool.clearnet) explains ALL its paths, so a commit touching one could
            # still suppress a concurrent hand-edit of its sibling. Inherent to a name-only audit
            # log; fix only if per-path audit keys ever land.
            unexplained = [
                k
                for k in changed_keys
                if not any(k == p or k.startswith(p + ".") for p in explained_paths)
            ]
            if unexplained:
                await self._record_audit_event(
                    "host-edit", "", "host-edit", "detected", " ".join(unexplained)
                )
        self._last_host_config, self._last_host_check = current, now

    async def _mirror_control_audit(self):
        """Copy the #33 control.log's recent entries into the durable ``audit_events`` table
        (#530), so the Security panel's time-grouped view can drill deeper than the log's own
        trimmed tail. ``audit_service.recent_changes()`` output is already sanitized (it's the SAME
        read the panel used before this table existed); ``add_audit_event``'s ``INSERT OR IGNORE``
        on the log's own ``id`` makes re-mirroring the same tail every poll a no-op. Entries with no
        id (a handful of pre-auth "invalid"/"refused" rows, #33) are skipped — they're visible only
        while still in the log tail, same as before this feature."""
        if not config.DASHBOARD_CONTROL_ENABLED:
            return
        for e in audit_service.recent_changes():
            if not e.get("id"):
                continue
            await asyncio.to_thread(
                self.state_manager.add_audit_event,
                id=e["id"],
                ts=e.get("ts", ""),
                source="control",
                actor=e.get("actor", ""),
                action=e.get("action", ""),
                status=e.get("status", ""),
                keys=e.get("keys", ""),
            )

    def _rig_edit_within_cap(self, worker, now):
        """Per-worker fixed-window cap on NEW rig-edit audit rows (#724). Counts this rig-edit
        against the worker's current hour window and returns ``(allowed, first_over)``: ``allowed``
        is True while the worker is under ``_RIG_EDIT_CAP_PER_HOUR`` this window; ``first_over`` is
        True only on the single call that tips it over, so the caller logs + records the
        rate-limited marker exactly once per window rather than every poll. A handful of real edits
        an hour never trips it; a rig spamming distinct change_ids does."""
        start, count = self._rig_edit_window.get(worker, (now, 0))
        if now - start >= _RIG_EDIT_WINDOW_SEC:
            start, count = now, 0
        self._rig_edit_window[worker] = (start, count + 1)
        return count < _RIG_EDIT_CAP_PER_HOUR, count == _RIG_EDIT_CAP_PER_HOUR

    async def _reconcile_worker_config(self, workers, worker_results):
        """Catch up any still-``accepted`` #185 worker-config history row whose change_id the rig
        now reports terminal (#579), and flag an out-of-band RIG-EDIT (#530).

        A rollback slower than the host runner's 20s status-poll deadline (#517/#543) is honestly
        recorded ``accepted`` and never revisited — this rides THIS poll's already-fetched enriched
        bodies (``worker_results``, positionally aligned with ``workers`` and with the worker probes
        in ``run()``), so there's no new dial and no host-runner change. A plain-xmrig rig, a rig
        still mid-change, or an unreachable/offline rig (``{}``) all parse to ``None`` via
        ``parse_worker_control_status`` and are a quiet no-op.

        A TERMINAL report whose ``change_id`` this dashboard never spooled (``worker_config`` has no
        row for it — checked via ``worker_config_change_known``) is a change the RIG applied on its
        own: reconciling it would be a silent no-op anyway (the ``WHERE status='accepted'`` UPDATE
        matches nothing), so instead it's recorded as a ``rig-edit`` audit row naming the worker.
        RigForge's ``/status`` mirror carries only the outcome of a change, not a per-key diff, so
        unlike host-edit's ``keys`` this can only name the change_id — a real limitation, not an
        oversight; see the #530 PR notes.

        A rig keeps reporting its last terminal change_id every poll, so this fires ONCE per
        (worker, change_id): an in-memory guard skips the redundant work in the steady state, and
        the audit row's deterministic id makes the write itself idempotent even across a restart
        (when the guard is empty but a repeat report must still not duplicate the row). Both matter
        — the id is the correctness bound (a rogue rig can't flood the permanent table with repeats
        of one bogus change_id), the guard is the optimisation.

        DISTINCT change_ids each clear that dedup, though, so a rogue rig on the unauthenticated
        feed can still write one permanent row per poll (#724). ``_rig_edit_within_cap`` bounds NEW
        rig-edit rows to ``_RIG_EDIT_CAP_PER_HOUR`` per worker per hour; beyond that the row is
        dropped, but never silently — a single ``rate-limited`` marker is logged and recorded so the
        flood stays visible in the Security panel. host-edit rows are unaffected (a different,
        non-attacker-controlled path)."""
        for w, extra_stats in zip(workers, worker_results, strict=False):
            ctrl = parse_worker_control_status(extra_stats) if extra_stats else None
            if not ctrl:
                continue
            known = await asyncio.to_thread(
                self.state_manager.worker_config_change_known, ctrl["change_id"]
            )
            if known:
                await asyncio.to_thread(
                    self.state_manager.reconcile_worker_config_status,
                    ctrl["change_id"],
                    ctrl["status"],
                    ctrl["reason"],
                )
            else:
                worker = w.get("name", "")
                guard_key = (worker, ctrl["change_id"])
                if guard_key in self._flagged_rig_changes:
                    continue
                allowed, first_over = self._rig_edit_within_cap(worker, time.time())
                if not allowed:
                    # Over cap this window — drop the row (don't add to the guard set, so its size
                    # stays bounded by what we actually record, not by the flood). Surface the cap
                    # once per window: a warning plus one marker row, its deterministic id keyed to
                    # this worker's window start so it's idempotent even if a restart re-trips
                    # `first_over`, and a fresh window later gets its own distinct marker.
                    if first_over:
                        window_start = self._rig_edit_window[worker][0]
                        logger.warning(
                            "Worker %s exceeded %d rig-edit audit rows this hour (#724) — a rig "
                            "reporting distinct change_ids on the unauthenticated feed; further "
                            "rig-edit rows are dropped until the window resets.",
                            worker,
                            _RIG_EDIT_CAP_PER_HOUR,
                        )
                        await self._record_audit_event(
                            "rig-edit",
                            worker,
                            "rate-limited",
                            "dropped",
                            f"rig-edit rows capped at {_RIG_EDIT_CAP_PER_HOUR}/hour",
                            event_id=f"rig-edit-ratelimited-{worker}-{int(window_start)}",
                        )
                    continue
                self._flagged_rig_changes.add(guard_key)
                await self._record_audit_event(
                    "rig-edit",
                    worker,
                    "rig-edit",
                    ctrl["status"],
                    f"change_id={ctrl['change_id']}",
                    event_id=f"rig-edit-{worker}-{ctrl['change_id']}",
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
            tari_client = TariClient()

            # P2Pool shares are recorded from the cumulative shares_found counter (#129); None until
            # the first poll baselines it, so we never backfill the whole historical count on startup
            # or re-record what the DB already loaded.
            last_known_shares_total = None

            while True:
                try:
                    # 1. Collect Local Statistics (High Frequency Polling)
                    stratum_raw = get_stratum_stats()

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

                    # 2c. Persist this poll's share-health deltas (#116): what the cumulative
                    # counters gained since the last poll, reset-safe and skipping all-zero rows
                    # (see _summary_deltas). Feeds the reject-rate trend + high_reject_rate alert.
                    if proxy_summary:
                        deltas, self._last_share_totals = _summary_deltas(
                            self._last_share_totals,
                            {k: proxy_summary.get(k, 0) or 0 for k in _SHARE_STAT_KEYS},
                        )
                        if deltas:
                            await asyncio.to_thread(
                                self.state_manager.add_share_stats, time.time(), **deltas
                            )

                    # 3. Augment with Direct Worker Stats (Uptime, Hashrate) via Local API
                    tasks = [worker_client.get_stats(w["ip"], w["name"]) for w in proxy_workers]
                    worker_results = await asyncio.gather(*tasks)

                    # 3a. Reconcile any #185 history row a slow rig rollback left stuck 'accepted'
                    # (#579), and flag a rig-side out-of-band edit (#530) — rides this same poll's
                    # results, no new dial.
                    await self._reconcile_worker_config(proxy_workers, worker_results)

                    # 3a-2. Out-of-band audit (#530): a config.json change not made through the
                    # control channel, plus mirroring the #33 log into the durable audit_events
                    # table so the Security panel can group by hour/day/month. Both are no-ops with
                    # the control channel off.
                    await self._watch_host_config()
                    await self._mirror_control_audit()

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

                    # v1.7 telemetry backbone (#196 Wave-0): persist a block-found event as a time
                    # series. The #336 alert already detects a new block via this same cumulative
                    # blocks_found counter; `_shares_to_record` re-baselines without backfilling on
                    # the first poll or a p2pool restart (counter goes backwards), so this fires
                    # exactly once per genuinely new block. `difficulty` is tagged from the network
                    # stats at detection time (p2pool exposes no per-block effort figure).
                    blocks_found_total = p2pool_stats["pool"].get("blocks_found", 0) or 0
                    new_blocks, self._last_blocks_found = _shares_to_record(
                        self._last_blocks_found, blocks_found_total
                    )
                    if new_blocks > 0:
                        await asyncio.to_thread(
                            self.state_manager.add_block,
                            time.time(),
                            p2pool_stats["pool"].get("last_block_found", 0) or 0,
                            network_stats.get("difficulty", 0) or 0,
                        )

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

                    # 5. Operator alerts (Issues #121/#45): push debounced node/worker/sync/host
                    # edges to Telegram. Consumes the flags computed above; worker presence is only
                    # tracked while the proxy is actually serving (miner released and not rejected) —
                    # its intentional absence otherwise must not read as offline. Disk usage is read
                    # once here and reused in the snapshot below. No-op unless Telegram is configured;
                    # never raises.
                    disk_usage = get_disk_usage()
                    # Host-perf snapshot (#104), read once and reused for both the alerts and the
                    # system panel below. Cheap /proc reads.
                    hugepages = get_hugepages_status()
                    memory = get_memory_usage()
                    avx2 = get_cpu_avx2()
                    db_healthy = self.state_manager.is_db_healthy()
                    # Fetch fresh shares list (also used to populate the UI below) so the PPLNS-share
                    # gate the XvB alert watches is computed from the same figure the dashboard shows.
                    shares_list = await asyncio.to_thread(self.state_manager.get_shares)
                    pool_local = p2pool_stats.get("pool", {})
                    pool_type = p2pool_stats.get("p2p", {}).get("type", "Main")
                    shares_in_window = shares_in_pplns_window(
                        shares_list,
                        pool_local.get("pplns_window", DEFAULT_PPLNS_WINDOW),
                        pplns_block_time(pool_type),
                    )
                    # Build the domain metrics once per cycle for the alerter — but only when the
                    # bot is actually on, so the default (Telegram-off) stack pays nothing. Reused
                    # for the hashrate-low edge and the daily digest.
                    alert_metrics = (
                        build_metrics(self.latest_data, self.state_manager)
                        if self.alert_service.enabled
                        else None
                    )
                    # Per-container restart/health snapshot for the crash-loop/unhealthy alert
                    # (#337) — 9 inspect calls against the read-only docker-proxy, skipped
                    # entirely while Telegram is off AND dashboard.fail_closed is off (same cost
                    # discipline as alert_metrics). fail_closed needs it even with Telegram off:
                    # it's the only source for "is the dashboard container itself crash-looping"
                    # (#490).
                    container_states = (
                        await get_container_health()
                        if (self.alert_service.enabled or DASHBOARD_FAIL_CLOSED)
                        else {}
                    )
                    await self.alert_service.process(
                        monero_down=monero_down,
                        tari_down=tari_down,
                        tari_required=TARI_REQUIRED,
                        miner_released=self.miner_released,
                        # The same worker rows the dashboard shows; the monitor reads each rig's
                        # status (DOWN = offline) so alerts line up with the on-screen state.
                        workers=final_workers,
                        workers_expected=self.miner_released and not self.workers_rejected,
                        disk_percent=(disk_usage or {}).get("percent", 0) or 0,
                        db_healthy=db_healthy,
                        # DB self-heal one-shot (#489): a monotonic counter + the last reset's detail,
                        # so the alerter fires exactly once when a corrupt DB was quarantined + reset.
                        db_reset_seq=self.state_manager.db_reset_count,
                        db_reset_detail=self.state_manager.last_db_reset,
                        xvb_enabled=ENABLE_XVB,
                        shares_in_window=shares_in_window,
                        clearnet_active=bool(self.clearnet_sync_state.get("active")),
                        xvb_registration_state=(self.state_manager.get_xvb_stats() or {}).get(
                            "registration_state", ""
                        ),
                        # From the previous cycle's snapshot (the update check writes it below); a
                        # one-cycle lag is fine for a one-shot "new release" ping.
                        update_available=bool(
                            (self.latest_data.get("update") or {}).get("available")
                        ),
                        low_hr_warning=bool(alert_metrics and alert_metrics.low_hr_warning),
                        # Persistent host-perf conditions (#104). HugePages "Disabled" = not
                        # reserved (recoverable via reboot); low_ram compares live total to the
                        # threshold. avx2 is badge-only (no alert), so it isn't passed here.
                        hugepages_reserved=(hugepages[0] != "Disabled"),
                        low_ram=(0 < (memory.get("total_gb") or 0) < LOW_RAM_GB),
                        # Trailing-1h reject rate from the delta series (#116); None while no
                        # shares were submitted in the window, which the edge treats as "no
                        # verdict" rather than healthy.
                        reject_rate_1h=share_reject_pct(self.state_manager.get_share_stats(), 3600),
                        # Payout-wallet tripwire (#375): what p2pool itself reports mining to —
                        # the same stratum field the dashboard's Stratum card shows — with the
                        # env address as fallback while p2pool is down/restarting. Empty => no-op.
                        observed_wallet=stratum_raw.get("wallet") or MONERO_WALLET_ADDRESS,
                        # Block-found / payout-found edges (#336): p2pool's cumulative pool-wide
                        # block counter and the height of the last one. 0 while the stats file is
                        # missing/unparsable, which the edge treats as a silent rebaseline.
                        blocks_found_total=pool_local.get("blocks_found", 0) or 0,
                        block_height=pool_local.get("last_block_found", 0) or 0,
                        # Container crash-loop / stuck-unhealthy edges (#337), read above from
                        # the read-only docker-proxy.
                        containers=container_states,
                    )
                    # 5b. Fail-closed miner hold (#490), opt-in via dashboard.fail_closed. Reads
                    # the DB auto-heal outcome and the dashboard's OWN crash-loop state — both
                    # narrow, non-transient "unrecoverable" signals — off the trackers `process`
                    # above just fed (see `_apply_fail_closed_gate` for what counts and why).
                    await self._apply_fail_closed_gate(
                        self.state_manager.is_db_unrecoverable()
                        or self.alert_service.containers.is_confirmed_bad("dashboard")
                    )
                    # Once-daily status digest, reusing the metrics built above (only when the bot
                    # is on, which is also the only time maybe_daily_summary would send).
                    await self.alert_service.maybe_daily_summary(
                        time.time(),
                        # bind this cycle's metrics (the provider runs within this iteration); drain
                        # the day's incident tally into the digest (#342).
                        lambda m=alert_metrics: format_daily_summary(
                            m,
                            self.latest_data,
                            HOST_IP,
                            incidents=self.alert_service.drain_incidents(),
                        ),
                    )
                    # 6. Degradation detector (#99): a sustained total-hashrate drop / recovery is
                    # persisted as a chart event marker and pushed as a hashrate_loss alert.
                    deg_edge = self.degradation.update(total_hr)
                    if deg_edge:
                        kind, drop_frac, _baseline, current = deg_edge
                        if kind == "loss":
                            ev_type = "hashrate_loss"
                            detail = (
                                f"Hashrate −{drop_frac * 100:.0f}% ({format_hashrate(current)})"
                            )
                        else:
                            ev_type = "hashrate_recovered"
                            detail = f"Hashrate recovered ({format_hashrate(current)})"
                        await asyncio.to_thread(
                            self.state_manager.add_event, time.time(), ev_type, detail
                        )
                        await self.alert_service.degradation_alert(kind, drop_frac)

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
                            "fail_closed_held": self.fail_closed_held,
                            "clearnet_sync": self.clearnet_sync_state,
                            "system": {
                                "disk": disk_usage,
                                "hugepages": hugepages,
                                "memory": memory,
                                "avx2": avx2,
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

                    # 6a2. v1.7 telemetry backbone (#196 Wave-0), hourly wall-clock gate: monerod
                    # DB size + host disk usage (disk_growth, permanent) and Monero
                    # difficulty/height/reward + pool hashrate (network_history, 90-day
                    # retention). Both DB-only — nothing reads either per-cycle.
                    now_ts = time.time()
                    if now_ts - self._last_hourly_capture >= _HOURLY_CAPTURE_SEC:
                        await asyncio.to_thread(
                            self.state_manager.add_disk_growth,
                            now_ts,
                            monero_db_bytes=monero_sync.get("db_size", 0) or 0,
                            disk_used_gb=(disk_usage or {}).get("used_gb", 0) or 0,
                            disk_total_gb=(disk_usage or {}).get("total_gb", 0) or 0,
                        )
                        await asyncio.to_thread(
                            self.state_manager.add_network_history,
                            now_ts,
                            difficulty=network_stats.get("difficulty", 0) or 0,
                            height=network_stats.get("height", 0) or 0,
                            reward=network_stats.get("reward", 0) or 0,
                            pool_hashrate=pool_local.get("hashrate", 0) or 0,
                        )
                        self._last_hourly_capture = now_ts

                    # 6a3. v1.7 telemetry backbone (#196 Wave-0), ~5 min wall-clock gate:
                    # per-worker hashrate/share history, batched into ONE executemany call rather
                    # than N inserts per cycle. 30-day retention.
                    if now_ts - self._last_worker_capture >= _WORKER_HISTORY_CAPTURE_SEC:
                        worker_rows = [
                            {
                                "ts": now_ts,
                                "name": w.get("name", ""),
                                "h15": w.get("h15", 0) or 0,
                                "accepted": w.get("accepted", 0) or 0,
                                "rejected": w.get("rejected", 0) or 0,
                            }
                            for w in final_workers
                            if w.get("status") == "online"
                        ]
                        if worker_rows:
                            await asyncio.to_thread(
                                self.state_manager.add_worker_history, worker_rows
                            )
                        self._last_worker_capture = now_ts

                    # 6b. Healthchecks.io dead-man's switch (Issue #79). Ping each cycle so the
                    # external monitor alerts on the *absence* of a ping if the host ever dies
                    # (power loss, crash, NIC death) — a pure "is the stack alive" liveness signal.
                    # Node-health alerting (a node down while the box is up) is out of scope here;
                    # that's the Telegram alerter's job (#121). The client throttles and fails
                    # silently; `enabled` is just "a ping URL is set", so an unconfigured stack
                    # never pings.
                    if self.healthchecks.enabled:
                        await asyncio.to_thread(self.healthchecks.ping)

                    # 6c. Tor guard self-heal (#424): when opted in, probe Tor clearnet egress
                    # (self-throttled) and restart tor if it's stuck on a failing guard —
                    # bounded, cooled-down, loud. Off (the default) this is a plain no-op.
                    await self.tor_healer.check()

                    # 7. External XvB stats sync over Tor (#163), throttled to every 10th iteration,
                    # and ONLY when XvB is enabled — disabling XvB must stop the egress entirely.
                    if ENABLE_XVB and iteration_count % 10 == 0:
                        await self._sync_xvb_stats()

                        # 7a. XvB published per-tier reward estimates (#118) — same throttle/egress
                        # (Tor, every 10th poll, XvB-enabled only) so the tier-payout comparison in
                        # the earnings card is current without an extra fetch cadence.
                        await self._sync_xvb_reward_estimates()

                        # 7b. XvB raffle auto-registration (#263). Rides the same throttle/egress as
                        # the stats sync (Tor, every 10th poll, XvB-enabled only). Gated on a PPLNS
                        # share existing — before then the endpoint is a no-op, so we just retry.
                        await self._maybe_register_xvb(shares_list, p2pool_stats)

                        # 7c. XvB raffle winners. Rides the same throttle/egress, with its own
                        # 30-min wall-clock gate inside (the winners file updates ~hourly).
                        await self._sync_xvb_winners()

                    # 7d. On-chain payout confirmation (#381), every 10th poll (~5 min). Independent
                    # of XvB — gated on the view-only wallet-rpc being configured (local node + view
                    # key). Polls get_transfers, persists new confirmed payouts, fires one alert each.
                    if self.wallet_client is not None and iteration_count % 10 == 0:
                        await self._sync_payouts()

                    # 7e. Tari on-chain payout confirmation (#462), same cadence — gated on the
                    # view-only Tari console wallet being configured (local node + tari view key).
                    if self.tari_wallet_client is not None and iteration_count % 10 == 0:
                        await self._sync_tari_payouts()

                    # 8. New-release check over Tor (#224) — ONLY when explicitly enabled (default off,
                    # so the appliance never phones GitHub unbidden). The checker self-throttles to
                    # hourly and returns the cached result; surfaced as state.update for the header badge.
                    if self.update_checker.enabled:
                        self.latest_data["update"] = await asyncio.to_thread(
                            self.update_checker.maybe_check, time.time()
                        )
                    # 8b. The RigForge counterpart (#596): cache the latest RigForge release
                    # (raw {tag, url}); build_workers derives each rig's badge from it. Written
                    # unconditionally — the accessor returns None without dialing when the check
                    # is disabled, so a snapshot-restored release can't outlive a flag flip.
                    self.latest_data["rigforge_release"] = await asyncio.to_thread(
                        self.rigforge_update_checker.latest_release_cached, time.time()
                    )

                    # 9. Live XMR/XTM prices over Tor (#520) — ONLY when dashboard.energy.price_feed
                    # is set (default off, so the appliance never dials CoinGecko unbidden). The
                    # feed self-throttles (15 min) and keeps the last good prices on failure;
                    # surfaced as state.energy price fields via build_energy.
                    await self._sync_prices()

                    iteration_count += 1
                except Exception as e:
                    logger.error(f"Data Collection Error: {e}")
                await asyncio.sleep(UPDATE_INTERVAL)
