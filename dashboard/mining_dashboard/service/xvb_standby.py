"""Backup-stack XvB warm-standby puller (#249).

Two full Pithead hosts sharing one Monero/Tari wallet run as a failover pair: workers list both in
``pools[]`` (primary first), and on a primary outage they fail over to the backup. The backup's XvB
donation controller would otherwise cold-start — it restarts the donation split from the feedforward
estimate and re-ramps for hours — so its credited tier over/under-shoots until the closed loop
reconverges.

This service closes that gap on the **backup**: when ``xvb.standby.source`` names the primary's
dashboard, it periodically pulls the primary's read-only ``/api/xvb-standby`` and holds the result as
*standby* state (``StateManager.set_xvb_standby``). It is never acted on while the primary is
authoritative — the backup has no workers then, so its controller stays on P2Pool regardless. The
adoption happens only at failover, inside ``AlgoService._seed_donation_fraction``, when the backup
first actually donates.

One-way, backup-pulls-from-primary; inert unless configured (blank source = off). The pull follows
the dashboard's #160-safe egress rule (``_proxies`` / ``egress._xvb_standby_route``): an ``.onion``
source, a public IP, or any hostname rides the bridge Tor SOCKS — so the primary sees a Tor exit,
never the backup's real IP — and only a provably-private/loopback IP *literal* dials direct as a LAN
hop. It never opens a clearnet path. Every failure is silent — a missed pull just keeps the
last-held standby, and a backup with no standby yet simply cold-starts as before.
"""

import asyncio
import logging
import time

import requests

from mining_dashboard.config.config import (
    TOR_SOCKS_PROXY,
    XVB_STANDBY_INTERVAL_S,
    XVB_STANDBY_SOURCE,
)
from mining_dashboard.helper.http import bounded_get
from mining_dashboard.service.egress import LOCAL, _xvb_standby_route

logger = logging.getLogger("XvbStandby")


def parse_standby(payload) -> dict | None:
    """The minimal warm state from a primary's ``/api/xvb-standby`` body, or ``None`` when the
    payload is unusable. Pure + unit-tested. Coerces the numeric fields defensively — the source is
    another stack's API, trusted but still validated so a malformed body degrades to "no pull"
    rather than poisoning the held standby."""
    if not isinstance(payload, dict):
        return None
    try:
        commanded = float(payload.get("commanded_fraction", 0.0) or 0.0)
        avg_1h = float(payload.get("avg_1h", 0.0) or 0.0)
        avg_24h = float(payload.get("avg_24h", 0.0) or 0.0)
    except (TypeError, ValueError):
        return None
    return {
        "commanded_fraction": commanded,
        "avg_1h": avg_1h,
        "avg_24h": avg_24h,
        "donation_level": str(payload.get("donation_level", "")),
        "mode": str(payload.get("mode", "")),
    }


class XvbStandbyPuller:
    """Periodically pulls the primary's XvB controller state into standby (#249).

    Inert unless ``source`` is set. ``fetch_once`` does one blocking HTTP read (call via
    ``asyncio.to_thread`` or straight in a test); ``run`` is the throttled loop wired into main."""

    def __init__(self, state_manager, source=XVB_STANDBY_SOURCE, interval=XVB_STANDBY_INTERVAL_S):
        self.state_manager = state_manager
        self.source = (source or "").strip()
        self.interval = interval

    @property
    def enabled(self):
        return bool(self.source)

    def _proxies(self):
        """Route the pull the way the whole dashboard reads clearnet: an ``.onion`` OR any public /
        not-provably-private source rides the bridge Tor SOCKS (DNS resolved proxy-side), so the
        primary sees a Tor exit — never the backup's real IP (#160/#249). Only a provably-private,
        loopback, or link-local IP *literal* dials direct, as a LAN hop. A hostname can't be proven
        private without DNS, so it goes over Tor. This mirrors ``egress._xvb_standby_route`` exactly
        (``local`` there == direct here), so the Security panel reports where this pull truly goes."""
        return (
            None
            if _xvb_standby_route(self.source) == LOCAL
            else {
                "http": TOR_SOCKS_PROXY,
                "https": TOR_SOCKS_PROXY,
            }
        )

    def fetch_once(self) -> dict | None:
        """Pull the primary's ``/api/xvb-standby`` once and store it as standby. Returns the stored
        blob, or ``None`` on any failure (kept silent — the last-held standby stands)."""
        if not self.enabled:
            return None
        try:
            resp = bounded_get(
                self.source,
                timeout=15,
                proxies=self._proxies(),
                headers={"User-Agent": "pithead-dashboard"},
            )
            if resp.status_code != 200:
                logger.debug("Standby pull got HTTP %s (kept silent)", resp.status_code)
                return None
            standby = parse_standby(resp.json())
        except (requests.RequestException, ValueError) as e:
            logger.debug("Standby pull failed (kept silent): %s", e)
            return None
        if standby is None:
            return None
        standby["pulled_at"] = time.time()
        self.state_manager.set_xvb_standby(standby)
        logger.info(
            "Pulled primary XvB standby: commanded %.3f, 1h %.0f / 24h %.0f, tier %s",
            standby["commanded_fraction"],
            standby["avg_1h"],
            standby["avg_24h"],
            standby["donation_level"] or "auto",
        )
        return standby

    async def run(self):
        """Poll the primary on ``interval`` while configured. A no-op forever when the source is
        blank, so an ordinary single-stack install pays nothing."""
        if not self.enabled:
            logger.info("XvB standby puller idle (no xvb.standby.source configured).")
            return
        # Log only the enabled state, never the source URL — it can embed basic-auth userinfo, a
        # capability secret that must not land in stdout/docker logs (mirrors healthchecks.py, which
        # logs "enabled" and never the ping_url).
        logger.info("Service Started: XvB standby puller (enabled).")
        while True:
            await asyncio.to_thread(self.fetch_once)
            await asyncio.sleep(self.interval)
