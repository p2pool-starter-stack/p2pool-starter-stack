import importlib
import json
import os
from unittest.mock import patch


def _reload_config():
    import mining_dashboard.config.config as cfg

    return importlib.reload(cfg)


class TestConfig:
    def teardown_method(self):
        # Reset module-level state so a TIER_CONFIG override doesn't leak into other tests.
        _reload_config()

    def test_defaults_load(self):
        import mining_dashboard.config.config as cfg

        assert cfg.XMRIG_API_PORT == 8080
        assert cfg.XVB_DONATION_LEVEL == "auto"
        assert cfg.XVB_MAX_DONATION_FRACTION == 0.85
        assert isinstance(cfg.TIER_DEFAULTS, dict)
        assert cfg.TIER_DEFAULTS["donor_mega"] == 1_000_000

    def test_donation_level_env_override(self):
        with patch.dict(os.environ, {"XVB_DONATION_LEVEL": "AUTO"}):
            cfg = _reload_config()
            assert cfg.XVB_DONATION_LEVEL == "auto"  # normalized to lowercase

    def test_monero_prune_accepts_truthy_forms(self):
        # pithead writes MONERO_PRUNE=1, so "1" (and friends) must read as pruned — not just
        # the literal "true". Regression for the Pruned/Full label always showing Full (#32).
        for v in ("true", "1", "yes", "On", " 1 ", "TRUE"):
            with patch.dict(os.environ, {"MONERO_PRUNE": v}):
                assert _reload_config().MONERO_PRUNE is True, f"{v!r} should be pruned"

    def test_monero_prune_accepts_falsy_forms(self):
        for v in ("false", "0", "no", "off", ""):
            with patch.dict(os.environ, {"MONERO_PRUNE": v}):
                assert _reload_config().MONERO_PRUNE is False, f"{v!r} should be full"

    def test_fail_closed_defaults_off(self):
        # #490: the dashboard is an observability layer, so a cosmetic fault must never idle the
        # fleet by default — absent DASHBOARD_FAIL_CLOSED must read False.
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DASHBOARD_FAIL_CLOSED", None)
            assert _reload_config().DASHBOARD_FAIL_CLOSED is False

    def test_fail_closed_env_override(self):
        with patch.dict(os.environ, {"DASHBOARD_FAIL_CLOSED": "true"}):
            assert _reload_config().DASHBOARD_FAIL_CLOSED is True
        with patch.dict(os.environ, {"DASHBOARD_FAIL_CLOSED": "false"}):
            assert _reload_config().DASHBOARD_FAIL_CLOSED is False

    def test_update_interval_tolerates_bad_values(self):
        # A malformed override must fall back to the default, not crash the dashboard at import.
        for v, expected in [("2", 2), ("2.5", 2), ("", 30), ("nonsense", 30)]:
            with patch.dict(os.environ, {"UPDATE_INTERVAL": v}):
                assert _reload_config().UPDATE_INTERVAL == expected, f"{v!r} -> {expected}"

    def test_tier_config_env_override_valid(self):
        custom = {"donor_ultra": 5_000_000, "donor_basic": 500}
        # deploy injects the JSON wrapped in single quotes
        with patch.dict(os.environ, {"TIER_CONFIG": f"'{json.dumps(custom)}'"}):
            cfg = _reload_config()
            assert cfg.TIER_DEFAULTS["donor_ultra"] == 5_000_000
            assert "donor_mega" not in cfg.TIER_DEFAULTS

    def test_tier_config_env_override_invalid_json_falls_back(self):
        with patch.dict(os.environ, {"TIER_CONFIG": "'{bad_json: missing_quotes}'"}):
            cfg = _reload_config()
            assert cfg.TIER_DEFAULTS["donor_mega"] == 1_000_000

    def test_xvb_enabled_flag(self):
        with patch.dict(os.environ, {"XVB_ENABLED": "false"}):
            cfg = _reload_config()
            assert cfg.ENABLE_XVB is False
        with patch.dict(os.environ, {"XVB_ENABLED": "true"}):
            cfg = _reload_config()
            assert cfg.ENABLE_XVB is True

    def test_xvb_submit_url_default_is_the_real_endpoint(self):
        # #263: registration works out of the box — the default is the real submit endpoint.
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("XVB_SUBMIT_URL", None)
            cfg = _reload_config()
        assert cfg.XVB_SUBMIT_URL == "https://xmrvsbeast.com/cgi-bin/p2pool_bonus_submit_api.cgi"

    def test_xvb_submit_url_explicit_override(self):
        with patch.dict(os.environ, {"XVB_SUBMIT_URL": "https://test.example/submit.cgi"}):
            assert _reload_config().XVB_SUBMIT_URL == "https://test.example/submit.cgi"

    def test_xvb_submit_url_disable_sentinels(self):
        # Turn auto-registration off (keeping XvB on) without knowing the endpoint.
        for v in ("off", "none", "FALSE", "disabled", "0"):
            with patch.dict(os.environ, {"XVB_SUBMIT_URL": v}):
                assert _reload_config().XVB_SUBMIT_URL == "", f"{v!r} should disable"


