"""The header's address block (``web/header.py``): the hostname/IP line and the .onion under it.

Split out of ``test_views.py`` when ``host_display_addr`` moved to ``web/header.py`` alongside the
onion reader it belongs beside (#1853). The ``host_display_addr`` cases are the originals, moved
verbatim except for the patch target — they patched ``views``, and a module attribute patched by
name does not follow a function to its new home.

The address fixture is a run of one letter rather than a realistic v3 address on purpose: nothing
here depends on the characters, and a realistic-looking high-entropy literal is what puts a repo's
secret scanner on a test file that holds no secret.
"""

from unittest.mock import patch

from mining_dashboard.web import header
from mining_dashboard.web.header import dashboard_onion, host_display_addr

ONION = "a" * 56 + ".onion"
ON = {"DASHBOARD_ONION_ENABLED": "true", "DASHBOARD_ONION_ADDRESS": ONION}


# --- Host address beside the hostname (Issue #119) ------------------------------------


class TestHostDisplayAddr:
    def test_resolves_ip_for_a_hostname(self):
        with patch.object(header, "detect_host_ipv4", return_value="192.168.1.42"):
            assert host_display_addr("pithead.local") == "192.168.1.42"

    def test_none_when_host_is_already_an_ip(self):
        # Nothing to add beside a literal address — don't call detection at all.
        with patch.object(header, "detect_host_ipv4") as detect:
            assert host_display_addr("192.168.1.42") is None
            detect.assert_not_called()

    def test_none_when_ip_undetectable(self):
        with patch.object(header, "detect_host_ipv4", return_value=None):
            assert host_display_addr("pithead.local") is None

    def test_none_when_detected_ip_equals_host(self):
        with patch.object(header, "detect_host_ipv4", return_value="my-rig"):
            assert host_display_addr("my-rig") is None


# --- The dashboard onion in the header (#1853) ----------------------------------------


class TestDashboardOnion:
    def test_enabled_and_provisioned_yields_the_pasteable_url(self):
        assert dashboard_onion(ON) == {"url": f"http://{ONION}", "client_auth": False}

    def test_the_address_is_carried_whole(self):
        # The product is a URL someone can paste into a phone. A 56-character base32 address has
        # no redundancy, so any elision yields a string that does not open.
        assert dashboard_onion(ON)["url"].endswith(ONION)

    def test_client_auth_is_reported_when_on(self):
        env = {**ON, "DASHBOARD_ONION_CLIENT_AUTH": "true"}
        assert dashboard_onion(env)["client_auth"] is True

    def test_off_yields_nothing_even_with_an_address_present(self):
        # The control for every "renders nothing" case below: the SAME address, one flag flipped,
        # produces a real payload — so a None here means the flag was read, not that the fixture
        # was incapable of producing one.
        assert dashboard_onion({**ON, "DASHBOARD_ONION_ENABLED": "false"}) is None
        assert dashboard_onion({"DASHBOARD_ONION_ADDRESS": ONION}) is None
        assert dashboard_onion(ON) is not None

    def test_unprovisioned_placeholder_is_not_an_address(self):
        # pithead writes the literal "placeholder" into .env before the service exists. Enabled
        # but unprovisioned has to render as nothing; an empty row reads as breakage.
        assert dashboard_onion({**ON, "DASHBOARD_ONION_ADDRESS": "placeholder"}) is None

    def test_missing_or_blank_address_yields_nothing(self):
        assert dashboard_onion({"DASHBOARD_ONION_ENABLED": "true"}) is None
        assert dashboard_onion({**ON, "DASHBOARD_ONION_ADDRESS": "   "}) is None

    def test_a_value_that_is_not_an_onion_address_yields_nothing(self):
        # The sanity check that keeps a status word out of the header.
        assert dashboard_onion({**ON, "DASHBOARD_ONION_ADDRESS": "not-provisioned"}) is None

    def test_flags_tolerate_the_casing_and_padding_env_carries(self):
        env = {
            "DASHBOARD_ONION_ENABLED": " True ",
            "DASHBOARD_ONION_ADDRESS": f"  {ONION} ",
            "DASHBOARD_ONION_CLIENT_AUTH": "TRUE",
        }
        assert dashboard_onion(env) == {"url": f"http://{ONION}", "client_auth": True}

    def test_no_client_key_material_can_reach_the_payload(self):
        # The keys are not passed into the container at all, but the payload's shape is the thing
        # a future edit would widen, so pin it: exactly two keys, and nothing carrying a secret
        # survives into either value even when the environment holds one.
        env = {
            **ON,
            "DASHBOARD_ONION_CLIENT_AUTH": "true",
            "DASHBOARD_ONION_CLIENT_PRIVKEY": "PRIVKEY-SENTINEL",
            "DASHBOARD_ONION_CLIENT_PUBKEY": "PUBKEY-SENTINEL",
        }
        payload = dashboard_onion(env)
        assert set(payload) == {"url", "client_auth"}
        assert "SENTINEL" not in str(payload)

    def test_the_default_reader_is_the_process_environment(self, monkeypatch):
        # Every other case injects a dict, so on its own the suite would never exercise the path
        # production actually takes. build_state calls dashboard_onion() with no argument.
        monkeypatch.setenv("DASHBOARD_ONION_ENABLED", "true")
        monkeypatch.setenv("DASHBOARD_ONION_ADDRESS", ONION)
        monkeypatch.delenv("DASHBOARD_ONION_CLIENT_AUTH", raising=False)
        assert dashboard_onion() == {"url": f"http://{ONION}", "client_auth": False}
        monkeypatch.setenv("DASHBOARD_ONION_ENABLED", "false")
        assert dashboard_onion() is None
