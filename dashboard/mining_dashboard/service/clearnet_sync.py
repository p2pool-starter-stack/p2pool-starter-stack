import logging
import os

logger = logging.getLogger("ClearnetSync")

# Restart timeouts for the clearnet→Tor flip (#234). A daemon can be slow to stop (Tari took >10s
# and was SIGKILL'd), and Docker holds the stop request open until the container is down — so the
# HTTP timeout MUST exceed the stop deadline, or the stop call aborts early, reports failure, and
# (with the old `stop and start`) skipped the start entirely, leaving the daemon down.
_RESTART_STOP_TIMEOUT = 30  # seconds Docker waits (SIGTERM → SIGKILL) for the daemon to stop
_RESTART_HTTP_TIMEOUT = (
    60  # HTTP timeout for the stop/start calls; must exceed _RESTART_STOP_TIMEOUT
)


class ClearnetSyncSupervisor:
    """Auto-transition a clearnet-syncing node back to Tor once it's synced (#183/#234).

    When ``monero.clearnet_initial_sync`` / ``tari.clearnet_initial_sync`` is on, the daemon does
    its initial block download over CLEARNET (fast) instead of Tor — briefly exposing this host's IP
    to that chain's P2P network. This supervisor watches the per-chain "synced" signal the data loop
    already computes; the first time a clearnet node reports synced it drops a persistent marker in
    the shared ``state_dir`` and restarts the container. The daemon's entrypoint, seeing the marker,
    comes back up Tor-only — and stays there across restarts/``apply`` (a reboot can't silently
    re-expose it). The marker is removed by ``pithead`` only when the flag is re-enabled, re-arming.

    Direction is one-way: it only ever moves a node TOWARD Tor. Fail-safe: the marker is written
    BEFORE the restart (so the restarted container is guaranteed to pick Tor), and a failed restart
    is retried on the next cycle rather than left half-done — a node is never silently stranded on
    clearnet.

    The supervisor is intentionally passive about chains whose flag is off; it only acts on the ones
    the operator opted into.
    """

    def __init__(self, state_dir, docker_control, *, on_transition=None):
        self.state_dir = state_dir
        self.docker_control = docker_control
        # Called as on_transition(name, ok) after a flip attempt — lets the UI surface the event.
        self.on_transition = on_transition
        # Markers already present when the dashboard started = a PRIOR run already transitioned that
        # chain (e.g. across a reboot); its container came up Tor-only via the marker, so never touch
        # it. Distinguishing these from markers we write THIS run is what lets a failed restart retry.
        self._preexisting = {n for n in ("monero", "tari") if self._marker_exists(n)}
        # Chains we have confirmed restarted onto Tor this process-life.
        self._flipped = set()

    def marker_path(self, name):
        return os.path.join(self.state_dir, f"{name}.synced")

    def _marker_exists(self, name):
        try:
            return os.path.exists(self.marker_path(name))
        except OSError:
            return False

    def _write_marker(self, name):
        """Persist the per-chain transition marker. Returns True on success."""
        try:
            os.makedirs(self.state_dir, exist_ok=True)
            with open(self.marker_path(name), "w") as fh:
                fh.write("clearnet initial sync complete; node returned to Tor (#234)\n")
            return True
        except OSError as exc:
            logger.error(
                "%s: could not write Tor-resync marker at %s: %s", name, self.marker_path(name), exc
            )
            return False

    async def maybe_transition(self, name, container, flag_on, synced):
        """Drive one chain's clearnet→Tor transition. Idempotent; call every poll cycle.

        Returns True iff the node is CURRENTLY exposed on clearnet (still syncing, or a flip that
        hasn't succeeded yet) — the caller uses this to surface the "clearnet active" banner.
        """
        if not flag_on:
            return False
        # Already on Tor: a prior run transitioned it, or we did this run.
        if name in self._preexisting or name in self._flipped:
            return False
        if not synced:
            return True  # still doing its clearnet initial sync — exposed

        # Synced over clearnet → commit to Tor. Persist the marker FIRST: it's what makes the
        # restarted container (and every future start, incl. after a reboot) render Tor. If we can't
        # persist it, do NOT restart — a restart without the marker would just re-render clearnet,
        # and a reboot would re-expose the node. Stay exposed and retry next cycle instead.
        if not self._write_marker(name):
            return True
        logger.warning(
            "%s: CLEARNET initial sync complete — switching %s back to Tor (#234).", name, container
        )
        # Stop with a generous window + an HTTP timeout that OUTLASTS it, then ALWAYS start. The old
        # `stop and start` left a slow-stopping daemon down: when stop's HTTP call timed out before
        # the container finished stopping, `and` short-circuited and start was never called (#234:
        # Tari took >5s to stop and never came back). `ok` is now the START result — the container
        # must end up running; a stop hiccup can no longer skip the start.
        await self.docker_control.stop(
            container, stop_timeout=_RESTART_STOP_TIMEOUT, request_timeout=_RESTART_HTTP_TIMEOUT
        )
        ok = await self.docker_control.start(container, request_timeout=_RESTART_HTTP_TIMEOUT)
        if ok:
            self._flipped.add(name)
            logger.info("%s: %s restarted — now Tor-only.", name, container)
        else:
            # Restart failed: do NOT mark flipped, so we retry next cycle. The marker is already on
            # disk, so any start (this retry, a manual restart, a reboot) brings the node up on Tor.
            logger.error(
                "%s: restart of %s onto Tor failed — will retry next cycle (the marker is "
                "set, so any restart comes up Tor-only).",
                name,
                container,
            )
        if self.on_transition is not None:
            try:
                self.on_transition(name, ok)
            except Exception:  # never let a UI callback break the supervisor
                logger.debug("on_transition callback raised", exc_info=True)
        return not ok