class TestWorkerEndpoints:
    """Per-worker endpoint descriptor validation (#172), read from the read-only config.json
    mount. Exercised here via the deprecated dashboard.workers[] fallback shape — the field
    validation below is shared code, identical for the current workers.list[] shape (dual-read
    precedence is covered separately in TestWorkerEndpointsDualRead, #506). Every field bar
    `name` is optional; an entry with any invalid field is dropped WHOLE (fail closed — a typo'd
    host must not leave its token attached to the miner-IP fallback path)."""

    def _load(self, tmp_path, payload):
        from mining_dashboard.config.config import load_worker_endpoints

        p = tmp_path / "config.json"
        p.write_text(json.dumps(payload))
        return load_worker_endpoints(str(p))

    def test_valid_entries_load_with_only_set_fields(self, tmp_path):
        got = self._load(
            tmp_path,
            {
                "dashboard": {
                    "workers": [
                        {"name": "rig1", "host": "10.0.0.5", "port": 18088, "token": "s3cr3t"},
                        {"name": "rig2"},
                    ]
                }
            },
        )
        assert got == [
            {"name": "rig1", "host": "10.0.0.5", "port": 18088, "token": "s3cr3t"},
            {"name": "rig2"},
        ]

    def test_duplicate_names_first_declared_wins(self, tmp_path):
        got = self._load(
            tmp_path,
            {
                "dashboard": {
                    "workers": [{"name": "rig1", "port": 1111}, {"name": "rig1", "port": 2222}]
                }
            },
        )
        assert got == [{"name": "rig1", "port": 1111}]

    def test_invalid_entries_are_dropped_whole(self, tmp_path):
        got = self._load(
            tmp_path,
            {
                "dashboard": {
                    "workers": [
                        "not-a-dict",
                        {"port": 8080},  # no name
                        {"name": ""},  # empty name
                        {"name": "bad host", "host": "10.0.0.5 evil"},  # unsafe chars
                        {"name": "badhost2", "host": "10.0.0.5/path"},  # URL structure
                        {"name": "badhost3", "host": "a:b@c"},  # credential/port smuggling
                        {"name": "badport", "port": 0},
                        {"name": "badport2", "port": 65536},
                        {"name": "badport3", "port": True},  # bool is not a port
                        {"name": "badport4", "port": "8080"},  # string is not a port
                        {"name": "badtoken", "token": "has space"},
                        {"name": "badtoken2", "token": "x" * 129},
                        {"name": "ok", "port": 8081},
                    ]
                }
            },
        )
        assert got == [{"name": "ok", "port": 8081}]

    def test_masked_sentinel_token_is_kept_but_other_dicts_drop(self, tmp_path):
        # The container ONLY ever reads the masked config (#440), where a real token is the sentinel
        # {"__secret__": true}. The entry must SURVIVE (token present, value hidden) so the worker is
        # editable — the host-side runner uses the real token when it dials the rig (#508). Any other
        # dict is not the sentinel and drops the whole entry, fail-closed.
        got = self._load(
            tmp_path,
            {
                "dashboard": {
                    "workers": [
                        {
                            "name": "rig1",
                            "host": "10.0.0.5",
                            "control_port": 8082,
                            "token": {"__secret__": True},
                        },
                        {"name": "rig2", "host": "10.0.0.6", "token": {"__secret__": False}},
                        {"name": "rig3", "host": "10.0.0.7", "token": {"foo": "bar"}},
                    ]
                }
            },
        )
        assert got == [
            {
                "name": "rig1",
                "host": "10.0.0.5",
                "control_port": 8082,
                "token": {"__secret__": True},
            },
        ]

    def test_missing_file_and_missing_key_read_empty(self, tmp_path):
        from mining_dashboard.config.config import load_worker_endpoints

        assert load_worker_endpoints(str(tmp_path / "absent.json")) == []
        assert self._load(tmp_path, {"dashboard": {}}) == []

    def test_valid_control_port_loads_and_bad_drops_entry(self, tmp_path):
        # control_port (#185) is validated like port: an out-of-range or non-int value drops the
        # whole entry (fail-closed), so a typo can't leave a half-configured writable target.
        got = self._load(
            tmp_path,
            {
                "dashboard": {
                    "workers": [
                        {"name": "rig1", "host": "10.0.0.5", "control_port": 8082},
                        {"name": "bad", "control_port": 70000},
                        {"name": "boolcp", "control_port": True},
                        {"name": "ok", "port": 8081},
                    ]
                }
            },
        )
        assert got == [
            {"name": "rig1", "host": "10.0.0.5", "control_port": 8082},
            {"name": "ok", "port": 8081},
        ]

    def test_valid_watts_loads_and_bad_watts_drops_entry(self, tmp_path):
        # A positive watts estimate (#260) rides on the descriptor; a bad one fails closed like
        # every other field so a typo can't silently distort the fleet power total.
        got = self._load(
            tmp_path,
            {
                "dashboard": {
                    "workers": [
                        {"name": "rig1", "watts": 142.5},
                        {"name": "zero", "watts": 0},  # not positive
                        {"name": "neg", "watts": -5},  # negative
                        {"name": "boolw", "watts": True},  # bool is not watts
                        {"name": "strw", "watts": "142"},  # string is not watts
                        {"name": "ok", "port": 8081},
                    ]
                }
            },
        )
        assert got == [{"name": "rig1", "watts": 142.5}, {"name": "ok", "port": 8081}]


