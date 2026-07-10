"""Dashboard side of the config-editor host-mutation channel (Issue #33).

The dashboard never mutates the host itself. It reads the host's ``config.json`` through a
read-only mount (secrets masked before anything is served), writes typed JSON *intents* into
the ``requests/`` spool — the only control directory the container can write — and polls the
``results/`` directory, which the host-side runner (``pithead control-run-pending``) writes and
the container mounts read-only. The rw/ro mount split in ``docker-compose.yml`` is the trust
boundary: the container can ask; it cannot forge a result, alter a staged intent, or rewrite
the host-side audit log.

Secret handling: known secret leaves are replaced with the ``{"__secret__": true}`` sentinel on
the way out (:func:`read_config`), and a sentinel coming back in a proposed config means
"unchanged" — :func:`merge_secrets` re-inserts the real value from the host config before the
intent is written, so a secret round-trips without ever reaching the browser.
"""

import json
import logging
import os
import re
import uuid

from mining_dashboard.config.config import (
    CONTROL_AUDIT_DIR,
    CONTROL_REQUESTS_DIR,
    CONTROL_RESULTS_DIR,
    HOST_CONFIG_PATH,
    HOST_REFERENCE_PATH,
)

logger = logging.getLogger("ControlService")

# The sentinel a masked secret is replaced with in GET /api/config, and the marker a proposed
# config sends back to mean "keep the current value".
SECRET_SENTINEL = {"__secret__": True}

# Every secret leaf in config.json, as key paths. Masked on read; sentinel-merged on write.
SECRET_PATHS = [
    ("dashboard", "auth", "password"),
    ("telegram", "bot_token"),
    ("workers", "api_token"),
    ("monero", "node_username"),
    ("monero", "node_password"),
    ("p2pool", "stratum_password"),
]

# Result files are looked up by client-supplied id; the id becomes a filename, so only a
# canonical uuid4 shape is ever accepted (same regex as the host-side runner).
_ID_RE = re.compile(r"^[0-9a-f-]{36}$")


def _get_path(cfg, path):
    """The value at a nested key path, or None when any segment is absent."""
    node = cfg
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    return node


def _set_path(cfg, path, value):
    """Set a nested key path, creating intermediate dicts as needed."""
    node = cfg
    for key in path[:-1]:
        node = node.setdefault(key, {})
    node[path[-1]] = value


def is_sentinel(value):
    """Whether a proposed leaf is the "keep the current secret" marker."""
    return isinstance(value, dict) and value.get("__secret__") is True


def _deep_merge(base, override):
    """Recursively lay ``override`` over ``base`` (dicts merge; any other value replaces)."""
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def read_config(path=None, reference_path=None):
    """The full config schema for the editor's form, secrets masked.

    ``config.reference.json`` (every key, with its default) is merged under the operator's
    sparse ``config.json``, so the form covers the whole schema — a missing reference file
    degrades to the host config alone. Every non-empty secret leaf is then masked to
    :data:`SECRET_SENTINEL`; an unset secret stays ``""`` so the form can tell "set — leave
    blank to keep" from "not set". Raises on an unreadable host config; the route maps that
    to a sanitized 500.
    """
    with open(path or HOST_CONFIG_PATH) as fh:
        cfg = json.load(fh)
    try:
        with open(reference_path or HOST_REFERENCE_PATH) as fh:
            reference = json.load(fh)
        reference.pop("_docs", None)
        cfg = _deep_merge(reference, cfg)
    except (OSError, ValueError):
        logger.warning("config.reference.json unavailable — serving the host config alone.")
    for secret_path in SECRET_PATHS:
        if _get_path(cfg, secret_path):
            _set_path(cfg, secret_path, dict(SECRET_SENTINEL))
    return cfg


def merge_secrets(proposed, path=None):
    """Replace every sentinel leaf in a proposed config with the real host value.

    A sentinel means "unchanged": the browser never saw the secret, so the real value is
    re-read from the host config here, just before the intent is written. A sentinel for a
    secret the host doesn't have collapses to ``""`` (nothing to keep). Non-sentinel values —
    including ``""`` to clear a secret — pass through untouched.
    """
    with open(path or HOST_CONFIG_PATH) as fh:
        current = json.load(fh)
    for secret_path in SECRET_PATHS:
        if is_sentinel(_get_path(proposed, secret_path)):
            _set_path(proposed, secret_path, _get_path(current, secret_path) or "")
    return proposed


def submit(action, config=None, actor="", intent_id=None, requests_dir=None):
    """Write one typed intent into the requests spool; returns the request id.

    Atomic (temp + rename) so the host runner — triggered by the very rename — never reads a
    half-written request. The temp name carries no ``.json`` suffix, so the runner's glob
    can't pick it up early.
    """
    rid = str(uuid.uuid4())
    intent = {"id": rid, "action": action, "actor": actor or "unknown"}
    if config is not None:
        intent["config"] = config
    if intent_id is not None:
        intent["intent_id"] = intent_id
    directory = requests_dir or CONTROL_REQUESTS_DIR
    tmp = os.path.join(directory, f".{rid}.tmp")
    with open(tmp, "w") as fh:
        json.dump(intent, fh)
    os.rename(tmp, os.path.join(directory, f"{rid}.json"))
    return rid


def result(request_id, results_dir=None):
    """The runner's result for a request id, or None while it's still pending.

    The id is validated against the uuid shape before it touches the filesystem — it comes
    from the browser and becomes a filename, so anything else is treated as "no result".
    """
    if not request_id or not _ID_RE.match(request_id):
        return None
    path = os.path.join(results_dir or CONTROL_RESULTS_DIR, f"{request_id}.json")
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def read_audit(limit=50, audit_dir=None):
    """The last ``limit`` audit entries (newest last); [] when there's no trail yet."""
    path = os.path.join(audit_dir or CONTROL_AUDIT_DIR, "audit.log")
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError:
        return []
    entries = []
    for line in lines[-limit:]:
        try:
            entries.append(json.loads(line))
        except ValueError:
            logger.warning("Skipping a malformed audit line.")
    return entries
