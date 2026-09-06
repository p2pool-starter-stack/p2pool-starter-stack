"""The ceiling on one rig's ``/1/summary`` (#1347).

The worker poll reads a device's response straight into the dashboard's memory, and since #1235
part of it is forwarded on to the operator's browser. Nothing else bounds it.

The ceiling has two failure modes and they pull in opposite directions: set too high it does not
prevent the exhaustion it exists for, and set too low it silently breaks a real operator's rig —
the worse of the two, because it looks like the rig is broken rather than the dashboard. So these
pin BOTH ends, with a body of an actual measured size on the accept side.

The fakes are local rather than shared with test_xmrig_client.py: pytest runs with
``--import-mode=importlib``, so a test module cannot import a sibling, and these need to set the
body BYTES directly rather than a payload object.
"""

import pytest

from mining_dashboard.client import xmrig_client as xc
from mining_dashboard.client.xmrig_client import XMRigWorkerClient

# Measured, JSON-serialized /1/summary with the RigForge block included: ~2.8 KiB for an 8-thread
# rig, 8.0 KiB for a 192-thread EPYC, and 16.0 KiB for an absurd-but-legitimate 512 threads with
# 8 pools. The term that scales is hashrate.threads — one row per mining thread.
LARGEST_REAL_RIG_BYTES = 16 * 1024


def body_of(n):
    """A well-formed JSON object body of exactly ``n`` bytes."""
    body = b'{"a":"' + b"x" * (n - 8) + b'"}'
    assert len(body) == n, (len(body), n)
    return body


class FakeResponse:
    """``read`` is a SHORT read, like aiohttp's StreamReader: it hands back what is buffered, never
    necessarily ``n`` bytes, and it advances a position. Modelling that is the point — the first
    version of this fake returned the full slice on every call, which let a client that read ONCE
    pass every test here while truncating any real body that arrived split across TCP reads."""

    def __init__(self, status, raw, content_length=None, chunk=1024):
        self.status = status
        self._raw = raw
        self._pos = 0
        self._chunk = chunk
        # Present so a test can prove the client does NOT consult it.
        self.content_length = content_length
        self.content = self

    async def read(self, n=-1):
        end = len(self._raw) if n < 0 else min(len(self._raw), self._pos + min(n, self._chunk))
        chunk, self._pos = self._raw[self._pos : end], end
        return chunk


class FakeGet:
    def __init__(self, response):
        self._response = response

    async def __aenter__(self):
        return self._response

    async def __aexit__(self, *exc):
        return False


class FakeSession:
    def __init__(self, response):
        self._response = response

    def get(self, url, headers=None, timeout=None):
        return FakeGet(self._response)


async def _stats(raw, content_length=None, chunk=1024):
    session = FakeSession(FakeResponse(200, raw, content_length, chunk))
    return await XMRigWorkerClient(session).get_stats("10.0.0.1", "rig1")


@pytest.mark.parametrize(
    "size",
    [
        pytest.param(LARGEST_REAL_RIG_BYTES, id="largest-real-rig"),
        pytest.param(xc._MAX_SUMMARY_BYTES, id="exactly-at-the-ceiling"),
    ],
)
async def test_a_body_up_to_the_ceiling_is_accepted(size):
    # The accept side matters most: a ceiling that rejects a real rig presents as a broken rig.
    assert (await _stats(body_of(size)))["api_ok"] is True


async def test_a_body_past_the_ceiling_is_refused_without_raising():
    # Refused, not crashed: one oversized rig must not take the poll down for every other worker.
    result = await _stats(body_of(xc._MAX_SUMMARY_BYTES + 1))
    assert result == {"api_ok": False, "adopted": False}


async def test_the_ceiling_does_not_trust_the_rig_s_content_length():
    # A rig lying about its size is exactly the case this exists for, and Content-Length is what it
    # would lie WITH — it is also absent under chunked encoding. The client must bound the read
    # itself rather than believe the header.
    result = await _stats(body_of(xc._MAX_SUMMARY_BYTES + 1), content_length=10)
    assert result == {"api_ok": False, "adopted": False}


async def test_an_oversized_body_is_never_parsed():
    # The refusal has to happen on the BYTES. Handing json.loads a body we already know is over the
    # ceiling would do the expensive thing first and check afterwards.
    huge = b'{"a":"' + b"x" * (xc._MAX_SUMMARY_BYTES * 2) + b'"}'
    assert (await _stats(huge)) == {"api_ok": False, "adopted": False}


async def test_a_body_split_across_many_reads_is_still_read_whole():
    # The regression that a single bounded read would cause, and the reason this fake models a
    # short read at all. A rig on WiFi, or any link with latency, delivers its body in pieces;
    # reading once returns only the first piece, json.loads then fails, and a perfectly healthy
    # rig is reported unreachable for a reason with nothing to do with its size. Verified against
    # a real aiohttp server: one read(1000) of a 994-byte body returned 100 bytes.
    result = await _stats(body_of(64 * 1024), chunk=97)  # a deliberately unaligned chunk
    assert result["api_ok"] is True


async def test_an_oversized_body_delivered_in_pieces_is_still_refused():
    # The other half: trickling an oversized body must not slip past the ceiling either.
    result = await _stats(body_of(xc._MAX_SUMMARY_BYTES + 1), chunk=97)
    assert result == {"api_ok": False, "adopted": False}
