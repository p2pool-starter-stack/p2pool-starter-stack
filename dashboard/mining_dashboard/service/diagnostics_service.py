"""Spooling for the read-only diagnostics verbs (#913 doctor detail, #943 log tail).

Split out of control_service.py rather than added to it: that module is at its recorded line
ceiling, and these two intents are the only ones in the channel that carry no operator input the
host must gate — they ASK for a report and mutate nothing, which is why they skip the approval
path every committing verb goes through.

WHAT IS DELIBERATELY NOT HERE: a copy of the host's container allowlist. The authority is
PITHEAD_DIAG_CONTAINERS in lib/pithead/46a-control-diagnostics.sh, which matches by exact
membership; a second list in this container is how the two drift, and the drift would fail in the
direction that looks like a dashboard bug. This module checks only that the name is a plausible
compose service (charset + length), so a malformed request gets a fast, clear 400 instead of a
round-trip; deciding whether a WELL-FORMED name may be read is the host's, and its refusal comes
back as a "rejected" result the panel shows verbatim.
"""

import json
import os
import re
import uuid

from mining_dashboard.config import config

# Compose service names: the charset docker-compose itself allows. Not an allowlist — a shape
# check. Anything passing this still has to survive the host's membership test.
_CONTAINER_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,62}$")

# Mirrors PITHEAD_DIAG_MAX_LINES so the picker can't offer more than the host will serve. The
# host clamps regardless — it does not trust this number, and neither should a reader.
MAX_TAIL_LINES = 200


def valid_container(name) -> bool:
    """True if ``name`` is shaped like a compose service. Says nothing about whether it is
    readable — see the module docstring."""
    return isinstance(name, str) and bool(_CONTAINER_RE.match(name))


def _spool(request: dict) -> str:
    """Atomic write into the requests spool: temp + rename, so the host runner never reads a
    half-written file. The same four lines appear in control_service.submit* — folding all four
    into one writer is a worthwhile change and a different one; it is filed, not done here,
    because control_service.py has no line budget left to receive it."""
    rid = request["id"]
    tmp = os.path.join(config.CONTROL_REQUESTS_DIR, f".{rid}.tmp")
    with open(tmp, "w") as f:
        json.dump(request, f)
    os.replace(tmp, os.path.join(config.CONTROL_REQUESTS_DIR, f"{rid}.json"))
    return rid


def submit_diag_doctor(actor: str = "") -> str:
    """Spool a `doctor --json` request (#913). Takes no operator input at all."""
    return _spool({"id": str(uuid.uuid4()), "action": "diag-doctor", "actor": actor})


def submit_diag_logs(container: str, lines: int, actor: str = "") -> str:
    """Spool a bounded log-tail request for one container (#943).

    ``lines`` is a REQUEST, not a bound: the host clamps it to its own cap and falls back to that
    cap on anything non-numeric, so a tampered intent can at most ask for what the host was
    already willing to give."""
    return _spool(
        {
            "id": str(uuid.uuid4()),
            "action": "diag-logs",
            "actor": actor,
            "container": container,
            "lines": lines,
        }
    )
