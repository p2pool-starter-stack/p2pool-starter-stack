import asyncio
import json
import logging
import re
import struct

import aiofiles
import aiohttp

from mining_dashboard.client.monero.monero_client import MoneroClient
from mining_dashboard.config.config import (
    DOCKER_PROXY_URL,
    DOCKER_TIMEOUT,
    LOCAL_MONERO_HOST,
    LOG_TAIL_LINES,
    MONERO_NODE_HOST,
    NETWORK_STATS_PATH,
)
from mining_dashboard.helper.http import MAX_RESPONSE_BYTES, bounded_read

logger = logging.getLogger("LogCollector")

# The log read is the one bounded site (#1360) where a legitimately large body exists, so the cap
# is derived from what the operator asked for rather than fixed. ``tail`` bounds LINES, never bytes,
# so a container emitting very long lines is unbounded — and container logs carry miner-supplied
# strings (worker names, pool messages), which is why "our own daemon serves it" is not the question.
#
# 16 KiB is where Docker's json-file driver splits a log line, so ``tail * 16 KiB`` is the ceiling a
# well-behaved daemon can legitimately produce for the requested number of lines. The 1 MiB floor
# keeps the default (100 lines) generous. A cap set too tight is worse than the exhaustion it
# prevents, because it presents to the operator as the far end being broken rather than as a refusal.
#
# Both halves of that were measured against a live stack (#1360), because they are claims about an
# external system rather than about our code. The driver does split at exactly 16384 payload bytes: a
# single 40,960-byte line came back as frames of 16384 / 16384 / 8193. And the half the derivation
# silently depends on — ``tail=N`` counts FRAMES, not logical lines — holds too: ``tail=1`` against
# that three-frame line returns only its last 8193-byte fragment. Were ``tail`` counting logical
# lines, no per-line constant could bound the response at all.
_LOG_BYTES_PER_LINE = 16 * 1024

# ...but the payload is not the whole frame. Docker prefixes each one with an 8-byte header (stream
# type, three pad bytes, then a big-endian uint32 payload size — see ``_parse_docker_stream``), and
# ``bounded_read`` counts RAW STREAM bytes, headers included. A cap of ``tail * 16 KiB`` is therefore
# short by ``tail * 8`` against what a completely full window legitimately weighs, so the maximally
# packed case — the exact case the ceiling exists to admit — was refused. Measured: three frames
# whose payloads sum to 40,961 arrive as 40,985 raw bytes.
_LOG_FRAME_HEADER = 8


def _log_cap(tail):
    """The byte cap for a ``tail``-line log read: the 1 MiB floor, or what ``tail`` completely full
    frames actually weigh on the wire, whichever is larger. Exposed rather than inlined so a test
    cannot restate the arithmetic and quietly drift from it."""
    return max(MAX_RESPONSE_BYTES, int(tail) * (_LOG_BYTES_PER_LINE + _LOG_FRAME_HEADER))


# Stateless client reused across cycles; reads monerod's get_info RPC (Issue #29).
_monero_client = MoneroClient()


async def fetch_docker_logs(container_name, tail=None):
    """
    Fetches logs from a container via the Docker Socket Proxy.
    Handles the Docker binary stream format (multiplexed stdout/stderr).
    """
    if tail is None:
        tail = LOG_TAIL_LINES

    # Ensure URL scheme is http for aiohttp, even if env var is tcp://
    base_url = DOCKER_PROXY_URL
    if base_url.startswith("tcp://"):
        base_url = base_url.replace("tcp://", "http://")

    # Docker Engine API: /containers/{id}/logs
    url = f"{base_url}/containers/{container_name}/logs"
    params = {"stdout": 1, "stderr": 1, "tail": tail}

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, params=params, timeout=DOCKER_TIMEOUT) as response:
                if response.status == 200:
                    raw_data = await bounded_read(
                        response.content,
                        max_bytes=_log_cap(tail),
                        what=f"{container_name} logs",
                    )
                    return _parse_docker_stream(raw_data)
                else:
                    logger.error(
                        f"Failed to fetch logs for {container_name}. Status: {response.status}"
                    )
                    return [f"Error: Could not retrieve logs (Status {response.status})"]
    except Exception as e:
        logger.error(f"Error connecting to Docker Proxy at {base_url}: {e}")
        return ["Error: Connection to Docker Proxy failed."]


