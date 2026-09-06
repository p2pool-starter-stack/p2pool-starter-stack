"""The #424 Tor egress probe, in both privacy views (#1856 row 13b).

``tor_heal`` sends ``PROBE_URL`` through ``TOR_SOCKS_PROXY`` every five minutes while
``tor.auto_heal`` is on (``service/tor_heal.py:63``, ``:130-134``). That is a real outbound call,
so the egress list and the topology diagram both have to name it: an operator auditing "All
connections" was reading a list that did not contain every connection.

Its own module rather than ``test_egress.py`` because that file is at its file-budget ceiling
(451/451). The same ceiling kept ``tor_auto_heal`` out of the ``_KNOBS`` product there, which
costs less than it looks: the row and the edge are UNCONDITIONAL — only their route varies — so
the exhaustive sweeps already cover the off branch, well-formedness and summary agreement. What
they cannot see is the on branch, and that is what this module pins.
"""

import itertools

from mining_dashboard.service.egress import CLEARNET, INACTIVE, TOR

_PROBE = "Tor egress probe"


def _conn(posture):
    dashboard = next(c for c in posture["components"] if c["name"] == "dashboard")
    return next(c for c in dashboard["conns"] if c["to"] == _PROBE)


def _edge_of(topo):
    return next(e for e in topo["edges"] if e["label"] == _PROBE)


def test_the_probe_is_inactive_until_auto_heal_is_turned_on(_posture, _topo):
    # tor.auto_heal is opt-in, so the resting box makes no probe at all. The row has to say that
    # rather than show a connection nothing is making — an inactive row is the honest answer.
    assert _conn(_posture())["route"] == INACTIVE
    assert _edge_of(_topo())["route"] == INACTIVE


def test_the_probe_rides_tor_when_auto_heal_is_on(_posture, _topo):
    # tor_heal passes TOR_SOCKS_PROXY for both schemes, so Tor is the only honest route, and the
    # edge has to land on the hub — a probe drawn straight to `internet` would read as a leak.
    assert _conn(_posture(tor_auto_heal=True))["route"] == TOR
    edge = _edge_of(_topo(tor_auto_heal=True))
    assert (edge["route"], edge["to"], edge["kind"]) == (TOR, "tor", "egress")


def test_the_probe_never_leaks_and_the_two_views_never_disagree(_posture, _topo):
    # The probe's half of test_egress.py::_TOR_HARDWIRED, which could not take another row. No
    # knob combination may derive a clearnet route for a socks5h-only client, and turning one on
    # may never move the privacy verdict — a headline that shifted here would blame the probe for
    # a leak it cannot cause. The list and the diagram are derived separately, so they are also
    # asserted to agree rather than assumed to.
    for auto_heal, firewall, xvb_tor in itertools.product((False, True), repeat=3):
        knobs = {"firewall": firewall, "xvb_tor": xvb_tor, "tor_auto_heal": auto_heal}
        posture = _posture(**knobs)
        assert _conn(posture)["route"] != CLEARNET, knobs
        assert _conn(posture)["route"] == _edge_of(_topo(**knobs))["route"], knobs
        flipped = _posture(**{**knobs, "tor_auto_heal": not auto_heal})
        assert posture["summary"] == flipped["summary"], knobs
