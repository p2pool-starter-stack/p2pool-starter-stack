import logging

import aiohttp

from mining_dashboard.config.config import DOCKER_CONTROL_URL, DOCKER_TIMEOUT
from mining_dashboard.helper.http import bounded_read

logger = logging.getLogger("DockerControl")


class DockerControl:
    """
    Narrow start/stop control of stack containers (Issue #31).

    Goes through a dedicated `docker-control` socket proxy whose ruleset allows exactly
    `POST /containers/<id>/{start,stop}` and nothing else — not the read-only `docker-proxy`
    the dashboard uses for stats/logs. (tecnativa/docker-socket-proxy v0.5.0 denies all POST
    unless POST=1, and POST=1 on the read proxy would also open create/kill/exec via its
    CONTAINERS grant — so container control lives on its own minimal proxy instead.)

    Stopping (not pausing) is deliberate: a stopped container closes its published port,
    so miners get a clean disconnect and fail over to their backup pools; a paused one
    leaves the port open-but-dead and they stall instead.
    """

    def __init__(self, proxy_url=DOCKER_CONTROL_URL, timeout=DOCKER_TIMEOUT):
        # aiohttp needs an http:// scheme even though the env var uses tcp://.
        base = proxy_url
        if base.startswith("tcp://"):
            base = base.replace("tcp://", "http://")
        self.base_url = base.rstrip("/")
        self.timeout = timeout

    async def stop(self, container, stop_timeout=10, quiet=False, request_timeout=None):
        """Stop a container. Returns True on success (incl. already-stopped).

        `quiet` logs success at debug instead of info — used by the sync-gate hold (#35),
        which re-asserts the stop every cycle and would otherwise flood the log for hours.
        `request_timeout` overrides the HTTP timeout: Docker holds the stop request open until
        the container is down (up to `stop_timeout` seconds before SIGKILL), so a slow-stopping
        daemon needs an HTTP timeout that OUTLASTS `stop_timeout` or the call gives up early and
        wrongly reports failure (#234: Tari took >5s to stop, so the default timeout aborted it).
        """
        return await self._post(
            f"/containers/{container}/stop",
            params={"t": stop_timeout},
            action="stop",
            container=container,
            quiet=quiet,
            request_timeout=request_timeout,
        )

    async def start(self, container, quiet=False, request_timeout=None):
        """Start a container. Returns True on success (incl. already-running)."""
        return await self._post(
            f"/containers/{container}/start",
            params=None,
            action="start",
            container=container,
            quiet=quiet,
            request_timeout=request_timeout,
        )

    async def _post(self, path, params, action, container, quiet=False, request_timeout=None):
        url = f"{self.base_url}{path}"
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    url, params=params, timeout=request_timeout or self.timeout
                ) as resp:
                    # 204 No Content = done; 304 Not Modified = already in that state
                    # (Docker's idempotent response) — both are success for us.
                    if resp.status in (204, 304):
                        log = logger.debug if quiet else logger.info
                        log(f"Container {container} {action}: ok (HTTP {resp.status})")
                        return True
                    # Bounded (#1360). The 200-char slice below only ever trimmed the LOG LINE —
                    # the whole body was buffered first, so an error response was the one path
                    # here that read without a limit.
                    raw = await bounded_read(resp.content, what=f"{container} {action} error")
                    body = raw.decode("utf-8", errors="replace")
                    logger.error(
                        f"Container {container} {action} failed: HTTP {resp.status} {body[:200]}"
                    )
                    return False
        except Exception as e:
            logger.error(f"Container {container} {action} error via {self.base_url}: {e}")
            return False
