"""Bounded reads for every external HTTP fetch (#660).

Each external client (GitHub release checks #224, the three XvB reads, the CoinGecko price feed
#651, the Tor egress probe, the Healthchecks ping, the Telegram getUpdates long-poll) is
individually tolerant of a bad *parse*, but nothing bounded what got *read*: a hostile or broken
endpoint could hand any of them a multi-GB body and the process would buffer it all before
parsing. ``bounded_get`` streams the body and cuts it at a cap far above any legitimate payload;
over-cap raises a ``requests.RequestException`` subclass, so every caller's existing failure
contract (return ``None`` / keep the last good result) applies unchanged.
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


def bounded_get(url, max_bytes=MAX_RESPONSE_BYTES, timeout=20, **kwargs):
    """``requests.get`` with a hard response-size cap.

    Streams the body and raises ``ResponseTooLarge`` once it exceeds ``max_bytes``, instead of
    buffering an unbounded payload. Passes ``proxies`` / ``params`` / ``headers`` through
    unchanged; raises exactly what ``requests.get`` raises otherwise.
    """
    with requests.get(url, stream=True, timeout=timeout, **kwargs) as resp:
        chunks, size = [], 0
        for chunk in resp.iter_content(chunk_size=65536):
            size += len(chunk)
            if size > max_bytes:
                raise ResponseTooLarge(f"response body exceeded {max_bytes} bytes: {url}")
            chunks.append(chunk)
        return BoundedResponse(resp.status_code, b"".join(chunks), resp.encoding)
