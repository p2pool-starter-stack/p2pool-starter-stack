"""The adoption verdict a rig's Workers-table badge words itself from (#1857).

One probe verdict was answering two different questions. A rig whose configured xmrig feed broke
and a rig the dashboard was never given a control token for both arrived at the row as
``api_ok: False``, so an un-adopted appliance rig was sent to ``workers.api_auth`` / ``api_port``
when the thing to do is adopt it.

The fix threads one more fact — ``adopted`` — from the probe, where the ``workers.list[]``
descriptor has already been resolved, through the merge to the serialised row. **This file is
deliberately cross-layer**: the defect is that verdict's journey, and splitting it across the three
layers' own test files would leave the joins — the part that was missing — covered nowhere. Each
layer's own behaviour stays in ``test_xmrig_client.py`` / ``test_data_helpers.py`` /
``test_infra_views.py``.

Tier 1 (unit) per ``docs/dev/testing-strategy.md``: no network, no container, no rendering.
"""

import json

import pytest

from mining_dashboard.client import xmrig_client as xc
from mining_dashboard.client.xmrig_client import XMRigWorkerClient
from mining_dashboard.service.data_helpers import _merge_direct_stats
from mining_dashboard.web.infra_views import build_workers

# A deliberately thin session fake: these tests only need "the probe answered 200" versus "the probe
# failed". The bounded-read / short-read fakes that matter to the size cap live in
# test_xmrig_client.py and test_summary_size_cap.py, and re-implementing them here would give this
# file a second, quietly diverging copy of that contract.


class _Response:
    def __init__(self, status, payload):
        self.status = status
        self._raw = json.dumps(payload).encode()
        self._pos = 0
        self.content = self

    async def read(self, n=-1):
        end = len(self._raw) if n < 0 else min(len(self._raw), self._pos + n)
        chunk, self._pos = self._raw[self._pos : end], end
        return chunk


class _Get:
    def __init__(self, response):
        self._response = response

    async def __aenter__(self):
        return self._response

    async def __aexit__(self, *exc):
        return False


class _Session:
    def __init__(self, status=200, payload=None):
        self._response = _Response(status, {"ok": True} if payload is None else payload)
        self.calls = []

    def get(self, url, headers=None, timeout=None):
        self.calls.append(url)
        return _Get(self._response)


async def _probe(monkeypatch, entries, ip, name, status=401):
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", entries)
    return await XMRigWorkerClient(_Session(status=status)).get_stats(ip, name)


# --- The producer: adoption is decided where the descriptor is resolved -------------------------


async def test_a_failed_probe_on_an_adopted_rig_still_reports_adopted(monkeypatch):
    # The half that must NOT change: an adopted rig whose feed then fails is a real fault, and the
    # red "api ⚠" badge with its config advice is the right thing to show it.
    result = await _probe(monkeypatch, [{"name": "rig1", "token": "t0k"}], "10.0.0.1", "rig1")
    assert result == {"api_ok": False, "adopted": True}


async def test_a_failed_probe_on_an_unlisted_rig_reports_not_adopted(monkeypatch):
    # The #1857 case: the operator's freshly provisioned appliance rig. Nothing is misconfigured.
    result = await _probe(monkeypatch, [], "10.0.0.1", "rig1")
    assert result == {"api_ok": False, "adopted": False}


async def test_a_descriptor_without_a_control_token_is_not_adopted(monkeypatch):
    # Adoption is the TOKEN, not mere presence in workers.list: validate_worker_descriptor refuses
    # an entry without one ("the rig's control API is bearer-mandatory"), so a hand-written
    # host-only entry is a probe target, not an adopted rig.
    entries = [{"name": "rig1", "host": "10.0.0.1", "port": 8080}]
    assert await _probe(monkeypatch, entries, "10.0.0.1", "rig1") == {
        "api_ok": False,
        "adopted": False,
    }


