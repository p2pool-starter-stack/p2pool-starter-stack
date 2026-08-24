# Covers the rig's own writable config, carried off the enriched RigForge feed for the editor
# prefill (#1235).
import json

from mining_dashboard.client.xmrig_client import parse_rigforge


class TestRigWritableConfig:
    """The rig's own writable config, carried off the enriched feed for the editor prefill (#1235)."""

    def _block(self, cfg):
        payload = {"rigforge": {"version": "1.10.0", "config": cfg}}
        return parse_rigforge(payload)["config"]

    def test_writable_config_is_carried_through(self):
        cfg = {
            "pools": [{"url": "rig:3333", "user": "48edf", "keepalive": True}],
            "DONATION": 1,
            "autotune": "performance",
            "watchdog": "enabled",
            "watchdog_interval_min": 5,
            "max_temp_c": 85,
        }
        assert self._block(cfg) == cfg

    def test_a_rig_that_sends_no_config_block_yields_none(self):
        # RigForge older than the release that added it: the editor must fall back, not show empty
        # boxes as if they were the rig's values.
        assert parse_rigforge({"rigforge": {"version": "1.10.0"}})["config"] is None
        assert self._block(None) is None
        assert self._block({}) is None
        assert self._block("not-a-dict") is None

    def test_keys_outside_the_writable_allowlist_are_dropped(self):
        # This prefills an editor whose contents can be POSTed back at the rig. A key the apply
        # path would reject anyway can only mislead, so it never reaches the UI.
        out = self._block({"DONATION": 2, "ACCESS_TOKEN": "s3cret", "api_port": 8081, "pools": []})
        # An empty pools list is a real value the rig is running, so it survives; the two
        # non-writable keys do not.
        assert out == {"DONATION": 2, "pools": []}
        assert "ACCESS_TOKEN" not in out
        assert "api_port" not in out

    def test_pool_credentials_are_stripped_even_if_the_rig_sends_them(self):
        # RigForge deletes these before serving, but its read is token-OPTIONAL and the rig is
        # remote — an older or patched build is exactly what a single mask at the source misses.
        out = self._block(
            {
                "pools": [
                    {
                        "url": "rig:3333",
                        "user": "48edf",
                        "pass": "hunter2",
                        "tls-fingerprint": "ab",
                    },
                    {"url": "two:3333", "pass": "also-secret"},
                ]
            }
        )
        assert out["pools"] == [{"url": "rig:3333", "user": "48edf"}, {"url": "two:3333"}]
        assert "hunter2" not in json.dumps(out)
        assert "also-secret" not in json.dumps(out)

    def test_a_credential_is_stripped_whatever_shape_the_rig_wraps_it_in(self):
        # The threat model is a rig that picks its own response shape, so the strip must not assume
        # one. An earlier version only ran when `pools` arrived as a list of dicts: a rig serving it
        # as a dict, or nesting the credential a level deeper, walked past the filter intact. Both
        # shapes were reproduced against the real function before this test was written.
        for cfg in (
            {"pools": {"pass": "hunter2", "tls-fingerprint": "ab"}},
            {"pools": [{"url": "rig:3333", "auth": {"pass": "hunter2"}}]},
            {"watchdog": {"nested": {"deeper": {"pass": "hunter2"}}}},
            {"pools": [[{"pass": "hunter2"}]]},
        ):
            assert "hunter2" not in json.dumps(self._block(cfg)), cfg

    def test_a_config_nested_past_all_reason_is_refused_rather_than_walked(self):
        # A hostile rig should not get to drive our recursion down its own stack, and no real
        # writable config is anywhere near this deep.
        deep = cur = {}
        for _ in range(60):
            cur["watchdog"] = {}
            cur = cur["watchdog"]
        cur["pass"] = "hunter2"
        assert "hunter2" not in json.dumps(self._block({"watchdog": deep}))

    def test_a_malformed_pool_entry_does_not_crash_the_whole_poll(self):
        out = self._block({"pools": ["not-a-dict", None, {"url": "ok:1", "pass": "x"}]})
        assert out["pools"] == ["not-a-dict", None, {"url": "ok:1"}]


# --- RigForge enriched feed parse (#235) ---------------------------------------------------------
# The enriched feed is a SUPERSET of /1/summary: the whole XMRig object plus one `rigforge` key.
# parse_rigforge lifts the display-relevant fields, nullable-safe; a plain-xmrig body → None.


def test_parse_rigforge_absent_is_none():
    # A plain-xmrig worker (no `rigforge` key) parses to None — the UI renders it as today.
    assert parse_rigforge({"hashrate": {"total": [100]}, "api_ok": True}) is None
    assert parse_rigforge({}) is None
    assert parse_rigforge(["not", "a", "dict"]) is None


def test_parse_rigforge_miner_down_has_no_xmrig_keys():
    # Miner-down body: XMRig keys drop, only the rigforge block with xmrig_api unreachable remains.
    rf = parse_rigforge({"rigforge": {"version": "1.7.0", "xmrig_api": "unreachable"}})
    assert rf["miner_down"] is True
    assert rf["version"] == "1.7.0"
    # Absent sub-objects default cleanly — no chip data, no crash.
    assert rf["power"] == {"watts": None, "hs_per_watt": None}
    assert rf["watchdog"]["enabled"] is False


def test_parse_rigforge_all_null_fields():
    # Every enriched field is nullable on the wire (no RAPL, non-root, watchdog disabled).
    block = {
        "version": "1.7.0",
        "tune": {"target": None, "autotune": {"enabled": False, "next": None}},
        "power": {"watts": None, "hs_per_watt": None},
        "health": {"governor": None, "throttling": None, "firmware": {}, "hugepages_total": None},
        "watchdog": {"mode": "disabled"},
    }
    rf = parse_rigforge({"rigforge": block})
    assert rf["power"] == {"watts": None, "hs_per_watt": None}
    assert rf["health"] == {
        "governor": None,
        "throttling": None,
        "board": None,
        "hugepages_total": None,
    }
    assert rf["tune"] == {"target": None, "autotune_enabled": False, "autotune_next": None}
    # A disabled watchdog masks its temp fields.
    assert rf["watchdog"] == {
        "enabled": False,
        "thermal_hold": None,
        "temp_c": None,
        "max_temp_c": None,
    }
