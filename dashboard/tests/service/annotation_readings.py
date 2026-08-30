"""#1556's read exceptions: the `unjudged` functions somebody read, with the reading beside each.

Nothing here is a test and nothing here asserts anything. Law 2 and the vacuity guard that read
this set live in `test_annotation_coverage.py`; `annotation_pins.py` beside this file holds the
other half of the pin's data, `PINNED` and `_ANCHORS`. Read that file's docstring for what a pin
is and this one only for what an exception is.

An entry means a human read the function and wrote the reading down. It does NOT certify the
design, and nothing may be added because `annotation_gate.classify` happened to score it
`unjudged` — that is the baseline #1487 refused, wearing the pin's name. Each reading is the
entry's justification, so the two travel together: an entry whose argument is somewhere else is an
entry nobody can check.

## Why this is its own module

`annotation_pins.py` reached exactly 400 lines at slice 11, and 400 is the line at which
`scripts/lint-file-budget.sh` obliges a `docs/dev/file-budget.tsv` row. That file's own docstring
had already named this moment and what to do at it — "if it ever crosses 400 that is the moment to
re-read the split, not to raise a number" — and slice 12 owed two more readings than would fit.

A row would in fact have PASSED the gate, measured rather than assumed: `check_monotonic` iterates
the BASE branch's budget and compares only paths present in both, so a path with no base row is not
a raise and nothing rejects it. It was still refused. A row is a one-way door — from then on that
ceiling only ever falls — so taking one means recording a number nobody intends to honour, in a
file whose whole worth is that its rows are ceilings somebody meant. The gate would have allowed
what the ratchet exists to prevent, which is an argument about the gate's reach and not a licence.

The cut is between two datasets, never between an entry and its argument. `PINNED`/`_ANCHORS`
kept their comments and this set kept its readings, so no entry in either file lost the paragraph
that justifies it. The moved block came across VERBATIM — 5,700 bytes of comment prose, checked
present unchanged with a control that a one-token alteration is reported as absent — because
nothing inside it pointed anywhere. What the move DID falsify was six sentences in
`annotation_pins.py` that pointed AT this set: its opening line, its "adds an entry" sentence, its
underscore section, its record of the first split, slice 9's "filed with its entry below", and the
`_ANCHORS` comment's note about the separate vacuity guard. All six were corrected in the same
commit, which is the only reason that count is worth stating.

## The name keeps its leading underscore

`_UNJUDGED_AND_READ` is imported by name, which is what a leading underscore usually argues
against. It keeps it for the reason it kept it in `annotation_pins.py`: the underscore states the
real scope — it exists for `test_annotation_coverage.py`'s law 2, and nothing else may read it —
and two docstrings in that file quote the name while arguing why law 2 is shaped as it is, so a
rename would falsify prose in the same commit that moved the data.

Import it as `from tests.service.annotation_readings import _UNJUDGED_AND_READ`. `tests` resolves
as a namespace package because pytest runs with `dashboard/` on `sys.path`; a sibling TEST module
is not importable by name here (`--import-mode=importlib`, no `__init__.py`), which is why this is
a plain module rather than a helper inside the test file.
"""

