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

    def test_xvb_submit_url_default_is_assembled_endpoint(self):
        # #263: registration works out of the box — the default is the real endpoint, assembled onto
        # the public cgi-bin base (we assert structure, not the exact script name, to avoid
        # re-committing the path the operator asked us not to publish).
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("XVB_SUBMIT_URL", None)
            cfg = _reload_config()
        assert cfg.XVB_SUBMIT_URL.startswith("https://xmrvsbeast.com/cgi-bin/")
        assert cfg.XVB_SUBMIT_URL.endswith(".cgi")
        assert "history" not in cfg.XVB_SUBMIT_URL  # the submit endpoint, not the stats one

    def test_xvb_submit_url_explicit_override(self):
        with patch.dict(os.environ, {"XVB_SUBMIT_URL": "https://test.example/submit.cgi"}):
            assert _reload_config().XVB_SUBMIT_URL == "https://test.example/submit.cgi"

    def test_xvb_submit_url_disable_sentinels(self):
        # Turn auto-registration off (keeping XvB on) without knowing the endpoint.
        for v in ("off", "none", "FALSE", "disabled", "0"):
            with patch.dict(os.environ, {"XVB_SUBMIT_URL": v}):
                assert _reload_config().XVB_SUBMIT_URL == "", f"{v!r} should disable"