async def test_the_masked_token_the_container_sees_still_reads_as_adopted(monkeypatch):
    # The appliance's real shape. The dashboard container reads the MASKED config (#440), where a
    # per-worker token arrives as the {"__secret__": true} sentinel — "a token exists, but you do
    # not hold it". That rig IS adopted; reading the sentinel as no-token would badge every adopted
    # appliance rig "not adopted" the moment its feed hiccuped, which is this bug wearing a mask.
    entries = [{"name": "rig1", "token": {"__secret__": True}}]
    assert await _probe(monkeypatch, entries, "10.0.0.1", "rig1") == {
        "api_ok": False,
        "adopted": True,
    }


async def test_a_fixed_difficulty_suffix_still_resolves_its_descriptor(monkeypatch):
    # WHY the verdict is decided at the probe rather than re-derived from the row's name later.
    # A rig mining as "rig1+50000" is one rig with one descriptor; the probe already strips the
    # suffix to match it. The control is the second assertion: a name-only lookup on the row's own
    # name — what a downstream re-derivation would have — finds nothing and would badge this
    # adopted rig "not adopted".
    entries = [{"name": "rig1", "token": "t0k"}]
    result = await _probe(monkeypatch, entries, "10.0.0.1", "rig1+50000")
    assert result == {"api_ok": False, "adopted": True}
    assert not [e for e in entries if e["name"] == "rig1+50000"]


async def test_a_renamed_rig_resolves_by_its_operator_set_host(monkeypatch):
    # The probe's other match: a rig that changed its stratum name still resolves through the host
    # the operator wrote into config.json. Same reason as above — the name alone would miss it.
    entries = [{"name": "was-rig1", "host": "192.168.7.9", "token": "t0k"}]
    result = await _probe(monkeypatch, entries, "192.168.7.9", "now-rig9")
    assert result == {"api_ok": False, "adopted": True}


async def test_a_successful_probe_carries_the_same_adoption_fact(monkeypatch):
    # The field rides both verdicts, so it cannot flip between two polls of one unchanged rig.
    entries = [{"name": "rig1", "token": "t0k"}]
    ok = await _probe(monkeypatch, entries, "10.0.0.1", "rig1", status=200)
    assert ok == {"ok": True, "api_ok": True, "adopted": True}


async def test_a_worker_we_never_probe_claims_no_adoption_verdict(monkeypatch):
    # An SSRF-guarded address is "unknown", not "not adopted" — and an unknown that arrived as
    # False would badge a rig the dashboard never even looked at.
    result = await _probe(monkeypatch, [{"name": "rig1", "token": "t0k"}], "172.28.0.30", "rig1")
    assert result == {}


# --- The merge: the fact reaches the worker beside api_ok ---------------------------------------


def _worker():
    return {"name": "rig1", "ip": "10.0.0.1", "status": "online", "uptime": 5}


@pytest.mark.parametrize("adopted", [True, False])
def test_the_merge_carries_adoption_on_a_failed_probe(adopted):
    [w] = _merge_direct_stats([_worker()], [{"api_ok": False, "adopted": adopted}], "3333")
    assert (w["api_ok"], w["adopted"]) == (False, adopted)


@pytest.mark.parametrize("adopted", [True, False])
def test_the_merge_carries_adoption_on_a_successful_probe(adopted):
    extra = {"api_ok": True, "adopted": adopted, "uptime": 9}
    [w] = _merge_direct_stats([_worker()], [extra], "3333")
    assert (w["api_ok"], w["adopted"]) == (True, adopted)


def test_an_unprobed_worker_is_left_without_an_adoption_claim():
    # No api_ok verdict means no adoption verdict either: the row must stay silent, not say False.
    [w] = _merge_direct_stats([_worker()], [{}], "3333")
    assert "api_ok" not in w and "adopted" not in w


# --- The row: the client gets the fact it branches the badge on ---------------------------------


def _row(**extra):
    base = {"name": "rig1", "ip": "10.0.0.1", "status": "online", "active_pool": "3333"}
    return build_workers([{**base, **extra}])[0]


@pytest.mark.parametrize("adopted", [True, False])
def test_the_row_serialises_the_adoption_fact(adopted):
    assert _row(api_ok=False, adopted=adopted)["adopted"] is adopted


def test_an_absent_adoption_fact_serialises_as_unknown_not_as_false():
    # None, never False: the client badges only on api_ok False, and a payload from before this
    # shipped must not read as a fleet of un-adopted rigs.
    assert _row()["adopted"] is None
