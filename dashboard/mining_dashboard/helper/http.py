"""Bounded reads for every external HTTP fetch (#660).

Each external client (GitHub release checks #224, the three XvB reads, the CoinGecko price feed
#651, the Tor egress probe, the Healthchecks ping, the Telegram getUpdates long-poll) is
individually tolerant of a bad *parse*, but nothing bounded what got *read*: a hostile or broken
endpoint could hand any of them a multi-GB body and the process would buffer it all before
parsing. ``bounded_get`` streams the body and cuts it at a cap far above any legitimate payload;
over-cap raises a ``requests.RequestException`` subclass, so every caller's existing failure
contract (return ``None`` / keep the last good result) applies unchanged.

#660 exempted the clients it judged *internal* — the on-box or same-LAN endpoints. That exemption
did not survive contact: the rig poll was in the untreated set and needed bounding anyway (#1347),
because "our own container" describes who serves the body, not who wrote it. xmrig-proxy's summary
is built from what miners advertise; container logs carry miner-supplied worker names and pool
messages; and a *remote* monerod is someone else's server on someone else's network. #1360 brings
the rest of that set behind the same two helpers — ``bounded_get`` for the ``requests`` sites,
``bounded_read`` for the ``aiohttp`` ones.
"""

import json

import requests

# Generous by orders of magnitude: the largest legitimate payload here (the XvB winners file) is
# well under 100 KiB; the GitHub/CoinGecko JSON bodies are a few KiB.
MAX_RESPONSE_BYTES = 1024 * 1024


class ResponseTooLarge(requests.RequestException):
    """Response body exceeded the cap. Subclasses ``RequestException`` so callers' existing
    fail-silent handling treats it like any other transport failure."""


class BoundedResponse:
    """The slice of ``requests.Response`` the clients actually use: ``status_code``, ``text``,
    ``json()``, ``raise_for_status()`` — backed by the capped body."""

    def __init__(self, status_code, content, encoding):
        self.status_code = status_code
        self.content = content
        self.encoding = encoding

    @property
    def text(self):
        return self.content.decode(self.encoding or "utf-8", errors="replace")

    def json(self):
        return json.loads(self.text)

    def raise_for_status(self):
        # HTTPError subclasses RequestException, matching requests' own contract.
        if self.status_code >= 400:
            raise requests.HTTPError(f"HTTP {self.status_code}")


def bounded_request(method, url, max_bytes=MAX_RESPONSE_BYTES, timeout=20, session=None, **kwargs):
    """``requests`` with a hard response-size cap, for any method.

    ``session`` takes a caller's own ``requests.Session`` so bounding a read never costs it the
    connection pooling or the retry adapter it configured (#1360 — the xmrig-proxy client polls
    twice a cycle and mounts a deliberate ``Retry``). Defaults to the module, i.e. plain
    ``requests.<method>``.

    Streams the body and raises ``ResponseTooLarge`` once it exceeds ``max_bytes``, instead of
    buffering an unbounded payload. Passes ``proxies`` / ``params`` / ``headers`` / ``json``
    through unchanged; raises exactly what ``requests`` raises otherwise.
    """
    caller = getattr(session if session is not None else requests, method.lower())
    with caller(url, stream=True, timeout=timeout, **kwargs) as resp:
        chunks, size = [], 0
        for chunk in resp.iter_content(chunk_size=65536):
            size += len(chunk)
            if size > max_bytes:
                raise ResponseTooLarge(f"response body exceeded {max_bytes} bytes: {url}")
            chunks.append(chunk)
        return BoundedResponse(resp.status_code, b"".join(chunks), resp.encoding)


def bounded_get(url, max_bytes=MAX_RESPONSE_BYTES, timeout=20, **kwargs):
    """``requests.get`` with a hard response-size cap — the #660 entry point, unchanged."""
    return bounded_request("GET", url, max_bytes=max_bytes, timeout=timeout, **kwargs)


async def bounded_read(content, max_bytes=MAX_RESPONSE_BYTES, what="response"):
    """The async twin of :func:`bounded_get`: read an ``aiohttp`` body whole, or refuse it (#1360).

    Takes the response's ``content`` stream rather than making the request, because the async call
    sites differ in everything except this one step — session, params, timeout, and whether they
    want bytes, text or JSON. Bounding the read is the only part they share.

    **This is deliberately not a single ``read(max_bytes)``.** ``aiohttp``'s ``StreamReader.read(n)``
    is a SHORT read: it returns what is currently buffered, never necessarily ``n`` bytes. A body
    split across TCP reads — any link with latency — would come back truncated, and the far end
    would then read as broken for a reason with nothing to do with its size. Measured against a real
    aiohttp server while fixing #1347: one ``read(1000)`` of a 994-byte body returned 100 bytes.

    So it accumulates until EOF or one byte PAST the cap, which is what makes the boundary exact —
    a body of exactly ``max_bytes`` is returned, ``max_bytes + 1`` refuses. ``Content-Length`` is
    deliberately never consulted: the far end picks it, so trusting it would let a hostile endpoint
    declare 10 bytes and send 10 GB.

    Raises :class:`ResponseTooLarge`, the same type the sync twin raises, so a caller's existing
    ``except Exception`` fail-silent path applies unchanged.
    """
    # A ``bytearray``, not ``bytes``, and that is not a style choice. ``bytes`` is immutable, so
    # ``body += chunk`` reallocates and re-copies everything accumulated so far — O(n^2) in the
    # number of reads. Because the read above is SHORT, the far end chooses that number: a sender
    # writing one byte per segment turns a 1 MiB body into ~1M copies of a growing buffer. Measured
    # through this function: 64 KiB took 0.13s, 128 KiB 0.82s, 256 KiB 3.68s. This is asyncio, so
    # that time is the WHOLE event loop — every other collector and the state loop stall behind one
    # hostile response. A cap that converts memory exhaustion into CPU exhaustion is not a fix.
    body = bytearray()
    while len(body) <= max_bytes:
        chunk = await content.read(max_bytes + 1 - len(body))
        if not chunk:
            return bytes(body)
        body.extend(chunk)
    raise ResponseTooLarge(f"{what} body exceeded {max_bytes} bytes")
