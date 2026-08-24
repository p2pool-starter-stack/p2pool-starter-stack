"""The rig's own account of when its writable config last changed, and what changed it (#1345).

RigForge v1.8.0 and newer stamp ``rigforge.config_meta`` onto the enriched ``/1/summary`` feed
(rigforge#254): ``{revision, changed_at, source, last_change_id}``. #1235 taught the Worker Inspect
editor to prefill from the rig's own ``config``, which fixed the *values* being wrong. It did not
answer the question the operator actually has when they disagree with their own record — did this
change come from here, or did something change it underneath me?

Two of these fields answer that, and they answer it in different ways:

``revision`` is recomputed by the rig from the config it is running, every time it serves the feed.
``changed_at`` / ``source`` / ``last_change_id`` come out of a marker file the rig writes when it
*records* a change. So a config edited on the rig and applied through RigForge stamps all four; a
config file edited underneath RigForge with nothing recording it moves only the revision.

The revision is a truncated SHA-256 over a jq-canonicalized form of the writable keys. Recomputing
it here would mean reproducing that canonical form byte for byte — key order, null handling, number
formatting — so this treats it as an opaque token to be shown and compared, never as something to
verify. A comparison we could get subtly wrong would report drift on a rig that has none.

Everything here is remote-supplied, from a device that picks its own response, so each field is
validated to the shape RigForge actually produces rather than passed through. That is the #1235
lesson applied one field further on: a filter that assumes the shape of the input it is defending
against is not a filter.
"""

import re

# Every value RigForge stamps into ``source`` (its ``_stamp_config_meta``): a change applied over
# the control channel, one applied on the rig itself, and one restored from a saved config — which
# includes the rig's own automatic rollback after a failed change, so it is NOT evidence that a
# person touched the rig. Anything else is a rig speaking a dialect we do not know; it becomes None
# rather than reaching the operator's screen, because the whole value of this line is that the
# operator can trust who it names, and free text from the rig would let a compromised one write its
# own provenance.
CONFIG_SOURCES = ("control", "local", "restore")

# Long enough for the ids RigForge actually mints (a 16-hex change id, a 16-hex revision) with room
# for a future format; short enough that a rig cannot push a wall of text into the operator's view.
_MAX_TOKEN_LEN = 64

# The exact stamp RigForge writes: `date -u +%Y-%m-%dT%H:%M:%SZ`. Matched rather than parsed — this
# only needs to decide whether to show the rig's word for it, and a value that is not that shape is
# not a timestamp we can render honestly.
_TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

# Ids and revisions are hex today. Allowing the usual id punctuation costs nothing and keeps a
# future RigForge format from reading as a hostile value.
_TOKEN_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def _token(value):
    """A short opaque id, or None. Anything that is not a plausible id is not shown at all."""
    if not isinstance(value, str) or not value or len(value) > _MAX_TOKEN_LEN:
        return None
    return value if _TOKEN_RE.match(value) else None


def parse_config_meta(meta):
    """Normalize the rig's ``config_meta`` block, or None when the rig said nothing usable.

    None is the honest answer for a plain-xmrig rig, for a RigForge older than v1.8.0, and for a rig
    whose block is unreadable — all three cases mean the same thing to the operator, which is that
    this rig cannot say where its config came from. A fresh RigForge rig that has simply never had a
    config change is different: it serves a real ``revision`` with the other three null, and that
    survives here as a meta with a revision and no provenance.
    """
    if not isinstance(meta, dict):
        return None
    source = meta.get("source")
    out = {
        "revision": _token(meta.get("revision")),
        "changed_at": (
            meta["changed_at"]
            if isinstance(meta.get("changed_at"), str) and _TS_RE.match(meta["changed_at"])
            else None
        ),
        "source": source if source in CONFIG_SOURCES else None,
        "last_change_id": _token(meta.get("last_change_id")),
    }
    return out if any(out.values()) else None


def config_origin(meta, change_id_known):
    """Where the rig's current config came from, as far as we can honestly tell.

    ``change_id_known`` is whether this dashboard has a ``worker_config`` row for the rig's
    ``last_change_id`` — the ids are minted by the rig's control server and handed back to us in the
    202, so a control change we made is one we can recognise by id. That comparison is what
    separates the two cases the operator most needs told apart:

    - ``here``      — applied over the control channel, with an id in our own history.
    - ``elsewhere`` — applied over a control channel, with an id we have never seen. Another host,
                      or our record of it is gone. Either way it is not something to present as ours.
    - ``rig``       — applied on the rig itself.
    - ``restored``  — restored from a saved config, which the rig also does on its own after a
                      failed change. Deliberately not folded into ``rig``: that would tell the
                      operator someone edited the rig when the rig may simply have rolled back.
    - ``unrecorded``— the rig is running a config whose change it never recorded. A fresh rig that
                      has never been changed looks exactly like this, and so does one whose config
                      file was edited underneath RigForge, so this claims neither.

    Returns None when there is no meta at all, which the UI must render as saying nothing rather
    than as saying "unknown" — an absent block is a rig too old to answer, not a suspicious one.
    """
    if not meta:
        return None
    source = meta.get("source")
    if source == "control":
        return "here" if change_id_known else "elsewhere"
    if source == "local":
        return "rig"
    if source == "restore":
        return "restored"
    return "unrecorded"
