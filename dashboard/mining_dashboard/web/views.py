"""View layer for the dashboard: turn the computed :class:`Metrics` (plus a little passthrough
from ``latest_data``) into the structured ``/api/state`` payload the Preact client renders.

Separation of concerns (Issue #61): the *domain* values are computed once in
``service/metrics.py``; this layer only **formats at the edge** — display strings
(``"10.50 kH/s"``) and presentation tokens (``variant: "ok"``, ``level: "high"``) — and never
emits HTML. The client maps tokens to CSS classes and builds the DOM.

``build_state`` is the single assembly point and the contract the ``/api/state`` endpoint and
the client share; ``server.py`` stays pure transport.
"""

import json
import logging
import os
import time

from mining_dashboard.config import config
from mining_dashboard.config.config import (
    DEFAULT_HASHRATE_WINDOW,
    HASHRATE_WINDOWS,
    HOST_IP,
)
from mining_dashboard.helper.utils import (
    detect_host_ipv4,
    format_disk_size,
    format_duration,
    format_hashrate,
    format_time_abs,
    is_ip_address,
)
from mining_dashboard.service.egress import egress_posture_from_config, topology_from_config
from mining_dashboard.service.metrics import build_metrics, share_reject_pct
from mining_dashboard.service.update_checker import compute_update, parse_semver
from mining_dashboard.version import resolve_version

# The chart/window hub lives in web/charts.py (#1105). views.py stays the facade: the last two
# are re-exported unused so `server.py`'s existing `from ...web.views import` keeps resolving.
from mining_dashboard.web.charts import (
    _MAX_CHART_POINTS,
    _RANGE_SECONDS,
    _filter_events,
    build_chart,
    canonical_window,  # noqa: F401 — re-export for server.py
    parse_window,  # noqa: F401 — re-export for server.py
)

# The XvB/earnings/badges cluster lives in web/xvb_views.py (#1105). views.py stays the facade:
# build_state assembles these sections, build_hashrate uses the low-hashrate title, and
# service/telegram_commands.py imports build_badges from here.
from mining_dashboard.web.xvb_views import (
    _LOW_HR_TITLE,
    build_badges,
    build_earnings,
    build_earnings_vs_actual,
    build_xvb_calc,
    recent_wallet_change,
    xvb_current_tier_reward_day,
    xvb_expected_wins_day,
    xvb_forecast_tier_key,
    xvb_realization,
    xvb_tempered_day,
)

logger = logging.getLogger("WebViews")


# Pool/mode palette *tokens* -> CSS colour classes on the client (``.c-<token>``/``.bg-<token>``).
# The active pool is coloured, the inactive one muted (Issue #27).
_TOKEN_GREEN = "ok"  # P2Pool active  # noqa: S105 — CSS palette token, not a secret
_TOKEN_PURPLE = "purple"  # XvB active  # noqa: S105
_TOKEN_BLUE = "accent"  # split / neutral mode  # noqa: S105
_TOKEN_MUTED = "muted"  # inactive pool  # noqa: S105


# The XvB card's raffle-wins log shows the most recent wins only; the chart still gets every win
# in the selected range. Keeps a long-lived fleet's history from bloating every /api/state payload.
_RAFFLE_LOG_LIMIT = 20


def build_raffle_log(wins):
    """The XvB card's raffle-wins log: newest first, display-formatted, capped at
    ``_RAFFLE_LOG_LIMIT``. ``wins`` is ``StateManager.get_raffle_wins()`` output (oldest first)."""
    return [
        {
            "time": format_time_abs(w["ts"]),
            "tier": w["tier"],
            "hashrate": format_hashrate(w["hashrate"]),
            "height": w["height"],
        }
        for w in list(reversed(wins))[:_RAFFLE_LOG_LIMIT]
    ]


def build_raffle_eligibility(metrics):
    """Raffle-eligibility status — are you set up to both WIN and COLLECT an XvB payout? (#158)

    Green "Yes" requires XvB to be on plus BOTH gates:
    - **In a donor tier** — your CREDITED donation (XvB's avg_1h *and* avg_24h, via ``current_tier``,
      which clears on the lower of the two) has reached at least the lowest donor threshold, so you
      qualify for a donor round; and
    - **A P2Pool PPLNS share** — XvB calls this being a "VIP"; without it a win is skipped and you
      take a fail, regardless of tier.

    Shows "N/A (XvB off)" when XvB is disabled — there's no raffle to be eligible for. This is
    intentionally stricter than XvB's bare "VIP = just a share" so a green Yes means a win is paid.
    """
    if not metrics.xvb_enabled:
        return {"applies": False, "eligible": False, "label": "N/A (XvB off)"}
    # current_tier is get_tier_info(min(credited_1h, credited_24h)); "None" => below the lowest tier.
    in_tier = metrics.current_tier not in ("None", "Disabled")
    eligible = in_tier and metrics.shares_in_window > 0
    return {"applies": True, "eligible": eligible, "label": "Yes" if eligible else "No"}


def build_share_stats(share_stats, range_arg, window=None):
    """The persisted per-poll share-health deltas (#116) as chart-ready points, restricted to the
    selected range/window — same bounds as ``_filter_events`` — and bounded at
    ``_MAX_CHART_POINTS`` like the hashrate series (the default "all" range over the 30-day
    retention is ~86k rows, which /api/state would otherwise ship every poll). Each point is
    ``{x: ms epoch, a, r, i, e}`` (accepted/rejected/invalid/expired deltas for that interval).
    ``reject_pct_24h`` stays exact — it is computed from the raw rows, never this thinned series."""
    return [
        {
            "x": int(s["ts"] * 1000),
            "a": s.get("accepted", 0),
            "r": s.get("rejected", 0),
            "i": s.get("invalid", 0),
            "e": s.get("expired", 0),
        }
        for s in _downsample_share_stats(_filter_share_stats(share_stats, range_arg, window))
    ]


