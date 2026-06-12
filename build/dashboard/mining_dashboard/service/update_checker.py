"""New-release check (#224) — notify-only.

When `dashboard.check_for_updates` is enabled (default OFF), the dashboard periodically asks GitHub
for the latest published release and, if it's newer than the running version, surfaces a header badge
linking to it (`build_state` -> `state.update`). It never updates anything — it's a callout so the
operator knows to upgrade on their own terms (the one-click upgrade is the separate #59).

Privacy: the check is **opt-in (default off)** and routed over the bridge **Tor SOCKS** (reusing
`XVB_TOR_PROXY`, like the XvB stats fetch #163), so enabling it doesn't reveal the host IP to GitHub.
Every failure path is silent (returns ``None``) so an offline / Tor-only stack just shows no badge.
"""
import logging

import requests

logger = logging.getLogger("UpdateChecker")


def parse_semver(s):
    """``'v1.2.3'`` / ``'1.2.3'`` -> ``(1, 2, 3)``; ``None`` if unparseable.

    Tolerates a leading ``v`` and ignores any ``-prerelease`` / ``+build`` suffix, so a tag and the
    bare ``VERSION`` string compare cleanly. Pure + unit-tested.
    """
    if not s:
        return None
    core = s.strip().lstrip("vV").split("-", 1)[0].split("+", 1)[0]
    parts = core.split(".")
    if len(parts) < 3 or not all(p.isdigit() for p in parts[:3]):
        return None
    return tuple(int(p) for p in parts[:3])


def compute_update(running, latest_tag, url):
    """``{available, latest, url}`` when ``latest_tag`` is a newer SemVer than ``running``, else
    ``None`` (equal/older/unparseable). Pure — the network lives in ``GitHubReleaseClient``."""
    rv, lv = parse_semver(running), parse_semver(latest_tag)
    if rv and lv and lv > rv:
        return {"available": True, "latest": latest_tag, "url": url}
    return None


class GitHubReleaseClient:
    """Fetches the latest published release from the GitHub API, fail-silent over Tor."""

    def __init__(self, api_url, tor_proxy=None):
        self.api_url = api_url
        self.tor_proxy = tor_proxy

    def latest_release(self):
        """Return ``{"tag": ..., "url": ...}`` for the latest published release, or ``None`` on any
        failure (network, non-200, malformed JSON). Routed through Tor when a proxy is set."""
        proxies = {"http": self.tor_proxy, "https": self.tor_proxy} if self.tor_proxy else None
        try:
            resp = requests.get(
                self.api_url, timeout=20, proxies=proxies,
                headers={"Accept": "application/vnd.github+json", "User-Agent": "pithead-dashboard"},
            )
            if resp.status_code != 200:
                return None
            data = resp.json()
            tag, url = data.get("tag_name"), data.get("html_url")
            return {"tag": tag, "url": url} if tag and url else None
        except (requests.RequestException, ValueError) as e:
            logger.debug("Update check failed (kept silent): %s", e)
            return None


class UpdateChecker:
    """Throttled wrapper around the client. ``maybe_check(now)`` hits the network at most once per
    ``interval`` and otherwise returns the cached result, so the badge persists between checks and a
    transient outage doesn't drop it."""

    def __init__(self, client, running_version, enabled, interval=3600):
        self.client = client
        self.running = running_version
        self.enabled = enabled
        self.interval = interval
        self._last = 0.0
        self.result = None

    def maybe_check(self, now):
        """Return the cached ``{available, ...}`` (or ``None``). Performs the (blocking) fetch only
        when enabled and the throttle window has elapsed — call via ``asyncio.to_thread``."""
        if not self.enabled:
            self.result = None
            return None
        if self._last and (now - self._last) < self.interval:
            return self.result
        self._last = now
        rel = self.client.latest_release()
        if rel:
            self.result = compute_update(self.running, rel["tag"], rel["url"])
        # On a failed fetch keep the previous result — a blip shouldn't drop a real "update available".
        return self.result