def _parse_docker_stream(data):
    """
    Parses the Docker raw stream format.
    Header format (8 bytes): [STREAM_TYPE] [0 0 0] [SIZE (Big Endian uint32)]
    """
    logs = []
    i = 0
    n = len(data)

    while i < n:
        if i + 8 > n:
            break

        payload_size = struct.unpack(">I", data[i + 4 : i + 8])[0]

        i += 8
        if i + payload_size > n:
            break

        line = data[i : i + payload_size].decode("utf-8", errors="replace").strip()
        if line:
            logs.append(line)

        i += payload_size

    return logs


async def get_monero_logs(tail=None):
    return await fetch_docker_logs("monerod", tail=tail)


async def _get_remote_monero_sync_status():
    """
    Reads monerod sync status from the local stats file generated by p2pool.
    """
    try:
        async with aiofiles.open(NETWORK_STATS_PATH) as f:
            contents = await f.read()
            if not contents:
                return {"is_syncing": False}

            stats = json.loads(contents)

            current_height = stats.get("height", 0)
            target_height = stats.get("target_height", 0)

            if target_height > 0 and current_height < target_height:
                percent = int((current_height / target_height) * 100)
                return {
                    "is_syncing": True,
                    "current": current_height,
                    "target": target_height,
                    "percent": percent,
                }
            else:
                return {"is_syncing": False}

    except FileNotFoundError:
        logger.warning(f"Network stats file not found at {NETWORK_STATS_PATH}")
        return {"is_syncing": False}
    except json.JSONDecodeError:
        logger.error(f"Failed to parse JSON from {NETWORK_STATS_PATH}")
        return {"is_syncing": False}
    except Exception as e:
        logger.error(f"Error reading monero sync status: {e}")
        return {"is_syncing": False}


async def _get_local_monero_sync_status():
    """
    Sync status for a local monerod.

    Prefers monerod's get_info RPC (format-stable, Issue #29); the RPC runs in a thread
    because the client is synchronous (requests + digest auth). Falls back to scraping
    docker logs when the RPC is unreachable — e.g. creds not plumbed into the dashboard
    env, or monerod briefly down — so this is never worse than the previous behaviour.
    """
    rpc_status = await asyncio.to_thread(_monero_client.get_sync_status)
    if rpc_status is not None:
        # RPC answered → monerod is reachable. `reachable` drives node-down detection
        # (Issue #31); it's distinct from is_syncing (a synced node is reachable).
        rpc_status["reachable"] = True
        return rpc_status
    # RPC unreachable this cycle: fall back to log scraping for the display value, but
    # report the node as not reachable so the down-detector can act on a sustained outage.
    # (Old docker logs persist after monerod dies, so log success != monerod up.)
    status = await _get_monero_sync_status_from_logs()
    status["reachable"] = False
    return status


async def _get_monero_sync_status_from_logs():
    """
    Parses local monerod docker logs to determine if the node is currently syncing.

    Recent monerod (v0.18.x at log-level 0) no longer prints the old "Synced N/M"
    progress line — it logs "... top block candidate: CURRENT -> TARGET ..." instead.
    We match both formats, and read a larger tail so the DNS-blocklist "Host ... blocked"
    spam can't push the most recent sync line out of the window.
    """
    logs = await get_monero_logs(tail=250)
    if not logs or (len(logs) == 1 and logs[0].startswith("Error")):
        return {"is_syncing": False}

    for line in reversed(logs):
        if "You are now synchronized" in line:
            return {"is_syncing": False}

        # Old format: "Synced 1351344/3686301 (36%, ...)"
        match = re.search(r"Synced\s+(\d+)/(\d+)", line)
        # Current format: "... top block candidate: 1351344 -> 3686301 [Your node is ...]"
        if not match:
            match = re.search(r"top block candidate:\s*(\d+)\s*->\s*(\d+)", line)

        if match:
            current = int(match.group(1))
            target = int(match.group(2))

            if target == 0 or current >= target:
                return {"is_syncing": False}

            percent = 0
            pct_match = re.search(r"\((\d+)%", line)
            if pct_match:
                percent = int(pct_match.group(1))
            elif target > 0:
                percent = int((current / target) * 100)

            return {"is_syncing": True, "current": current, "target": target, "percent": percent}

    return {"is_syncing": False}


async def get_monero_sync_status():
    """
    Determines whether to check local docker logs or P2Pool's network stats
    based on the configured MONERO_NODE_HOST.
    """
    if MONERO_NODE_HOST == LOCAL_MONERO_HOST:
        return await _get_local_monero_sync_status()
    # Remote node: we don't probe its RPC, so report it reachable — the reject-workers
    # feature (Issue #31) deliberately no-ops for remote nodes (p2pool manages those).
    status = await _get_remote_monero_sync_status()
    status.setdefault("reachable", True)
    return status
