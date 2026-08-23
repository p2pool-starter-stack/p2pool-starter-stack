"""Tier 1 — bounded_get (#660): the shared response-size cap for external HTTP fetches."""

import re
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import requests

from mining_dashboard.helper.http import BoundedResponse, ResponseTooLarge, bounded_get


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
