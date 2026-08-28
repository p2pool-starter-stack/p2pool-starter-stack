"""Time-series sections for the dashboard: the ``/api/state`` blocks that carry a *history* rather
than a current reading — share health, blocks, payouts, disk growth, XvB history — plus the two
headline rate cards, hashrate and cadence, that summarise the same series.

Split out of ``web/views.py`` (#1105). What lives here is the persisted per-poll share-health
deltas (#116), the Tier-1 telemetry backbone's three formatters (#196), the pool/mode palette
tokens (#27) and the hashrate and cadence cards. They share the chart hub's downsampling bounds
and range filter, so they sit together rather than beside the point-in-time status sections.
``views.py`` stays the facade — ``build_state`` assembles these sections and
``web/worker_detail.py`` imports the gauge-series helper from there — so the move is invisible to
consumers.

Presentation only, per Issue #61: domain values are computed in ``service/metrics.py``; this layer
formats at the edge and emits tokens the client maps to CSS, never HTML.
"""

import time

from mining_dashboard.config import config
from mining_dashboard.helper.utils import format_duration, format_hashrate, format_time_abs
from mining_dashboard.service.metrics import share_reject_pct
from mining_dashboard.web.charts import _MAX_CHART_POINTS, _RANGE_SECONDS, _filter_events
from mining_dashboard.web.xvb_views import _LOW_HR_TITLE

# Pool/mode palette *tokens* -> CSS colour classes on the client (``.c-<token>``/``.bg-<token>``).
# The active pool is coloured, the inactive one muted (Issue #27).
_TOKEN_GREEN = "ok"  # P2Pool active  # noqa: S105 — CSS palette token, not a secret
_TOKEN_PURPLE = "purple"  # XvB active  # noqa: S105
_TOKEN_BLUE = "accent"  # split / neutral mode  # noqa: S105
_TOKEN_MUTED = "muted"  # inactive pool  # noqa: S105


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
