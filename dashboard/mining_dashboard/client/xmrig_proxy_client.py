import logging

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from mining_dashboard.helper.http import bounded_request


class XMRigProxyClient:
    def __init__(self, host="127.0.0.1", port=8080, access_token=None):
        """
        Initialize the XMRig Proxy Client.

        :param host: The hostname or IP address of the xmrig-proxy.
        :param port: The HTTP API port (configured via --http-port).
        :param access_token: The access token (configured via --http-access-token).
        """
        self.logger = logging.getLogger("ProxyClient")
        self.base_url = f"http://{host}:{port}"

        # Configure Session with Retries
        self.session = requests.Session()
        retry_strategy = Retry(
            total=3,
            # Never retry CONNECT failures: while the miner is held for first sync the proxy is
            # legitimately down, and the state loop calls this twice per cycle — with connect
            # retries each call burned ~7s of backoff, so every dashboard update (and the first
            # page paint) crawled for the whole sync, hours to days. Refused/no-route answers in
            # milliseconds; the retries stay for a RUNNING proxy's transient 5xx/429 hiccups.
            connect=0,
            backoff_factor=1,  # Wait 1s, 2s, 4s between retries
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET", "PUT", "OPTIONS"],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)

        if access_token:
            self.session.headers.update({"Authorization": f"Bearer {access_token}"})

    def get_summary(self):
        """
        Get proxy summary information including uptime, version, and resources.
        Endpoint: GET /1/summary

        Response:
        {
            "id": "str",
            "worker_id": "str",
            "uptime": int,
            "restricted": bool,
            "resources": {
                "memory": { "free": int, "total": int, "resident_set_memory": int },
                "load_average": [float, float, float],
                "hardware_concurrency": int
            },
            "features": ["str"],
            "version": "str",
            "kind": "str",
            "mode": "str",
            "ua": "str",
            "donate_level": int,
            "hashrate": { "total": [float, ...] },
            "miners": { "now": int, "max": int },
            "workers": int,
            "upstreams": { "active": int, "total": int, ... },
            "results": {
                "accepted": int, "rejected": int, "invalid": int, "expired": int,
                "avg_time": int, "hashes_total": int, "best": [int, ...]
            }
        }
        """
        url = f"{self.base_url}/1/summary"
        # Bounded (#1360). Highest trust class of that set: xmrig-proxy is our own container, but
        # this body is built from what MINERS advertise to it — the same boundary as #1347, one hop
        # back. ``session=`` keeps the retry adapter configured above.
        response = bounded_request("GET", url, timeout=5, session=self.session)
        response.raise_for_status()
        return response.json()

    def get_workers(self):
        """
        Get details about connected workers.
        Endpoint: GET /1/workers

        Response:
        {
            "hashrate": {
                "total": [float, ...]
            },
            "mode": "str",
            "workers": [
                [
                    "name",         // 0: Worker Name
                    "ip",           // 1: IP Address
                    int,            // 2: Connection count
                    int,            // 3: Accepted shares
                    int,            // 4: Rejected shares
                    int,            // 5: Invalid shares
                    int,            // 6: Total hashes
                    int,            // 7: Last share timestamp (ms)
                    float,          // 8: Hashrate 1m
                    float,          // 9: Hashrate 10m
                    float,          // 10: Hashrate 1h
                    float,          // 11: Hashrate 12h
                    float           // 12: Hashrate 24h
                ]
            ]
        }
        """
        url = f"{self.base_url}/1/workers"
        # Bounded (#1360). Highest trust class of that set: xmrig-proxy is our own container, but
        # this body is built from what MINERS advertise to it — the same boundary as #1347, one hop
        # back. ``session=`` keeps the retry adapter configured above.
        response = bounded_request("GET", url, timeout=5, session=self.session)
        response.raise_for_status()
        return response.json()

    def get_config(self):
        """
        Get the current configuration of the proxy.
        Endpoint: GET /1/config

        Response:
        {
            "pools": [
                {
                    "url": "str",
                    "user": "str",
                    "pass": "str",
                    "keepalive": bool,
                    "tls": bool
                }
            ],
            "bind": "str",                  // Bind address (e.g. "0.0.0.0:3333")
            "mode": "str",                  // Proxy mode ("nicehash" or "simple")
            "donate-level": int,            // Donation level percentage
            "custom-diff": int,             // Global custom difficulty
            "api": {
                "port": int,
                "access-token": "str",
                "worker-id": "str",
                "ipv6": bool,
                "restricted": bool
            },
            "log-file": "str"
        }
        """
        url = f"{self.base_url}/1/config"
        # Bounded (#1360). Highest trust class of that set: xmrig-proxy is our own container, but
        # this body is built from what MINERS advertise to it — the same boundary as #1347, one hop
        # back. ``session=`` keeps the retry adapter configured above.
        response = bounded_request("GET", url, timeout=5, session=self.session)
        response.raise_for_status()
        return response.json()

    def update_config(self, config_data):
        """
        Update the proxy configuration.
        Endpoint: PUT /1/config

        :param config_data: A dictionary containing the configuration fields to update.

        Body:
        {
            "pools": [
                {
                    "url": "host:port",
                    "user": "wallet_address",
                    "pass": "x"
                }
            ],
            "donate-level": int
            ... (Any other config fields to update)
        }
        """
        url = f"{self.base_url}/1/config"
        response = bounded_request("PUT", url, json=config_data, timeout=5, session=self.session)
        response.raise_for_status()
        # Handle 204 No Content or empty responses which cause JSON decode errors
        if response.status_code == 204 or not response.content:
            return {}
        return response.json()