class TestWorkerEndpointsDualRead:
    """workers.list[] (#506) is the current sub-key; dashboard.workers[] (#172) is read as a
    deprecated fallback when workers.list is unset or an empty array. pithead's apply-time
    validation refuses a config that populates both, but an empty array is a schema default
    (config.reference.json ships both keys as []) and must never shadow the populated shape
    (#679)."""

    def _load(self, tmp_path, payload):
        from mining_dashboard.config.config import load_worker_endpoints

        p = tmp_path / "config.json"
        p.write_text(json.dumps(payload))
        return load_worker_endpoints(str(p))

    def test_new_shape_loads(self, tmp_path):
        got = self._load(
            tmp_path,
            {"workers": {"list": [{"name": "rig1", "host": "10.0.0.5", "port": 18088}]}},
        )
        assert got == [{"name": "rig1", "host": "10.0.0.5", "port": 18088}]

    def test_new_shape_wins_when_both_present(self, tmp_path):
        # pithead's apply-time validation refuses a config that sets both, but the loader must
        # still resolve deterministically for a stale/hand-edited mount: new shape wins.
        got = self._load(
            tmp_path,
            {
                "workers": {"list": [{"name": "new-rig"}]},
                "dashboard": {"workers": [{"name": "legacy-rig"}]},
            },
        )
        assert got == [{"name": "new-rig"}]

    def test_legacy_fallback_used_when_new_shape_unset(self, tmp_path):
        got = self._load(tmp_path, {"dashboard": {"workers": [{"name": "legacy-rig"}]}})
        assert got == [{"name": "legacy-rig"}]

    def test_legacy_fallback_used_when_new_shape_empty(self, tmp_path):
        # The editor round-trip shape (#679): config.reference.json's workers.list: [] merged
        # beside a populated legacy key — the empty schema default must not shadow the entries.
        got = self._load(
            tmp_path,
            {
                "workers": {"list": []},
                "dashboard": {"workers": [{"name": "legacy-rig"}]},
            },
        )
        assert got == [{"name": "legacy-rig"}]

    def test_empty_legacy_default_beside_populated_new_shape_reads_new(self, tmp_path):
        # The mirror round-trip shape (#679): dashboard.workers: [] injected by the reference
        # merge beside a populated workers.list.
        got = self._load(
            tmp_path,
            {
                "workers": {"list": [{"name": "new-rig"}]},
                "dashboard": {"workers": []},
            },
        )
        assert got == [{"name": "new-rig"}]

    def test_legacy_fallback_logs_a_deprecation_notice(self, tmp_path, caplog):
        import logging

        with caplog.at_level(logging.INFO, logger="Config"):
            self._load(tmp_path, {"dashboard": {"workers": [{"name": "legacy-rig"}]}})
        assert any("deprecated" in r.message for r in caplog.records)

    def test_new_shape_logs_no_deprecation_notice(self, tmp_path, caplog):
        import logging

        with caplog.at_level(logging.INFO, logger="Config"):
            self._load(tmp_path, {"workers": {"list": [{"name": "rig1"}]}})
        assert not any("deprecated" in r.message for r in caplog.records)

    def test_neither_shape_set_reads_empty(self, tmp_path):
        assert self._load(tmp_path, {}) == []
        assert self._load(tmp_path, {"workers": {"api_port": 8080}}) == []


