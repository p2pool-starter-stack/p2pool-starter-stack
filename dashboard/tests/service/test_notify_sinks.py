from unittest.mock import MagicMock, patch

import requests

import mining_dashboard.service.notify_sinks as ns_mod
from mining_dashboard.service.notify_sinks import NtfySink, WebhookSink, config_sinks


def _ok_resp():
    resp = MagicMock()
    resp.raise_for_status = MagicMock()
    return resp


class TestEnabledGating:
    def test_blank_url_disables(self):
        assert WebhookSink("").enabled is False
        assert NtfySink("").enabled is False
        assert WebhookSink("  ").enabled is False

    def test_url_enables(self):
        assert WebhookSink("https://hook.test/x").enabled is True
        assert NtfySink("https://ntfy.test/topic").enabled is True

    def test_event_enabled_tracks_enabled_for_every_event(self):
        # No per-event toggles (yet): an enabled sink carries every event kind.
        hook = WebhookSink("https://hook.test/x")
        assert hook.event_enabled("node_down") is True
        assert hook.event_enabled("anything") is True
        assert WebhookSink("").event_enabled("node_down") is False

    def test_disabled_send_is_a_noop(self):
        with patch.object(ns_mod.requests, "post") as post:
            assert WebhookSink("").send("hi", "node_down") is False
            assert NtfySink("").send("hi", "node_down") is False
        post.assert_not_called()


class TestWebhookPayload:
    def test_posts_event_text_ts_json(self):
        hook = WebhookSink("https://hook.test/x", tor_proxy="")
        with patch.object(ns_mod.requests, "post", return_value=_ok_resp()) as post:
            assert hook.send("Monero node is DOWN", "node_down") is True
        assert post.call_args.args[0] == "https://hook.test/x"
        body = post.call_args.kwargs["json"]
        assert body["event"] == "node_down"
        assert body["text"] == "Monero node is DOWN"
        assert isinstance(body["ts"], int) and body["ts"] > 0


class TestNtfyPayload:
    def test_posts_text_as_body(self):
        sink = NtfySink("https://ntfy.test/topic", tor_proxy="")
        with patch.object(ns_mod.requests, "post", return_value=_ok_resp()) as post:
            assert sink.send("Monero node is DOWN", "node_down") is True
        assert post.call_args.args[0] == "https://ntfy.test/topic"
        assert post.call_args.kwargs["data"] == b"Monero node is DOWN"

    def test_bearer_header_only_when_token_set(self):
        with patch.object(ns_mod.requests, "post", return_value=_ok_resp()) as post:
            NtfySink("https://ntfy.test/t", token="tok123", tor_proxy="").send("x")
        assert post.call_args.kwargs["headers"] == {"Authorization": "Bearer tok123"}
        with patch.object(ns_mod.requests, "post", return_value=_ok_resp()) as post:
            NtfySink("https://ntfy.test/t", tor_proxy="").send("x")
        assert post.call_args.kwargs["headers"] is None


class TestTorRouting:
    def test_default_rides_the_tor_socks_proxy(self):
        # The default proxy is the stack's Tor SOCKS (socks5h) — the endpoint must see a Tor
        # exit, never the host IP (#340 posture).
        for sink in (WebhookSink("https://hook.test/x"), NtfySink("https://ntfy.test/t")):
            with patch.object(ns_mod.requests, "post", return_value=_ok_resp()) as post:
                sink.send("x")
            assert post.call_args.kwargs["proxies"] == {
                "http": ns_mod.TOR_SOCKS_PROXY,
                "https": ns_mod.TOR_SOCKS_PROXY,
            }

    def test_tor_opt_out_goes_direct(self):
        sink = WebhookSink("http://192.168.1.5/hook", tor_proxy="")
        with patch.object(ns_mod.requests, "post", return_value=_ok_resp()) as post:
            sink.send("x")
        assert post.call_args.kwargs["proxies"] is None


class TestFailSilent:
    def test_network_error_swallowed(self):
        hook = WebhookSink("https://hook.test/x")
        with patch.object(ns_mod.requests, "post", side_effect=requests.RequestException("no")):
            assert hook.send("x", "node_down") is False

    def test_http_error_swallowed(self):
        resp = MagicMock()
        resp.raise_for_status.side_effect = requests.HTTPError("503")
        with patch.object(ns_mod.requests, "post", return_value=resp):
            assert NtfySink("https://ntfy.test/t").send("x") is False

    def test_url_and_token_never_logged_on_failure(self, caplog):
        # A requests error message embeds the request URL — webhook URLs often carry tokens in
        # the query string, so only the exception *type* may reach the logs.
        boom = requests.RequestException(
            "HTTPSConnectionPool failed for url: https://hook.test/x?key=HOOKSECRET"
        )
        with caplog.at_level("DEBUG"):
            with patch.object(ns_mod.requests, "post", side_effect=boom):
                WebhookSink("https://hook.test/x?key=HOOKSECRET").send("x")
                NtfySink("https://ntfy.test/t", token="NTFYSECRET").send("x")
        assert "HOOKSECRET" not in caplog.text
        assert "NTFYSECRET" not in caplog.text
        assert "hook.test" not in caplog.text


class TestConfigSinks:
    def test_default_stack_builds_nothing(self, monkeypatch):
        monkeypatch.setattr(ns_mod, "NOTIFY_WEBHOOK_URLS", [])
        monkeypatch.setattr(ns_mod, "NTFY_URL", "")
        assert config_sinks() == []

    def test_builds_one_sink_per_webhook_plus_ntfy(self, monkeypatch):
        monkeypatch.setattr(ns_mod, "NOTIFY_WEBHOOK_URLS", ["https://a.test/1", "https://b.test/2"])
        monkeypatch.setattr(ns_mod, "NTFY_URL", "https://ntfy.sh/pit")
        monkeypatch.setattr(ns_mod, "NTFY_TOKEN", "tok")
        monkeypatch.setattr(ns_mod, "NOTIFY_TOR", True)
        sinks = config_sinks()
        assert [type(s).__name__ for s in sinks] == ["WebhookSink", "WebhookSink", "NtfySink"]
        assert all(s.enabled for s in sinks)
        assert all(
            s._proxies == {"http": ns_mod.TOR_SOCKS_PROXY, "https": ns_mod.TOR_SOCKS_PROXY}
            for s in sinks
        )

    def test_notify_tor_false_drops_the_proxy(self, monkeypatch):
        monkeypatch.setattr(ns_mod, "NOTIFY_WEBHOOK_URLS", ["http://10.0.0.2/hook"])
        monkeypatch.setattr(ns_mod, "NTFY_URL", "")
        monkeypatch.setattr(ns_mod, "NOTIFY_TOR", False)
        (hook,) = config_sinks()
        assert hook._proxies is None
