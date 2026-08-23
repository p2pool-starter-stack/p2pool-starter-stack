"""Tests for the notify-only new-release check (#224)."""

from unittest.mock import MagicMock, patch

import requests

from mining_dashboard.service.update_checker import (
    GitHubReleaseClient,
    UpdateChecker,
    compute_update,
    parse_semver,
)


class TestParseSemver:
    def test_accepts_plain_and_v_prefixed(self):
        assert parse_semver("1.2.3") == (1, 2, 3)
        assert parse_semver("v1.2.3") == (1, 2, 3)
        assert parse_semver(" v0.1.0 ") == (0, 1, 0)

    def test_ignores_prerelease_and_build_suffix(self):
        assert parse_semver("v1.4.0-rc.1") == (1, 4, 0)
        assert parse_semver("1.4.0+build.7") == (1, 4, 0)

    def test_rejects_garbage_partial_and_empty(self):
        for bad in (None, "", "garbage", "1.2", "v1", "1.x.0"):
            assert parse_semver(bad) is None


class TestComputeUpdate:
    def test_newer_returns_payload(self):
        out = compute_update("0.1.0", "v0.2.0", "https://x/releases/tag/v0.2.0")
        assert out == {
            "available": True,
            "latest": "v0.2.0",
            "url": "https://x/releases/tag/v0.2.0",
        }

    def test_equal_or_older_returns_none(self):
        assert compute_update("0.2.0", "v0.2.0", "u") is None  # equal
        assert compute_update("0.2.0", "v0.1.0", "u") is None  # older

    def test_unparseable_either_side_returns_none(self):
        assert compute_update("0.1.0", "nightly", "u") is None
        assert compute_update("", "v0.2.0", "u") is None

    def test_major_and_minor_ordering(self):
        assert compute_update("1.9.9", "v2.0.0", "u")["latest"] == "v2.0.0"
        assert compute_update("1.2.0", "v1.10.0", "u")["latest"] == "v1.10.0"  # 10 > 2, not lexical

    def test_bare_rig_version_vs_v_prefixed_tag(self):
        # The rig reports bare "1.11.2"; RigForge release tags are "v1.11.2" (#596). Equality
        # must hold across the format difference — a current rig never badges its own version.
        assert compute_update("1.11.2", "v1.11.2", "u") is None
        assert compute_update("1.11.1", "v1.11.2", "u")["latest"] == "v1.11.2"


class TestGitHubReleaseClient:
    def _resp(self, status=200, payload=None):
        r = MagicMock()
        r.status_code = status
        r.json.return_value = payload if payload is not None else {}
        return r

    def test_parses_tag_and_url(self):
        c = GitHubReleaseClient("https://api/releases/latest", tor_proxy="socks5h://t:9050")
        with patch(
            "mining_dashboard.service.update_checker.bounded_get",
            return_value=self._resp(200, {"tag_name": "v1.4.0", "html_url": "https://h/v1.4.0"}),
        ) as g:
            assert c.latest_release() == {"tag": "v1.4.0", "url": "https://h/v1.4.0"}
            # routed through the Tor proxy
            assert g.call_args.kwargs["proxies"] == {
                "http": "socks5h://t:9050",
                "https": "socks5h://t:9050",
            }

    def test_non_200_is_silent_none(self):
        c = GitHubReleaseClient("u")
        with patch(
            "mining_dashboard.service.update_checker.bounded_get", return_value=self._resp(404)
        ):
            assert c.latest_release() is None

    def test_network_error_is_silent_none(self):
        c = GitHubReleaseClient("u")
        with patch(
            "mining_dashboard.service.update_checker.bounded_get",
            side_effect=requests.RequestException("offline"),
        ):
            assert c.latest_release() is None

    def test_missing_fields_is_none(self):
        c = GitHubReleaseClient("u")
        with patch(
            "mining_dashboard.service.update_checker.bounded_get",
            return_value=self._resp(200, {"tag_name": "v1.0.0"}),
        ):  # no html_url
            assert c.latest_release() is None

    def test_surfaces_raucb_asset_size(self):
        # The appliance's OS bundle rides the release as a .raucb asset; its size feeds the
        # OS-update control's "what a download costs" line.
        c = GitHubReleaseClient("u")
        payload = {
            "tag_name": "v1.4.0",
            "html_url": "h",
            "assets": [
                {"name": "pithead.tar.gz", "size": 5},
                {"name": "pithead-os-v1.4.0.raucb", "size": 123456},
            ],
        }
        with patch(
            "mining_dashboard.service.update_checker.bounded_get",
            return_value=self._resp(200, payload),
        ):
            assert c.latest_release() == {"tag": "v1.4.0", "url": "h", "raucb_size": 123456}

    def test_release_without_raucb_omits_the_key(self):
        # Every DIY-only release (and RigForge's) has no .raucb — the key just isn't there.
        c = GitHubReleaseClient("u")
        payload = {"tag_name": "v1.4.0", "html_url": "h", "assets": [{"name": "pithead.tar.gz"}]}
        with patch(
            "mining_dashboard.service.update_checker.bounded_get",
            return_value=self._resp(200, payload),
        ):
            assert c.latest_release() == {"tag": "v1.4.0", "url": "h"}


