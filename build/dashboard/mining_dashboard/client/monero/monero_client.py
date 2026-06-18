import logging
import requests
from requests.auth import HTTPDigestAuth

from mining_dashboard.config.config import (
    MONERO_RPC_URL,
    MONERO_NODE_USERNAME,
    MONERO_NODE_PASSWORD,
)

logger = logging.getLogger("MoneroClient")


class MoneroClient:
    """
    Reads monerod state from its `get_info` RPC instead of scraping docker logs.

    The dashboard runs `network_mode: host` and monerod publishes 127.0.0.1:18081, so
    the RPC is directly reachable. Reading height/target_height from `get_info` is
    format-stable, unlike the log line (which broke once already when v0.18.x changed
    "Synced N/M" to "... top block candidate: X -> Y").

    monerod runs with `restricted-rpc=1` + `rpc-login`, so calls use HTTP digest auth.
    This client is synchronous (requests + HTTPDigestAuth); the async data loop calls it
    via `asyncio.to_thread`, mirroring how XvbClient / proxy_client are used.
    """

    def __init__(
        self,
        url=MONERO_RPC_URL,
        username=MONERO_NODE_USERNAME,
        password=MONERO_NODE_PASSWORD,
        timeout=5,
    ):
        self.url = url.rstrip("/") + "/get_info"
        # No creds (e.g. a remote node deployment) → send unauthenticated; the request
        # will simply fail and the caller falls back to log scraping.
        self._auth = HTTPDigestAuth(username, password) if username else None
        self.timeout = timeout

    def get_info(self):
        """Return monerod's `get_info` payload as a dict, or None if unreachable/errored."""
        try:
            resp = requests.get(self.url, auth=self._auth, timeout=self.timeout)
        except requests.RequestException as e:
            logger.warning(f"monerod get_info unreachable at {self.url}: {e}")
            return None

        if resp.status_code != 200:
            logger.warning(f"monerod get_info returned HTTP {resp.status_code}")
            return None

        try:
            data = resp.json()
        except ValueError:
            logger.error("monerod get_info returned a non-JSON body")
            return None

        # get_info embeds its own status string; anything other than OK (e.g. "BUSY")
        # means the heights aren't trustworthy yet.
        status = data.get("status")
        if status not in (None, "OK"):
            logger.warning(f"monerod get_info status={status}")
            return None

        return data

    def get_sync_status(self):
        """
        Map `get_info` onto the dashboard's sync dict.

        Returns the same shape as the log-scraping path so it's a drop-in:
          - syncing:   {"is_syncing": True, "current", "target", "percent", "db_size"}
          - synced:    {"is_syncing": False, "db_size"}
          - unreachable: None  (signals the caller to fall back to log scraping)

        `db_size` is monerod's on-disk database size in bytes (from get_info, available even
        under restricted RPC). The UI shows it next to the configured pruned/full mode so a
        config/DB mismatch is visible at a glance (Issue #32).
        """
        info = self.get_info()
        if info is None:
            return None

        height = int(info.get("height", 0) or 0)
        target = int(info.get("target_height", 0) or 0)
        db_size = int(info.get("database_size", 0) or 0)

        # `synchronized` is monerod's authoritative "caught up" flag; once synced it also
        # reports target_height: 0. Trust it over the height comparison (mirrors how the
        # Tari client trusts initial_sync_achieved).
        if info.get("synchronized") or target == 0 or height >= target:
            return {"is_syncing": False, "db_size": db_size}

        percent = int((height / target) * 100)
        return {
            "is_syncing": True,
            "current": height,
            "target": target,
            "percent": percent,
            "db_size": db_size,
        }