def _downsample_share_stats(rows, target=_MAX_CHART_POINTS):
    """Bucket the delta rows down to ``target`` points. Unlike ``_downsample_history`` (which
    averages a rate), the counts are per-interval DELTAS, so each bucket is **summed** — totals
    and the reject ratio survive thinning exactly. The bucket's mid-row timestamp positions the
    point, matching the hashrate downsampler."""
    if len(rows) <= target:
        return rows
    chunk_size = len(rows) / target
    out = []
    for i in range(target):
        chunk = rows[int(i * chunk_size) : int((i + 1) * chunk_size)]
        if not chunk:
            continue
        bucket = {"ts": chunk[len(chunk) // 2]["ts"]}
        for col in ("accepted", "rejected", "invalid", "expired"):
            bucket[col] = sum(r.get(col, 0) or 0 for r in chunk)
        out.append(bucket)
    return out


def _filter_share_stats(rows, range_arg, window=None):
    """Restrict share-stat deltas (#116) to the selected window — same bounds as
    ``_filter_events``, for the ``ts``-keyed delta rows."""
    if window is not None:
        lo, hi = window
        return [s for s in rows if lo <= s["ts"] <= hi]
    if range_arg == "all":
        return rows
    secs = _RANGE_SECONDS.get(range_arg, 0)
    if secs <= 0:
        return rows
    cutoff = time.time() - secs
    return [s for s in rows if s["ts"] >= cutoff]


def _window_reject_pct(rows, seconds):
    """Trailing reject rate over ``seconds`` from the delta series (#116), as a display string.
    "—" when no shares were submitted in the window (a 0% would read as falsely healthy)."""
    pct = share_reject_pct(rows, seconds)
    return "—" if pct is None else f"{pct:.2f}%"


# --------------------------------------------------------------------------------------
# #196 Tier-1 telemetry backbone: blocks / disk_growth / xvb_history surfaced on /api/state.
# The backbone (capture + storage + retention, PR #600) shipped without this exposure step —
# these three formatters are it. network_history and worker_history are Tier-2 (a separate
# slice of the epic) and are not exposed here.
# --------------------------------------------------------------------------------------


def _downsample_gauge_rows(rows, value_cols, target=_MAX_CHART_POINTS):
    """Bucket-average arbitrary point-in-time (gauge) columns down to ``target`` points.

    Mirrors ``_downsample_share_stats``, but averages instead of summing: these rows are
    periodic READINGS (disk size, XvB credited averages), not per-interval deltas, so summing
    them would inflate the series instead of thinning it. A no-op when already at/under target."""
    if len(rows) <= target:
        return rows
    chunk_size = len(rows) / target
    out = []
    for i in range(target):
        chunk = rows[int(i * chunk_size) : int((i + 1) * chunk_size)]
        if not chunk:
            continue
        bucket = {"ts": chunk[len(chunk) // 2]["ts"]}
        for col in value_cols:
            vals = [r.get(col, 0) or 0 for r in chunk]
            bucket[col] = round(sum(vals) / len(vals), 2)
        out.append(bucket)
    return out


def build_blocks(blocks, range_arg, window=None):
    """Persisted P2Pool block-found events (#196) as chart-ready points, restricted to the
    selected range/window (``_filter_events`` bounds any ts-keyed list, so this table reuses
    it as-is). A handful of rows a week — no downsampling needed."""
    return [
        {
            "x": int(b["ts"] * 1000),
            "height": b.get("height", 0),
            "difficulty": b.get("difficulty", 0),
        }
        for b in _filter_events(blocks, range_arg, window)
    ]


def build_payouts(state_mgr, range_arg, window=None):
    """Persisted confirmed payouts per chain as chart-ready points, restricted to the selected
    range/window like ``build_blocks`` (payout rows are ``ts``-keyed too). A confirmed Tari
    coinbase payout is the wallet's proof of a solo-found Tari block, so this series is what
    lets the client mark Tari income on a timeline (the mine cart train's purple coin; a chart
    series can reuse it). Amounts stay atomic (piconero / microTari) — the client only marks
    the moment, it does no coin math. Empty when payout confirmation is off or the wallet
    hasn't scanned yet; a handful of rows a week — no downsampling needed."""
    chains = (
        ("monero", config.PAYOUT_CONFIRM_ENABLED),
        ("tari", config.TARI_PAYOUT_CONFIRM_ENABLED),
    )
    return {
        chain: [
            {"x": int(p["ts"] * 1000), "amount": p.get("amount_atomic", 0)}
            for p in _filter_events(state_mgr.get_payouts(chain), range_arg, window)
        ]
        if enabled and state_mgr is not None
        else []
        for chain, enabled in chains
    }


def _gauge_series(rows, range_arg, window, value_cols):
    """Shared shape for a persisted gauge series (#196): filter to the selected range/window,
    bucket-average past ``_MAX_CHART_POINTS`` like ``share_stats``, and key each row's own
    ``value_cols`` under ``x`` (ms epoch). ``build_disk_growth``/``build_xvb_history`` are this
    with their own column set — the only thing that differs between them."""
    filtered = _downsample_gauge_rows(_filter_events(rows, range_arg, window), value_cols)
    return [{"x": int(r["ts"] * 1000), **{c: r.get(c, 0) for c in value_cols}} for r in filtered]


def build_disk_growth(rows, range_arg, window=None):
    """Persisted hourly monerod-DB-size + host-disk-usage samples (#196) as chart-ready points —
    the table keeps every row (no retention prune), so a long-lived install can otherwise pass
    the chart-point cap ``_gauge_series`` bounds it at."""
    return _gauge_series(
        rows, range_arg, window, ("monero_db_bytes", "disk_used_gb", "disk_total_gb")
    )


def build_xvb_history(rows, range_arg, window=None):
    """Persisted ~5-minute XvB-credited scalar samples (#196) as chart-ready points — the 30-day
    retention at this cadence is ~8.6k rows, well past the chart-point cap ``_gauge_series``
    bounds it at."""
    return _gauge_series(
        rows, range_arg, window, ("avg_1h", "avg_24h", "fail_count", "donation_fraction")
    )


# --------------------------------------------------------------------------------------
# Section builders: Metrics (+ passthrough) -> display data.
# --------------------------------------------------------------------------------------


def _mode_palette(current_mode):
    """(mode, p2p, xvb) palette tokens for the algo mode. Checked most-specific first:
    "XVB (Split)" contains both "Split" and "XVB"."""
    if "Split" in current_mode:
        return _TOKEN_BLUE, _TOKEN_GREEN, _TOKEN_PURPLE  # both pools active
    if "XVB" in current_mode:
        return _TOKEN_PURPLE, _TOKEN_MUTED, _TOKEN_PURPLE
    return _TOKEN_GREEN, _TOKEN_GREEN, _TOKEN_MUTED  # P2POOL


def build_hashrate(metrics, mode_tok, p2p_tok, xvb_tok):
    """The hashrate/mode/tier values shown across the dashboard, formatted from Metrics."""
    return {
        "mode_name": metrics.mode,
        "mode_variant": mode_tok,
        "total": format_hashrate(metrics.total_h15),
        "p2p_1h": format_hashrate(metrics.p2pool_1h),
        "p2p_24h": format_hashrate(metrics.p2pool_24h),
        "p2p_variant": p2p_tok,
        # Credited (XvB API) — Advanced card only (#156).
        "xvb_1h": format_hashrate(metrics.xvb_1h),
        "xvb_24h": format_hashrate(metrics.xvb_24h),
        # Routed (proxy v_xvb) — header / Simple / chart.
        "xvb_routed_1h": format_hashrate(metrics.xvb_routed_1h),
        "xvb_routed_24h": format_hashrate(metrics.xvb_routed_24h),
        "xvb_variant": xvb_tok,
        "tier": metrics.current_tier,
        "target_tier": metrics.target_tier,
        "xvb_fail_count": metrics.xvb_fail_count,
        "xvb_updated": format_time_abs(metrics.xvb_last_update),
        # Credited 1h/24h are frozen while the fetch is stale (#311) — the UI greys
        # them and flags the "Updated" line so the operator isn't misled by stale data.
        "xvb_stale": metrics.xvb_stale,
        "low_hr": {"text": "⚠ Hashrate low for tier", "title": _LOW_HR_TITLE}
        if metrics.low_hr_warning
        else None,
    }


def build_cadence(metrics):
    """Pool cadence & luck display values (#84). Formatting only — the figures live on Metrics.

    Durations (not localtime stamps) for the "since" figure so no timezone appears; ``available``
    gates luck/time-to-share, which are meaningless until there is hashrate history AND a pool
    difficulty (0 for the first samples after a wipe — never show inf/0s). ``weight`` is the
    miner's OWN PPLNS share-weight, not p2pool's pool-wide ``pplnsWeight``.
    """
    available = metrics.expected_share_sec > 0
    return {
        "last_block": format_time_abs(metrics.last_block_ts),
        "since_block": format_duration(time.time() - metrics.last_block_ts)
        if metrics.last_block_ts
        else "—",
        "tts": format_duration(metrics.expected_share_sec) if available else "—",
        "luck": f"{metrics.luck_pct:.0f}%" if available else "—",
        "weight": f"{metrics.own_pplns_weight:,.0f}",
        "available": available,
    }


def build_pool_network(data, metrics):
    """P2Pool / Stratum / Monero-network display values (computed bits come from Metrics)."""
    stratum = data.get("stratum", {})
    local_pool = data.get("pool", {}).get("pool", {})
    p2p = data.get("pool", {}).get("p2p", {})
    network = data.get("network", {})
    s_addr = stratum.get("wallet", "Unknown")
    # Relative, matching the cadence card's "Since Pool's Last Block": a bare HH:MM:SS with no
    # date or timezone cue two cards away from a real duration reads as a duration.
    last_block_ts = local_pool.get("last_block_ts", 0)
    last_blk = f"{format_duration(time.time() - last_block_ts)} ago" if last_block_ts else "Never"

    return {
        "stratum": {
            "h15": format_hashrate(metrics.stratum_h15),
            "h1h": format_hashrate(metrics.stratum_h1h),
            "h24h": format_hashrate(metrics.stratum_h24h),
            "shares": f"{stratum.get('shares_found', 0)} / {stratum.get('shares_failed', 0)}",
            "effort": f"{stratum.get('current_effort', 0):.1f}%",
            "total_shares": stratum.get("total_stratum_shares", 0),
            "reward_pct": f"{stratum.get('block_reward_share_percent', 0):.4f}%",
            "conns": stratum.get("connections", 0),
            "last_share": format_time_abs(stratum.get("last_share_found_time", 0)),
            "total_hashes": stratum.get("total_hashes", 0),
            "wallet": s_addr,
            "wallet_short": _shorten(s_addr),
        },
        "pool": {
            "type": metrics.pool_type,
            "sidechain_height": local_pool.get("sidechain_height", 0),
            "diff": f"{metrics.pool_difficulty / 1e6:.2f} M",
            "hr": format_hashrate(metrics.pool_hashrate),
            "total_hashes": local_pool.get("total_hashes", 0),
            "miners": local_pool.get("miners", 0),
            "pplns_win": f"{metrics.pplns_window} ({format_duration(metrics.pplns_window * metrics.block_time)})",
            "pplns_wgt": local_pool.get("pplns_weight", 0),
            "blocks": local_pool.get("blocks_found", 0),
            "last_blk": last_blk,
            "peers": f"{p2p.get('out_peers', 0)} / {p2p.get('in_peers', 0)}",
            "uptime": format_duration(p2p.get("uptime", 0)),
        },
        "network": {
            "height": metrics.network_height,
            "reward": f"{network.get('reward', 0) / 1e12:.4f} XMR",
            "diff": f"{metrics.network_difficulty / 1e9:.2f} G",
            "hash": _shorten(str(network.get("hash", "N/A")), threshold=20),
            "ts": format_time_abs(network.get("timestamp", 0)),
        },
        "monero": {
            "mode": metrics.monero_mode,
            "db_size": _monero_db_size(data.get("monero_sync", {})),
        },
        "shares_window": {"count": metrics.shares_in_window, "ok": metrics.shares_in_window > 0},
    }


def _monero_db_size(monero_sync):
    """Human-readable on-disk Monero DB size (Issue #32); em-dash when unknown."""
    db_bytes = monero_sync.get("db_size", 0) or 0
    return f"{db_bytes / 1e9:.1f} GB" if db_bytes > 0 else "—"


def _shorten(addr, keep=8, threshold=16):
    """Elide a long address to ``head...tail`` for compact display; short ones pass through."""
    return addr if len(addr) <= threshold else f"{addr[:keep]}...{addr[-keep:]}"


def _usage_level(percent, threshold=80):
    """'high' once a resource gauge crosses ``threshold``, else 'ok'."""
    return "high" if percent > threshold else "ok"


# Per-worker reject flag (Issue #82). Purely presentational: flag a worker once its rejected-share
# rate crosses _REJECT_FLAG_RATE *and* it has enough rejects to not just be early-run noise, so an
# operator can spot a misbehaving rig. A worker submitting all-rejects (rate 100%) still trips the
# noise floor, so it flags as soon as the floor is reached.
_REJECT_FLAG_RATE = 0.05  # >= 5% of submitted shares rejected
_REJECT_FLAG_MIN = 3  # and at least this many rejects


def _reject_flag(accepted, rejected):
    """A ``{text, title}`` warning flag for a high per-worker reject rate, or ``None``."""
    total = accepted + rejected
    if total <= 0 or rejected < _REJECT_FLAG_MIN:
        return None
    rate = rejected / total
    if rate < _REJECT_FLAG_RATE:
        return None
    return {"text": "⚠", "title": f"High reject rate: {rate * 100:.1f}% ({rejected} rejected)"}


def _num(v):
    """A number for display, or None for anything non-numeric (incl. bools, which JSON booleans
    would otherwise pass as 0/1). Every enriched RigForge field is nullable on the wire (#235)."""
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _fmt_num(v):
    """Trim a display number: drop a pointless ``.0`` so ``142.0 W`` reads ``142 W``."""
    return str(int(v)) if isinstance(v, float) and v.is_integer() else str(v)


def _rigforge_display(rf):
    """A ``{version, miner_down, chips, stats}`` view of a worker's parsed ``rigforge`` block, or
    ``None`` for a plain-xmrig worker (#235). Each metric is emitted ONLY when its data is present —
    a rig with no RAPL shows no power row, a disabled watchdog shows no watchdog row.

    Both outputs come from one pass so they can't drift: ``chips`` is the merged ``{text, variant,
    title}`` badge shape the compact Workers-Alive list renders, and ``stats`` is the same metrics
    split into ``{label, value, variant, title}`` for the Worker Inspect detail table (#507).
    Building the set (and its thresholds) here keeps the client a dumb renderer, matching the
    ``_reject_flag`` precedent."""
    if not rf:
        return None
    rows = []

    def add(label, value, chip, variant, title):
        rows.append(
            {"label": label, "value": value, "chip": chip, "variant": variant, "title": title}
        )

    if rf.get("miner_down"):
        add(
            "Miner",
            "down",
            "miner down",
            "bad",
            "RigForge is up but its XMRig API is unreachable — the rig is present but not mining. "
            "Live hashrate and uptime come from the proxy.",
        )

    health = rf.get("health") or {}
    if health.get("throttling") is True:
        add("CPU", "throttling", "throttling", "bad", "CPU is thermal/power throttling.")
    gov = health.get("governor")
    if gov:
        ok = gov == "performance"
        add(
            "Governor",
            gov,
            f"gov: {gov}",
            "ok" if ok else "warn",
            "CPU frequency governor"
            + ("" if ok else " — 'performance' is recommended for mining."),
        )
    hp = _num(health.get("hugepages_total"))
    if hp is not None:
        add(
            "HugePages",
            _fmt_num(hp),
            f"HP {_fmt_num(hp)}",
            "outline",
            f"HugePages allocated: {_fmt_num(hp)}.",
        )
    board = health.get("board")
    if board:
        add("Mainboard", board, board, "outline", "Mainboard (firmware).")

    power = rf.get("power") or {}
    watts = _num(power.get("watts"))
    hspw = _num(power.get("hs_per_watt"))
    if watts is not None or hspw is not None:
        parts = []
        if watts is not None:
            parts.append(f"{_fmt_num(round(watts, 1))} W")
        if hspw is not None:
            parts.append(f"{_fmt_num(round(hspw, 1))} H/s·W")
        text = " · ".join(parts)
        add("Power / efficiency", text, text, "outline", "Power draw / efficiency.")

    tune = rf.get("tune") or {}
    if tune.get("target"):
        add(
            "Tuning target",
            tune["target"],
            f"tune: {tune['target']}",
            "outline",
            "Active tuning target.",
        )
    if tune.get("autotune_enabled") and tune.get("autotune_next"):
        add(
            "Autotune",
            tune["autotune_next"],
            f"autotune → {tune['autotune_next']}",
            "outline",
            "Next scheduled autotune run.",
        )

    wd = rf.get("watchdog") or {}
    if wd.get("enabled"):
        temp = _num(wd.get("temp_c"))
        maxt = _num(wd.get("max_temp_c"))
        if wd.get("thermal_hold") is True:
            add(
                "Watchdog",
                "thermal hold",
                "thermal hold",
                "bad",
                "Watchdog is holding the rig back — temperature above its ceiling.",
            )
        elif temp is not None:
            text = f"{_fmt_num(round(temp, 1))}°C"
            if maxt is not None:
                text += f" / {_fmt_num(maxt)}°C"
            add("Temp / max", text, text, "outline", "Watchdog temperature / ceiling.")

    chips = [{"text": r["chip"], "variant": r["variant"], "title": r["title"]} for r in rows]
    stats = [
        {"label": r["label"], "value": r["value"], "variant": r["variant"], "title": r["title"]}
        for r in rows
    ]
    return {
        "version": rf.get("version"),
        "miner_down": bool(rf.get("miner_down")),
        "chips": chips,
        "stats": stats,
    }


def build_system(data):
    """System resource metrics (CPU, RAM, Disk, HugePages) as formatted values + level tokens.

    These thresholds are purely presentational (how to colour a gauge), so they live here
    rather than in the domain metrics layer."""
    system = data.get("system", {})

    disk_usage = system.get("disk", {})
    disk_used, disk_total, disk_unit = format_disk_size(
        disk_usage.get("used_gb", 0), disk_usage.get("total_gb", 0)
    )
    disk_percent = disk_usage.get("percent", 0)
    disk_fill = "critical" if disk_percent > 90 else "warning" if disk_percent > 70 else ""

    mem_usage = system.get("memory", {})
    cpu_str = system.get("cpu_percent", "0.0%")
    try:
        cpu_val = float(cpu_str.strip("%"))
    except ValueError:
        cpu_val = 0.0

    load_raw = system.get("load", "0.00 0.00 0.00")
    load_parts = load_raw.split()
    load_avg = (
        f"1m: {load_parts[0]} 5m: {load_parts[1]} 15m: {load_parts[2]}"
        if len(load_parts) == 3
        else load_raw
    )

    hp_status, hp_class, hp_val = system.get("hugepages", ["Disabled", "status-bad", "0/0"])

    return {
        "cpu": {"percent": cpu_str, "load": load_avg, "level": _usage_level(cpu_val)},
        "mem": {
            "used": f"{mem_usage.get('used_gb', 0):.1f}",
            "total": f"{mem_usage.get('total_gb', 0):.1f}",
            "percent": mem_usage.get("percent_str", "0%"),
            "level": _usage_level(mem_usage.get("percent", 0)),
        },
        "disk": {
            "used": disk_used,
            "total": disk_total,
            "unit": disk_unit,
            "percent": disk_usage.get("percent_str", "0%"),
            "width": f"{disk_percent}%",
            "fill": disk_fill,
            "level": _usage_level(disk_percent),
        },
        "hugepages": {
            "status": hp_status,
            "value": hp_val,
            "variant": "ok" if hp_class == "status-ok" else "bad",
        },
    }


def rigforge_update_for(worker, release):
    """The per-worker RigForge new-release callout (#596): ``{available, latest, url}`` or ``None``.

    Derived at the render seam from the rig's live reported version and the fleet-wide cached
    latest release — never stored, so it can't outlive its inputs (the #664 lesson: a rig running
    X must never badge "X available"). ``compute_update`` normalizes the rig's bare ``1.11.2``
    against the release tag's ``v1.11.2``. No reported version (plain xmrig, sister API off) or no
    cached release → ``None``, an honest "unknown", not a false "up to date"."""
    if not worker or not release:
        return None
    version = (worker.get("rigforge") or {}).get("version")
    if not version:
        return None
    return compute_update(version, release.get("tag"), release.get("url"))


def build_workers(workers, rigforge_release=None):
    """Worker rows as data: raw numeric fields (for client-side sorting) alongside their
    formatted display strings, plus a pool token for the badge. Online first, then by name."""
    rows = []
    sorted_workers = sorted(workers, key=lambda x: (x["status"] != "online", x["name"]))

    for worker in sorted_workers:
        try:
            active_pool = worker.get("active_pool", "")
            if any(p in active_pool for p in ["3333", "37889", "37888", "37890"]):
                pool = "p2pool"
            elif any(p in active_pool for p in ["3344", "4247"]):
                pool = "xvb"
            else:
                pool = "unknown"

            uptime = worker.get("uptime", 0)
            h60 = worker.get("h60", 0)
            h15 = worker.get("h15", 0)
            # Per-worker share health (Issue #82). Raw counts for client-side sorting; a display
            # string that appends invalid only when it's non-zero (keeps the common case clean);
            # and an optional warning flag the client renders when the reject rate is high.
            accepted = worker.get("accepted", 0)
            rejected = worker.get("rejected", 0)
            invalid = worker.get("invalid", 0)
            rejected_str = f"{rejected:,} (+{invalid:,} inv)" if invalid else f"{rejected:,}"
            rows.append(
                {
                    "name": worker["name"],
                    "ip": worker["ip"],
                    "ip_sort": _ip_to_sort_int(worker.get("ip", "0.0.0.0")),
                    "pool": pool,
                    "status": "online" if worker["status"] == "online" else "offline",
                    "uptime": uptime,
                    "uptime_str": format_duration(uptime),
                    # No h10 here: the table shows the 1m (h60) and 10m (h15) windows — via the
                    # proxy the legacy h10 field is just a second copy of the 1m rate (#387).
                    "h60": h60,
                    "h60_str": format_hashrate(h60),
                    "h15": h15,
                    "h15_str": format_hashrate(h15),
                    "accepted": accepted,
                    "accepted_str": f"{accepted:,}",
                    "rejected": rejected,
                    "rejected_str": rejected_str,
                    "invalid": invalid,
                    "reject_flag": _reject_flag(accepted, rejected),
                    # Worker-API probe verdict: False = configured probe failed (uptime/per-miner
                    # hashrate unavailable; the client badges it), True = ok, None = not probed
                    # (internal/invalid IP per the SSRF guard) — don't flag the unknown case.
                    "api_ok": worker.get("api_ok"),
                    # RigForge enriched feed (#235): version badge + health/power/tune/watchdog
                    # chips, or None for a plain-xmrig worker (renders nothing extra).
                    "rigforge": _rigforge_display(worker.get("rigforge")),
                    # {available, latest, url} | None — this rig runs an older RigForge (#596).
                    "rigforge_update": rigforge_update_for(worker, rigforge_release),
                }
            )
        except Exception as e:
            logger.error(f"Error processing worker {worker.get('name', 'unknown')}: {e}")
            continue
    return rows


# --------------------------------------------------------------------------------------
# Energy & profit calculator (Issue #260, Tari revenue #520): fleet power draw + efficiency, and —
# once the operator sets an electricity price (and an XMR price) — the net profit after power.
# Setting a Tari price too folds the estimated Tari merge-mining revenue into gross so a Tari
# merge-miner's net profit isn't silently undercounted (P2Pool-only was the #520 bug). The server
# totals the measured draw and publishes the prices; the client does the per-day/month/year
# arithmetic and the net = gross − cost, scaling gross with the same what-if hashrate the earnings
# card already uses (one source of truth, #61). Deliberately NO price feed for either coin: fetching
# one is a clearnet egress this privacy-first stack avoids (#160) — an opt-in Tor-routed feed is
# deferred, see #520 — so all prices are operator-supplied.
# --------------------------------------------------------------------------------------

_ENERGY_DISCLAIMER = (
    "Power draw is measured (RAPL, 15s sample) or your per-worker estimate; a worker reporting "
    "neither is excluded and the fleet total is marked incomplete. kWh and cost extrapolate the "
    "current draw at a constant rate — a naive projection, not a metered bill. Net profit is "
    "P2Pool XMR earnings valued at the XMR price in use (your configured price, or the live "
    "CoinGecko-over-Tor feed when dashboard.energy.price_feed is on), plus Tari merge-mining "
    "earnings valued at the Tari price when one is set (0/unset counts P2Pool XMR only) — minus "
    "power cost. XvB stays excluded: it's raffle status, not a clean per-day income estimate. "
    "Estimates, not guarantees."
)


def _worker_watts_config(name):
    """The operator's manual watts estimate for a worker name (#172 descriptor ``watts``), or None."""
    for entry in config.DASHBOARD_WORKERS:
        if entry["name"] == name:
            return entry.get("watts")
    return None


def build_energy(workers, prices=None):
    """Fleet energy inputs for the earnings card's Energy tab (Issue #260).

    Sums each worker's power draw — measured watts from the RigForge enriched feed (#235) first, else
    the operator's per-worker ``watts`` estimate (marked ``estimated``). A worker with neither is
    excluded and flips ``incomplete`` so the UI shows the total as a lower bound rather than counting
    it as zero. Fleet efficiency (H/s per watt) is the summed hashrate of the powered workers over
    their summed watts, so a worker with unknown draw skews neither number.

    Publishes the summed watts + prices; the client scales to kWh / cost / net per day·month·year
    (``computeEnergy`` in ``logic.mjs``). ``available`` is False only when no worker reports or is
    configured with any power — the card then shows nothing rather than a zero-watt fleet.

    ``prices`` is the live feed result (#520, ``state.prices`` — ``{xmr, tari, currency,
    fetched_at}`` or None). When the feed is enabled and has fetched, the live prices replace the
    static config numbers and ``price_source`` says so (with their age) — the calculator always
    states which price it's using. Until the first fetch (or with the feed off) the static config
    prices stand."""
    cfg = config.DASHBOARD_ENERGY
    live = prices if cfg["price_feed"] else None
    price_source = {
        # feed: the operator turned dashboard.energy.price_feed on; live: a fetch has landed.
        "feed": cfg["price_feed"],
        "live": bool(live),
        "age_sec": round(time.time() - live["fetched_at"]) if live else None,
    }
    xmr_price = live["xmr"] if live else cfg["xmr_price"]
    tari_price = live["tari"] if live else cfg["tari_price"]
    per_worker = []
    total_watts = 0.0
    powered_hs = 0.0
    incomplete = False
    for worker in workers:
        name = worker.get("name", "")
        rf = worker.get("rigforge") or {}
        power = rf.get("power") or {}
        watts = _num(power.get("watts"))
        estimated = False
        if watts is None or watts <= 0:
            cfg_watts = _worker_watts_config(name)
            watts = cfg_watts if (cfg_watts and cfg_watts > 0) else None
            estimated = watts is not None
        hs = _num(worker.get("h60")) or 0.0
        if watts is None:
            incomplete = True
            per_worker.append(
                {"name": name, "watts": None, "estimated": False, "hs": hs, "hs_per_watt": None}
            )
            continue
        total_watts += watts
        powered_hs += hs
        per_worker.append(
            {
                "name": name,
                "watts": round(watts, 1),
                "estimated": estimated,
                "hs": hs,
                "hs_per_watt": round(hs / watts, 2) if watts > 0 else None,
            }
        )
    have_power = total_watts > 0
    return {
        "available": have_power,
        "total_watts": round(total_watts, 1) if have_power else None,
        "hs_per_watt": round(powered_hs / total_watts, 2) if have_power else None,
        "incomplete": incomplete,
        "cost_per_kwh": cfg["cost_per_kwh"],
        "xmr_price": xmr_price,
        "tari_price": tari_price,
        "currency": cfg["currency"],
        "price_source": price_source,
        "per_worker": per_worker,
        "disclaimer": _ENERGY_DISCLAIMER,
    }


def build_proxy_summary(data):
    """Pool-wide share-health totals from the xmrig-proxy ``/summary`` (Issue #82): cumulative
    accepted/rejected/invalid/expired shares submitted to the upstream pool, the aggregate reject
    rate, and the best difficulty found. ``has_data`` is False until the proxy has been polled (no
    shares yet) so the client can hide an all-zero footer."""
    summary = data.get("proxy_summary", {}) or {}
    accepted = summary.get("accepted", 0) or 0
    rejected = summary.get("rejected", 0) or 0
    invalid = summary.get("invalid", 0) or 0
    expired = summary.get("expired", 0) or 0
    best = summary.get("best", 0) or 0

    total = accepted + rejected
    reject_pct = (rejected / total * 100) if total > 0 else 0.0
    return {
        "accepted": f"{accepted:,}",
        "rejected": f"{rejected:,}",
        "invalid": f"{invalid:,}",
        "expired": f"{expired:,}",
        "best": f"{int(best):,}" if best else "—",
        "reject_pct": f"{reject_pct:.2f}%",
        "reject_level": _usage_level(reject_pct, threshold=_REJECT_FLAG_RATE * 100),
        "has_data": (accepted + rejected + invalid) > 0,
    }


def _ip_to_sort_int(ip):
    """Pack a dotted-quad IP into an int for client-side numeric sorting; 0 on malformed input."""
    try:
        a, b, c, d = (int(part) for part in ip.split("."))
        return (a << 24) + (b << 16) + (c << 8) + d
    except (ValueError, IndexError, AttributeError):
        return 0


def build_tari(data):
    """Tari merge-mining display values. ``status`` is plain text; the client adds the ✔ only when
    ``connected`` (the gRPC merge-mine channel is actually READY), never merely when ``active``."""
    # This is the SINGLE place the effective Tari UI status is derived — `active`, the "Waiting..."
    # fallback, and the connected-gates-the-✔ rule. A duplicate that computed the same thing and then
    # discarded it lived (dead) in data_service and was removed in #280; keep this the only source so
    # the panel can't drift or go stale (#295).
    tari_stats = data.get("tari", {})
    tari_active = tari_stats.get("active", False)
    t_addr = tari_stats.get("address", "Unknown")

    return {
        "active": tari_active,
        "connected": bool(tari_stats.get("connected", False)) and tari_active,
        "status": tari_stats.get("status", "Waiting...") if tari_active else "Waiting...",
        "reward": f"{tari_stats.get('reward', 0):.2f} TARI",
        "height": str(tari_stats.get("height", 0)),
        "diff": f"{int(tari_stats.get('difficulty', 0)):,}",
        "wallet": t_addr,
        "wallet_short": _shorten(t_addr),
    }


def build_sync(metrics, monero_db_size):
    """Sync-screen state for both chains, mapping each SyncMetric to the client's 3-state
    gauge: 'done' (caught up — checked first, since a synced node may have no target height),
    'loading' (no target/data yet), else 'syncing'."""

    def section(sm, extra=None):
        state = "done" if sm.done else ("loading" if not sm.has_target else "syncing")
        out = {
            "state": state,
            "percent": sm.percent,
            "current": sm.current,
            "target": sm.target,
            "remaining": sm.remaining,
        }
        if extra:
            out.update(extra)
        return out

    # `local` (#1040) lives here: sync.* is the only per-node block covering BOTH chains.
    mono = {"mode": metrics.monero_mode, "db_size": monero_db_size, "local": metrics.monero_local}
    tari = {"local": metrics.tari_local}
    return {"monero": section(metrics.monero, mono), "tari": section(metrics.tari, tari)}


# --------------------------------------------------------------------------------------
# Assembly.
# --------------------------------------------------------------------------------------


def host_display_addr(host):
    """The numeric IP to show *beside* the configured host in the header, or ``None`` (Issue #119).

    The configured ``dashboard.host`` is often a hostname that won't resolve from another machine
    on the LAN (flaky mDNS/``.local``, no DNS entry), so we surface the host's primary IP next to
    it as a fallback way in. Returns ``None`` — meaning "show the host alone" — when there's
    nothing useful to add: the host is already an IP, the address can't be determined, or it just
    duplicates the host.
    """
    if is_ip_address(host):
        return None
    addr = detect_host_ipv4()
    if not addr or addr == host:
        return None
    return addr


def _egress_badge(summary):
    """Glanceable header badge for the egress posture (#170): green when Tor-only, red on a leak."""
    ok = summary["level"] == "ok"
    return {
        "variant": "ok" if ok else "bad",
        "text": "🛡️ Tor-only egress" if ok else f"⚠️ {summary['leaks']} clearnet egress",
        "title": summary["label"],
    }


def visible_update(update, running=None):
    """The new-release badge, only when it is self-consistent (#664).

    A restored snapshot can resurrect a pre-upgrade ``{available, latest, url}`` right after the
    upgrade it advertised — and "new release X available" while *running* X is contradictory by
    definition, whatever put it in the state. Suppress the badge whenever ``latest`` is not
    strictly newer than the running version. A dev build (unparseable running version) keeps the
    badge, mirroring ``compute_update``'s own semantics. Pure + unit-tested."""
    if not update:
        return None
    if running is None:
        running = (resolve_version() or {}).get("text")
    rv = parse_semver(running)
    lv = parse_semver(update.get("latest"))
    if rv and lv and lv <= rv:
        return None
    return update


def read_os_update_state():
    """The appliance OS-update state (step + post-reboot verdict), or ``None`` off an appliance.

    Host-written under a fixed name in the read-only results/ mount — only a Pithead OS
    appliance seeds it, so ``None`` doubles as "not an appliance: render no OS update control".
    Fail-silent on a missing/garbled file: the control degrades to absent, never a 500."""
    try:
        with open(config.OS_UPDATE_STATE_PATH) as f:
            state = json.load(f)
        return state if isinstance(state, dict) else None
    except (OSError, ValueError):
        return None


def build_state(data, state_mgr, range_arg, window=None, avg_window=DEFAULT_HASHRATE_WINDOW):
    """Assemble the full ``/api/state`` payload — the contract the client renders against.

    ``window`` is an optional ``(from, to)`` epoch-second manual-zoom window (Issue #47) that
    overrides ``range_arg`` for the chart. ``avg_window`` (#168) picks which hashrate-averaging
    window the chart plots. Computes domain values once (``build_metrics``), then
    formats each section. Every value is a JSON-serializable primitive, list or dict. May raise
    (e.g. ``state_mgr.get_history`` failing); the caller turns that into a sanitized 500."""
    data = data or {}
    history = state_mgr.get_history()
    share_stats = state_mgr.get_share_stats()  # per-poll share-health deltas (#116)
    raffle_wins = state_mgr.get_raffle_wins()  # rounds this wallet won, from XvB's winners file
    # Confirmed on-chain payouts (#381): fetched once when the view-only wallet feature is on (else
    # None), fed to both the earnings totals and the chart markers. config read at call time so
    # tests can flip the flag per-app.
    monero_payouts = state_mgr.get_payouts("monero") if config.PAYOUT_CONFIRM_ENABLED else None
    metrics = build_metrics(data, state_mgr, history)
    db_healthy = state_mgr.is_db_healthy()

    mode_tok, p2p_tok, xvb_tok = _mode_palette(metrics.mode)
    pool_net = build_pool_network(data, metrics)

    # Built once, consumed twice: the Earnings card reads the full payload, the expected-vs-actual
    # summary (#808) rolls the same figures up — one build, so the two can't disagree.
    earnings = build_earnings(
        data,
        metrics,
        payouts=monero_payouts,
        tari_payouts=(
            state_mgr.get_payouts("tari") if config.TARI_PAYOUT_CONFIRM_ENABLED else None
        ),
        xvb_day=xvb_current_tier_reward_day(metrics, state_mgr),
    )

    # XvB honesty figures (#866/#872), computed once and shared by the earnings summary and the
    # tier calculator so the two can never disagree: the forecast win rate from XvB's own winners
    # file, and the measured fraction of the published reward this wallet's wins actually paid.
    xvb_wins_day = xvb_realized = None
    if metrics.xvb_enabled:
        xvb_tiers = state_mgr.get_tiers()
        xvb_wins_day = xvb_expected_wins_day(
            state_mgr.get_xvb_round_stats(), xvb_forecast_tier_key(metrics, xvb_tiers), xvb_tiers
        )
        xvb_realized = xvb_realization(
            monero_payouts,
            raffle_wins,
            earnings["xvb_day"],
            xvb_wins_day,
            p2pool_day=earnings["coeff_day"] * metrics.p2pool_30d,
        )

    # Expected vs actual (#808) reads the published FACE value — it tempers its own XvB leg by
    # the measured factor and labels the untempered fallback face value in the tooltip — so it
    # is built before the calculator's copy is tempered below.
    earnings_summary = build_earnings_vs_actual(
        metrics,
        earnings,
        raffle_wins,
        expected_wins_day=xvb_wins_day,
        realization=xvb_realized,
    )
    # The calculator/energy copy (est.xvbDay) ships TEMPERED (#902): measured realization when
    # this wallet has one, else the delivery prior's midpoint — the raw published figure was the
    # last untempered money surface (a donating box's fiat net read ~3x high on the XvB addend).
    earnings["xvb_day"] = xvb_tempered_day(earnings["xvb_day"], xvb_realized)

    egress = egress_posture_from_config()  # per-component egress route + privacy roll-up (#170)
    topology = (
        topology_from_config()
    )  # full stack wiring for the topology panel (#170); shares summary
    badges = build_badges(
        data, metrics, mode_tok, db_healthy, wallet_change=recent_wallet_change(state_mgr)
    )
    badges.append(_egress_badge(egress["summary"]))  # glanceable Tor-only / leak header badge

    return {
        "syncing": metrics.global_syncing,
        "page_title": "Pithead Dashboard - Syncing"
        if metrics.global_syncing
        else "Pithead Dashboard",
        "host_ip": HOST_IP,
        "host_addr": host_display_addr(HOST_IP),
        # The operator-facing stratum port (#172) — feeds the "point your rigs at host:PORT" hint.
        "stratum_port": config.STRATUM_PORT,
        "version": resolve_version(),
        # {available, latest, url} | None — new-release badge (#224), self-consistency-guarded:
        # never advertise the version already running (#664).
        "update": visible_update(data.get("update")),
        # Whether the control channel is on (#33) — gates the header Upgrade button (#59). The
        # routes 404 when off, so this is display gating only, not a security control. Read at
        # call time (module attribute, not from-import) so tests can flip the flag per-app.
        "control_enabled": config.DASHBOARD_CONTROL_ENABLED,
        # Appliance OS-update state (step + verdict) | None off an appliance. Presence swaps the
        # header's tarball Upgrade button for the OS update control.
        "os_update": read_os_update_state(),
        # #559: use the snapshot's own timestamp, not now — a restored stale snapshot must
        # report its true age; falls back to now only when timestamp is missing/0.
        "last_update": format_time_abs(data.get("timestamp") or time.time()),
        "range": range_arg,
        "window": {"from": window[0], "to": window[1]} if window else None,
        "avg_window": avg_window,
        "avg_windows": HASHRATE_WINDOWS,
        "badges": badges,
        "db_healthy": db_healthy,
        "hashrate": build_hashrate(metrics, mode_tok, p2p_tok, xvb_tok),
        "system": build_system(data),
        "sync": build_sync(metrics, pool_net["monero"]["db_size"]),
        "stratum": pool_net["stratum"],
        "pool": pool_net["pool"],
        "network": pool_net["network"],
        "monero": pool_net["monero"],
        "shares_window": pool_net["shares_window"],
        "cadence": build_cadence(metrics),
        "raffle_eligible": build_raffle_eligibility(metrics),
        "raffle_wins": build_raffle_log(raffle_wins),
        "proxy_workers": metrics.workers_online,
        # Confirmed payouts (#381): the stored list rides in when the feature is on, else None
        # (feature off → earnings shows only the estimate). Built above, before the payload.
        "earnings": earnings,
        # Expected vs actual, one row per stream (#808) — the Simple view's earnings figure.
        # Built above, from the face-value earnings dict, before the #902 tempering.
        "earnings_summary": earnings_summary,
        "xvb_calc": build_xvb_calc(metrics, state_mgr, realization=xvb_realized),
        # On a backup stack, the XvB controller state last pulled from the primary (#249) — held as
        # standby, adopted only at failover. None on a single stack (nothing pulls). Inspectable so
        # an operator can confirm the backup is warm before it takes over.
        "xvb_standby": state_mgr.get_xvb_standby(),
        "tari": build_tari(data),
        "workers": build_workers(data.get("workers", []), data.get("rigforge_release")),
        # Fleet power draw / efficiency and (once a price is set) net profit after power (#260),
        # with live feed prices (#520) when dashboard.energy.price_feed is on.
        "energy": build_energy(data.get("workers", []), data.get("prices")),
        "proxy_summary": build_proxy_summary(data),
        # Persisted per-poll share-health deltas + trailing 24h reject rate (#116). Kept out of
        # proxy_summary so its (cumulative) shape stays unchanged for existing clients.
        "share_stats": build_share_stats(share_stats, range_arg, window),
        "reject_pct_24h": _window_reject_pct(share_stats, 24 * 3600),
        # #196 Tier-1 telemetry backbone exposure: block-found events, hourly disk-growth
        # samples, and ~5-min XvB-credited samples. No chart renders these yet — that's the
        # deliberate next slice — the payload just carries the persisted series.
        "blocks": build_blocks(state_mgr.get_blocks(), range_arg, window),
        # Confirmed payouts per chain as timeline points ({x: ms, amount: atomic}), same
        # range/window bounds as blocks. Feeds the mine cart train's Tari marker; empty lists
        # while payout confirmation is off.
        "payouts": build_payouts(state_mgr, range_arg, window),
        "disk_growth": build_disk_growth(state_mgr.get_disk_growth(), range_arg, window),
        "xvb_history": build_xvb_history(state_mgr.get_xvb_history(), range_arg, window),
        "egress": egress,
        "topology": topology,
        "chart": build_chart(
            history,
            data.get("shares", []),
            range_arg,
            window,
            avg_window,
            events=state_mgr.get_events(),
            raffle_wins=raffle_wins,
            payouts=monero_payouts,
        ),
    }


# --------------------------------------------------------------------------------------
# Static HTML shell (served at ``/``). No templated data — the client fetches ``/api/state``
# and renders. Cached, reloaded only if the file changes.
# --------------------------------------------------------------------------------------

SHELL_PATH = os.path.join(os.path.dirname(__file__), "templates", "index.html")
_SHELL_CACHE = None
_SHELL_MTIME = 0


def get_shell_html():
    """Return the cached index.html shell, reloading from disk only if it changed."""
    global _SHELL_CACHE, _SHELL_MTIME
    try:
        mtime = os.path.getmtime(SHELL_PATH)
        if _SHELL_CACHE is None or mtime > _SHELL_MTIME:
            with open(SHELL_PATH) as f:
                _SHELL_CACHE = f.read()
            _SHELL_MTIME = mtime
    except Exception as e:
        logger.error(f"Error loading shell: {e}")
    return _SHELL_CACHE or "<h1>Dashboard shell error</h1>"
