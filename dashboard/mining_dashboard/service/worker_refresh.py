"""Bounded, targeted worker-status refresh after a successful one-click rig upgrade (issue #1233,
companion to #893).

The per-rig RigForge version shown to the operator is derived at the render seam from the rig's
own last-reported ``/1/summary`` (``web/infra_views.py``'s ``rigforge_update_for`` —
never stored, so it can't outlive its input, the #664 lesson). That read normally happens once per
``UPDATE_INTERVAL`` on the shared poll loop (``DataService.run``), so after an upgrade the operator
watches a stale badge for up to a full cycle even though the dashboard already knows the exact
moment the rig finished rebuilding.

This module does nothing that loop doesn't already do — it makes the SAME ``/1/summary`` probe
(``XMRigWorkerClient.get_stats``) the SAME way, just for the ONE rig that just upgraded, and only a
few times right after upgrade success. It never re-derives "latest available release" (that lookup
stays on its own Tor-throttled cadence, the anti-beacon contract ``update_checker`` owns) and never
changes anything (read-only). ``web/server.py``'s ``_finalize_worker_upgrade`` is the one caller,
triggered only on a worker-upgrade result that means the rig actually rebuilt (``applied`` or
``accepted`` — not a rejection/failure/rollback/throttle, where nothing changed rig-side).
"""

import asyncio
import logging

from aiohttp import ClientSession

from mining_dashboard.client.xmrig_client import XMRigWorkerClient, parse_rigforge
from mining_dashboard.service.update_checker import parse_semver

logger = logging.getLogger("WorkerRefresh")

# A few tries spaced over the rebuild window, not a busy-poll: the common case (no XMRig pin
# change) is a git checkout + restart, done in seconds; a pin-change rebuild can take minutes, but
# a rig that never comes back is exactly what the bounded cap gives up on cleanly.
REFRESH_ATTEMPTS = 6
REFRESH_DELAY_S = 10.0


async def _poll_until_matched(worker_client, ip, name, target, entry, attempts, delay_s, sleep):
    """Probe ``ip``/``name`` up to ``attempts`` times, merging each reachable read's ``rigforge``
    block into ``entry`` in place (same field the main poll loop merges, ``_merge_direct_stats``).
    Stops as soon as the reported version matches ``target`` (parsed SemVer) or the attempts run
    out; a target that doesn't parse (caller passed something odd) stops after the first reachable
    read instead of spinning for nothing."""
    for _ in range(attempts):
        await sleep(delay_s)
        try:
            payload = await worker_client.get_stats(ip, name)
        except Exception:
            logger.debug("Post-upgrade refresh probe failed for worker %r", name, exc_info=True)
            continue
        rf = parse_rigforge(payload) if payload else None
        if rf is None:
            continue
        entry["rigforge"] = rf
        reported = parse_semver(rf.get("version"))
        if target is None or (reported and reported == target):
            return True
    return False


async def refresh_worker_after_upgrade(
    latest_data,
    name,
    target_version,
    worker_client=None,
    attempts=REFRESH_ATTEMPTS,
    delay_s=REFRESH_DELAY_S,
    sleep=asyncio.sleep,
):
    """Out-of-cycle refresh of one worker's reported RigForge version (#1233).

    ``latest_data`` is the SAME shared dict the main poll loop publishes to ``/api/state``/
    ``/api/worker`` — mutating the matched worker's ``rigforge`` entry in place is what lets the
    NEXT read reflect the fresh version without waiting out ``UPDATE_INTERVAL``. A worker that has
    since dropped out of the table (offline fall-off, #182) or never had an IP is a silent no-op —
    nothing to refresh. ``worker_client`` is an injection seam for tests; production opens its own
    short-lived session so this never competes with the main loop's long-lived one.
    """
    workers = (latest_data or {}).get("workers") or []
    entry = next((w for w in workers if w.get("name") == name), None)
    if not entry or not entry.get("ip"):
        return False
    target = parse_semver(target_version)
    if worker_client is not None:
        return await _poll_until_matched(
            worker_client, entry["ip"], name, target, entry, attempts, delay_s, sleep
        )
    async with ClientSession() as session:
        return await _poll_until_matched(
            XMRigWorkerClient(session), entry["ip"], name, target, entry, attempts, delay_s, sleep
        )


# Upgrade outcomes meaning the rig genuinely rebuilt (or is still rebuilding) — worth kicking the
# refresh above. Excludes "noop" (nothing changed) and every non-success.
UPGRADE_REFRESH_STATUSES = ("applied", "accepted")


async def maybe_refresh_after_upgrade(latest_data, worker, version, res):
    """Called from ``web/server.py``'s ``_finalize_worker_upgrade`` with the terminal worker-upgrade
    result: kicks the out-of-cycle refresh above only when ``res`` means the rig actually rebuilt."""
    if res.get("status") in UPGRADE_REFRESH_STATUSES:
        await refresh_worker_after_upgrade(latest_data, worker, res.get("version") or version)
