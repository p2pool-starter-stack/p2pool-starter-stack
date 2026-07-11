"""Dashboard side of the host-mutation control channel (#33).

The container can only ASK. This module reads the host-rendered PRE-MASKED config copy (#440) to
prefill the editor form, writes typed JSON intents into the requests/ spool — the container's
single writable leg — and reads results back from the read-only results/ mount. The host-side
runner (``pithead control-run-pending``) re-validates and executes; nothing here runs a command.

Secrets never enter the container: the host masks every set secret to the ``{"__secret__": true}``
sentinel before the copy is mounted (the raw config.json is not mounted at all), a proposal
carries the sentinel back for an untouched secret, and the host swaps it for the live value when
it stages the intent. ``read_config`` re-applies the same masking as defense-in-depth.
"""

import asyncio
import json
import logging
import os
import time
import uuid

from mining_dashboard.config import config

logger = logging.getLogger("ControlService")

# Config paths whose leaves are secrets. Mirrors pithead's CONTROL_SECRET_PATHS (the host-side
# masking source, #440) — keep the two lists in step.
SECRET_PATHS = [
    ("dashboard", "auth", "password"),
    ("telegram", "bot_token"),
    ("workers", "api_token"),
    ("monero", "node_username"),
    ("monero", "node_password"),
    # The private view key (#381): reveals all incoming payout amounts/timing to anyone who reads it.
    ("monero", "view_key"),
    ("p2pool", "stratum_password"),
    # A capability secret: pithead's describe_change already refuses to echo it, but read_config
    # was serving it in cleartext to the browser. Mask it too (#33 hardening).
    ("healthchecks", "ping_url"),
]
SECRET_SENTINEL = {"__secret__": True}

_RESULT_POLL_S = 0.5


def _load_host_config():
    """The host-rendered, pre-masked config copy (#440) — no raw secret ever crosses the mount."""
    with open(config.HOST_CONFIG_PATH) as f:
        return json.load(f)


def _get(cfg, path):
    """Walk ``path`` through nested dicts. Returns (found, value)."""
    node = cfg
    for key in path[:-1]:
        if not isinstance(node, dict) or key not in node:
            return False, None
        node = node[key]
    if not isinstance(node, dict) or path[-1] not in node:
        return False, None
    return True, node[path[-1]]


def _set(cfg, path, value):
    node = cfg
    for key in path[:-1]:
        node = node[key]
    node[path[-1]] = value


def _deep_merge(base, override):
    """Recursively lay ``override`` over ``base`` (dicts merge; any other value replaces)."""
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def read_config():
    """The full config schema for the editor's form, every set secret masked to the sentinel.

    ``config.reference.json`` (every key with its default) is merged UNDER the host's sparse,
    pre-masked copy so the form covers the whole schema — a missing/unreadable reference degrades
    to the host copy alone (graft #437). An *empty* secret stays empty, so the UI can tell
    "set — leave blank to keep" from "not set". The copy arrives already masked (#440); the
    masking pass here is defense-in-depth and runs AFTER the merge."""
    cfg = _load_host_config()
    try:
        with open(config.HOST_REFERENCE_PATH) as f:
            reference = json.load(f)
        reference.pop("_docs", None)
        cfg = _deep_merge(reference, cfg)
    except (OSError, ValueError):
        logger.warning("config.reference.json unavailable — serving the host config alone.")
    for path in SECRET_PATHS:
        found, value = _get(cfg, path)
        if found and value:
            _set(cfg, path, dict(SECRET_SENTINEL))
    return cfg


def submit(action, cfg=None, actor="", intent_id=None, version=None):
    """Write one intent into the requests spool (atomic: temp + rename, so the runner never
    reads a half-written file). Returns the request id — always a UUID, because the id becomes
    a host-side filename and the runner rejects anything else. ``version`` rides only on the
    upgrade intent (#59): the version the operator confirmed, which the host re-verifies
    against the GitHub release API — a proposal, never a target the container picks."""
    rid = str(uuid.UUID(intent_id)) if intent_id else str(uuid.uuid4())
    request = {"id": rid, "action": action, "actor": actor}
    if cfg is not None:
        request["config"] = cfg
    if version is not None:
        request["version"] = version
    tmp = os.path.join(config.CONTROL_REQUESTS_DIR, f".{rid}.tmp")
    with open(tmp, "w") as f:
        json.dump(request, f)
    os.replace(tmp, os.path.join(config.CONTROL_REQUESTS_DIR, f"{rid}.json"))
    return rid


def result(rid):
    """The runner's result for ``rid``, or None while pending. The id is validated as a UUID
    before it touches a path (it arrives from a query param)."""
    rid = str(uuid.UUID(rid))
    try:
        with open(os.path.join(config.CONTROL_RESULTS_DIR, f"{rid}.json")) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


async def wait_result(rid, done=None, timeout_s=None):
    """Poll for the result until ``done(result)`` (default: any result exists) or timeout;
    returns the result dict or None. Commit passes a predicate that skips the still-present
    preview result (same id) until the runner overwrites it with the commit outcome."""
    if timeout_s is None:
        timeout_s = config.CONTROL_WAIT_S
    deadline = time.monotonic() + timeout_s
    while True:
        res = result(rid)
        if res is not None and (done is None or done(res)):
            return res
        if time.monotonic() >= deadline:
            return None
        await asyncio.sleep(_RESULT_POLL_S)