class _FakeClient:
    def __init__(self, rel=None):
        self.rel = rel
        self.calls = 0

    def latest_release(self):
        self.calls += 1
        return self.rel


class TestUpdateChecker:
    def test_disabled_never_calls_and_returns_none(self):
        c = _FakeClient({"tag": "v0.2.0", "url": "u"})
        uc = UpdateChecker(c, "0.1.0", enabled=False)
        assert uc.maybe_check(1000) is None
        assert c.calls == 0

    def test_enabled_flags_a_newer_release(self):
        c = _FakeClient({"tag": "v0.2.0", "url": "https://h/v0.2.0"})
        uc = UpdateChecker(c, "0.1.0", enabled=True, interval=3600)
        out = uc.maybe_check(1000)
        assert out == {"available": True, "latest": "v0.2.0", "url": "https://h/v0.2.0"}

    def test_throttles_to_interval(self):
        c = _FakeClient({"tag": "v0.2.0", "url": "u"})
        uc = UpdateChecker(c, "0.1.0", enabled=True, interval=3600)
        uc.maybe_check(1000)
        uc.maybe_check(1000 + 1800)  # within window -> cached, no network
        assert c.calls == 1
        uc.maybe_check(1000 + 3601)  # past window -> network again
        assert c.calls == 2

    def test_failed_fetch_keeps_previous_result(self):
        uc = UpdateChecker(_FakeClient(None), "0.1.0", enabled=True, interval=0)
        uc.result = {"available": True, "latest": "v0.2.0", "url": "u"}
        assert uc.maybe_check(2000)["latest"] == "v0.2.0"  # a blip must not drop the badge

    def test_up_to_date_yields_none(self):
        uc = UpdateChecker(_FakeClient({"tag": "v0.1.0", "url": "u"}), "0.1.0", enabled=True)
        assert uc.maybe_check(1000) is None

    def test_raucb_size_rides_the_update_payload(self):
        c = _FakeClient({"tag": "v0.2.0", "url": "u", "raucb_size": 999})
        uc = UpdateChecker(c, "0.1.0", enabled=True)
        assert uc.maybe_check(1000)["raucb_size"] == 999


class TestLatestReleaseCached:
    """The raw-release accessor (#596): one throttled fleet-wide fetch, many consumers."""

    def test_disabled_never_calls_and_returns_none(self):
        c = _FakeClient({"tag": "v1.11.2", "url": "u"})
        uc = UpdateChecker(c, None, enabled=False)
        assert uc.latest_release_cached(1000) is None
        assert c.calls == 0

    def test_returns_raw_release_and_throttles(self):
        c = _FakeClient({"tag": "v1.11.2", "url": "https://h/v1.11.2"})
        uc = UpdateChecker(c, None, enabled=True, interval=3600)
        assert uc.latest_release_cached(1000) == {"tag": "v1.11.2", "url": "https://h/v1.11.2"}
        assert uc.latest_release_cached(1000 + 1800) == {
            "tag": "v1.11.2",
            "url": "https://h/v1.11.2",
        }
        assert c.calls == 1  # within the window: cached, no network
        uc.latest_release_cached(1000 + 3601)
        assert c.calls == 2

    def test_failed_fetch_keeps_previous_release(self):
        uc = UpdateChecker(_FakeClient(None), None, enabled=True, interval=0)
        uc.release = {"tag": "v1.11.2", "url": "u"}
        assert uc.latest_release_cached(2000)["tag"] == "v1.11.2"  # a blip keeps the cache
