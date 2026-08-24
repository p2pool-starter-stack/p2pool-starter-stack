"""Tier 1 — bounded_get (#660): the shared response-size cap for external HTTP fetches."""

import re
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import requests

from mining_dashboard.helper.http import (
    MAX_RESPONSE_BYTES,
    BoundedResponse,
    ResponseTooLarge,
    bounded_get,
    bounded_read,
    bounded_request,
)


def _streaming_resp(chunks, status_code=200, encoding="utf-8"):
    resp = MagicMock(status_code=status_code, encoding=encoding)
    resp.iter_content.return_value = iter(chunks)
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


class TestBoundedGet:
    def test_under_cap_returns_body(self):
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp([b'{"tag_nam', b'e": "v1.2.3"}']),
        ) as g:
            resp = bounded_get("https://example.test/x", timeout=20)
        assert resp.status_code == 200
        assert resp.text == '{"tag_name": "v1.2.3"}'
        assert resp.json() == {"tag_name": "v1.2.3"}
        # The read is streamed, never buffered whole by requests itself.
        assert g.call_args.kwargs["stream"] is True

    def test_exactly_at_cap_returns_body(self):
        # The cap is strictly greater-than: a body of exactly max_bytes succeeds.
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp([b"x" * 1024, b"x" * 1024]),
        ):
            resp = bounded_get("https://example.test/x", max_bytes=2048)
        assert resp.content == b"x" * 2048

    def test_over_cap_raises_request_exception(self):
        # ResponseTooLarge subclasses RequestException, so every caller's existing
        # fail-silent handling (return None / keep last good) applies unchanged.
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp([b"x" * 1024] * 3),
        ):
            with pytest.raises(requests.RequestException):
                bounded_get("https://example.test/x", max_bytes=2048)

    def test_stops_reading_at_the_cap(self):
        # The over-cap chunk is the last one consumed — the rest of a multi-GB body is never read.
        chunks = iter([b"x" * 1024, b"x" * 1024, b"x" * 1024])
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp(chunks),
        ):
            with pytest.raises(ResponseTooLarge):
                bounded_get("https://example.test/x", max_bytes=1024)
        assert next(chunks, None) is not None  # at least one chunk was left unread

    def test_kwargs_pass_through(self):
        with patch(
            "mining_dashboard.helper.http.requests.get",
            return_value=_streaming_resp([b"ok"]),
        ) as g:
            bounded_get(
                "https://example.test/x",
                timeout=20,
                proxies={"https": "socks5h://tor:9050"},
                params={"a": "b"},
                headers={"User-Agent": "pithead-dashboard"},
            )
        kw = g.call_args.kwargs
        assert kw["timeout"] == 20
        assert kw["proxies"] == {"https": "socks5h://tor:9050"}
        assert kw["params"] == {"a": "b"}
        assert kw["headers"] == {"User-Agent": "pithead-dashboard"}

    def test_bad_encoding_degrades_not_crashes(self):
        resp_obj = _streaming_resp([b"\xff\xfe"], encoding=None)
        with patch("mining_dashboard.helper.http.requests.get", return_value=resp_obj):
            resp = bounded_get("https://example.test/x")
        assert isinstance(resp.text, str)  # errors="replace", never a decode crash

    def test_raise_for_status_matches_requests_contract(self):
        # The Telegram long-poll calls raise_for_status(); an HTTP error must surface as a
        # RequestException so the caller's existing catch-and-backoff applies unchanged.
        BoundedResponse(200, b"", "utf-8").raise_for_status()  # 2xx: no raise
        with pytest.raises(requests.RequestException):
            BoundedResponse(502, b"", "utf-8").raise_for_status()


class _Stream:
    """An aiohttp ``StreamReader``: ``read(n)`` is a SHORT read, returning what is buffered rather
    than ``n`` bytes. Measured against a real aiohttp server while fixing #1347 — one ``read(1000)``
    of a 994-byte body came back with 100 bytes."""

    def __init__(self, raw, chunk=1024):
        self._raw, self._pos, self._chunk = raw, 0, chunk
        self.bytes_read = 0

    async def read(self, n=-1):
        end = len(self._raw) if n < 0 else min(len(self._raw), self._pos + min(n, self._chunk))
        chunk, self._pos = self._raw[self._pos : end], end
        self.bytes_read += len(chunk)
        return chunk


