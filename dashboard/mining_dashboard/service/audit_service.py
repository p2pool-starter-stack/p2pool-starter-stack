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

import calendar
import hashlib
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


# The audit row id is the ONE field the #530 writer does not put through ``_clean``, and it is the
# ``audit_events`` PRIMARY KEY on a table with no retention prune (#1561) — so an oversized id is
# permanent. Callers build it from their own inputs, and on the rig-edit path that input is an
# unauthenticated worker's ``change_id``, validated upstream only as a non-empty ``str`` inside a
# body capped at 1 MiB. The bound has to clear every id this repo legitimately constructs: the
# longest is ``rig-drift-{worker}-{revision}`` at 10 + 128 (``_WORKER_NAME_RE``) + 1 + 64
# (``parse_config_meta``) = 203 characters.
MAX_EVENT_ID_LEN = 256

# Enough digest that distinct inputs stay distinct in practice; a sha256 prefix, not a truncation.
_EVENT_ID_DIGEST_LEN = 16


def clean_event_id(event_id):
    """``event_id`` as a bounded, charset-restricted, still-DETERMINISTIC audit row id (#1561).

    An id that survives ``_clean`` unchanged is returned verbatim, so every id this repo builds
    keeps the key it already has and no existing row is orphaned or duplicated. Anything the
    whitelist or the length cap would alter is replaced by its safe prefix plus a sha256 digest of
    the ORIGINAL, because bounding this field cannot be a plain truncation: two distinct long ids
    sharing a prefix would collapse to one row under ``INSERT OR IGNORE`` and LOSE a detection.
    The digest keeps the mapping one-way-collision-free while staying a pure function of the input,
    so a rig re-reporting the same change every poll still dedupes to exactly one row.

    Returns "" for a non-str or empty input, which is what the caller's ``or`` fallback to a random
    id is written against."""
    if not isinstance(event_id, str) or not event_id:
        return ""
    safe = _clean(event_id, MAX_EVENT_ID_LEN)
    if safe == event_id:
        return safe
    digest = hashlib.sha256(event_id.encode("utf-8", "surrogatepass")).hexdigest()
    keep = MAX_EVENT_ID_LEN - _EVENT_ID_DIGEST_LEN - 1
    return f"{safe[:keep]}-{digest[:_EVENT_ID_DIGEST_LEN]}"


def _tail_json_lines(path) -> list | None:
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


# Log-navigation filters (#823). One helper serves BOTH log surfaces even though their timestamps
# differ — access entries carry epoch seconds, audit entries the canonical "YYYY-MM-DDTHH:MM:SSZ"
# string — by normalizing each entry's ts to epoch at the comparison. The window is half-open
# [frm, to) so a "to" built from a date input's next midnight includes that whole day exactly
# once; an entry whose ts cannot be read matches NO window (filtering means placing entries in
# time — an undatable row has no place) but still matches a pure text search.


def _entry_epoch(ts) -> float | None:
    """``ts`` as epoch seconds, or None when unreadable. Accepts the two shapes the log surfaces
    actually emit: a number (access log) or the canonical UTC ISO string (audit trail)."""
    if isinstance(ts, (int, float)):
        return float(ts)
    if isinstance(ts, str):
        try:
            return float(calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")))
        except ValueError:
            return None
    return None


def filter_log_entries(entries, frm=None, to=None, q=None):
    """``entries`` narrowed to the [frm, to) epoch window and/or a case-insensitive substring
    ``q`` across every field value. Filters compose; None means "don't filter on this axis"."""
    ql = (q or "").lower()
    out = []
    for e in entries:
        if frm is not None or to is not None:
            ep = _entry_epoch(e.get("ts"))
            if ep is None:
                continue
            if frm is not None and ep < frm:
                continue
            if to is not None and ep >= to:
                continue
        if ql and not any(ql in str(v).lower() for v in e.values()):
            continue
        out.append(e)
    return out


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
