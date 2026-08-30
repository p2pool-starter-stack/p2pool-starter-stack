"""#1556's pin data: which modules are pinned, what anchors each one, and which `unjudged`
functions inside them somebody read and signed off on.

Nothing here is a test and nothing here asserts anything. The three laws and the vacuity guards
that read this data live in `test_annotation_coverage.py`, and so does the argument for the pin —
why it is coverage of a mechanism rather than a verdict, why it is by module rather than by
function, and why it is not the baseline #1487 refused. Read that file's module docstring first;
this one only holds what the laws run over.

## Why the data is a separate module

The pin grows by construction. Every slice of #1556 adds a row to `PINNED` and a row to
`_ANCHORS`, and a slice that reads an `unjudged` function adds an entry to `_UNJUDGED_AND_READ`
with the reading beside it. Held in the test file, that growth ran straight into
`docs/dev/file-budget.tsv`, whose ceilings only ever go down: at slice 6 the file was 592 lines
against a recorded ceiling of 579, with 8 of 33 modules still unpinned. Raising the ceiling was
refused — 579 against a 400 target is already 1.45x, and `--generate` rewrites every row to the
actual count, so a hand-set high row does not survive the next regeneration. Compressing the file
would have deleted comments that are controls.

So the split is the third answer, and the rule it implements is: the part that grows is not the
part that is budgeted. This module is under the 400-line target and therefore records no ceiling
at all. If it ever crosses 400 that is the moment to re-read the split, not to raise a number.

The cost was priced and accepted: the data now sits one file away from the laws that read it. The
argument for each entry travels WITH the entry — the comments below moved here from the test file
along with the values they explain — so the split is between data and laws, never between an
entry and its justification. Three sentences changed in the move and only three: two that said
"wearing this file's name" while meaning the pin's, and one that pointed at a test class as
"below" when it is now in the sibling file.

## The names keep their leading underscores

`_ANCHORS` and `_UNJUDGED_AND_READ` are imported by name, which is what a leading underscore
usually argues against. They keep it for two reasons. The underscore states their real scope:
they exist for `test_annotation_coverage.py`'s laws, and nothing else may read them. And two
docstrings in that file quote `_UNJUDGED_AND_READ` by name while arguing why law 2 is shaped as
it is — `_unsigned_unjudged_under`'s account of the mutation that survived a count-based form,
and the narrowness control's — so a rename would have falsified prose in the same commit that
moved the data, which is the failure the pin comment below records happening twice already.
"""

