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
# adds the module it finished. Measured at this tip: 25 of 33 modules that hold a failure return at
# all — `client/xvb_client.py` by slice 1, `service/worker_config_store.py` by pre-existing work,
# the six single-function `client/` modules by slice 2, the four single-function `web/` modules by
# slice 3, the two single-function `config/` modules by slice 4, the four outbound senders under
# `service/` by slice 5a, and the last three `service/` singletons by slice 5b. Slice 6 is the first
# MULTI-function slice — the four parse-or-read pairs under `service/`, each pinned only once BOTH of
# its failure returns were annotated and read. **25 failure returns are still blind.**
#
# That "25 of 33" read 18 until this slice measured it: 5b moved this tuple from 18 to 21 and left
# the sentence beside it saying 18. A slice adds rows to a tuple and the counting prose next to it is
# falsified in the same commit, silently — re-derive it here rather than carrying it.
#
# The `client/` scoping below applies to `tor_heal.py` too, measured: `decide` holds four
# unannotated `None` returns and `check` two bare ones, all six OUTSIDE the gate's two doors —
# pinned, law 1 honestly green, and NOT "fully annotated".
#
# That sentence was true and, until #1604, it was the ONLY one of its kind here. Eight other pinned
# modules hold the same residue and were named nowhere but inside the tuple below, so a reader who
# found `tor_heal.py`'s disclosure could reasonably infer the rest were clean: an asymmetric
# disclosure is worse than a uniform absence, because the silence beside the others reads as a
# statement. The residue is now MEASURED for all twenty-one and printed by
# `TestTheResidueThePinCannotRuleOn` in `test_annotation_coverage.py`, which is the form of
# disclosure that cannot go
# asymmetric again — a module joining `PINNED` gets a line whether anyone writes a sentence or not.
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
    "service/healthchecks.py",
    "service/notify_sinks.py",
    "service/telegram_notifier.py",
    "service/audit_service.py",
    "service/data_helpers.py",
    "service/egress.py",
    "service/price_feed.py",
    "service/steering_projection.py",
    "service/tor_heal.py",
    "service/update_checker.py",
    "service/worker_config_store.py",
    "service/xvb_standby.py",
    "web/charts.py",
    "web/infra_views.py",
    "web/views.py",
    "web/xvb_views.py",
)

# One function per pinned module, as the vacuity anchor. Law 1's own guard uses this shape: a
# statement about "no blind names under this prefix" is satisfied perfectly by a module that has
# vanished from the walk, and that is the reading a deleted file, a moved package root or a broken
# `rglob` all produce. `note_worker_revision` is the deliberate choice for its module — it is the
# one signed function `_SIGNED` never named.
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
    "service/healthchecks.py": "service/healthchecks.py:ping",
    "service/notify_sinks.py": "service/notify_sinks.py:_post",
    "service/telegram_notifier.py": "service/telegram_notifier.py:send",
    "service/audit_service.py": "service/audit_service.py:_tail_json_lines",
    "service/data_helpers.py": "service/data_helpers.py:_read_host_config",
    "service/egress.py": "service/egress.py:_sinks_all_private",
    "service/price_feed.py": "service/price_feed.py:parse_prices",
    "service/xvb_standby.py": "service/xvb_standby.py:parse_standby",
    "service/steering_projection.py": "service/steering_projection.py:won_round_live",
    "service/tor_heal.py": "service/tor_heal.py:_probe_egress",
    "service/update_checker.py": "service/update_checker.py:latest_release",
    "service/worker_config_store.py": "service/worker_config_store.py:note_worker_revision",
    "web/charts.py": "web/charts.py:parse_window",
    "web/infra_views.py": "web/infra_views.py:_ip_to_sort_int",
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
_UNJUDGED_AND_READ = frozenset(
    {
        "client/docker/docker_control.py:_post",
        "config/config.py:local_miner_enabled",
        "service/healthchecks.py:ping",
        "service/notify_sinks.py:_post",
        "service/telegram_notifier.py:send",
        "service/egress.py:_sinks_all_private",
        "service/steering_projection.py:won_round_live",
        "service/tor_heal.py:_probe_egress",
        "service/worker_config_store.py:worker_config_change_known",
    }
)
