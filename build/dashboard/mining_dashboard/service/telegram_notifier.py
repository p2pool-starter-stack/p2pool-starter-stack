import logging

import requests

from mining_dashboard.config.config import TOR_SOCKS_PROXY

logger = logging.getLogger("TelegramNotifier")

# Telegram Bot API base. Overridable in tests so we never touch the network.
TELEGRAM_API_BASE = "https://api.telegram.org"


class TelegramNotifier:
    """
    Thin, fire-and-forget Telegram push notifier (Issue #121).

    Pushes short operational alerts to a single chat via the Bot API ``sendMessage``
    endpoint. Deliberately minimal — there is no interactive bot, no commands, no polling
    (that's #45); this is the notifications-only half.

    Discipline (mirrors the rest of the stack):

    - **Disabled by default.** ``enabled`` is only true when explicitly switched on *and*
      both ``bot_token`` and ``chat_id`` are present. A missing/half-filled config leaves it
      off, so :meth:`send` is a silent no-op rather than an error on every cycle.
    - **Per-event toggles.** ``events`` gates which alert kinds are delivered, so an operator
      can enable Telegram and still silence the ones they find noisy.
    - **Always over Tor.** Sends ride the bridge Tor SOCKS proxy (``socks5h``, so the DNS lookup
      goes through Tor too), so Telegram sees a Tor exit, not the host IP — never a clearnet beacon,
      matching the Healthchecks.io pinger (#79) and the XvB fetch (#163).
    - **Fail silent.** Any network error (offline host, Tor down, Telegram unreachable / blocking a
      Tor exit) is swallowed and logged at debug — an alerter must never crash the data loop or spam
      ERROR for the very condition it exists to report (#59 discipline).
    - **Never logs the token.** ``bot_token`` is a secret; it only ever appears in the request
      URL and is never written to a log line — not even inside an exception message (which for
      ``requests`` would otherwise include the full URL).
    """

    def __init__(
        self,
        enabled=False,
        bot_token="",
        chat_id="",
        events=None,
        timeout=10,
        api_base=TELEGRAM_API_BASE,
        tor_proxy=TOR_SOCKS_PROXY,
    ):
        self.bot_token = (bot_token or "").strip()
        # chat_id may be a negative integer (Telegram group ids look like -1001234567890);
        # keep it as a string so render/transport never reformat it.
        self.chat_id = str(chat_id or "").strip()
        self.events = dict(events or {})
        self.timeout = timeout
        self._api_base = api_base.rstrip("/")
        # Route over the bridge Tor SOCKS proxy so the host IP is never exposed to Telegram.
        # tor_proxy is a test seam; the default wires the configured proxy.
        self._proxies = {"http": tor_proxy, "https": tor_proxy} if tor_proxy else None
        self.enabled = bool(enabled and self.bot_token and self.chat_id)

        if enabled and not self.enabled:
            # Switched on but unusable — tell the operator once, without leaking the token.
            logger.warning(
                "Telegram alerts enabled but bot_token/chat_id are missing — alerts stay off."
            )

    def event_enabled(self, event):
        """True only when the notifier is usable *and* this event kind is toggled on."""
        return self.enabled and bool(self.events.get(event, False))

    def send(self, text):
        """Push one message. Returns True on a successful 2xx send, False otherwise
        (including when disabled). Never raises."""
        if not self.enabled:
            return False

        url = f"{self._api_base}/bot{self.bot_token}/sendMessage"
        try:
            resp = requests.post(
                url,
                json={
                    "chat_id": self.chat_id,
                    "text": text,
                    "disable_web_page_preview": True,
                },
                timeout=self.timeout,
                proxies=self._proxies,
            )
            resp.raise_for_status()
            return True
        except requests.RequestException as exc:
            # Log only the exception *type*: a requests error message can embed the full URL,
            # which contains the bot token. Telegram being unreachable on a private/Tor-only
            # host is expected, so this stays at debug to avoid log noise.
            logger.debug("Telegram send failed (%s)", type(exc).__name__)
            return False
