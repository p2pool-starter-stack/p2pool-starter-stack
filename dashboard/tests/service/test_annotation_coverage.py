"""#1556 — a module that has been annotated stays annotated.

`test_collapsed_return_channels.py` (#1487) enforces the rule that a failure path may not return a
value inhabiting the declared success type. That rule can only judge a function that DECLARES a
return type. An unannotated function is scored `blind`: not clean, not in breach, simply outside
what the mechanism can see. At the tip this file shipped against there were **52** such failure
returns across **31** modules, and #1556 is the work of annotating them slice by slice.

This file is the ratchet that makes each slice stick. Without it a slice is undone by any edit that
drops a `| None`, and nothing goes red: the collapse count does not move, and the #1487 laws have
nothing to say because they only speak about functions that made a promise.

**Where the function actually goes matters, and getting it wrong cost this file a round.** An edit
that DELETES the annotation returns the function to `blind`. An edit that merely drops the `| None`
does NOT — it leaves the function annotated, so `blind` never sees it, and its failure value is
outside `_EMPTY` so `collapse` never sees it either. Before #1556 gave that state the name
`unjudged`, such a function landed in no verdict list at all and a law phrased as "nothing here is
blind" was satisfied by it VANISHING. Both regressions are real and each has its own law below;
one law cannot cover both, because the second admits a read-and-signed exception and the first
admits none.

## Why this is a pin and not the baseline #1487 refused

#1487 refused to baseline the collapsed instances, and the reasoning stands: putting a `<= 11`
bound on them would certify whatever real defects they contain as intentional, on the strength of
nobody having read them. **This pin is the opposite case.** Every function inside a pinned module
was read as part of the slice that annotated it, and what is being asserted is that the reading
happened, not that the result is acceptable. The distinction is the same one `_SIGNED` draws in the
sibling file, moved up a level: a set someone signed, not a count nobody looked at.

So the pin is worded as **coverage**, never as a verdict. A pinned module may still hold a genuine
collapse — the gate will flag it, loudly, and this file will stay green while it does. What this
file refuses is the module going QUIET again.

## Why by module rather than by function

A per-function pin is a list of names that a rename breaks and a deletion silently shrinks — the
failure `_SIGNED`'s own docstring names. Pinning the module asserts something a rename cannot
disturb and a new function cannot slip past: **no failure return in this module is unannotated.**
Adding an unannotated one to a pinned module goes red, which is the point and is also the cost, and
it is a cost paid by exactly the modules someone has already done the work on.

`service/worker_config_store.py` is here for a reason that predates #1556: it was fully annotated
already, and two of its three signed functions were pinned by `_SIGNED` while `note_worker_revision`
was not. That gap was in the tree at the base of this branch, not introduced by any slice.
"""

import pytest

from tests.service.annotation_gate import (
    classify,
    classify_package,
    unannotated_falsy_by_module,
    unannotated_falsy_returns,
)

# The modules with ZERO unannotated failure returns, measured over live source. Each slice of #1556
# adds the module it finished. Measured at this tip: 18 of 33 modules that hold a failure return at
# all — `client/xvb_client.py` by slice 1, `service/worker_config_store.py` by pre-existing work,
# the six single-function `client/` modules by slice 2, the four single-function `web/` modules by
# slice 3, the two single-function `config/` modules by slice 4, the four outbound senders under
# `service/` by slice 5a, and the last three `service/` singletons by slice 5b. That finishes the
# SINGLETON tail, not #1556: **33 failure returns are still blind**, all in multi-function modules.
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
# `TestTheResidueThePinCannotRuleOn` below, which is the form of disclosure that cannot go
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
# is the baseline #1487 refused, wearing this file's name.
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
    "service/egress.py",
    "service/steering_projection.py",
    "service/tor_heal.py",
    "service/update_checker.py",
    "service/worker_config_store.py",
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
    "service/egress.py": "service/egress.py:_sinks_all_private",
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
# refused, wearing this file's name. `worker_config_change_known` returns `False` on a closed
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


def _blind_under(module: str, verdicts: dict[str, list]) -> list[str]:
    """Every unannotated failure return the walk found in one module."""
    return sorted(name for name in verdicts["blind"] if name.startswith(f"{module}:"))


def _unjudged_under(module: str, verdicts: dict[str, list]) -> list[str]:
    """Every failure return in one module the #1487 gate declined to rule on."""
    return sorted(row[0] for row in verdicts["unjudged"] if row[0].startswith(f"{module}:"))


