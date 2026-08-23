"""Click-to-adopt a rig: the dashboard-side half of the adopt flow (the operator-decision
comment, issue #893).

The write itself rides the EXISTING control-channel config path — the same preview/commit
mechanics ``ConfigView`` uses for any other edit (no new write endpoint, ``web/server.py``
``handle_control_preview``/``handle_control_commit``). This module only builds the one guard that
path needs to carry a ``workers.list[]`` write at all: ``pithead``'s ``control_approval_gate``
(``pithead`` ~L9695) refuses ANY diff to the per-worker descriptors outright — deliberately, since
they hold per-rig hosts and bearer tokens (the #122 SSRF class) — with a single narrow exception
for a strictly ADD-ONLY append (a brand-new descriptor; every already-live entry must reappear
byte-for-byte). That host-side gate is the actual security authority and is exercised at commit.

What lives here is the *dashboard-side* mirror of the same shape/charset validation pithead's own
``validate_worker_endpoints`` applies (defense in depth, the same pattern ``control_service``'s
``SECRET_PATHS``/``EDITABLE_ENV_KEY_PATHS`` already follow), wired into ``handle_control_preview``
so a malformed adopt submission is refused before it ever reaches the spool — never a
miner-advertised value auto-trusted: the host field the operator confirms is still just a
PREFILL, and every field here is exactly what the operator typed or edited in the adopt form.
"""

import re

# Mirrors pithead's per-entry regexes (``validate_worker_endpoints``, pithead ~L5901) byte for
# byte: the host charset in particular is the #122 guard — letters/digits/dot/dash/underscore
# only, so a submitted value can never smuggle a port, path, or userinfo into a probe URL.
NAME_RE = re.compile(r"^[!-~]{1,128}$")
HOST_RE = re.compile(r"^[A-Za-z0-9._-]{1,253}$")
TOKEN_RE = re.compile(r"^[!-~]{1,128}$")

# RigForge's default writable control-API port (rigforge#185); the adopt form prefills it and the
# operator may override it, same as any other ``workers.list[].control_port``.
DEFAULT_CONTROL_PORT = 8082


def validate_worker_descriptor(entry):
    """Return an error string for a malformed new ``workers.list[]`` entry, else ``""``.

    Unlike pithead's own per-field validation (where host/port/token are each individually
    optional), an ADOPTED entry must carry all three — a descriptor with a name but no host/token
    is not a write target (``resolve_worker_target`` would refuse it anyway), so refusing it here
    gives the operator an immediate, specific reason instead of a spooled request that could only
    ever come back rejected.
    """
    if not isinstance(entry, dict):
        return "a new worker entry must be an object."
    name = entry.get("name")
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        return "a new worker needs a name of 1-128 printable, non-space characters."
    host = entry.get("host")
    if not isinstance(host, str) or not HOST_RE.fullmatch(host):
        return (
            f"worker '{name}': host must be a hostname or IPv4 address "
            "(letters, digits, and . _ - only — no port or path)."
        )
    control_port = entry.get("control_port", DEFAULT_CONTROL_PORT)
    if (
        isinstance(control_port, bool)
        or not isinstance(control_port, int)
        or not 1 <= control_port <= 65535
    ):
        return f"worker '{name}': control_port must be an integer between 1 and 65535."
    token = entry.get("token")
    if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
        return f"worker '{name}': a control token is required — the rig's control API is bearer-mandatory."
    return ""


def new_worker_entries(live_cfg, staged_cfg):
    """The entries a staged config would ADD to ``workers.list[]``, or ``[]`` if the staged list
    isn't a pure append of the live one (a non-append change is left for the host's own add-only
    gate to refuse, with its own message — this only identifies the genuinely-new tail to
    pre-validate)."""
    live_list = ((live_cfg or {}).get("workers") or {}).get("list")
    staged_list = ((staged_cfg or {}).get("workers") or {}).get("list")
    live_list = live_list if isinstance(live_list, list) else []
    if not isinstance(staged_list, list):
        return []
    if staged_list[: len(live_list)] != live_list:
        return []
    return staged_list[len(live_list) :]


def validate_new_worker_entries(live_cfg, staged_cfg):
    """The first validation error among the entries a staged config would newly append to
    ``workers.list[]``, or ``""`` if every new entry is well-formed (including "no new entries")."""
    for entry in new_worker_entries(live_cfg, staged_cfg):
        err = validate_worker_descriptor(entry)
        if err:
            return err
    return ""