class TestEnergyConfig:
    """dashboard.energy loader (#260): operator-set electricity + XMR prices, read off the config.json
    mount. Every field optional; an invalid value degrades to its default (feature off) rather than
    crashing. Prices are operator-set, or fetched live over Tor when `price_feed` opts in (#520)."""

    DEFAULTS = {
        "cost_per_kwh": 0.0,
        "xmr_price": 0.0,
        "tari_price": 0.0,
        "currency": "USD",
        "price_feed": False,
    }

    def _load(self, tmp_path, payload):
        from mining_dashboard.config.config import load_energy_config

        p = tmp_path / "config.json"
        p.write_text(json.dumps(payload))
        return load_energy_config(str(p))

    def test_defaults_when_absent(self, tmp_path):
        assert self._load(tmp_path, {"dashboard": {}}) == self.DEFAULTS

    def test_valid_values_load(self, tmp_path):
        got = self._load(
            tmp_path,
            {
                "dashboard": {
                    "energy": {
                        "cost_per_kwh": 0.18,
                        "xmr_price": 150,
                        "tari_price": 2.5,
                        "currency": "EUR",
                        "price_feed": True,
                    }
                }
            },
        )
        assert got == {
            "cost_per_kwh": 0.18,
            "xmr_price": 150.0,
            "tari_price": 2.5,
            "currency": "EUR",
            "price_feed": True,
        }

    def test_invalid_values_degrade_to_defaults(self, tmp_path):
        got = self._load(
            tmp_path,
            {
                "dashboard": {
                    "energy": {
                        "cost_per_kwh": -1,
                        "xmr_price": "expensive",
                        "tari_price": -2,
                        "currency": "has space",
                        "price_feed": "yes",  # only literal true opts in — a truthy string doesn't
                    }
                }
            },
        )
        assert got == self.DEFAULTS

    def test_non_object_energy_degrades_to_defaults(self, tmp_path):
        # A hand-edited `energy` that isn't an object mustn't crash — fall back to defaults.
        got = self._load(tmp_path, {"dashboard": {"energy": "nope"}})
        assert got == self.DEFAULTS

    def test_missing_file_reads_defaults(self, tmp_path):
        from mining_dashboard.config.config import load_energy_config

        assert load_energy_config(str(tmp_path / "absent.json")) == self.DEFAULTS