class TestBoundedRead:
    """The async twin (#1360). The aiohttp call sites differ in everything — session, params,
    timeout, whether they want bytes/text/JSON — except this one step, so the helper takes the
    stream rather than making the request."""

    async def test_a_body_up_to_the_cap_is_returned_whole(self):
        # The accept side matters most: a cap that refuses a legitimate body presents to the
        # operator as the far end being broken, which is worse than the exhaustion it prevents.
        assert await bounded_read(_Stream(b"x" * 2048), max_bytes=2048) == b"x" * 2048

    async def test_one_byte_past_the_cap_is_refused(self):
        with pytest.raises(ResponseTooLarge):
            await bounded_read(_Stream(b"x" * 2049), max_bytes=2048)

    async def test_it_raises_the_same_type_as_the_sync_twin(self):
        # Callers here fail silently on requests.RequestException; sharing the type means their
        # existing handling covers a refusal with no change.
        with pytest.raises(requests.RequestException):
            await bounded_read(_Stream(b"x" * 4), max_bytes=2)

    async def test_a_body_split_across_many_reads_is_still_read_whole(self):
        # The regression a single read(max_bytes) would cause, and the reason the fake above models
        # a short read at all: any link with latency delivers a body in pieces.
        stream = _Stream(b"y" * 8192, chunk=97)  # a deliberately unaligned chunk
        assert await bounded_read(stream, max_bytes=MAX_RESPONSE_BYTES) == b"y" * 8192

    async def test_an_oversized_body_delivered_in_pieces_is_still_refused(self):
        with pytest.raises(ResponseTooLarge):
            await bounded_read(_Stream(b"y" * 8192, chunk=97), max_bytes=4096)

    async def test_it_stops_reading_at_the_cap(self):
        # Refusing after buffering the whole body would prevent nothing at all.
        stream = _Stream(b"z" * (10 * 1024 * 1024), chunk=65536)
        with pytest.raises(ResponseTooLarge):
            await bounded_read(stream, max_bytes=4096)
        assert stream.bytes_read <= 4097

    async def test_an_empty_body_is_not_an_error(self):
        assert await bounded_read(_Stream(b"")) == b""

    async def test_the_refusal_names_what_was_being_read(self):
        # These log at the caller; a message saying only "too large" would not say which container
        # or which endpoint, on a box polling several every cycle.
        with pytest.raises(ResponseTooLarge, match="monerod logs"):
            await bounded_read(_Stream(b"x" * 4), max_bytes=2, what="monerod logs")


class TestBoundedRequest:
    def test_it_uses_a_caller_s_own_session(self):
        """The xmrig-proxy client mounts a deliberate ``Retry`` adapter and polls twice a cycle;
        bounding its reads must not silently drop that by falling back to module-level requests."""
        session = MagicMock()
        session.get.return_value = _streaming_resp([b"{}"])
        resp = bounded_request("GET", "http://x/1/summary", session=session)
        assert resp.json() == {}
        assert session.get.called
        assert session.get.call_args.kwargs["stream"] is True

    def test_it_dispatches_on_the_method(self):
        session = MagicMock()
        session.put.return_value = _streaming_resp([b'{"ok": true}'])
        assert bounded_request(
            "PUT", "http://x/1/config", session=session, json={"a": 1}
        ).json() == {"ok": True}
        assert session.put.call_args.kwargs["json"] == {"a": 1}
        assert not session.get.called

    def test_no_session_falls_back_to_module_level_requests(self):
        with patch(
            "mining_dashboard.helper.http.requests.post", return_value=_streaming_resp([b"{}"])
        ) as post:
            bounded_request("POST", "http://x/json_rpc", json={"m": "x"})
        assert post.call_args.kwargs["json"] == {"m": "x"}

    def test_the_cap_applies_to_any_method(self):
        session = MagicMock()
        session.put.return_value = _streaming_resp([b"x" * 1024] * 3)
        with pytest.raises(ResponseTooLarge):
            bounded_request("PUT", "http://x/1/config", max_bytes=2048, session=session)

    def test_bounded_get_still_delegates_with_its_660_signature(self):
        with patch(
            "mining_dashboard.helper.http.requests.get", return_value=_streaming_resp([b"{}"])
        ) as g:
            bounded_get("https://example.test/x", timeout=7, params={"a": "b"})
        assert g.call_args.kwargs["timeout"] == 7
        assert g.call_args.kwargs["params"] == {"a": "b"}
        assert g.call_args.kwargs["stream"] is True


