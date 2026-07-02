"""Healthchecks.io dead-man's-switch pinger (Issue #79).

A thin, self-contained client the data loop calls once per cycle to ping a unique
Healthchecks.io URL. The value is in what *stops* happening: if the host dies, the
dashboard dies with it, the pings stop, and Healthchecks.io fires an alert on the absence
of a ping — evaluated on *their* servers, so it survives the very outage (power loss, kernel
panic, NIC death) an in-stack notifier can't report from a dead machine.

Design notes:
- **Default off.** A disabled client is a no-op: :meth:`ping` returns immediately, opens no
  socket, and logs nothing.
- **Fails silently.** A ping that can't reach the endpoint (offline, or Tor momentarily down)
  is logged at DEBUG only — never WARNING/ERROR — so the log stays quiet, consistent with the
  stack's offline check discipline (#59). A blank ``ping_url`` while *enabled* is a genuine
  misconfiguration and warns once.
- **Throttled.** :data:`interval` is a floor between pings; the loop calls every cycle but we
  only hit the network once per interval. The throttle clock only advances on a *successful*
  send, so while offline we keep retrying every cycle rather than backing off.

Manual setup only (MVP): the operator pastes the ping URL from Healthchecks.io. Auto-
provisioning via the Management API (which would mean storing a powerful API key) is
intentionally left out — see ``docs/monitoring.md``.
"""

import logging
import time

import requests

from mining_dashboard.config.config import (
    HEALTHCHECKS_ENABLED,
    HEALTHCHECKS_INTERVAL_SEC,
    HEALTHCHECKS_PING_URL,
    HEALTHCHECKS_TOR_PROXY,
)

logger = logging.getLogger("Healthchecks")

# A ping is a tiny request; keep the timeout short so a hung endpoint can't stall the loop's
# worker thread for long. Healthchecks.io recommends GET/HEAD/POST to the ping URL.
_PING_TIMEOUT_SEC = 10


class HealthchecksClient:
    """Pings a Healthchecks.io check on a throttle; safe to call every loop cycle."""

    def __init__(
        self,
        enabled,
        ping_url,
        interval_seconds,
        tor_proxy=None,
        clock=time.monotonic,
    ):
        self.enabled = bool(enabled)
        # Paste the full ping URL Healthchecks.io shows you (hosted or self-hosted — it already
        # carries the host). Anything that isn't an http(s) URL is treated as unset, so `ping()`
        # warns once instead of silently failing on a bad value.
        url = (ping_url or "").strip()
        self.url = url.rstrip("/") if url.startswith(("http://", "https://")) else ""
        self.interval = max(0, int(interval_seconds or 0))
        # A requests proxies dict when routing over Tor, else None (direct clearnet ping). Reuses the
        # bridge Tor SOCKS the XvB fetch uses; socks5h so hc-ping.com's host resolves through Tor too.
        self._proxies = {"http": tor_proxy, "https": tor_proxy} if tor_proxy else None
        self._clock = clock
        self._last_ping = None  # monotonic time of the last *successful* send
        self._warned_misconfig = False

        if self.enabled and self.url:
            logger.info(
                "Healthchecks.io dead-man's switch enabled (ping every %ss, %s).",
                self.interval,
                "over Tor" if self._proxies else "over clearnet",
            )

    @classmethod
    def from_config(cls):
        """Build a client from the module-level config (env-backed) values."""
        return cls(
            enabled=HEALTHCHECKS_ENABLED,
            ping_url=HEALTHCHECKS_PING_URL,
            interval_seconds=HEALTHCHECKS_INTERVAL_SEC,
            tor_proxy=HEALTHCHECKS_TOR_PROXY,
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

        Returns ``True`` if a request was sent and accepted, else ``False`` (disabled,
        misconfigured, throttled, or the request failed).
        """
        if not self.enabled:
            return False
        if not self.url:
            # Enabled but nothing to ping — surface the misconfig once, then stay quiet.
            if not self._warned_misconfig:
                logger.warning(
                    "Healthchecks enabled but no ping_url configured — not pinging. "
                    "Set healthchecks.ping_url in config.json."
                )
                self._warned_misconfig = True
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
