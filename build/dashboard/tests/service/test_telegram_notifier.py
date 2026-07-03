from unittest.mock import MagicMock, patch

import requests

import mining_dashboard.service.telegram_notifier as tg_mod
from mining_dashboard.service.telegram_notifier import TelegramNotifier

EVENTS = {"node_down": True, "node_recovered": False}


def _enabled(**kw):
    opts = dict(enabled=True, bot_token="TOKEN", chat_id="123", events=EVENTS)
    opts.update(kw)
    return TelegramNotifier(**opts)


class TestEnabledGating:
    def test_disabled_by_default(self):
        assert TelegramNotifier().enabled is False

    def test_enabled_requires_token_and_chat(self):
        assert TelegramNotifier(enabled=True, bot_token="", chat_id="123").enabled is False
        assert TelegramNotifier(enabled=True, bot_token="t", chat_id="").enabled is False
        assert TelegramNotifier(enabled=True, bot_token="t", chat_id="123").enabled is True

    def test_enabled_flag_off_disables_even_with_creds(self):
        assert TelegramNotifier(enabled=False, bot_token="t", chat_id="123").enabled is False

    def test_event_enabled_respects_toggle_and_enabled(self):
        n = _enabled()
        assert n.event_enabled("node_down") is True
        assert n.event_enabled("node_recovered") is False  # toggled off
        assert n.event_enabled("worker_offline") is False  # absent -> off
        # A disabled notifier reports every event as off.
        assert TelegramNotifier(events={"node_down": True}).event_enabled("node_down") is False


class TestSend:
    def test_send_noop_when_disabled(self):
        with patch.object(tg_mod.requests, "post") as post:
            assert TelegramNotifier().send("hi") is False
        post.assert_not_called()

    def test_send_posts_to_bot_api(self):
        n = _enabled(api_base="https://tg.test")
        resp = MagicMock()
        resp.raise_for_status = MagicMock()
        with patch.object(tg_mod.requests, "post", return_value=resp) as post:
            assert n.send("node down") is True
        url = post.call_args.args[0]
        assert url == "https://tg.test/botTOKEN/sendMessage"
        body = post.call_args.kwargs["json"]
        assert body["chat_id"] == "123"
        assert body["text"] == "node down"

    def test_send_routes_over_tor(self):
        # The bot dial must ride the Tor SOCKS proxy, never leak the host IP to Telegram.
        n = _enabled(tor_proxy="socks5h://tor:9050")
        resp = MagicMock()
        resp.raise_for_status = MagicMock()
        with patch.object(tg_mod.requests, "post", return_value=resp) as post:
            n.send("x")
        assert post.call_args.kwargs["proxies"] == {
            "http": "socks5h://tor:9050",
            "https": "socks5h://tor:9050",
        }

    def test_send_swallows_network_error(self):
        n = _enabled()
        with patch.object(
            tg_mod.requests, "post", side_effect=requests.RequestException("offline")
        ):
            assert n.send("x") is False

    def test_send_swallows_http_error(self):
        n = _enabled()
        resp = MagicMock()
        resp.raise_for_status.side_effect = requests.HTTPError("401")
        with patch.object(tg_mod.requests, "post", return_value=resp):
            assert n.send("x") is False


class TestTokenSecrecy:
    def test_token_never_logged_on_failure(self, caplog):
        # A requests error message embeds the request URL (with the token). Assert the token
        # never reaches the logs even when a send fails.
        n = _enabled(bot_token="SUPERSECRETTOKEN")
        boom = requests.RequestException(
            "HTTPSConnectionPool failed for url: "
            "https://api.telegram.org/botSUPERSECRETTOKEN/sendMessage"
        )
        with caplog.at_level("DEBUG"):
            with patch.object(tg_mod.requests, "post", side_effect=boom):
                n.send("x")
        assert "SUPERSECRETTOKEN" not in caplog.text
