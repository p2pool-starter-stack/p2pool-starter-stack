"""Tor guard self-heal (#424) — restart the tor container when clearnet egress is stuck.

Tor can bootstrap to 100% yet sit on a FAILING GUARD: circuits build but clearnet exits time
out at the 60s cutoff, so every Tor-clearnet feature (Healthchecks pings, the Telegram bot,
XvB stats) dies at once while mining — onion / already-established circuits — keeps working
and the stack looks healthy. Seen live on pithead-prod after the v1.3.0 deploy: ~6 hours dark
until a manual ``docker compose restart tor`` reselected guards. The doctor check (v1.3.1)
detects this state; this monitor is the heal half.

It is **opt-in** (``tor.auto_heal: true``): a tor restart drops ALL circuits — the mining
onions included, which then rebuild — so the stack never restarts its privacy boundary behind
the operator's back by default. When off, this class does nothing: no probe traffic, no
restarts.

Guardrails — a restart storm is worse than a stuck guard (the tor log's own diagnosis is "the
Tor network is overloaded", so fresh guards may be just as bad):

- **Probe, not inference.** The trigger is the same active probe as the doctor check — one
  GET to a no-content endpoint through the Tor SOCKS — on a fixed cadence, never a guess from
  app-level failures.
- **Sustained, not a blip.** Egress must fail continuously for :data:`BROKEN_AFTER_SEC`
  before the first restart.
- **Cooldown.** At least :data:`COOLDOWN_SEC` between restarts, so later probes verify the
  new guards actually work before another attempt is allowed.
- **Bounded.** At most :data:`MAX_RESTARTS` restarts per outage; past that it only warns
  (the doctor check and the Healthchecks dead-man's switch remain the operator's signal).
  A successful probe closes the outage and resets the budget.
- **Loud.** Every restart and give-up is logged at WARNING; recovery after a restart sends a
  one-time Telegram note — deliverable exactly then, since Telegram rides the path that just
  healed.

The restart goes through the same start/stop-only docker-control proxy as the #31 failover.
The manual leg is ``./pithead restart tor``. Real stuck-guard recovery is tier 4 (gouda).
"""

import asyncio
import logging
import time

import requests

from mining_dashboard.config.config import TOR_AUTO_HEAL, TOR_SOCKS_PROXY

logger = logging.getLogger("TorHeal")

# Same robust no-content endpoint the doctor check probes: any HTTP response proves a working
# clearnet exit; a timeout/connect failure is exactly the stuck-guard symptom.
PROBE_URL = "https://www.google.com/generate_204"
PROBE_TIMEOUT_SEC = 15

# Fixed, not configurable: nobody should have to tune a self-heal, and a knob here is a knob on
# the privacy boundary. ponytail: constructor-injectable for tests only.
PROBE_INTERVAL_SEC = 5 * 60  # active probe cadence (only while the heal is enabled)
BROKEN_AFTER_SEC = 15 * 60  # sustained failure before the first restart (issue #424's "N minutes")
COOLDOWN_SEC = 30 * 60  # minimum gap between restarts — verify-then-retry, never thrash
MAX_RESTARTS = 3  # restart budget per outage; after this, warn only


