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
    format_duration,
    format_hashrate,
    format_time_abs,
)
from mining_dashboard.service.egress import egress_posture_from_config, topology_from_config
from mining_dashboard.service.metrics import build_metrics
from mining_dashboard.service.update_checker import parse_semver
from mining_dashboard.version import resolve_version

# The chart/window hub lives in web/charts.py (#1105). views.py stays the facade: the last two
# are re-exported unused so `server.py`'s existing `from ...web.views import` keeps resolving.
from mining_dashboard.web.charts import (
    _filter_events,  # noqa: F401 — re-export for worker_detail.py
    build_chart,
    canonical_window,  # noqa: F401 — re-export for server.py
    parse_window,  # noqa: F401 — re-export for server.py
)

# The header's address block lives in web/header.py (#1853): the hostname/IP line and the
# .onion URL under it are ways IN to the machine, not readings off it.
from mining_dashboard.web.header import dashboard_onion, host_display_addr

# The host/rig/node status sections live in web/infra_views.py (#1105). views.py stays the
# facade: build_state assembles these sections, build_pool_network uses the address elider, and
# the last two are re-exported unused so web/worker_detail.py's existing import keeps resolving.
from mining_dashboard.web.infra_views import (
    _rigforge_display,  # noqa: F401 — re-export for worker_detail.py
    _shorten,
    build_energy,
    build_proxy_summary,
    build_sync,
    build_system,
    build_tari,
    build_workers,
    rigforge_update_for,  # noqa: F401 — re-export for worker_detail.py
)

# The time-series sections live in web/series_views.py (#1105). views.py stays the facade:
# build_state assembles these sections and reads the palette and the window reject rate, and
# _gauge_series is re-exported unused so web/worker_detail.py's existing import keeps resolving.
from mining_dashboard.web.series_views import (
    _gauge_series,  # noqa: F401 — re-export for worker_detail.py
    _mode_palette,
    _window_reject_pct,
    build_blocks,
    build_cadence,
    build_disk_growth,
    build_hashrate,
    build_payouts,
    build_share_stats,
    build_xvb_history,
)

# The XvB/earnings/badges cluster lives in web/xvb_views.py (#1105). views.py stays the facade:
# build_state assembles these sections, build_hashrate uses the low-hashrate title, and
# service/telegram_commands.py imports build_badges from here.
from mining_dashboard.web.xvb_views import (
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


# --------------------------------------------------------------------------------------
# Assembly.
# --------------------------------------------------------------------------------------


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


def read_os_update_state() -> dict | None:
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
        # {url, client_auth} | None — the dashboard's Tor way in (#1853), shown under the host
        # line. None whenever the onion is off or not yet provisioned, so the header renders
        # nothing rather than an empty row. Never carries client-auth key material.
        "dashboard_onion": dashboard_onion(),
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