class TestWiringDriftGuard:
    def test_external_clients_route_through_bounded_get(self):
        """Every external fetch module goes via bounded_get — any direct requests.<verb>( is drift."""
        pkg = Path(__file__).resolve().parents[2] / "mining_dashboard"
        external = [
            pkg / "service" / "update_checker.py",
            pkg / "service" / "price_feed.py",
            pkg / "client" / "xvb_client.py",
            pkg / "service" / "tor_heal.py",
            pkg / "service" / "healthchecks.py",
        ]
        direct_call = re.compile(r"requests\.(get|post|put|delete|head|request)\(")
        for mod in external:
            src = mod.read_text()
            hit = direct_call.search(src)
            assert hit is None, (
                f"{mod.name}: unbounded {hit.group() if hit else ''} slipped back in"
            )
            assert "bounded_get(" in src, f"{mod.name}: no bounded_get call found"

    def test_telegram_get_updates_routes_through_bounded_get(self):
        """The getUpdates long-poll is bounded. The module's requests.post( sends (sendMessage,
        answerCallbackQuery) keep their own contract — tiny echo bodies of caller-authored
        payloads — so only GETs are drift here."""
        pkg = Path(__file__).resolve().parents[2] / "mining_dashboard"
        src = (pkg / "service" / "telegram_commands.py").read_text()
        hit = re.search(r"requests\.(get|head|request)\(", src)
        assert hit is None, f"telegram_commands.py: unbounded {hit.group() if hit else ''}"
        assert "bounded_get(" in src

    def test_the_1360_internal_clients_route_through_the_bounded_helpers(self):
        """#660 exempted the clients it judged *internal*; that exemption did not survive contact
        (#1347), and #1360 brought the rest of the set behind the same helpers. This is a text
        check and proves only the text — the behavioural half is one refusal test per site, in each
        site's own test module."""
        pkg = Path(__file__).resolve().parents[2] / "mining_dashboard"
        sync_sites = {
            pkg / "client" / "monero" / "monero_client.py": r"requests\.(get|post|put|request)\(",
            pkg
            / "client"
            / "monero"
            / "monero_wallet_client.py": r"requests\.(get|post|put|request)\(",
            # This one calls through its own Session, so the drift to watch for is self.session.<verb>(
            pkg / "client" / "xmrig_proxy_client.py": r"self\.session\.(get|post|put)\(",
        }
        for mod, pattern in sync_sites.items():
            src = mod.read_text()
            hit = re.search(pattern, src)
            assert hit is None, (
                f"{mod.name}: unbounded {hit.group() if hit else ''} slipped back in"
            )
            assert "bounded_get(" in src or "bounded_request(" in src, f"{mod.name}: not bounded"

        async_sites = {
            pkg / "collector" / "logs.py": r"await response\.(read|text|json)\(",
            pkg / "collector" / "containers.py": r"await response\.(read|text|json)\(",
            pkg / "client" / "docker" / "docker_control.py": r"await resp\.(read|text|json)\(",
        }
        for mod, pattern in async_sites.items():
            src = mod.read_text()
            hit = re.search(pattern, src)
            assert hit is None, (
                f"{mod.name}: unbounded {hit.group() if hit else ''} slipped back in"
            )
            assert "bounded_read(" in src, f"{mod.name}: no bounded_read call found"
