"""Prometheus text exposition (version 0.0.4) for the dashboard's ``/metrics`` endpoint (#379).

One pure function renders the live gauges from the same :class:`~mining_dashboard.service.metrics.Metrics`
snapshot ``/api/state`` consumes — raw H/s and 0/1 flags, no display formatting, no history
(the telemetry epic, #196, is about persisted series; this exports the current values only).
Hand-rendered on purpose: the format is ``# TYPE name gauge`` + ``name value`` lines, so a
``prometheus_client`` dependency would buy nothing.
"""


def _fmt(value):
    """One sample value as Prometheus text: bools as 0/1, ints bare, floats via repr
    (shortest round-trip, no precision loss on e.g. network difficulty)."""
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    return repr(float(value))


def render_prometheus(metrics, disk_percent, db_healthy):
    """Render the exposition body from a ``Metrics`` snapshot plus the two values that live
    outside it (raw disk percent from the system snapshot, DB health from the state manager)."""
    m = metrics
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
    ]
    lines = []
    typed = set()
    for name, labels, value in samples:
        if name not in typed:
            typed.add(name)
            lines.append(f"# TYPE {name} gauge")
        lines.append(f"{name}{labels} {_fmt(value)}")
    return "\n".join(lines) + "\n"
