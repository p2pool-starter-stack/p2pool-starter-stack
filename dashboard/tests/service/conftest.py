"""Shared fixtures and builders for the ``dashboard/tests/service/`` tests.

``algo`` predates this file's second purpose: it is the AlgoService under test, split across
test_algo_service.py and test_projected_steering.py (#1285).

Everything below it is the ``tests/service/`` half of the fixture consolidation (#1541). #1459 did
``tests/web/`` and closed; the pointer in ``test_data_helpers.py`` that named it as tracking
``_totals`` was left behind by that close, which is why #1541 exists. Until now each of six modules
carried its own copy of one of these builders. Duplicating them was the standing ruling while the
#1105 cuts were in flight, because those cuts proved themselves by moving test bodies verbatim and
converting the builders would have rewritten every call site inside the same change. The cuts
finished with #1529, so the copies are consolidated here.

The fixtures are FACTORIES, following #1459: each yields the callable the modules used to define
for themselves, so every call site reads exactly as it did before and only the signatures change.

``_SAFE`` stays a module constant rather than a fixture because no test asks for it directly; it is
read only by ``_posture`` and ``_topo``.

**``_SAFE`` is the UNION of the two dicts it replaces, and that changes what one module tracks.**
``test_egress.SAFE`` carried three keys ``test_node_route.SAFE`` did not — ``notify_sinks_enabled``,
``notify_tor``, ``notify_sinks_private`` — and no shared key disagreed. Passing those three is a
no-op *by construction*: ``compute_egress_posture`` and ``compute_topology`` both default them to
``False``/``True``/``False``, which is exactly what the egress dict supplies (egress.py, both
signatures). The consequence to know about: the node-route tests now PIN those three rather than
inheriting them, so a change to those defaults no longer reaches them. That was measured before the
merge, not assumed — every override set those tests pass produced byte-identical output under
either dict, while seeding ``notify_sinks_enabled=True`` moved it.

Deliberately NOT consolidated — the name is shared, the code is not:

* ``_monitor`` is defined by test_worker_presence.py, test_node_health.py and
  test_container_health.py, and all three build a DIFFERENT class with a different signature
  (``WorkerPresenceMonitor``, ``NodeHealthMonitor``, ``ContainerHealthMonitor``). Same name, three
  builders.
* ``_conn`` (test_egress.py) and ``_from`` (test_egress.py) have one definition each and stay with
  their module; a conftest entry for a single caller buys nothing.
* ``tests/service/test_metrics.py`` keeps its own ``_state_mgr``/``_data``, and
  ``test_telegram_commands.py`` its own ``_metrics``. Those are the ``tests/web/`` conftest's
  exclusions and its docstring records why; they are out of this file's reach anyway.

A note carried over from ``test_data_helpers.py``, which used to state it beside its own copy: the
``_totals`` there was a duplicate of ``test_data_service.py``'s, and it named #1459 as tracking the
merge. #1459 shipped ``tests/web/`` only, so that pointer went stale on its close. This is the fix.
"""

from unittest.mock import MagicMock

import pytest

from mining_dashboard.config.config import TIER_DEFAULTS
from mining_dashboard.service.algo_service import AlgoService
from mining_dashboard.service.egress import LOCAL, compute_egress_posture, compute_topology

# The privacy-safe resting config: firewall on, p2pool over Tor, XvB over Tor, local node, no sync,
# healthchecks off (no ping URL configured), no alert sinks configured. Any leak an assertion sees
# was caused by the override under test and not by an unrelated knob.
_SAFE = {
    "firewall": True,
    "p2pool_clearnet": False,
    "xvb_enabled": True,
    "xvb_tor": True,
    "monero_clearnet_sync": False,
    "tari_clearnet_sync": False,
    "monero_route": LOCAL,
    "healthchecks_enabled": False,
    "telegram_enabled": False,
    "notify_sinks_enabled": False,
    "notify_tor": True,
    "notify_sinks_private": False,
}


@pytest.fixture
def algo():
    state_manager = MagicMock()
    state_manager.get_tiers.return_value = dict(TIER_DEFAULTS)
    # Cold controller by default (#249): no persisted commanded fraction, no standby held — so
    # the warm-resume seed falls through to feedforward. Warm-resume tests override these.
    state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
    state_manager.get_xvb_standby.return_value = None
    # No recorded raffle wins by default, so the in-round hold (#769) is inactive
    # and the calibration loop steers freely. Hold tests override this.
    state_manager.get_raffle_wins.return_value = []
    proxy_client = MagicMock()  # called via asyncio.to_thread -> sync methods
    data_service = MagicMock()
    data_service.workers_rejected = False  # not rejecting workers (Issue #31 guard off)
    return AlgoService(state_manager, proxy_client, data_service)


@pytest.fixture
def _totals():
    """Factory for the ``_totals`` test_data_helpers.py and test_data_service.py each defined."""

    def _totals(accepted=0, rejected=0, invalid=0, expired=0):
        return {"accepted": accepted, "rejected": rejected, "invalid": invalid, "expired": expired}

    return _totals


@pytest.fixture
def _posture():
    """Factory for the ``_posture`` test_egress.py and test_node_route.py each defined."""

    def _posture(**overrides):
        return compute_egress_posture(**{**_SAFE, **overrides})

    return _posture


@pytest.fixture
def _topo():
    """Factory for the ``_topo`` test_egress.py and test_node_route.py each defined."""

    def _topo(**overrides):
        return compute_topology(**{**_SAFE, **overrides})

    return _topo


@pytest.fixture
def _edge():
    """Factory for the ``_edge`` test_egress.py and test_node_route.py each defined."""

    def _edge(topo, src, dst):
        return next(e for e in topo["edges"] if e["from"] == src and e["to"] == dst)

    return _edge


@pytest.fixture
def _on():
    """Factory for the ``_on`` test_alert_service.py and test_worker_presence.py each defined.

    Worker rows the proxy reports online.
    """

    def _on(*names):
        return [{"name": n, "status": "online"} for n in names]

    return _on


@pytest.fixture
def _down():
    """Factory for the ``_down`` test_alert_service.py and test_worker_presence.py each defined.

    Worker rows still listed by the proxy but disconnected — the DOWN state the dashboard shows.
    The two copies this replaces differed only in the wording of that sentence.
    """

    def _down(*names):
        return [{"name": n, "status": "offline"} for n in names]

    return _down
