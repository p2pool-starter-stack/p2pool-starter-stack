import json
from unittest.mock import patch

import mining_dashboard.collector.pools as pools
from mining_dashboard.collector.pools import (
    detect_pool_type,
    get_network_stats,
    get_p2pool_stats,
    get_stratum_stats,
    get_tari_stats,
)
from mining_dashboard.config.config import (
    P2P_STATS_PATH,
    POOL_STATS_PATH,
    SECOND_PER_BLOCK_MAIN,
    STRATUM_STATS_PATH,
)
from mining_dashboard.service.data_service import _shares_to_record


class TestDetectPoolType:
    def test_empty_is_unknown(self):
        assert detect_pool_type([]) == "Unknown"
        assert detect_pool_type(None) == "Unknown"

    def test_majority_wins(self):
        assert detect_pool_type(["1.1.1.1:37889", "2.2.2.2:37889", "3.3.3.3:37888"]) == "Main"
        assert detect_pool_type(["1.1.1.1:37888"]) == "Mini"
        assert detect_pool_type(["1.1.1.1:37890"]) == "Nano"

    def test_unknown_ports(self):
        assert detect_pool_type(["1.1.1.1:9999"]) == "Unknown"

    def test_port_matched_exactly_not_as_substring(self):
        # The port must match exactly (last colon-segment), not as a substring of the peer string.
        # Each of these returned a WRONG pool under the old `"37889" in p` substring check (#142).
        assert detect_pool_type(["1.1.1.1:137889"]) == "Unknown"  # old: contained "37889" -> Main
        assert detect_pool_type(["1.1.1.1:378880"]) == "Unknown"  # old: contained "37888" -> Mini
        assert (
            detect_pool_type(["1.1.1.1:37889x"]) == "Unknown"
        )  # trailing junk -> not the Main port
        assert detect_pool_type(["1.1.1.1:37888"]) == "Mini"  # exact port still detected


def _read_json_map(mapping):
    """Return a side_effect that maps a stats path to a fixture dict."""
    return lambda path: mapping.get(path, {})


class TestP2poolStats:
    def test_aggregates_sources(self):
        mapping = {
            P2P_STATS_PATH: {
                "peers": ["1.1.1.1:37889"],
                "connections": 8,
                "incoming_connections": 2,
            },
            POOL_STATS_PATH: {
                "pool_statistics": {"hashRate": 1234, "miners": 5, "pplnsWindowSize": 2160}
            },
            STRATUM_STATS_PATH: {"last_share_found_time": 99, "shares_found": 7},
        }
        with patch.object(pools, "_read_json", side_effect=_read_json_map(mapping)):
            s = get_p2pool_stats()
        assert s["p2p"]["type"] == "Main"
        assert s["p2p"]["out_peers"] == 8
        assert s["pool"]["hashrate"] == 1234
        assert s["pool"]["pplns_window"] == 2160
        assert s["pool"]["shares_found"] == 7
        assert s["pool"]["last_share_time"] == 99

    def test_empty_files_give_defaults(self):
        with patch.object(pools, "_read_json", return_value={}):
            s = get_p2pool_stats()
        assert s["p2p"]["type"] == "Unknown"
        assert s["pool"]["hashrate"] == 0

    def test_missing_pplns_window_key_omitted(self):
        # A failed pool-stats read (raw_pool == {}) must leave "pplns_window" OUT of the dict
        # entirely, not fill it with 0 — a materialized 0 defeats every downstream
        # `.get("pplns_window", DEFAULT_PPLNS_WINDOW)` fallback (#547).
        with patch.object(pools, "_read_json", return_value={}):
            s = get_p2pool_stats()
        assert "pplns_window" not in s["pool"]


class TestNetworkStats:
    def test_hashrate_derived_when_missing(self):
        with patch.object(pools, "_read_json", return_value={"difficulty": 1200, "height": 10}):
            s = get_network_stats()
        assert s["hash"] == 1200 / SECOND_PER_BLOCK_MAIN
        assert s["height"] == 10

    def test_hashrate_passthrough(self):
        with patch.object(pools, "_read_json", return_value={"difficulty": 1200, "hash": 999}):
            assert get_network_stats()["hash"] == 999


class TestStratumStats:
    def test_returns_raw_json(self):
        raw = {"workers": ["10.0.0.1:3333,x,y,z,rig-01"]}
        with patch.object(pools, "_read_json", return_value=raw):
            assert get_stratum_stats() == raw


class TestTariStats:
    def test_active_chain_converts_utari(self):
        raw = {
            "chains": [
                {
                    "channel_state": "READY",
                    "wallet": "T123",
                    "height": 5,
                    "reward": 2_000_000,
                    "difficulty": 42,
                }
            ]
        }
        with patch.object(pools, "_read_json", return_value=raw):
            s = get_tari_stats()
        assert s["active"] is True
        assert s["reward"] == 2.0  # 2_000_000 uTari -> 2 Tari
        assert s["status"] == "READY"
        assert s["connected"] is True  # gRPC channel READY -> drives the ✔

    def test_unhealthy_channel_is_active_but_not_connected(self):
        # A configured chain whose gRPC channel is down (e.g. dialled through Tor and rejected) must
        # report active=True (so the panel shows) but connected=False (so the UI shows no ✔).
        raw = {"chains": [{"channel_state": "TRANSIENT_FAILURE", "wallet": "T123"}]}
        with patch.object(pools, "_read_json", return_value=raw):
            s = get_tari_stats()
        assert s["active"] is True
        assert s["status"] == "TRANSIENT_FAILURE"
        assert s["connected"] is False

    def test_no_chains_inactive(self):
        with patch.object(pools, "_read_json", return_value={}):
            assert get_tari_stats() == {"active": False}