def _unsigned_unjudged_under(module: str, verdicts: dict[str, list]) -> set[str]:
    """Law 2's whole question, in one place: the unjudged functions in this module that NOBODY has
    signed off on.

    It lives here rather than inside the law because of a surviving mutation. When the law spelled
    the subtraction itself, `set(...) - _UNJUDGED_AND_READ == set()` could be rewritten as
    `len(...) <= len(_UNJUDGED_AND_READ)` and every test still passed — while a de-signed function
    in a module with one signed exception went green, which is the exact regression law 2 exists
    for. The narrowness control could not catch it because the control spelled the subtraction a
    second time and so was mutated in lockstep with nothing.

    With the set named here the law can only ask whether it is empty. The count comparison is not
    expressible in the law any more, and the control below tests the same code the law runs.
    """
    return set(_unjudged_under(module, verdicts)) - _UNJUDGED_AND_READ


def _rows_under(module: str, verdicts: dict[str, list]) -> list[str]:
    """Every failure return in one module, whatever the verdict — the anti-vacuity population."""
    found: list[str] = []
    for rows in verdicts.values():
        for row in rows:
            name = row[0] if isinstance(row, tuple) else row
            if name.startswith(f"{module}:"):
                found.append(name)
    return sorted(found)


@pytest.fixture(scope="module")
def package() -> dict[str, list]:
    """Every failure return in `mining_dashboard`, classified, in one pass over the real package."""
    return classify_package()


@pytest.fixture(scope="module")
def residue() -> dict[str, list[tuple[str, str, int]]]:
    """Every falsy return in an unannotated function, keyed by module, over the real package."""
    return unannotated_falsy_by_module()


class TestAnAnnotatedModuleStaysAnnotated:
    """The law. It ratchets coverage of the mechanism, never a verdict the mechanism returned."""

    @pytest.mark.parametrize("module", PINNED)
    def test_no_failure_return_in_a_pinned_module_is_unannotated(self, module, package):
        """LAW 1 — DELETING the annotation. That returns the function to the blind set, where the
        #1487 laws stop applying to it because they only judge a function that declared a
        contract. Nothing else in the suite notices. This is what notices.

        Scoped deliberately to deletion. An edit that keeps the annotation and drops only the
        `| None` never reaches `blind`, and law 2 is what catches that one — an earlier draft of
        this docstring claimed both and was measurably wrong about the second."""
        assert _blind_under(module, package) == []

    @pytest.mark.parametrize("module", PINNED)
    def test_no_failure_return_in_a_pinned_module_is_unjudged(self, module, package):
        """LAW 2 — DROPPING the `| None` while keeping the annotation. This is the regression the
        whole slice is undone by, and until #1556 named the `unjudged` verdict it was invisible:
        the function left `signed`, never arrived in `blind` or `collapse`, and appeared in no
        list at all. Law 1 above and the vacuity guard below both stayed green.

        The exception set is subtracted by NAME, never by count. A module may hold a function this
        gate declines to rule on, but only one somebody read and wrote down."""
        assert _unsigned_unjudged_under(module, package) == set()

    def test_every_signed_exception_is_still_there_and_still_needs_signing(self, package):
        """VACUITY GUARD for law 2's exception set, and the failure mode `_SIGNED`'s own docstring
        names: a per-function list goes stale the moment the function is renamed or deleted, and it
        goes stale SILENTLY — the subtraction in law 2 keeps passing over a name that matches
        nothing. So each entry must still name a function that exists AND still score `unjudged`.
        An entry whose function was fixed is a stale exception that would swallow the next real one
        in its module, which is exactly how an exception list becomes a baseline."""
        assert _UNJUDGED_AND_READ, "an empty exception set makes law 2's subtraction a no-op"
        unjudged = {row[0] for row in package["unjudged"]}
        assert _UNJUDGED_AND_READ <= unjudged

    @pytest.mark.parametrize("module", PINNED)
    def test_a_pinned_module_is_actually_in_the_walk(self, module, package):
        """VACUITY GUARD for laws 1 and 2. `[] == []` and `set() == set()` are what a deleted file,
        a renamed package root and a walk that matched nothing all return, and each of those
        satisfies BOTH laws perfectly. Both halves matter: the module must contribute rows, and its
        named anchor must still be there — the first catches the walk breaking, the second catches
        the module's own file being deleted while the rest of the package still walks.

        It is deliberately no longer the thing that catches a de-signed anchor. It used to be, and
        that was the defect: with law 2 missing, this guard was the only assertion that reddened on
        a dropped `| None`, and only for the one function per module named here. A guard doing a
        law's job hides the law's absence, because the suite goes red either way."""
        assert _rows_under(module, package), f"the walk found nothing at all in {module}"
        assert _ANCHORS[module] in _rows_under(module, package)


