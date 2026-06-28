"""Generate a representative /api/state payload fixture for the frontend render tests.

Run from build/dashboard:  uv run --extra test python tests/frontend/fixtures/_gen_state.py
Writes tests/frontend/fixtures/state.json — a real build_state() payload (the exact contract the
Preact client renders), so the JS smoke tests run against the true server shape rather than a
hand-built guess. Regenerate when the payload contract changes.
"""

import json
import time
from pathlib import Path
from unittest.mock import MagicMock

import mining_dashboard.web.views as views

HISTORY = [
    {"timestamp": int(time.time()) - 600, "v": 10200, "v_p2pool": 8000, "v_xvb": 2200, "t": "a"},
    {"timestamp": int(time.time()) - 300, "v": 10500, "v_p2pool": 8100, "v_xvb": 2400, "t": "b"},
]

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
    },
]


def _state_mgr():
    sm = MagicMock()
    sm.get_history.return_value = HISTORY
    sm.get_xvb_stats.return_value = {"current_mode": "P2POOL"}
    sm.get_tiers.return_value = {}
    sm.is_db_healthy.return_value = True
    return sm


def main():
    data = {
        "shares": [{"ts": int(time.time()) - 120}],
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
