"""Pure helpers behind the ``DataService`` poll loop (#1105 Phase 3, cut D5).

Parsers, normalizers and aggregators that turn one raw xmrig-proxy / miner / XvB read into the
shapes the poll loop stores, plus ``WorkerLifecycle``.  Every name here is a pure function of its
arguments or a module constant: nothing reaches for the network, the database or wall-clock state
except through what it is passed.  ``DataService`` itself -- the poll loop, its scheduling and its
collaborators -- deliberately stays in ``data_service``, which imports these back.

Split out of ``data_service`` as a pure move: the blocks below are byte-identical to their originals
apart from one declared comment edit (a "the capture cadences above" reference that the move would
have made false).
"""

import json
from datetime import UTC, datetime

from mining_dashboard.client.xmrig_client import parse_rigforge
from mining_dashboard.config import config
from mining_dashboard.helper.utils import effective_hashrate, get_tier_info
from mining_dashboard.service.control_service import SECRET_SENTINEL, mask_secrets

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


# XvB's public winners file updates once per hourly round and covers ~4 days, so a 30-min re-read
# can never miss a win outright. But the in-round hold (#769) reacts only when the mirror runs, so
# a win landing at the wrong phase went undetected — and unprotected — for up to 30 min (#892).
# The gate is therefore adaptive (_xvb_winners_gate_sec): 30-min baseline, dropping to the fast
# cadence in exactly the windows where detection latency costs money. Wall-clock gated like the
# capture cadences in ``data_service``.
_XVB_WINNERS_SYNC_SEC = 1800
_XVB_WINNERS_SYNC_FAST_SEC = 150
# The fast windows: the credited 1h average within 25% above the current tier threshold (the band
# the controller deliberately rides, #769's threshold + cushion — where a won round is one
# steering step from sagging out), or a recorded win younger than 90 min (rounds run ~an hour, so
# one may still be live).
_XVB_WINNERS_MARGIN = 0.25
_XVB_WIN_FRESH_S = 5400


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
    worker is tagged with ``active_pool`` for the UI badge, and with ``api_ok`` (True/False) plus
    ``adopted`` when the worker API was probed, so the UI can tell a rig whose configured feed
    failed from one never adopted (#1857) — both distinct from a worker that's simply offline.
    """
    final_workers = []
    for w, extra_stats in zip(workers, results, strict=False):
        # api_ok: True (probe succeeded), False (probe failed — surfaced, not swallowed), or unset
        # (not probed, e.g. an internal IP per the SSRF guard). `adopted` (#1857) rides with it.
        api_ok = extra_stats.get("api_ok") if extra_stats else None
        if api_ok is not None:
            w["api_ok"], w["adopted"] = api_ok, bool(extra_stats.get("adopted"))

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


def _parse_audit_ts(ts) -> float | None:
    """Parse a #33 audit-log ``ts`` string (``%Y-%m-%dT%H:%M:%SZ``) to epoch seconds, or None for
    anything else — a malformed/garbage ts (already length-capped and charset-stripped by
    ``audit_service._clean``) must never crash the out-of-band watcher, just fail to "explain" a
    change (the safe direction: an unparsable commit ts causes a spurious host-edit row, not a
    swallowed one)."""
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC).timestamp()
    except (TypeError, ValueError):
        return None


def _read_host_config() -> dict | None:
    """The masked config.json (``config.HOST_CONFIG_PATH``, #440), or None if the mount isn't
    ready / isn't valid JSON yet. A plain blocking function — ``_watch_host_config`` runs it via
    ``asyncio.to_thread`` rather than opening the file directly in an ``async def``.

    The mount is the host's PRE-MASKED copy already (docker-compose bind-mounts
    ``control/masked/config.json``; the raw config.json never enters the container). We still
    re-apply ``mask_secrets`` here — exactly the defense-in-depth pass ``control_service.
    read_config`` runs — so a host-side masking regression can never leave a raw secret VALUE
    resident in ``self._last_host_config`` across polls. The diff only ever compares/names keys,
    but this keeps the one long-lived config dict secret-free regardless."""
    try:
        with open(config.HOST_CONFIG_PATH) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return None
    return mask_secrets(cfg)


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
