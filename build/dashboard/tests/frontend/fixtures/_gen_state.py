"""Generate a representative /api/state payload fixture for the frontend render tests.

Run from build/dashboard:  uv run --extra test python tests/frontend/fixtures/_gen_state.py
Writes tests/frontend/fixtures/state.json — a real build_state() payload (the exact contract the
Preact client renders), so the JS smoke tests run against the true server shape rather than a
hand-built guess. Regenerate when the payload contract changes.
"""

import json
import os
import time
from pathlib import Path
from unittest.mock import MagicMock

import mining_dashboard.web.views as views

# Pin everything machine- or time-dependent so the fixture regenerates identically on any box.
# build_state stamps last_update via time.localtime(time.time()) and the chart x-axis is
# now-relative, so freeze NOW (2025-01-01 00:00:00 UTC) + patch views.time.time and force UTC
# for the localtime-based last_update string. host_addr is a live socket lookup
# (detect_host_ipv4) and host_ip an env default — pin both too.
os.environ["TZ"] = "UTC"
time.tzset()
NOW = 1735689600

views.time.time = lambda: NOW  # build_state's last_update + history cutoff
views.HOST_IP = "Unknown Host"
views.detect_host_ipv4 = lambda: "100.68.38.126"

HISTORY = [
    {"timestamp": NOW - 600, "v": 10200, "v_p2pool": 8000, "v_xvb": 2200, "t": "a"},
    {"timestamp": NOW - 300, "v": 10500, "v_p2pool": 8100, "v_xvb": 2400, "t": "b"},
]

# `h60` + the RigForge enriched `power` block feed build_energy (#260), so the fixture carries an
# available energy block (watts, efficiency) for the EarningsCard Energy-tab render tests.
WORKERS = [
    {
        "name": "rig-alpha",
        "ip": "192.168.1.10",
        "status": "online",
        "active_pool": "3333",
        "accepted": 1200,
        "rejected": 1,
        "hashrate_10s": 5200,
        "hashrate_1m": 5100,
        "hashrate_15m": 5000,
        "h60": 5100,
        "rigforge": {"power": {"watts": 142.0, "hs_per_watt": 35.9}},
    },
    {
        "name": "rig-bravo",
        "ip": "192.168.1.11",
        "status": "offline",
        "active_pool": "3333",
        "accepted": 800,
        "rejected": 40,
        "hashrate_10s": 0,
        "hashrate_1m": 0,
        "hashrate_15m": 4800,
        "h60": 4800,
        "rigforge": {"power": {"watts": 143.0, "hs_per_watt": 33.6}},
    },
]


def _state_mgr():
    sm = MagicMock()
    sm.get_history.return_value = HISTORY
    sm.get_xvb_stats.return_value = {"current_mode": "P2POOL"}
    # Real tiers + XvB's published per-tier reward estimates (#118) so the fixture carries the true
    # xvb_calc contract the client renders the tier-payout dropdown against (frozen sample values).
    sm.get_tiers.return_value = {
        "donor_mega": 1_000_000,
        "donor_whale": 100_000,
        "donor_vip": 10_000,
        "donor": 1_000,
    }
    sm.get_xvb_reward_estimates.return_value = {
        "estimates": {"donor": 0.06, "donor_vip": 0.81, "donor_whale": 6.17, "donor_mega": 56.9},
        "last_update": NOW,
    }
    # One recorded XvB raffle win (inside the chart window) so the fixture carries both the
    # chart's gold-star marker and the XvB card's wins-log row.
    sm.get_raffle_wins.return_value = [
        {
            "ts": NOW - 600,
            "hashrate": 4.2e6,
            "height": 3720833,
            "block_id": "0525a913e879",
            "tier": "donor_whale",
        }
    ]
    sm.is_db_healthy.return_value = True
    return sm


def main():
    data = {
        "shares": [{"ts": NOW - 120}],
        "workers": WORKERS,
        "global_sync": False,
        "total_live_h15": 10000,
        "monero_sync": {"percent": 100, "current": 3000000, "target": 3000000},
        "tari_sync": {"percent": 100, "current": 50000, "target": 50000},
        "update": {"available": True, "latest": "v9.9.9", "url": "https://example/releases/v9.9.9"},
    }
    state = views.build_state(data, _state_mgr(), "all")
    out = Path(__file__).with_name("state.json")
    out.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
