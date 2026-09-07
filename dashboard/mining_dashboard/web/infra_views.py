"""Host, rig and node status sections for the dashboard: the ``/api/state`` blocks that describe
the machines and services the stack runs on, as opposed to its pool economics.

Split out of ``web/views.py`` (#1105): the host system gauges (Issue #32), the per-worker rig rows
with their RigForge release callout (#596) and reject flag (#82), the fleet energy and profit inputs
(#260, Tari revenue #520), the xmrig-proxy summary, the Tari node block and the per-chain sync
display (#1040). ``views.py`` stays the facade — ``build_state`` assembles these sections and
``web/worker_detail.py`` imports the two RigForge helpers from there — so the move is invisible to
consumers.

Presentation only, per Issue #61: domain values are computed in ``service/metrics.py``; this layer
formats at the edge and emits tokens the client maps to CSS, never HTML.
"""

import logging
import time

from mining_dashboard.config import config
from mining_dashboard.helper.utils import format_disk_size, format_duration, format_hashrate
from mining_dashboard.service.update_checker import compute_update

# Same logger name as views.py on purpose: these sections were emitting under "WebViews" before the
# split and a rename would silently change every operator's log output.
logger = logging.getLogger("WebViews")


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
                    # Probe verdict + adoption (#1857): the client flags only api_ok False, and
                    # adopted decides whether that reads "api ⚠" (config to fix) or "not adopted".
                    "api_ok": worker.get("api_ok"),
                    "adopted": worker.get("adopted"),
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


def _ip_to_sort_int(ip) -> int:
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