class TestThePinCanSeeWhatItIsPinning:
    """A green law names nothing on its own. Each control is seeded ACROSS the boundary the law
    decides on, so a predicate that answered 'clean' to everything would fail them."""

    _BLIND = """
class Client:
    def get_stats(self):
        try:
            return self._session.get("/1/summary")
        except Exception:
            return None
"""

    _ANNOTATED = """
class Client:
    def get_stats(self) -> dict | None:
        try:
            return self._session.get("/1/summary")
        except Exception:
            return None
"""

    _DE_SIGNED = """
class Client:
    def get_stats(self) -> dict:
        try:
            return self._session.get("/1/summary")
        except Exception:
            return None
"""

    def test_it_flags_an_unannotated_failure_return_added_to_a_pinned_module(self):
        """POSITIVE CONTROL, and the only thing that makes the law's green mean anything. The law's
        product on real source is an ABSENCE, and an absence proves nothing until the predicate is
        shown able to produce a presence. This is the exact regression the file exists for: a
        function in a pinned module losing its annotation."""
        assert "-> " not in self._BLIND  # arming readback: the annotation really is absent
        verdicts = classify(self._BLIND, "client/xvb_client.py")
        assert _blind_under("client/xvb_client.py", verdicts) == ["client/xvb_client.py:get_stats"]

    def test_it_clears_the_same_function_once_the_annotation_is_back(self):
        """NEGATIVE CONTROL, one token apart from the positive one. Same class, same call, same
        failure value — only the signature differs. A predicate keying on anything but the
        annotation would be unable to tell these two apart."""
        verdicts = classify(self._ANNOTATED, "client/xvb_client.py")
        assert _blind_under("client/xvb_client.py", verdicts) == []
        assert verdicts["signed"] == ["client/xvb_client.py:get_stats"]

    def test_the_vacuity_guard_fires_on_a_module_that_is_not_there(self, package):
        """The guard has the same absence problem as the law, so it gets the same treatment: a
        module absent from the walk must not satisfy it. Both halves are the control — asserting
        only the absent one would pass against a predicate that returned nothing for everything,
        which is the shape a broken walk actually has, so the present sibling is what makes the
        absent result mean something. Run against the REAL package for that reason; a hand-built
        empty dict would prove only that an empty input yields an empty output."""
        assert not _rows_under("service/no_such_module.py", package)
        assert _rows_under("client/xvb_client.py", package)

    def test_it_flags_a_de_signed_failure_return_in_a_pinned_module(self):
        """POSITIVE CONTROL for law 2, seeded ACROSS the boundary law 2 decides on, and the one
        that makes law 2's green mean anything. `_DE_SIGNED` is `_ANNOTATED` with four characters
        removed — the whole edit is ` | None` becoming nothing — which is what the regression
        actually looks like in a diff.

        The second and third assertions are the point rather than padding: this function is NOT
        blind and NOT collapsed, so law 1 and the #1487 laws are all green on it. Law 2 is the only
        thing in the suite that sees it."""
        verdicts = classify(self._DE_SIGNED, "client/xvb_client.py")
        assert _unjudged_under("client/xvb_client.py", verdicts) == [
            "client/xvb_client.py:get_stats"
        ]
        assert _blind_under("client/xvb_client.py", verdicts) == []
        assert verdicts["collapse"] == []
        assert verdicts["signed"] == []

    def test_the_de_signed_control_differs_from_the_clean_one_by_the_marker_alone(self):
        """The arming readback for the control above, as an assertion rather than a comment. If
        `_DE_SIGNED` and `_ANNOTATED` ever stop being one token apart, the control stops being a
        control and starts being two unrelated snippets that happen to score differently."""
        assert self._DE_SIGNED == self._ANNOTATED.replace(" | None", "")
        assert " | None" in self._ANNOTATED
        assert " | None" not in self._DE_SIGNED

    def test_the_exception_set_does_not_excuse_a_sibling_in_the_same_module(self, package):
        """NARROWNESS CONTROL for the exception set. Subtracting a set is only as narrow as its
        members: a bug that widened `_UNJUDGED_AND_READ` to a module prefix, or that compared by
        count, would still pass law 2. Seeding a SECOND unjudged function into the same module the
        exception lives in is the near-miss that separates the two readings."""
        seeded = dict(package)
        seeded["unjudged"] = [
            *package["unjudged"],
            ("service/worker_config_store.py:some_new_helper", ["False"]),
        ]
        module = "service/worker_config_store.py"
        assert _unsigned_unjudged_under(module, seeded) == {f"{module}:some_new_helper"}
        assert _unsigned_unjudged_under(module, package) == set()

    def test_the_prefix_match_does_not_span_module_names(self, package):
        """`startswith(f"{module}:")` carries the delimiter deliberately. Without it
        `service/worker_config_store.py` would also claim any module whose path extends it, and the
        pin would silently cover files nobody read. Nothing wears that shape today; this is here so
        it cannot start to quietly."""
        assert _rows_under("client/xvb_client", package) == []
        assert _rows_under("service/worker_config_store", package) == []


