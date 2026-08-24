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
# the control channel, one applied on the rig itself, and one restored from a saved config.
# ``restore`` is narrower than it reads: RigForge stamps it only for the operator-run ``restore
# <archive>`` command. The rig's own automatic rollback after a failed control change is NOT a
# restore — ``control_apply`` re-enters apply() still scoped to ``source=control`` carrying the same
# change id, and RigForge's own comment there says it means to. So a rollback reaches us as
# ``control``; ``config_origin`` is where that is untangled. Anything else is a rig speaking a
# dialect we do not know; it becomes None rather than reaching the operator's screen, because the
# whole value of this line is that the operator can trust who it names, and free text from the rig
# would let a compromised one write its own provenance.
CONFIG_SOURCES = ("control", "local", "restore")

# The one status that positively records a control change as having taken effect. This is an
# ALLOWLIST and that is the whole point (#1371): "Last changed from this dashboard" is the one
# confidently wrong answer this line can give, so it is reached only by a status that says the
# change held, never by the absence of a status that says it did not. The first shape of this check
# was the inverse — everything outside ``REVERTED_STATUSES`` read as ``here`` — which handed the
# reassuring answer to ``accepted`` (the rig took the request; it has not said it kept it) and to
# every status a future RigForge or a future dashboard might write. A denylist cannot be made
# fail-closed by lengthening it; only inverting it does that.
HELD_STATUSES = ("applied",)

# Among the statuses that are NOT in ``HELD_STATUSES``, the ones we can name precisely: the change
# reached the rig and the rig threw it away. RigForge's rollback re-apply stamps the SAME change id
# it just reverted, so the rig goes on naming a change that is no longer what it is running.
# ``rejected`` cannot reach us today (a rejected change returns before config.json is touched, so it
# is never stamped at all); it is listed for the wording, not for safety.
#
# This one stays a denylist on purpose, and it is safe to be one because it no longer decides
# anything the operator can be misled by: it picks the SPECIFIC wording among rows we have already
# refused to call ``here``. A status missing from it falls to ``unconfirmed``, which under-claims.
REVERTED_STATUSES = ("rolled_back", "failed", "rejected")

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


def config_origin(meta, change_id_known, change_status=None, history_truncated=False):
    """Where the rig's current config came from, as far as we can honestly tell.

    ``change_id_known`` is whether this dashboard has a ``worker_config`` row for the rig's
    ``last_change_id`` — the ids are minted by the rig's control server and handed back to us in the
    202, so a control change we made is one we can recognise by id. That comparison is what
    separates the two cases the operator most needs told apart:

    - ``here``      — applied over the control channel, with an id in our own history, and that row
                      records the change as having held.
    - ``reverted``  — applied over the control channel with an id we know, but our own history says
                      that change was rolled back or failed. RigForge's rollback re-apply re-stamps
                      the id it just reverted, so the rig keeps naming it while running whatever
                      preceded it. Saying ``here`` over this would print a calm "changed from this
                      dashboard" directly above a history row reading "Rolled back" in red.
    - ``unconfirmed``— applied over the control channel with an id we know, and our own row for it
                      records neither that it held nor that it was reverted (#1371). ``accepted``
                      is the one that actually happens: the rig acknowledged the request and our
                      reconciler has not yet caught the row up to a terminal outcome, so a rollback
                      that lost the race to the poll sits here indefinitely. Distinct from both
                      neighbours because it is the honest answer — we do not know — and folding it
                      into either would state something we cannot support.
    - ``elsewhere`` — applied over a control channel, with an id we have never seen. Another host,
                      or our record of it is gone. Either way it is not something to present as ours.
    - ``untraced``  — applied over a control channel, with an id we did not find, *and* the history
                      we searched was full to its limit (#1369). The id may sit one row past the
                      window, so "we have never seen it" is a claim the read cannot support and
                      ``elsewhere`` would print an accusation over a change that may well be ours.
                      ``history_truncated`` is what separates the two, and it is deliberately the
                      only thing this argument may do: when it is False every verdict is exactly
                      what it was before, so a caller that cannot tell loses nothing. That matters
                      most on the error path — ``get_worker_config_history`` returns ``[]`` on a
                      ``sqlite3.Error``, and an empty list is NOT a full window, so a DB hiccup
                      keeps today's ``elsewhere`` instead of being upgraded into a confident one.
    - ``rig``       — applied on the rig itself.
    - ``restored``  — restored from a saved config by the operator-run ``restore`` command.
                      Deliberately not folded into ``rig``: a restore is not someone editing the rig.
                      It does NOT cover the rig's automatic rollback, which arrives as ``control``.
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
        if not change_id_known:
            return "untraced" if history_truncated else "elsewhere"
        if change_status in HELD_STATUSES:
            return "here"
        if change_status in REVERTED_STATUSES:
            return "reverted"
        return "unconfirmed"
    if source == "local":
        return "rig"
    if source == "restore":
        return "restored"
    return "unrecorded"