class TestReadJson:
    def test_missing_file_returns_empty(self, tmp_path):
        assert pools._read_json(str(tmp_path / "nope.json")) == {}

    def test_malformed_json_returns_empty(self, tmp_path):
        bad = tmp_path / "bad.json"
        bad.write_text("{not valid")
        assert pools._read_json(str(bad)) == {}

    def test_valid_json(self, tmp_path):
        good = tmp_path / "good.json"
        good.write_text('{"a": 1}')
        assert pools._read_json(str(good)) == {"a": 1}

    def test_read_failure_after_a_good_parse_serves_last_good(self, tmp_path):
        # #547: p2pool rewrites these files in place, so a poll can catch one mid-write. That
        # must serve the LAST successful parse, not {} — {} looks like a real reset to callers.
        path = tmp_path / "stratum"
        path.write_text('{"shares_found": 500}')
        assert pools._read_json(str(path)) == {"shares_found": 500}

        path.write_text("{not valid")  # caught mid-write
        assert pools._read_json(str(path)) == {"shares_found": 500}

        path.write_text('{"shares_found": 505}')  # write completes, next poll sees it
        assert pools._read_json(str(path)) == {"shares_found": 505}

    def test_never_parsed_still_returns_empty(self, tmp_path):
        # No good parse to fall back to yet -> {} unchanged, no crash (#547 acceptance: the
        # never-read case must behave exactly as before).
        bad = tmp_path / "bad.json"
        bad.write_text("{not valid")
        assert pools._read_json(str(bad)) == {}
        assert pools._read_json(str(tmp_path / "nope.json")) == {}


class TestPollSequenceReplay:
    """#547: a mid-write read race on p2pool's stats files must not replay the cumulative
    shares_found counter as fresh PPLNS shares, and must not blank pplns_window to 0."""

    def _point_at_tmp(self, tmp_path, monkeypatch):
        pool_path = tmp_path / "pool_stats"
        stratum_path = tmp_path / "stratum"
        p2p_path = tmp_path / "p2p"
        monkeypatch.setattr(pools, "POOL_STATS_PATH", str(pool_path))
        monkeypatch.setattr(pools, "STRATUM_STATS_PATH", str(stratum_path))
        monkeypatch.setattr(pools, "P2P_STATS_PATH", str(p2p_path))
        p2p_path.write_text("{}")
        return pool_path, stratum_path

    def test_good_fail_good_records_only_the_delta_and_keeps_the_window(
        self, tmp_path, monkeypatch
    ):
        pool_path, stratum_path = self._point_at_tmp(tmp_path, monkeypatch)

        def write_good(shares_total):
            pool_path.write_text(json.dumps({"pool_statistics": {"pplnsWindowSize": 2160}}))
            stratum_path.write_text(
                json.dumps({"shares_found": shares_total, "last_share_found_time": 1})
            )

        # Poll 1: good read, cumulative total 500 -> baselines, records nothing (#129).
        write_good(500)
        s1 = get_p2pool_stats()
        recorded, baseline = _shares_to_record(None, s1["pool"]["shares_found"])
        total_recorded = recorded
        assert s1["pool"]["pplns_window"] == 2160

        # Poll 2: both stats files caught mid-write -> JSONDecodeError on each.
        pool_path.write_text("{not valid")
        stratum_path.write_text("{not valid")
        s2 = get_p2pool_stats()
        recorded, baseline = _shares_to_record(baseline, s2["pool"]["shares_found"])
        total_recorded += recorded
        assert s2["pool"]["shares_found"] == 500  # last-good served, NOT 0
        assert s2["pool"]["pplns_window"] == 2160  # last-good served, NEVER 0

        # Poll 3: write completes, cumulative total 505 (5 real shares since poll 1).
        write_good(505)
        s3 = get_p2pool_stats()
        recorded, baseline = _shares_to_record(baseline, s3["pool"]["shares_found"])
        total_recorded += recorded

        assert total_recorded == 5  # not 505: the read-race poll never replayed the counter
        assert baseline == 505

    def test_never_read_case_unchanged(self, tmp_path, monkeypatch):
        # First poll ever fails (files don't exist yet) -> {} behavior, no crash, no shares.
        self._point_at_tmp(tmp_path, monkeypatch)
        s = get_p2pool_stats()
        assert s["pool"]["shares_found"] == 0
        assert "pplns_window" not in s["pool"]
        recorded, baseline = _shares_to_record(None, s["pool"]["shares_found"])
        assert (recorded, baseline) == (0, 0)