# The modules with ZERO unannotated failure returns, measured over live source. Each slice of #1556
# adds the module it finished, and a module holding more than one is pinned only once EVERY one of
# its failure returns has been annotated and read. Which slice took which module is in #1556 and in
# git, not here. Measured at this tip: 32 of 33 modules that hold a failure return at all. **2
# failure returns are still blind**, both in `service/clearnet_sync.py` and both through the
# `except` door — the handle-guard population closed at slice 8. That last clause is a measurement
# and not a reading the walk could not contradict: `guard` is a door the walk still reports 31
# times package-wide.
#
# Every figure above is re-derived at the head being shipped, never carried across a slice: 5b moved
# this tuple from 18 to 21 and left the sentence beside it saying 18. A slice adds rows to a tuple
# and the counting prose next to it is falsified in the same commit, silently, and no gate in this
# repo can see it — re-derive it here rather than carrying it. Slice 7 found two more of exactly
# that kind already standing below, one of them spelled in WORDS, where a digit-keyed sweep misses.
#
# The `client/` scoping below applies to `tor_heal.py` too, measured: `decide` holds four
# unannotated `None` returns and `check` two bare ones, all six OUTSIDE the gate's two doors —
# pinned, law 1 honestly green, and NOT "fully annotated".
#
# That sentence was true and, until #1604, the ONLY one of its kind here — eight other pinned
# modules held the same residue, named nowhere but inside the tuple below, so a reader who found
# `tor_heal.py`'s disclosure could reasonably infer the rest were clean. An asymmetric disclosure is
# worse than a uniform absence: the silence beside the others reads as a statement. The residue is
# now MEASURED for every pinned module and printed by `TestTheResidueThePinCannotRuleOn` — a module
# joining `PINNED` gets a line whether anyone writes a sentence or not, and cannot go asymmetric.
#
# Slice 7 is `service/storage_service.py`, the first slice carried by the HANDLE GUARD rather than
# the `except` door: nine of its ten come through the guard, and `_prune_quarantined` is the one
# handler. Ten, not the nine a guard-door count gives — that miscount was in the handoff this
# slice started from, and pinning the module needs all ten. All ten are the same shape and were
# read as one only after each was confirmed to BE that shape: the guard's whole body is a bare
# `return`, and the function returns no value on any path. That was measured, not eyeballed —
# zero valued returns and zero yields across all ten, with
# a positive control (`get_kv`, which has three valued returns) to show the walk could see one.
#
# So every one is a genuine `-> None` procedure, and the slice adds ZERO to `signed` and ten to
# `procedure`. That is the whole outcome and it is stated plainly rather than dressed up: what this
# module's pin asserts is that #1487's rule structurally CANNOT apply to these ten — a procedure has
# no success value for a failure to hide inside — and that this is now SAID rather than silent,
# which is exactly what #1581 added the sixth verdict for. Law 2 is NOT vacuous here despite the
# module holding no `unjudged` row: re-signing one of them `-> bool` sends its bare `return` to
# `unjudged`, and law 2 reds. That was seeded and confirmed, because a law nobody fired is a law
# nobody has evidence for.
#
# The module's `collapse` rows and its residue are untouched by this slice and stay flagged.
#
# The reading is also what found **#1615**: `add_block` and `add_worker_history` stamp the per-table
# write-health signal, and the guard returns BEFORE either stamp — so after a failed corruption
# recovery every telemetry table reports `healthy: True` while its writes are dropped. Filed rather
# than fixed here: this slice is annotation-only and proven bytecode-identical, and that fix is a
# behaviour change to five write paths.
#
# Slice 8 is `service/telemetry_store.py`, and it is slice 7's shape with nothing new to argue: its
# three writers are the same closed-handle guard whose whole body is a bare `return`, measured the
# same way (zero valued returns, zero yields, with `get_xvb_history`'s three valued returns as the
# control that the walk can see one). Three more `procedure` rows, ZERO to `signed`. It closes the
# HANDLE-GUARD population — at slice 8's own head every one of the twelve failure returns still
# blind came through the `except` door, a figure left scoped to that head rather than updated in
# place. A past-tense sentence cannot be falsified by a LATER slice, but it can still be wrong at
# the head it describes: slice 9 found exactly that in the sibling test file, where "the twelve
# that score zero" had drifted to thirteen unnoticed. Scoping a figure to its head protects it
# from the future, not from the measurement.
#
# One thing here is worth carrying: this module's residue and its blind set were the SAME THREE
# SITES. The gate saw them through the guard door, and #1604's sweep saw them as falsy returns from
# functions declaring nothing — two instruments answering different questions about one site. So
# annotating cleared both at once, and the module now reports **0 residue sites**. That zero is a
# disclosure, not an absence: it is printed because the module is pinned, which is the whole of why
# #1604 prints the clean modules too.
#
# That overlap is NOT unique and the first draft of this comment said it was, unmeasured. Measured
# at this tip: `helper/utils.py` had the same shape — 2 residue functions and the same 2 blind —
# and slice 9 took it, so that prediction is DISCHARGED rather than left standing: re-measured at
# slice 9's head, the module reports 0 residue sites.
#
# The sentence that stood here — "in every other module the two sets are DISJOINT", carrying
# `storage_service.py`'s `add_shares`/`save_snapshot` as its evidence — is RETRACTED. It was true
# of the module it named and false as the generalisation it read as, because the two halves were
# measured over DIFFERENT POPULATIONS: in a PINNED module `blind` is empty by construction, so
# "disjoint" is vacuous there rather than a finding, and every module it implicitly quantified over
# was pinned. Re-measured at slice 9's head over the five modules that still hold a blind return,
# the sets are disjoint in NOT ONE of them — `blind` is a SUBSET of the residue in all five, and in
# `web/server.py` they are the SAME SET (`_finalize_worker_upgrade` and `_num`), a THIRD module of
# the shape this paragraph first called unique and then called doubled. The mechanism is that a
# blind function is unannotated by definition, so a falsy failure return lands it in both
# instruments at once; only a blind function returning a NON-falsy value can separate them, which
# is why the coincidence is the common case and not the exception. **Do not infer one set from the
# other — but do not infer independence either: they answer different questions, they coincide far
# more often than this file used to say, and which way they fall depends on whether the module has
# been pinned yet.**
#
# Slice 9 is `helper/utils.py`, and slices 7 and 8 transfer NOTHING to it beyond the method. The
# discriminator is NOT the door — slice 7's `_prune_quarantined` came through the `except` door
# too — it is that those thirteen were all bare-`return` procedures, measured at zero valued
# returns and zero yields, where `-> None` is simply honest. BOTH of these return a VALUE, so
# each had to be read on its own terms and they landed in DIFFERENT verdicts. That split is the point of the slice: one `signed`, one `unjudged`, ZERO
# `procedure`. `helper/utils.py` is the SECOND module to hold both verdicts at once, not the first
# — `service/worker_config_store.py` already did. That was measured here rather than asserted,
# because the first draft of this sentence said "first" and the measurement refuted it.
#
#   `detect_host_ipv4` -> `str | None` is a true `signed`, and the annotation invents nothing: the
#     docstring ALREADY declared the contract in prose — "Returns ``None`` when it can't be
#     determined (e.g. no default route), so callers fall back to showing the hostname alone" — and
#     its sole production caller, `web/views.py:host_display_addr`, acts on exactly that. `None` is
#     the out-of-band answer, distinguishable from every success value, which is what `signed`
#     means. The annotation moves a promise the code already kept into the signature.
#
# `is_ip_address` is the `unjudged` one and its reading is filed with its entry below rather than
# here, so that the argument travels WITH the value the way every other entry in this file does.
#
# Both functions were proven bytecode-identical base-vs-head, with a seeded `return True` ->
# `return False` inside `is_ip_address` as the positive control: it flipped that function and ONLY
# that function, which is what makes the clean reading on the other two evidence rather than an
# empty result.
#
# Slice 10 is `web/server.py`, and it repeats slice 9's lesson rather than slice 7/8's: two blind
# functions, both through the `except` door, landing in DIFFERENT verdicts again — one `procedure`,
# one `signed`, ZERO `unjudged`, so no `_UNJUDGED_AND_READ` entry is owed. Two slices running now, a
# module's blind pair has not shared a verdict; do not expect the next one to.
#
#   `_finalize_worker_upgrade` -> `-> None` is a genuine procedure, measured the way slices 7 and 8
#     measured theirs: ONE return, ZERO valued, ZERO yields, with `handle_control_preview`'s three
#     valued returns as the control that the walk can see one. It is #1014's background half — it
#     records the terminal outcome of a worker upgrade and answers nobody — so its `except` return
#     is a bare `return` after `logger.exception`, with no success value to hide inside.
#
#   `_num` -> `-> float | None` is a true `signed`, and like `detect_host_ipv4` the annotation moves
#     a promise the code already kept into the signature. All three returns are valued and every one
#     is a float or `None`: an absent/empty param, the `ValueError` from `float()`, and
#     `f if math.isfinite(f) else None` because `float()` parses "inf"/"nan". Its docstring already
#     said so in prose — "anything non-numeric reads as absent" — and the consumer agrees, read
#     rather than assumed: `_log_filters`' two callers hand the pair straight to
#     `audit_service.filter_log_entries`, whose docstring says `None` means "don't filter on this
#     axis". `None` is out-of-band there, distinguishable from every float bound.
#
# The anchor is `_finalize_worker_upgrade`: declared first, and top-level where `_num` is a nested
# closure — lifting or inlining it would drop its row for a reason that is not a walk failure. What
# is NOT a reason, measured before choosing rather than argued after: the nested-def regression
# (`_own_nodes` degraded to `ast.walk`) ADDS a `_log_filters` row rather than removing one, so
# NEITHER candidate fires on it. Neither is double-guarded either, this module contributing no
# `_UNJUDGED_AND_READ` entry, so law 1's aggregate and this anchor are the whole of its cover.
#
# One thing slice 10 has that slices 1-9 did not, and it narrows what the proof claims. Annotating
# a NESTED def is not free at the bytecode level: both annotated functions ARE bytecode-identical
# base-vs-head, but the enclosing `_log_filters` is NOT — its whole delta is the annotation built at
# def time, read instruction by instruction, and that is correct rather than a defect. A FUNCTION
# scope is the only one that rebuilds an annotation per call; a method's is built once in the class
# body at import. Re-measured at this tip keyed by NODE, with a control that the walk can report a
# nested def at all: both blind functions left are class methods, so nothing remaining inherits
# this. Nothing is claimed about a nested def some future slice might introduce.
#
# The module's residue went 3 sites in 2 functions to ZERO, DISCHARGING the prediction slice 9's
# retraction left standing above: it named `web/server.py` as the module where `blind` and the
# residue are the SAME SET, and annotating the pair cleared both instruments at once.
#
# Slice 11 takes `alert_service.py`, `control_service.py` and `telegram_commands.py` under
# `service/` together, because not one of them owes an `_UNJUDGED_AND_READ` entry. Every verdict was
# READ off `classify` after annotating, never predicted: `process` and `_load_core_keys` ->
# `collapse` (each returns `[]` where the success value is a list — the defect #1556 documents, not
# one a slice fixes); `maybe_daily_summary`, `result`, `_safe_reply_for` -> `signed`;
# `_dispatch_control` -> `procedure` (ONE return, bare, in the handler). No pair shared a verdict.
#
# Three `signed` rows are weaker than the word — one here, two from earlier slices, recorded
# together because disclosing only the new one is what #1604 was. `classify` reads `signed` off the
# FAILURE returns ALONE and cannot see a SUCCESS return that is a CALL producing the same marker.
# Measured over all 31: `_safe_reply_for` (`reply_for` answers `None` on 3 of its 15 returns),
# `client/xvb_client.py:get_stats` (`_parse_html`, 2), `service/price_feed.py:fetch`
# (`parse_prices`, 2). Each type is the true one and stays; that a caller can tell the failure from
# the quiet success is NOT claimed — seeing that needs the callee's returns, a whole-package
# inference this walk deliberately does not make.
#
# Slice 4 added ZERO to `signed`, which is the CORRECT outcome and was predicted before it was
# written: `config/` holds one collapse (`load_worker_endpoints` returning `[]`) and one residual
# (`local_miner_enabled` returning `False`). A slice is coverage of the mechanism, so a slice whose
# two functions both decline to be signable has done its whole job.
#
# Slice 2 wrote here that "no module under `client/` holds an unannotated failure return any more".
# That is TRUE under `_failure_returns`' definition and it READS as "`client/` is done, never look
# here again". It is not. The gate sees exactly two doors — a `return` lexically inside an `except`
# handler, and a return that is the whole body of a `self._conn` guard — and **14 unannotated
# functions under `client/` hold collapse-shaped returns outside both of them**, measured.
# `client/monero/monero_wallet_client.py:get_confirmed_payouts` is a genuine failure path among
# them: it returns `[]` when `_rpc` returned `None`, which no caller can tell from "no payouts".
# So the claim is scoped to the instrument that makes it — no unannotated failure return **that
# this gate can see**. A pin is coverage of a mechanism, never a certificate about a package.
#
# **Only ever add a module you have read.** Adding one because the gate happens to score it clean
# is the baseline #1487 refused, wearing the pin's name.
PINNED = (
    "client/docker/docker_control.py",
    "client/monero/monero_client.py",
    "client/monero/monero_wallet_client.py",
    "client/tari/tari_client.py",
    "client/tari/tari_wallet_client.py",
    "client/xmrig_client.py",
    "client/xvb_client.py",
    "config/config.py",
    "config/worker_endpoints.py",
    "helper/utils.py",
    "service/healthchecks.py",
    "service/notify_sinks.py",
    "service/telegram_notifier.py",
    "service/alert_service.py",
    "service/audit_service.py",
    "service/control_service.py",
    "service/data_helpers.py",
    "service/egress.py",
    "service/price_feed.py",
    "service/steering_projection.py",
    "service/storage_service.py",
    "service/telegram_commands.py",
    "service/telemetry_store.py",
    "service/tor_heal.py",
    "service/update_checker.py",
    "service/worker_config_store.py",
    "service/xvb_standby.py",
    "web/charts.py",
    "web/infra_views.py",
    "web/server.py",
    "web/views.py",
    "web/xvb_views.py",
)

