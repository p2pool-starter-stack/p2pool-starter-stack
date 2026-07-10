"""Prometheus text exposition (version 0.0.4) for the dashboard's ``/metrics`` endpoint (#379).

One pure function renders the live gauges from the same :class:`~mining_dashboard.service.metrics.Metrics`
snapshot ``/api/state`` consumes — raw H/s and 0/1 flags, no display formatting, no history
(the telemetry epic, #196, is about persisted series; this exports the current values only).
Hand-rendered on purpose: the format is ``# TYPE name gauge`` + ``name value`` lines, so a
``prometheus_client`` dependency would buy nothing.
"""

import time

# Exposition content type. The version parameter tells scrapers this is the 0.0.4 text format.
CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"


def _fmt(value):
    """One sample value as Prometheus text: bools as 0/1, ints bare, floats via repr
    (shortest round-trip, no precision loss on e.g. network difficulty)."""
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    return repr(float(value))


def render_prometheus(
    metrics,
    disk_percent,
    db_healthy,
    *,
    reject_pct_1h=None,
    shares_accepted=0,
    shares_rejected=0,
    pool_blocks_found=0,
    snapshot_ts=0.0,
    now=None,
):
    """Render the exposition body from a ``Metrics`` snapshot plus the values that live outside
    it: raw disk percent from the system snapshot, DB health from the state manager, the
    trailing-1h reject rate (``share_reject_pct`` — ``None`` when no shares were submitted, in
    which case the sample is omitted rather than lying 0%), the proxy's cumulative
    accepted/rejected share counters, p2pool's cumulative blocks-found counter, and the data
    loop's snapshot timestamp — exposed as ``pithead_snapshot_age_seconds`` so a wedged loop
    stops scraping as healthy. ``now`` is injectable for tests."""
    m = metrics
    age = max(0.0, (now if now is not None else time.time()) - (snapshot_ts or 0))
    samples = [
        ("pithead_hashrate_15m_hs", "", m.total_h15),
        ("pithead_p2pool_hashrate_hs", '{window="1h"}', m.p2pool_1h),
        ("pithead_p2pool_hashrate_hs", '{window="24h"}', m.p2pool_24h),
        ("pithead_xvb_routed_hashrate_hs", '{window="1h"}', m.xvb_routed_1h),
        ("pithead_xvb_routed_hashrate_hs", '{window="24h"}', m.xvb_routed_24h),
        ("pithead_xvb_credited_hashrate_hs", '{window="1h"}', m.xvb_1h),
        ("pithead_xvb_credited_hashrate_hs", '{window="24h"}', m.xvb_24h),
        ("pithead_stratum_hashrate_hs", '{window="15m"}', m.stratum_h15),
        ("pithead_stratum_hashrate_hs", '{window="1h"}', m.stratum_h1h),
        ("pithead_stratum_hashrate_hs", '{window="24h"}', m.stratum_h24h),
        ("pithead_workers_online", "", m.workers_online),
        ("pithead_workers_total", "", m.workers_total),
        ("pithead_shares_in_window", "", m.shares_in_window),
        ("pithead_pplns_window_blocks", "", m.pplns_window),
        ("pithead_pool_hashrate_hs", "", m.pool_hashrate),
        ("pithead_pool_difficulty", "", m.pool_difficulty),
        ("pithead_network_difficulty", "", m.network_difficulty),
        ("pithead_network_height", "", m.network_height),
        ("pithead_node_sync_percent", '{chain="monero"}', m.monero.percent),
        ("pithead_node_sync_percent", '{chain="tari"}', m.tari.percent),
        ("pithead_node_down", '{chain="monero"}', m.monero.down),
        ("pithead_node_down", '{chain="tari"}', m.tari.down),
        ("pithead_syncing", "", m.global_syncing),
        ("pithead_tari_mining", "", m.tari_mining),
        ("pithead_xvb_stale", "", m.xvb_stale),
        ("pithead_xvb_enabled", "", m.xvb_enabled),
        ("pithead_disk_used_percent", "", disk_percent),
        ("pithead_db_healthy", "", db_healthy),
        ("pithead_luck_pct", "", m.luck_pct),
        ("pithead_expected_share_seconds", "", m.expected_share_sec),
        ("pithead_snapshot_age_seconds", "", age),
    ]
    if reject_pct_1h is not None:
        samples.append(("pithead_share_reject_pct", '{window="1h"}', reject_pct_1h))
    counters = [
        ("pithead_shares_accepted_total", "", shares_accepted),
        ("pithead_shares_rejected_total", "", shares_rejected),
        ("pithead_pool_blocks_found_total", "", pool_blocks_found),
    ]
    lines = []
    typed = set()
    for family, metric_type in ((samples, "gauge"), (counters, "counter")):
        for name, labels, value in family:
            if name not in typed:
                typed.add(name)
                lines.append(f"# TYPE {name} {metric_type}")
            lines.append(f"{name}{labels} {_fmt(value)}")
    return "\n".join(lines) + "\n"