class TorEgressHealer:
    """Probes Tor clearnet egress and restarts the tor container under strict guardrails.

    ``check()`` is safe to call every data-loop cycle: it self-throttles to the probe
    cadence and is a no-op when the heal is disabled. The decision core (:meth:`decide`)
    is pure state + clock, so the fire/hold/give-up logic is unit-testable without any
    network or docker.
    """

    CONTAINER = "tor"

    def __init__(self, docker_control, enabled=None, probe=None, notify=None, clock=time.monotonic):
        self.enabled = TOR_AUTO_HEAL if enabled is None else enabled
        self._docker = docker_control
        self._probe = probe or self._probe_egress
        self._notify = notify  # optional async callable(text) — the Telegram one-off
        self._clock = clock
        self._last_probe = None  # probe-cadence throttle
        self._failing_since = None  # start of the current unbroken failure streak
        self._restarts = 0  # restarts spent on the current outage
        self._last_restart = None  # cooldown anchor
        if self.enabled:
            logger.info(
                "Tor guard self-heal enabled (#424): probing clearnet egress every %ds; "
                "restart after %dm broken, max %d restarts %dm apart.",
                PROBE_INTERVAL_SEC,
                BROKEN_AFTER_SEC // 60,
                MAX_RESTARTS,
                COOLDOWN_SEC // 60,
            )

    @staticmethod
    def _probe_egress():
        """One SOCKS request through the tor container; True iff a clearnet exit answered."""
        try:
            requests.get(
                PROBE_URL,
                timeout=PROBE_TIMEOUT_SEC,
                proxies={"http": TOR_SOCKS_PROXY, "https": TOR_SOCKS_PROXY},
            )
            return True  # any HTTP response at all means the exit path works
        except requests.RequestException:
            return False

    def decide(self, ok, now):
        """Fold one probe result into the outage state; return the action to take.

        Returns ``None`` (nothing to do / keep waiting), ``"heal"`` (restart budget granted
        and spent — caller must restart tor), ``"exhausted"`` (still broken, budget gone:
        warn only), or ``"recovered"`` (egress is back after at least one restart).
        """
        if ok:
            healed = self._restarts > 0
            self._failing_since = None
            self._restarts = 0
            self._last_restart = None
            return "recovered" if healed else None
        if self._failing_since is None:
            self._failing_since = now
        # Transient blip guard: not broken until the failure streak spans the threshold.
        if (now - self._failing_since) < BROKEN_AFTER_SEC:
            return None
        # Retry cap: past the budget we never restart again this outage — warn instead.
        if self._restarts >= MAX_RESTARTS:
            return "exhausted"
        # Cooldown: give the previous restart's fresh guards time to prove themselves.
        if self._last_restart is not None and (now - self._last_restart) < COOLDOWN_SEC:
            return None
        self._restarts += 1
        self._last_restart = now
        return "heal"

    async def check(self):
        """Probe (throttled) and act. Called every data-loop cycle; never raises."""
        if not self.enabled:
            return
        now = self._clock()
        if self._last_probe is not None and (now - self._last_probe) < PROBE_INTERVAL_SEC:
            return
        self._last_probe = now
        try:
            ok = await asyncio.to_thread(self._probe)
            action = self.decide(ok, now)
            if action == "heal":
                logger.warning(
                    "Tor clearnet egress has been broken for %.0f minutes while tor runs — "
                    "stuck on a failing guard (#424). Restarting the tor container to pick "
                    "fresh guards (attempt %d/%d). All Tor circuits drop and rebuild.",
                    (now - self._failing_since) / 60,
                    self._restarts,
                    MAX_RESTARTS,
                )
                await self._docker.stop(self.CONTAINER, stop_timeout=15, request_timeout=60)
                await self._docker.start(self.CONTAINER, request_timeout=60)
            elif action == "exhausted":
                logger.warning(
                    "Tor clearnet egress is STILL broken after %d tor restarts — the Tor "
                    "network itself is likely overloaded; not restarting again (#424). "
                    "Healthchecks/Telegram/XvB stay down until egress recovers; "
                    "'./pithead doctor' shows the live state.",
                    MAX_RESTARTS,
                )
            elif action == "recovered":
                logger.info("Tor clearnet egress recovered after a tor restart (#424).")
                if self._notify is not None:
                    await self._notify(
                        "\U0001f9c5 Tor was stuck on a failing guard — clearnet egress "
                        "(Healthchecks/Telegram/XvB) broke while mining kept working. The "
                        "stack restarted the tor container and egress recovered (#424)."
                    )
        except Exception as exc:  # never let the healer break the data loop
            logger.debug("Tor heal cycle failed (%s)", type(exc).__name__)
