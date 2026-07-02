"""Healthchecks.io dead-man's-switch pinger (Issue #79).

A thin, self-contained client the data loop calls once per cycle to ping a unique
Healthchecks.io URL. The value is in what *stops* happening: if the host dies, the
dashboard dies with it, the pings stop, and Healthchecks.io fires an alert on the absence
of a ping — evaluated on *their* servers, so it survives the very outage (power loss, kernel
panic, NIC death) an in-stack notifier can't report from a dead machine.

Design notes:
- **Off until configured.** No ``ping_url`` → the client is a no-op: :meth:`ping` returns
  immediately, opens no socket, and logs nothing. Setting a URL is what turns it on.
- **Always over Tor.** The ping rides the bridge Tor SOCKS proxy so the endpoint sees a Tor
  exit, not the host IP — it's never a clearnet beacon.
- **Fails silently.** A ping that can't reach the endpoint (offline, or Tor momentarily down)
  is logged at DEBUG only — never WARNING/ERROR — so the log stays quiet, consistent with the
  stack's offline check discipline (#59).
- **Throttled.** :data:`interval` is a floor between pings; the loop calls every cycle but we
  only hit the network once per interval. The throttle clock only advances on a *successful*
  send, so while offline we keep retrying every cycle rather than backing off.

Manual setup: the operator pastes the full ping URL from Healthchecks.io (hosted or a
Tor-reachable self-hosted instance). Auto-provisioning via the Management API (which would
mean storing a powerful API key) is intentionally left out — see ``docs/monitoring.md``.
"""

import logging
import time

import requests

from mining_dashboard.config.config import (
    HEALTHCHECKS_INTERVAL_SEC,
    HEALTHCHECKS_PING_URL,
    TOR_SOCKS_PROXY,
)

logger = logging.getLogger("Healthchecks")

# A ping is a tiny request; keep the timeout short so a hung endpoint can't stall the loop's
# worker thread for long. Healthchecks.io recommends GET/HEAD/POST to the ping URL.
_PING_TIMEOUT_SEC = 10


class HealthchecksClient:
    """Pings a Healthchecks.io check on a throttle; safe to call every loop cycle."""

    def __init__(
        self,
        ping_url,
        interval_seconds,
        tor_proxy=None,
        clock=time.monotonic,
    ):
        # A ping URL is the on/off switch: paste the full URL Healthchecks.io shows you (hosted or a
        # Tor-reachable self-hosted instance) to enable; leave it blank to keep the switch off.
        # Anything that isn't an http(s) URL is treated as unset (a no-op), never a silent bad ping.
        url = (ping_url or "").strip()
        self.url = url.rstrip("/") if url.startswith(("http://", "https://")) else ""
        self.enabled = bool(self.url)
        self.interval = max(0, int(interval_seconds or 0))
        # Route the ping over the bridge Tor SOCKS (socks5h, so the host resolves through Tor too),
        # so the endpoint sees a Tor exit, not the host IP. tor_proxy is a test seam; from_config
        # always injects it.
        self._proxies = {"http": tor_proxy, "https": tor_proxy} if tor_proxy else None
        self._clock = clock
        self._last_ping = None  # monotonic time of the last *successful* send

        if self.enabled:
            logger.info(
                "Healthchecks.io dead-man's switch enabled (ping every %ss, over Tor).",
                self.interval,
            )

    @classmethod
    def from_config(cls):
        """Build a client from the module-level config (env-backed) values."""
        return cls(
            ping_url=HEALTHCHECKS_PING_URL,
            interval_seconds=HEALTHCHECKS_INTERVAL_SEC,
            tor_proxy=TOR_SOCKS_PROXY,
        )

    def _due(self, now):
        """Whether enough time has passed since the last successful ping to send another."""
        if self._last_ping is None:
            return True
        return (now - self._last_ping) >= self.interval

    def ping(self):
        """Send one liveness heartbeat if due. Never raises.

        This is a pure dead-man's switch: it only reports that the stack (this dashboard loop) is
        alive. Node-health alerting — monerod/Tari down while the box is up — is out of scope and
        handled in-stack by the Telegram alerter (#121), which can say more than a red check can.

        Returns ``True`` if a request was sent and accepted, else ``False`` (not configured,
        throttled, or the request failed).
        """
        if not self.url:
            return False

        now = self._clock()
        if not self._due(now):
            return False

        try:
            requests.get(self.url, timeout=_PING_TIMEOUT_SEC, proxies=self._proxies)
            # Advance the throttle only on success so a transient outage keeps retrying.
            self._last_ping = now
            return True
        except requests.RequestException as e:
            # Offline / Tor down / endpoint hiccup: the whole point is to survive these
            # silently — Healthchecks.io will alert on the missed ping. DEBUG, never noise.
            logger.debug("Healthchecks ping failed (offline?): %s", e)
            return False
        except Exception as e:  # pragma: no cover - defensive; never break the loop
            logger.debug("Healthchecks unexpected error: %s", e)
            return False
