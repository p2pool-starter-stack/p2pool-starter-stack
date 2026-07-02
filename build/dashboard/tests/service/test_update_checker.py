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


class TestGitHubReleaseClient:
    def _resp(self, status=200, payload=None):
        r = MagicMock()
        r.status_code = status
        r.json.return_value = payload if payload is not None else {}
        return r

    def test_parses_tag_and_url(self):
        c = GitHubReleaseClient("https://api/releases/latest", tor_proxy="socks5h://t:9050")
        with patch(
            "mining_dashboard.service.update_checker.requests.get",
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
            "mining_dashboard.service.update_checker.requests.get", return_value=self._resp(404)
        ):
            assert c.latest_release() is None

    def test_network_error_is_silent_none(self):
        c = GitHubReleaseClient("u")
        with patch(
            "mining_dashboard.service.update_checker.requests.get",
            side_effect=requests.RequestException("offline"),
        ):
            assert c.latest_release() is None

    def test_missing_fields_is_none(self):
        c = GitHubReleaseClient("u")
        with patch(
            "mining_dashboard.service.update_checker.requests.get",
            return_value=self._resp(200, {"tag_name": "v1.0.0"}),
        ):  # no html_url
            assert c.latest_release() is None


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