# One function per pinned module, as the vacuity anchor. Law 1's own guard uses this shape: a
# statement about "no blind names under this prefix" is satisfied perfectly by a module that has
# vanished from the walk, and that is the reading a deleted file, a moved package root or a broken
# `rglob` all produce. `note_worker_revision` is the deliberate choice for its module — it is the
# one signed function `_SIGNED` never named. `add_block` is the choice for
# `storage_service.py` — of that module's eleven procedures it is one of the two carrying the
# per-table health channel #1615 is about, so it is the one whose silent exit from the walk would
# cost most. For `telemetry_store.py` all three writers are equivalent for this purpose and
# `add_xvb_history` is simply the first declared — recorded so nobody hunts for a reason.
# `helper/utils.py` names `detect_host_ipv4` on a stronger ground than "either would do": that
# module's other candidate, `is_ip_address`, is ALREADY held alive by the separate vacuity guard on
# `_UNJUDGED_AND_READ`, which requires every entry to still exist and still score `unjudged`.
# Anchoring here on `is_ip_address` would guard one function twice and leave the `signed` one
# guarded by nothing but law 1's aggregate — which a vanished module satisfies perfectly. The
# anchor goes where the other guard is not.
_ANCHORS = {
    "client/docker/docker_control.py": "client/docker/docker_control.py:_post",
    "client/monero/monero_client.py": "client/monero/monero_client.py:get_info",
    "client/monero/monero_wallet_client.py": "client/monero/monero_wallet_client.py:_rpc",
    "client/tari/tari_client.py": "client/tari/tari_client.py:_fetch_sync_status",
    "client/tari/tari_wallet_client.py": (
        "client/tari/tari_wallet_client.py:get_confirmed_payouts"
    ),
    "client/xmrig_client.py": "client/xmrig_client.py:_safe_probe_host",
    "client/xvb_client.py": "client/xvb_client.py:get_stats",
    "config/config.py": "config/config.py:local_miner_enabled",
    "config/worker_endpoints.py": "config/worker_endpoints.py:load_worker_endpoints",
    "helper/utils.py": "helper/utils.py:detect_host_ipv4",
    "service/healthchecks.py": "service/healthchecks.py:ping",
    "service/notify_sinks.py": "service/notify_sinks.py:_post",
    "service/telegram_notifier.py": "service/telegram_notifier.py:send",
    "service/alert_service.py": "service/alert_service.py:process",
    "service/audit_service.py": "service/audit_service.py:_tail_json_lines",
    "service/control_service.py": "service/control_service.py:result",
    "service/data_helpers.py": "service/data_helpers.py:_read_host_config",
    "service/egress.py": "service/egress.py:_sinks_all_private",
    "service/price_feed.py": "service/price_feed.py:parse_prices",
    "service/xvb_standby.py": "service/xvb_standby.py:parse_standby",
    "service/steering_projection.py": "service/steering_projection.py:won_round_live",
    "service/storage_service.py": "service/storage_service.py:add_block",
    "service/telegram_commands.py": "service/telegram_commands.py:_dispatch_control",
    "service/telemetry_store.py": "service/telemetry_store.py:add_xvb_history",
    "service/tor_heal.py": "service/tor_heal.py:_probe_egress",
    "service/update_checker.py": "service/update_checker.py:latest_release",
    "service/worker_config_store.py": "service/worker_config_store.py:note_worker_revision",
    "web/charts.py": "web/charts.py:parse_window",
    "web/infra_views.py": "web/infra_views.py:_ip_to_sort_int",
    "web/server.py": "web/server.py:_finalize_worker_upgrade",
    "web/views.py": "web/views.py:read_os_update_state",
    "web/xvb_views.py": "web/xvb_views.py:recent_wallet_change",
}


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
    }
)
