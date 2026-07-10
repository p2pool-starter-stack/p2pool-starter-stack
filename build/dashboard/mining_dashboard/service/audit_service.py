"""Read-only views over the host-written security logs (#349).

Two sources, both mounted read-only: the #33 config-change audit trail
(``/control/audit/control.log``, one JSON line per handled control request) and Caddy's JSON
access log (``/access-log/access.log``) — the operator's brute-force signal, since over Tor there
is no source IP and the only useful pattern is the rate of 401s.

Every field read here is HOSTILE input: the access log echoes attacker-chosen strings (the
request URI, the attempted username), and a log line rendered raw into the dashboard would be
stored XSS against the operator — the exact attacker-to-operator direction the #33 reviews
guarded. ``_clean`` therefore whitelists a conservative ASCII charset (no ``<``, ``>``, quotes,
backslashes, or control characters) and caps length; nothing from either file is served
unfiltered. Growth is bounded by the writers, not here: the audit log is trimmed by
``control_audit`` and Caddy rolls its own access log — this module only ever reads a tail.
"""

import json
import os
import re
import time

from mining_dashboard.config import config

# Whitelist, not escape: strip every character outside a conservative ASCII set. Keeps
# timestamps, UUIDs, usernames, env-key names, and URL paths readable; drops anything that could
# carry markup or terminal escapes.
_SAFE_CHARS = re.compile(r"[^A-Za-z0-9 ._:;/@?&=%+#-]")

# Only ever displayed; anything else (attacker-invented verbs included) collapses to "?".
_KNOWN_METHODS = frozenset({"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})

# 401s in the last 24 h before the dashboard suggests rotating the password/onion. Low on
# purpose: the only legitimate 401s are the operator's own typos.
ROTATE_HINT_401S = 5

_TAIL_BYTES = 256 * 1024


def _clean(value, max_len=200):
    """``value`` as a display-safe string: whitelisted charset, length-capped."""
    if not isinstance(value, str):
        value = "" if value is None else str(value)
    return _SAFE_CHARS.sub("", value)[:max_len]


def _tail_json_lines(path):
    """The trailing complete JSON objects of ``path`` (newest last), or None if unreadable.

    Reads at most the last ``_TAIL_BYTES`` so a large log costs one bounded read; a partial
    first line from cutting into the middle of the file is dropped, as is any non-JSON line."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - _TAIL_BYTES))
            chunk = f.read()
    except OSError:
        return None
    lines = chunk.split(b"\n")
    if size > _TAIL_BYTES:
        lines = lines[1:]
    out = []
    for line in lines:
        try:
            obj = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def recent_changes(limit=50):
    """The newest config-change audit entries, sanitized, newest first.

    Explicit field whitelist — ts/id/actor/action/status/keys — so a foreign key smuggled into
    the log never reaches the browser. ``keys`` names WHAT changed (env-key names only; the
    writer never records values)."""
    raw = _tail_json_lines(config.CONTROL_AUDIT_LOG)
    if raw is None:
        return []
    entries = [
        {
            "ts": _clean(e.get("ts"), 32),
            "id": _clean(e.get("id"), 36),
            "actor": _clean(e.get("actor"), 64),
            "action": _clean(e.get("action"), 16),
            "status": _clean(e.get("status"), 32),
            "keys": _clean(e.get("keys"), 400),
        }
        for e in raw
    ]
    return entries[::-1][:limit]


def access_summary(limit=50, now=None):
    """Recent dashboard accesses plus the rotate-signal: 401s in the last 24 h.

    Shape: ``{available, entries, failures_24h, last_failure_ts, rotate_hint}``. ``available``
    is False until Caddy has written the log (pre-#349 deployments, or no request yet). Entries
    are newest first; ts is epoch seconds, status is clamped to a real HTTP range."""
    raw = _tail_json_lines(config.ACCESS_LOG_PATH)
    if raw is None:
        return {
            "available": False,
            "entries": [],
            "failures_24h": 0,
            "last_failure_ts": None,
            "rotate_hint": False,
        }
    now = time.time() if now is None else now
    entries = []
    failures = 0
    last_failure = None
    for e in raw:
        req = e.get("request") if isinstance(e.get("request"), dict) else {}
        try:
            ts = float(e.get("ts") or 0)
        except (TypeError, ValueError):
            ts = 0.0
        try:
            status = int(e.get("status") or 0)
        except (TypeError, ValueError):
            status = 0
        if not 100 <= status <= 599:
            status = 0
        method = req.get("method")
        entries.append(
            {
                "ts": ts,
                "status": status,
                "method": method if method in _KNOWN_METHODS else "?",
                "uri": _clean(req.get("uri")),
                "user": _clean(e.get("user_id"), 64),
            }
        )
        if status == 401 and now - ts <= 86400:
            failures += 1
            last_failure = ts if last_failure is None else max(last_failure, ts)
    return {
        "available": True,
        "entries": entries[-limit:][::-1],
        "failures_24h": failures,
        "last_failure_ts": last_failure,
        "rotate_hint": failures >= ROTATE_HINT_401S,
    }
