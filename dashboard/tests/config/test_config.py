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
    mount, at workers.list[] (#506) — the only shape since 2.0.0 removed the dashboard.workers[]
    alias (#1832), whose absence is covered separately in TestWorkerEndpointsLegacyKeyIsNotRead. Every field bar
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
                "workers": {
                    "list": [
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
            {"workers": {"list": [{"name": "rig1", "port": 1111}, {"name": "rig1", "port": 2222}]}},
        )
        assert got == [{"name": "rig1", "port": 1111}]

    def test_invalid_entries_are_dropped_whole(self, tmp_path):
        got = self._load(
            tmp_path,
            {
                "workers": {
                    "list": [
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
                "workers": {
                    "list": [
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
        assert self._load(tmp_path, {"workers": {}}) == []

    def test_valid_control_port_loads_and_bad_drops_entry(self, tmp_path):
        # control_port (#185) is validated like port: an out-of-range or non-int value drops the
        # whole entry (fail-closed), so a typo can't leave a half-configured writable target.
        got = self._load(
            tmp_path,
            {
                "workers": {
                    "list": [
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
                "workers": {
                    "list": [
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


class TestWorkerEndpointsLegacyKeyIsNotRead:
    """workers.list[] (#506) is the only sub-key. dashboard.workers[] (#172) was read as a
    deprecated fallback until 2.0.0 removed it (#1832): pithead migrates a pre-2.0 config into
    workers.list[] before this mount is ever written, so the loader needs no fallback and a stale
    mount still carrying the alias reads as no descriptors at all — fail-closed, rather than a
    silent read of a key pithead no longer validates."""

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

    def test_legacy_key_beside_the_new_shape_is_ignored(self, tmp_path):
        # A stale or hand-edited mount can still carry both. pithead refuses that config at apply
        # when the two differ; the loader must resolve deterministically regardless.
        got = self._load(
            tmp_path,
            {
                "workers": {"list": [{"name": "new-rig"}]},
                "dashboard": {"workers": [{"name": "legacy-rig"}]},
            },
        )
        assert got == [{"name": "new-rig"}]

    def test_legacy_key_alone_reads_empty(self, tmp_path):
        # Inverted at 2.0.0: this returned the legacy entries while the fallback existed.
        assert self._load(tmp_path, {"dashboard": {"workers": [{"name": "legacy-rig"}]}}) == []

    def test_legacy_key_beside_an_empty_new_shape_reads_empty(self, tmp_path):
        # Also inverted: the #679 editor round-trip shape no longer un-shadows the legacy key.
        got = self._load(
            tmp_path,
            {
                "workers": {"list": []},
                "dashboard": {"workers": [{"name": "legacy-rig"}]},
            },
        )
        assert got == []

    def test_empty_legacy_key_beside_populated_new_shape_reads_new(self, tmp_path):
        got = self._load(
            tmp_path,
            {
                "workers": {"list": [{"name": "new-rig"}]},
                "dashboard": {"workers": []},
            },
        )
        assert got == [{"name": "new-rig"}]

    def test_no_deprecation_notice_for_either_shape(self, tmp_path, caplog):
        # The one-time fallback notice went with the alias, so neither shape may log one.
        import logging

        with caplog.at_level(logging.INFO, logger="Config"):
            self._load(tmp_path, {"workers": {"list": [{"name": "rig1"}]}})
            self._load(tmp_path, {"dashboard": {"workers": [{"name": "legacy-rig"}]}})
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


class TestLowRamFloorLocalMiner:
    """The mode-aware floor counts the built-in miner's share when local_miner.enabled — read
    live off the same read-only masked-config mount as the worker descriptors, so a dashboard
    toggle moves the floor without a restart. The increment is the miner's OWN ~3 GB dataset
    reservation, never the 6 GB headroom its rendered config declares (that is the stack's own
    hugepage budget, which the per-container floors already count)."""

    def _write(self, tmp_path, payload):
        p = tmp_path / "config.json"
        p.write_text(payload if isinstance(payload, str) else json.dumps(payload))
        return str(p)

    def test_enabled_reads_true(self, tmp_path):
        from mining_dashboard.config.config import local_miner_enabled

        assert local_miner_enabled(self._write(tmp_path, {"local_miner": {"enabled": True}}))

    def test_anything_else_reads_false(self, tmp_path):
        # Only the literal boolean true counts; every degraded shape (off, absent, hand-edited
        # junk, a non-object document) reads False — the floor must never inflate on a typo.
        from mining_dashboard.config.config import local_miner_enabled

        for payload in (
            {"local_miner": {"enabled": False}},
            {"local_miner": {}},
            {},
            {"local_miner": "yes"},
            {"local_miner": {"enabled": "true"}},
            [],
            "{not json",
        ):
            assert local_miner_enabled(self._write(tmp_path, payload)) is False, payload
        assert local_miner_enabled(str(tmp_path / "absent.json")) is False

    def test_floor_adds_miner_share_only_when_enabled(self, tmp_path, monkeypatch):
        import mining_dashboard.config.config as cfg

        monkeypatch.setattr(
            cfg, "HOST_CONFIG_PATH", self._write(tmp_path, {"local_miner": {"enabled": True}})
        )
        # The Both role with both nodes local: 3 + 5 + 6 + 3 — a 16 GB box now warns, which is
        # exactly the OOM edge the adversarial pass flagged.
        assert cfg.low_ram_floor_gb(True, True) == 17
        assert cfg.low_ram_floor_gb(False, False) == 6
        # No mount (a DIY stack) or the miner off: the floors are what they always were.
        monkeypatch.setattr(cfg, "HOST_CONFIG_PATH", str(tmp_path / "absent.json"))
        assert cfg.low_ram_floor_gb(True, True) == 14

    def test_low_ram_gb_env_pin_still_wins(self, tmp_path, monkeypatch):
        import mining_dashboard.config.config as cfg

        monkeypatch.setattr(
            cfg, "HOST_CONFIG_PATH", self._write(tmp_path, {"local_miner": {"enabled": True}})
        )
        monkeypatch.setattr(cfg, "_LOW_RAM_ENV", "9")
        assert cfg.low_ram_floor_gb(True, True) == 9.0