# The `unjudged` functions inside a pinned module that have been READ, one entry per function.
# `unjudged` means the #1487 gate declines to rule: the function is annotated but declares no
# out-of-band marker, and its failure value is outside the `_EMPTY` set that gate measures.
#
# This list records that a human read the function; it does NOT certify the design, and nothing
# here may be added because the gate happened to score it this way — that is the baseline #1487
# refused, wearing the pin's name. `worker_config_change_known` returns `False` on a closed
# handle and its docstring argues the fail-open choice at length, including why it must answer the
# same for a closed handle and a `sqlite3.Error` while its sibling must not. That reading, not the
# gate's score, is what the entry stands for.
#
# `config/config.py:local_miner_enabled` (slice 4) is the third, and the first member that is NOT
# an outbound sender — so it deliberately does not lean on the grounds `annotation_gate._EMPTY`
# records (see #1599: measured at `b0a32bd`, the tip that comment was written against, TWELVE
# functions already held a `False` failure return and this was one of them, so its five senders
# were a subset somebody read, never the whole population). No member is waved through by that
# class; each is read on its own terms. It returns False when
# the masked-config mount is missing or unreadable, and its docstring argues the choice outright:
# DIY stacks without the mount never run the built-in miner. Its sole production caller is
# arithmetic — `config.py:low_ram_floor_gb` does `+ (LOW_RAM_LOCAL_MINER_GB if
# local_miner_enabled() else 0)` — so there is no third branch for an out-of-band answer to reach,
# and False-on-failure and False-because-no-miner move the RAM floor by exactly the same amount.
# `-> bool | None` would invent a return the function never makes.
# Slice 5a adds the four OUTBOUND SENDERS as a group, and the shared argument is precisely why
# they could be read as one: each returns True only when the send demonstrably landed, and False
# for every other outcome — disabled, throttled, a non-2xx, or an exception. Every caller acts on
# "the message did not go out", which is what all of those mean, so there is no out-of-band case
# to declare and `-> bool | None` would invent a return none of them makes. The grouping has to be
# EARNED, so each was confirmed to be that shape rather than admitted by it:
#   `notify_sinks.py:_post`     — False when `not self.enabled`, and on `RequestException`.
#   `telegram_notifier.py:send` — the same two, and its docstring states the contract outright.
#   `tor_heal.py:_probe_egress` — True iff a clearnet exit answered, False on `RequestException`.
#   `healthchecks.py:ping`      — a dead-man's switch, and the only one with TWO `except` handlers,
#     both returning False. Its docstring already enumerates the False cases (not configured,
#     throttled, request failed, endpoint rejected) as deliberately one answer.
#   `docker/docker_control.py:_post` (slice 2) is the same class and is folded in here: True only
#     on HTTP 204/304, False on every other status and any exception, and its callers act on "the
#     container action did not happen", which is what both False paths mean.
#
# Slice 5b adds two MORE, listed separately rather than folded into the group above, because they
# fail in OPPOSITE directions — which is why `service/` was split rather than taken whole:
#   `egress.py:_sinks_all_private` is FAIL-CLOSED. False means "assume public", DENYING the LAN
#     carve-out; its docstring gives the reason (a hostname cannot be verified without a DNS
#     lookup, which a pure config derivation must never do), so False-on-ValueError and
#     False-because-genuinely-public are one instruction: do not grant it.
#   `steering_projection.py:won_round_live` is FAIL-OPEN by design. False means steer normally —
#     the hold is a yield optimization, never a safety path, so a read error must not freeze
#     steering. Collapsing these two readings into one would be the bulk-fill this list refuses:
#     same shape, opposite safety argument. Neither reaches `signed` without inventing a return.
#
# Slice 9 adds `helper/utils.py:is_ip_address`, and it is the first member whose `except` handler
# is not an ERROR PATH at all — which is the whole reason it is readable rather than a collapse.
# `ipaddress.ip_address` communicates "this is not an address" by RAISING `ValueError`, so the
# handler is where the function's negative answer is computed, not where a failure is absorbed.
# `AttributeError` is the same answer arriving by a second route: `value.strip()` raises it when
# `value` is not a string, and a non-string is not an IP address either. So both handled cases and
# the `False` they return mean one thing — "not a literal IP" — and there is no third outcome for
# an out-of-band value to carry. `-> bool | None` would invent a return the function never makes.
#
# The sole production caller agrees, and was read rather than assumed: `web/views.py`'s
# `host_display_addr` does `if is_ip_address(host): return None`, i.e. "the configured host is
# already an address, so show it alone". On False it falls through and tries `detect_host_ipv4()`.
# A malformed or `None` host takes the False branch, which is correct there for the same reason —
# it is not an address, so there is something worth trying to add beside it. No caller branch
# exists that a third answer could reach.
#
# What this entry does NOT claim: that `False` is the right answer for every future caller. It is
# a reading of the two paths that exist at this head, which is all any entry in this list is.
#
# Slice 12 adds the last two, and it reads them SEPARATELY although they sit in one class, wear one
# shape (`-> bool`, `False` out of an `except OSError`) and were annotated in one commit. Reading
# them as a pair is the bulk-fill this list refuses: only one of the two Falses is ever an error
# report at all, and the reason each is honest is a different reason.
#
#   `service/clearnet_sync.py:_marker_exists` — its `False` is `os.path.exists`'s own `False`, and
#     the handler cannot give it a second meaning because the handler cannot be reached.
#     `genericpath.exists` catches `(OSError, ValueError)` around its `os.stat` and answers False
#     itself; the only other call in the `try` is `os.path.join`, which raises `TypeError` on bad
#     input and never `OSError`. Measured rather than reasoned from the name: raw `os.stat` on a
#     5000-character path raises `OSError` 36 (the positive control, so the probe can see the
#     exception it claims is swallowed), while `os.path.exists` answers False for that path, for a
#     path holding a NUL byte, and for a real file under a directory with mode 0.
#
#     So there is one negative answer here, not two, and `-> bool | None` would invent a return the
#     function never makes. The caller agrees and was read rather than assumed: `__init__` builds
#     `self._preexisting` with `{n for n in ("monero", "tari") if self._marker_exists(n)}`, a set
#     comprehension with exactly two outcomes — in the set or not — so no third branch exists for an
#     out-of-band value to reach.
#
#     The dead handler is DISCLOSED rather than removed: this slice is annotation-only and proven
#     bytecode-identical, and deleting it would change what the gate sees in this module (it is the
#     `except` door row, and losing it would take the module to a single row).
#
#   `service/clearnet_sync.py:_write_marker` — the opposite case, which is why it could not share
#     the reading above. Its `False` is EXCLUSIVELY an error report; there is no "wrote nothing,
#     correctly" outcome. It is also not a silent one — the handler logs at error level with the
#     path and the exception before returning — which is what separates it from the collapses #1487
#     documents, where the failure's only symptom is the value itself.
#
#     Its sole production caller is `maybe_transition`, and the False branch is the safety-critical
#     one: `if not self._write_marker(name): return True` — report the node as still exposed, do NOT
#     restart, retry next cycle. That ordering is the class's stated fail-safe, because a restart
#     with no marker on disk brings the daemon back up on clearnet. False therefore carries exactly
#     one instruction, "hold", and True the other, "restart". A third answer would have to be one of
#     those two under another name.
#
# What NEITHER entry claims is that the module is now fully annotated. `maybe_transition` returns
# `False` at two sites through neither of the gate's doors, so this module joins `PINNED` still
# holding 2 residue sites in 1 function — not the zero slices 9 and 10 reached. Measured at this
# head, and printed by `TestTheResidueThePinCannotRuleOn` whether anyone writes it here or not.
_UNJUDGED_AND_READ = frozenset(
    {
        "client/docker/docker_control.py:_post",
        "config/config.py:local_miner_enabled",
        "service/healthchecks.py:ping",
        "service/notify_sinks.py:_post",
        "service/telegram_notifier.py:send",
        "helper/utils.py:is_ip_address",
        "service/egress.py:_sinks_all_private",
        "service/steering_projection.py:won_round_live",
        "service/tor_heal.py:_probe_egress",
        "service/worker_config_store.py:worker_config_change_known",
        "service/clearnet_sync.py:_marker_exists",
        "service/clearnet_sync.py:_write_marker",
    }
)
