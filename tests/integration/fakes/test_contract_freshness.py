"""The vendored RigForge contract is the bytes the appliance bakes, not a matching ref line (#1426).

`test_contract.py`'s sibling guard compares two hand-edited strings: PROVENANCE's `ref=` line
against `ARG RIGFORGE_REF`. Nothing there can see the fixture *content*, so a pin bump followed by
an edit to the one obvious line in PROVENANCE reads green over stale fixtures — and
`test_fake_matches_the_vendored_wire_contract` then measures our fake against a stale contract and
passes too, which makes the whole file's thesis silently false with every guard green.

No offline check can close that. The producer is the only authority on what it emitted at a ref, and
a digest recorded beside the bytes is a claim checked against itself — it stays true precisely when
the bytes were NOT re-copied. So this leg consults the producer.

It reads the ref out of the Dockerfile rather than out of PROVENANCE deliberately: the baked pin is
what the appliance actually ships against, and PROVENANCE is the claim under suspicion. That makes
this leg stand alone rather than inherit the sibling's blind spot.

The pin is a full sha, so content-at-ref is immutable: this answer only changes when the pin moves.
"""

import os
import pathlib
import re

import pytest
import requests

_HERE = pathlib.Path(__file__).resolve().parent
_REPO = _HERE.parents[2]
_CONTRACT = _HERE / "contract" / "v1"
_FILES = ("feed.json", "control-status.json")

# Single-file raw reads rather than the archive tarball os/rootfs/Dockerfile pulls: two small files
# instead of a whole tree, and the pinned sha makes the read reproducible either way.
_RAW = (
    "https://raw.githubusercontent.com/p2pool-starter-stack/rigforge/{ref}/tests/contract/v1/{name}"
)


def _baked_ref():
    """The ref the appliance bakes. Same parse as the sibling guard, on purpose — if this regex ever
    stops matching, both legs must say so rather than one quietly verifying nothing."""
    dockerfile = (_REPO / "os" / "rootfs" / "Dockerfile").read_text()
    baked = re.search(r"^ARG RIGFORGE_REF=(\S+)", dockerfile, re.M)
    assert baked, "RIGFORGE_REF not found in os/rootfs/Dockerfile — did the pin move or rename?"
    return baked.group(1)


def _get(url):
    """One retry. A single transient failure must not red a PR; a producer that is genuinely
    unreachable still must, so the second exception propagates to the caller untouched."""
    try:
        return requests.get(url, timeout=15)
    except requests.RequestException:
        return requests.get(url, timeout=15)


def test_vendored_contract_bytes_match_the_producer_at_the_baked_ref():
    """Byte-compare tests/integration/fakes/contract/v1/ against RigForge at the baked pin (#1426).

    A transport failure and a non-200 are different findings and are treated differently. A non-200
    means the pin points somewhere these fixtures cannot be verified against at all — a real red,
    everywhere. A transport failure is our own reachability, which offline development is allowed to
    have and a release gate is NOT: in CI it fails, because a producer we could not reach must never
    be read as a producer we agreed with. That distinction is the whole point of the leg — the
    failure this file exists to prevent is a guard whose green means less than a reader thinks.
    """
    ref = _baked_ref()
    for name in _FILES:
        try:
            resp = _get(_RAW.format(ref=ref, name=name))
        except requests.RequestException as exc:
            unproven = (
                f"could not reach RigForge to verify tests/integration/fakes/contract/v1/{name} "
                f"against the baked pin {ref}: {exc}. The vendored fixtures are UNVERIFIED against "
                f"their producer — this run proves nothing about their freshness (#1426)."
            )
            if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
                pytest.fail(unproven)
            pytest.skip(unproven)
        assert resp.status_code == 200, (
            f"RigForge at the baked pin {ref} does not serve tests/contract/v1/{name} "
            f"(HTTP {resp.status_code}). The vendored contract cannot be verified against the ref "
            f"the appliance bakes: check whether the pin moved to a ref predating the contract "
            f"fixtures, or whether they were renamed upstream (#1426)."
        )
        assert (_CONTRACT / name).read_bytes() == resp.content, (
            f"tests/integration/fakes/contract/v1/{name} is NOT what RigForge emits at the baked "
            f"pin {ref} — the fixtures are stale. Re-copy tests/contract/v1/{name} from RigForge at "
            f"that ref and update PROVENANCE. Until then every contract assertion in this directory "
            f"is measured against a wire shape no rig sends (#1426)."
        )