class TestTheResidueThePinCannotRuleOn:
    """#1604 — what the pin has never said, said.

    Law 1 says no FAILURE RETURN in a pinned module is unannotated. It has never said the module is
    annotated, and the difference is not academic: nine of the twenty-one hold functions that
    declare no return type and return a falsy value. Those returns come through neither of the
    gate's two doors, so `classify` emits no row for them, and every law above is silent about them
    — correctly, because the mechanism genuinely cannot reach them.

    Nothing here rules on a single site. #1604 read none of them, and a count that grew a bound
    would be the baseline #1487 refused, wearing a third file's name. What is asserted is that the
    number exists and that the sweep producing it can tell one module from another."""

    def test_the_residue_in_every_pinned_module_is_reported_without_being_ruled_on(
        self, residue, capsys
    ):
        """Deliberately asserts NOTHING about the counts, for the reason the sibling file's
        residual report gives at length: a bound over sites nobody has read certifies whatever they
        contain, and this pass read none of them.

        Every pinned module gets a line INCLUDING the twelve that score zero, and the zero lines
        are the half that makes this a disclosure rather than a second asymmetry — an unmentioned
        module and a measured-clean module are the same silence otherwise, which is the whole of
        #1604."""
        with capsys.disabled():
            rows = {module: residue[module] for module in PINNED}
            sites = sum(len(found) for found in rows.values())
            functions = {name for found in rows.values() for name, _, _ in found}
            holding = sum(1 for found in rows.values() if found)
            print(
                f"\n#1604 residue — {sites} falsy returns in {len(functions)} functions that "
                f"declare no return type, across {holding} of the {len(PINNED)} pinned modules. "
                "The gate reaches none of them:"
            )
            for module, found in sorted(rows.items(), key=lambda row: (-len(row[1]), row[0])):
                names = {name for name, _, _ in found}
                print(f"    {len(found):3d} sites {len(names):2d} fns  {module}")
                for name, literal, lineno in sorted(found, key=lambda row: row[2]):
                    print(f"        {name}:{lineno} -> {literal}")

    def test_the_residue_sweep_tells_the_pinned_modules_apart(self, residue):
        """VACUITY AND DISCRIMINATION guard, and it is here because the instrument arrived with
        exactly this defect: #1604's first sweep keyed on a needle that also matched the `PINNED`
        tuple itself, scored all twenty-one modules identically, and read as a clean bill. A sweep
        that flags everything and a sweep that flags nothing are the same non-answer, so both ends
        are asserted.

        The membership check is the third failure this guards, and a different one: `residue` holds
        every module the walk found, so a pinned module MISSING from it is a file that was deleted
        or renamed while the rest of the package still walks — the absence that satisfies every law
        phrased as one.

        The lower bound reds the day the package becomes fully annotated. That is the same
        deliberate choice the sibling file's blind-spot measurement makes, and for the same reason:
        the pin would then cover something different from what it covers today, which is worth a
        look rather than a silent green."""
        missing = [module for module in PINNED if module not in residue]
        assert missing == [], f"pinned modules that left the walk entirely: {missing}"
        holding = [module for module in PINNED if residue[module]]
        assert holding, "a residue of zero everywhere would change what this pin covers"
        assert len(holding) < len(PINNED), "a sweep that flags every module discriminates nothing"


class TestTheResidueSweepCanSeeWhatItIsCounting:
    """The report above is a count, and a count nobody controlled is a number with no source. Each
    control is seeded ACROSS the annotation boundary the sweep keys on, so a sweep that answered
    "residue" to everything — or to nothing — fails them."""

    _UNANNOTATED = """
def read_window(request):
    value = request.query.get("window")
    if value not in _WINDOWS:
        return None
    return value
"""

    _ANNOTATED = """
def read_window(request) -> str | None:
    value = request.query.get("window")
    if value not in _WINDOWS:
        return None
    return value
"""

    _TRUTHY = """
def read_window(request):
    value = request.query.get("window")
    if value not in _WINDOWS:
        return "1h"
    return value
"""

    def test_it_counts_a_falsy_return_from_a_function_that_declared_nothing(self):
        """POSITIVE CONTROL, and the second assertion is what makes this residue rather than
        `blind` under another name: the SAME source through the gate produces no row in any of the
        six verdicts, because the return is through neither door. That is why every law in this
        file is silent about these sites, and why the count has to exist at all."""
        assert "-> " not in self._UNANNOTATED  # arming readback: the annotation really is absent
        found = unannotated_falsy_returns(self._UNANNOTATED, "web/charts.py")
        assert [(name, literal) for name, literal, _ in found] == [
            ("web/charts.py:read_window", "None")
        ]
        verdicts = classify(self._UNANNOTATED, "web/charts.py")
        assert all(rows == [] for rows in verdicts.values()), verdicts

    def test_it_drops_the_same_function_once_it_declares_a_return_type(self):
        """NEGATIVE CONTROL, one annotation apart from the positive one — same body, same falsy
        value, same call. A sweep keying on anything but the annotation could not tell these two
        apart, and every annotated function it swept in would be a function the gate already
        rules on, reported as a place the gate cannot reach."""
        assert self._ANNOTATED == self._UNANNOTATED.replace("(request)", "(request) -> str | None")
        assert unannotated_falsy_returns(self._ANNOTATED, "web/charts.py") == []

    def test_it_does_not_count_a_truthy_return_from_an_unannotated_function(self):
        """NARROWNESS CONTROL, and the near-miss that separates this count from "every return in an
        unannotated function". The package is mostly unannotated (#284 is closed for that reason),
        so a sweep that dropped the falsy half would report a number in the hundreds and mean
        nothing by it."""
        assert self._TRUTHY == self._UNANNOTATED.replace("return None", 'return "1h"')
        assert unannotated_falsy_returns(self._TRUTHY, "web/charts.py") == []

    def test_the_empty_string_is_counted_here_and_is_still_invisible_to_the_gate(self):
        """`""` is the one shape this sweep adds to the set `_collapsed_literal` tracks, and the
        two assertions are the two halves of that decision. It is counted here because a report
        that leaves out a falsy shape flatters its own number; it stays out of the gate's set
        because that set feeds verdicts quoted with a sha, and widening it would move them."""
        unannotated = 'def render(rows):\n    if not rows:\n        return ""\n    return rows[0]\n'
        found = unannotated_falsy_returns(unannotated, "web/charts.py")
        assert [literal for _, literal, _ in found] == ['""']
        collapsing = (
            "class Store:\n"
            "    def name(self) -> str:\n"
            "        try:\n"
            "            return self._conn.execute(SQL).fetchone()[0]\n"
            "        except Exception:\n"
            '            return ""\n'
        )
        verdicts = classify(collapsing, "service/storage_service.py")
        assert all(rows == [] for rows in verdicts.values()), verdicts

    def test_a_nested_def_is_counted_against_itself(self):
        """A nested def is its own function with its own contract, so its returns are never the
        parent's — and this is the control for a defect that HAS happened rather than a
        hypothetical. `web/xvb_views.py` is the case: `build_xvb_calc` holds `_odds_day` and
        `_face_value`, and a sweep using `ast.walk(function)` scored their returns at lines 731 and
        767 against `build_xvb_calc`, which holds no residue return of its own, while still
        counting them as themselves. That double count is the whole of #1604's 12-sites-in-6-
        functions figure where the truth is 10 in 5."""
        seeded = (
            "def build(rows):\n"
            "    def _odds(agg):\n"
            "        if not agg:\n"
            "            return None\n"
            "        return agg['n']\n"
            "    return _odds(rows)\n"
        )
        found = unannotated_falsy_returns(seeded, "web/xvb_views.py")
        assert [name for name, _, _ in found] == ["web/xvb_views.py:_odds"]
