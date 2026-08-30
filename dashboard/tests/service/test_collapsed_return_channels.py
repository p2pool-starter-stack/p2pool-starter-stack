"""#1487 — an error and an answer may not share a return channel, as a mechanism (#1409).

#1409 was one instance: `get_worker_config_history` returned `[]` both when the read failed and
when it succeeded and found nothing. Its caller reads that list to decide where a rig's running
config came from, and an empty list means *"we hold no row"*, which renders as **"Last changed
from another dashboard."** A database that failed to open produced an on-screen accusation that
another operator had changed the rig.

#1487 asked for a MECHANISM rather than a sweep of the instances, because fixing them one at a
time makes today's known instances safe and does nothing about the next one. This is that
mechanism, and the rule it enforces is:

    a FAILURE path may not return a value that inhabits the function's declared SUCCESS type.

**The opt-out is the type annotation, not a marker comment.** A handler that genuinely wants to
collapse says so by declaring a type the collapsed value fits; a handler that wants the failure to
be distinguishable widens its annotation to `T | None` and returns `None`. That is exactly the fix
#1409 applied, so the mechanism and the precedent agree by construction, and "a decision someone
signed rather than a default nobody noticed" is expressible in the signature a reader already
reads. Nothing here needs a new vocabulary.

## The two shapes this covers, and the one it does not

* **The `except` shape.** A collapsed literal returned from an exception handler.
* **The HANDLE-GUARD shape.** `if not self._conn: return []` — no exception involved. This is the
  SILENT half of #1409, the route that raised nothing and logged nothing, and it is invisible to
  any rule anchored on `except`. It is covered here because the two shapes are the same defect
  reached by two doors, and a gate that closed only one would leave the door the reader cannot see.

**It does NOT cover the general guard-clause shape, and does not claim to.** A guard on a DOMAIN
value — `if not rows`, `if prev is None`, `if cmd is None` — is usually a real early return rather
than a failure. Re-derived at this tip: 171 guard-clause failure-return sites, of which 32 test a
resource handle and 139 test a domain value; an earlier precision pass over the wider class found a
single true positive in it. The discriminator kept here is that the guard tests a RESOURCE HANDLE.
Widening past that would trade a gate people trust for a gate people mute; the near-miss control
below pins the narrowness so it cannot drift.

## What is asserted, and what is only reported

Two laws are HARD, and neither needs a baseline of existing instances:

1. **The signed set stays signed** (`_SIGNED`). Five functions are PINNED there, #1409's own fix
   among them — not every function the classifier scores signed. Dropping the `| None` from a pinned
   one would return it to the collapsed class silently: the regression this file exists to prevent.
2. **A signature that promises an out-of-band failure must honour it.** If a function's annotation
   admits `None`, every failure return in it must BE `None`, not an empty container. This is a
   self-consistency law with no baseline at all: it is clean today, it stays clean forever, and it
   catches the half-done fix — the except arm corrected while the handle guard is left returning
   `[]`, which is precisely the per-site shape a per-function reading of #1409 would miss.

The remaining collapses are **REPORTED, NOT CERTIFIED**, and the reporting test asserts nothing
about their number. This is deliberate and it is the whole ruling on this file:

> **A baseline is a RATCHET.** Baselining the current instances would mark whatever real defects
> they contain as permanently accepted — converting "a default nobody noticed" into "a default
> someone signed", with the same nobody having read them, and a GREEN GATE now asserting the state
> is intentional. That is #1487's own failure mode reintroduced one level up, concealed by the
> gate's own greenness. It is also the shape #1409 arrived in: `docs/dashboard.md` had written the
> defect down as a safety property.

So the un-read instances get no row, no ratchet, and no green. They get a count and their names.

## The residual, stated as a measurement AT A NAMED SHA

Every figure here is measured over live source, so it drifts under refactors unrelated to
annotation, in both directions: quote one with the sha you took it at, and never hang an imperative
on the number (#1556). At `b0a32bd`, the tip this shipped against — **11 collapses** flagged (all in
the DB read layer), **5 signed**, **0 half-fixes**, **57 blind**. At `a0ddbec` plus this slice
(`client/xvb_client.py`) — **11**, **10**, **0**, **52**, since joined by `unjudged` **1** (#1556)
and `procedure` **3** (#1581) at `17722da` — six, which `classify` asserts are exhaustive. #1556
annotates the blind layer slice by slice; the flagged count RISES as slices bring collapses in.

`add_payouts` is worth naming out of the 11, because it shows the class is not academic here: a
failed INSERT returns `[]`, indistinguishable from "every row was already stored", and that value
is what drives the `payout_confirmed` alert. The alert that does not fire is the failure's only
symptom.
"""

import pytest

from tests.service.annotation_gate import classify, classify_package

# Measured, read at source, and cleared — the only set this file ratchets. Each declares `T | None`
# and returns `None` from every failure path: the three-valued contract #1409 established,
# documented in `get_worker_config_change`'s own docstring. Naming them is what makes law 1
# enforceable; the vacuity guard below keeps the list from becoming a check against nothing.
_SIGNED = {
    "service/storage_service.py:get_xvb_standby",
    "service/storage_service.py:get_kv",
    "service/storage_service.py:load_snapshot",
    "service/worker_config_store.py:get_worker_config_history",
    "service/worker_config_store.py:get_worker_config_change",
}


@pytest.fixture(scope="module")
def package() -> dict[str, list]:
    """Every failure return in `mining_dashboard`, classified, in one pass over the real package."""
    return classify_package()


class TestTheSignedContractHolds:
    """The two laws. Neither ratchets an unread instance."""

    def test_the_signed_set_is_real(self, package):
        """Vacuity guard. Law 1 compares against `_SIGNED`; if the walk stopped finding those
        functions the comparison would pass by matching nothing at all, which is the failure this
        whole file argues against. #1409's own fix must be in there by name."""
        assert len(package["signed"]) >= len(_SIGNED)
        assert "service/worker_config_store.py:get_worker_config_history" in package["signed"]

    def test_every_signed_function_still_declares_its_out_of_band_failure(self, package):
        """LAW 1. These five were read at source and cleared. Dropping the `| None` from one
        would move it back into the collapsed class with nothing to notice — #1409 undone by an
        edit that looks like a simplification. A rename UPDATES its entry; deleting it shrinks
        the pinned set, and nothing IN THIS FILE goes red after that."""
        assert _SIGNED <= set(package["signed"])

    def test_no_signature_promises_an_out_of_band_failure_and_collapses_anyway(self, package):
        """LAW 2. No baseline: this is clean now and must stay clean. It catches the HALF-DONE fix
        — the `except` arm corrected to `None` while the handle guard still returns `[]` — which a
        per-function reading of #1409 cannot see, because the function scores 'fixed' on its
        handler while its silent route is untouched."""
        assert package["half_fix"] == []


class TestTheResidualIsReportedNotCertified:
    """#1487's ruling in executable form: the un-read instances get a count, never a green."""

    def test_the_remaining_collapses_are_reported_without_being_baselined(self, package, capsys):
        """Deliberately asserts NOTHING about the count.

        A `<= 11` bound here would be a ratchet over instances nobody has read, which certifies
        whatever real defects they contain as intentional and hides that behind a passing test. A
        `> 0` bound would be worse in the other direction: it would go red the day someone fixes
        the last one. So this reports, and the laws above are what actually hold."""
        with capsys.disabled():
            print(f"\n#1487 residual — {len(package['collapse'])} collapsed return channels:")
            for name, values in sorted(package["collapse"]):
                print(f"    {name} -> {','.join(values)}")
            print(
                f"  and {len(package['blind'])} failure returns in UNANNOTATED functions, which "
                "this mechanism cannot judge either way."
            )
            # The `unjudged` rows are NAMED, not counted, and that is the difference between this
            # line and the one above it. There are few enough to name; the day there are not, the
            # count alone would be the baseline #1487 refused. Reporting them here matters because
            # the verdict was added precisely so that declining to rule is something this gate
            # SAYS — a residual report that omits it puts the silence back one level up.
            print(
                f"  and {len(package['unjudged'])} where the gate DECLINES to rule — annotated, "
                "no out-of-band marker, failure value outside `_EMPTY`:"
            )
            for name, values in sorted(package["unjudged"]):
                print(f"    {name} -> {','.join(values)}")
            # NAMED, not counted — already non-empty, so an arrival moves no count anyone reads.
            print(f"  and {len(package['procedure'])} `-> None` procedures — out of scope (#1581):")
            for name in sorted(package["procedure"]):
                print(f"    {name}")

    def test_the_blind_spot_is_measured_rather_than_described(self, package):
        """The unannotated layer is this gate's real limit, so it is asserted to be a known
        quantity rather than left as a sentence in the docstring. If it collapses to zero the
        package became fully annotated and the gate's reach grew — both worth a deliberate look
        rather than a silent change in what the green means."""
        assert package["blind"], "an unannotated layer of zero would change what this gate covers"


class TestTheCheckerCanSeeWhatItIsBeingAskedAbout:
    """Without these the clean result above is worth nothing. Each control is seeded ACROSS the
    boundary the classifier decides on — a control built only from already-safe shapes would pass
    cleanly against a checker that answered 'safe' to everything."""

    _COLLAPSE = """
class Store:
    def get_rows(self) -> list[dict]:
        try:
            return [dict(r) for r in self._conn.execute("SELECT 1")]
        except Exception:
            return []
"""

    _SIGNED_SHAPE = """
class Store:
    def get_rows(self) -> list[dict] | None:
        try:
            return [dict(r) for r in self._conn.execute("SELECT 1")]
        except Exception:
            return None
"""

    _HALF_FIX = """
class Store:
    def get_rows(self) -> list[dict] | None:
        if not self._conn:
            return []
        try:
            return [dict(r) for r in self._conn.execute("SELECT 1")]
        except Exception:
            return None
"""

    _HANDLE_GUARD = """
class Store:
    def get_rows(self) -> list[dict]:
        if not self._conn:
            return []
        return [dict(r) for r in self._conn.execute("SELECT 1")]
"""

    _DOMAIN_GUARD = """
class Store:
    def add_rows(self, rows) -> list[dict]:
        if not rows:
            return []
        return [dict(r) for r in rows]
"""

    _UNANNOTATED = """
class Store:
    def get_rows(self):
        try:
            return [dict(r) for r in self._conn.execute("SELECT 1")]
        except Exception:
            return []
"""

    def test_it_flags_an_error_returning_a_value_its_success_type_admits(self):
        """POSITIVE CONTROL for the `except` shape — the exact #1409 collapse."""
        assert self._COLLAPSE.count("-> list[dict]:") == 1  # arming readback: no `| None` present
        assert classify(self._COLLAPSE, "m.py")["collapse"] == [("m.py:get_rows", ["[]"])]

    def test_it_clears_the_same_function_once_the_failure_is_out_of_band(self):
        """NEGATIVE CONTROL, and the one that proves the classifier reads the ANNOTATION rather
        than the literal. Same function, same call, same shape — only the contract widened and the
        error value moved out of the success type. A checker keying on `return []` alone would be
        unable to tell these two apart, and would flag #1409's own fix as the defect it fixed."""
        verdicts = classify(self._SIGNED_SHAPE, "m.py")
        assert verdicts["signed"] == ["m.py:get_rows"]
        assert verdicts["collapse"] == []

    def test_it_flags_a_signature_that_promises_out_of_band_and_collapses_anyway(self):
        """POSITIVE CONTROL for LAW 2, whose product on real source is an ABSENCE. An empty result
        there means nothing until the probe is shown able to return a non-empty one. This is the
        half-done fix exactly: handler corrected, handle guard left behind."""
        assert classify(self._HALF_FIX, "m.py")["half_fix"] == [("m.py:get_rows", ["[]"])]

    def test_it_sees_the_handle_guard_with_no_exception_anywhere(self):
        """POSITIVE CONTROL for the silent half of #1409. Nothing in this function raises, so a
        rule anchored on `except` reports it clean — which is how the route a reader could not see
        stayed invisible in the first place."""
        assert "except" not in self._HANDLE_GUARD
        assert classify(self._HANDLE_GUARD, "m.py")["collapse"] == [("m.py:get_rows", ["[]"])]

    def test_it_leaves_a_domain_guard_alone(self):
        """NEGATIVE CONTROL, and the sibling that pins the narrowness. Byte-for-byte the same
        `return []` under the same `if not ...`, differing only in testing a DOMAIN value instead
        of the handle. Without this, `_is_handle_guard` could widen to 'any falsiness guard' and
        every positive control above would still pass — while the gate started firing on the 139
        domain-value guards this rule deliberately leaves alone."""
        assert "        if not rows:\n            return []" in self._DOMAIN_GUARD
        assert classify(self._DOMAIN_GUARD, "m.py") == {
            "signed": [],
            "half_fix": [],
            "collapse": [],
            "blind": [],
            "unjudged": [],
            "procedure": [],
        }

    def test_an_unannotated_function_is_blind_rather_than_clean(self):
        """The third answer. This is the same body as the positive control with its annotation
        removed, and calling it 'clean' would let any collapse escape by deleting a type hint."""
        verdicts = classify(self._UNANNOTATED, "m.py")
        assert verdicts["blind"] == ["m.py:get_rows"]
        assert verdicts["collapse"] == []

    def test_a_boolean_failure_return_is_not_read_as_a_numeric_collapse(self):
        """`False == 0` is true in Python, so an unguarded `0` check reclassifies every boolean
        return as a collapse. `False` is excluded on measured grounds — five outbound senders where
        False-on-failure and False-elsewhere mean the same to a caller — and this proves the
        exclusion is implemented, not just documented."""
        seeded = (
            "class C:\n"
            "    def send(self) -> bool:\n"
            "        try:\n"
            "            return True\n"
            "        except Exception:\n"
            "            return False\n"
        )
        assert classify(seeded, "m.py")["collapse"] == []

    def test_the_walk_finds_the_collapses_that_really_are_in_the_package(self, package):
        """Corroboration on REAL source rather than seeded strings. `get_payouts` returns `[]` from
        its handler under a `-> list[dict[str, Any]]` signature; `add_payouts` does the same and
        that value drives the `payout_confirmed` alert. A walk that came back empty on the real
        package would be one that never matched anything at all."""
        found = dict(package["collapse"])
        assert found["service/storage_service.py:get_payouts"] == ["[]"]
        assert found["service/storage_service.py:add_payouts"] == ["[]"]

    def test_a_none_nested_inside_a_parameter_is_not_read_as_an_out_of_band_marker(self):
        """NEGATIVE CONTROL for `_union_members`. `Callable[[], None]` and `dict[str, None]` both
        contain the token `None` while promising a caller nothing about failure, so a substring or
        whole-tree test reads them as signed and clears a genuine collapse. Neither shape is in the
        package today — this is here so the gate cannot start being wrong about one quietly."""
        for annotation in ("Callable[[], None]", "dict[str, None]"):
            seeded = (
                f"class C:\n    def get(self) -> {annotation}:\n"
                "        try:\n            return build()\n"
                "        except Exception:\n            return {}\n"
            )
            verdicts = classify(seeded, "m.py")
            assert verdicts["signed"] == [], annotation
            assert verdicts["collapse"] == [("m.py:get", ["{}"])], annotation

    def test_optional_and_union_spellings_are_read_as_the_same_contract(self):
        """POSITIVE CONTROL, three spellings of one promise. `T | None`, `Optional[T]` and
        `Union[T, None]` mean the same thing to a caller, so a gate that recognised only the first
        would demand a rewrite of the other two to say what they already say."""
        for annotation in ("list[int] | None", "Optional[list[int]]", "Union[list[int], None]"):
            seeded = (
                f"class C:\n    def get(self) -> {annotation}:\n"
                "        try:\n            return [1]\n"
                "        except Exception:\n            return None\n"
            )
            assert classify(seeded, "m.py")["signed"] == ["m.py:get"], annotation

    def test_a_bare_return_honours_the_contract_the_same_as_return_none(self):
        """`return` and `return None` are one value in two spellings. Holding them apart would red
        law 1 against a function that keeps its promise, and a gate that cries wolf on correct code
        is one people learn to route around."""
        seeded = (
            "class C:\n    def get(self) -> list[int] | None:\n"
            "        if not self._conn:\n            return\n"
            "        return [1]\n"
        )
        assert classify(seeded, "m.py")["signed"] == ["m.py:get"]

    def test_a_procedure_returning_nothing_is_not_counted_as_a_signed_contract(self):
        """NEGATIVE CONTROL, sharpened by #1581. `reconcile_worker_config_status` and two
        siblings are `-> None` procedures whose handle guard is a bare `return`; read as `None`
        they scored as signed, inflating the cleared set with functions that never made the
        promise. It now asserts the row is NAMED `procedure`, not merely absent from `signed`."""
        seeded = (
            "class C:\n    def do(self) -> None:\n"
            "        if not self._conn:\n            return\n"
            "        self._conn.execute('x')\n"
        )
        assert classify(seeded, "m.py") == {
            "signed": [],
            "half_fix": [],
            "collapse": [],
            "blind": [],
            "unjudged": [],
            "procedure": ["m.py:do"],
        }

    def test_an_annotated_function_whose_failure_value_is_untracked_is_unjudged(self):
        """THE FIFTH VERDICT, and the one that had no name until #1556 measured its absence.

        `-> dict` returning `None` on failure: annotated, so not `blind`; declares no out-of-band
        marker, so not `signed`; and `None` is not in `_EMPTY`, so not `collapse` either. Before
        this verdict existed the function fell past every branch and landed in NO list, which made
        it invisible to any law phrased as an absence — a pin asserting "nothing here is blind" was
        satisfied by the function disappearing rather than by the function being clean.

        Both halves are the control. The first is the seeded shape; the second is its `| None`
        sibling, one token apart, which must score `signed` — without it a classifier that answered
        `unjudged` to everything would pass this test."""
        seeded = (
            "class C:\n    def get(self) -> dict:\n"
            "        try:\n            return self._fetch()\n"
            "        except Exception:\n            return None\n"
        )
        assert "-> dict:" in seeded  # arming readback: the marker really is absent
        verdicts = classify(seeded, "m.py")
        assert verdicts["unjudged"] == [("m.py:get", ["None"])]
        assert verdicts["blind"] == []
        assert verdicts["signed"] == []

        signed = seeded.replace("-> dict:", "-> dict | None:")
        assert classify(signed, "m.py")["signed"] == ["m.py:get"]
        assert classify(signed, "m.py")["unjudged"] == []

    def test_a_nested_def_is_attributed_to_itself(self):
        """`web/server.py:_log_filters` holds a `_num` closure, and a walk that folded the two
        together would misreport both — the parent inheriting a contract it never declared. The
        closure here is annotated and collapsing; its parent is not."""
        seeded = (
            "def outer() -> str:\n"
            "    def inner() -> list[int]:\n"
            "        try:\n"
            "            return [1]\n"
            "        except Exception:\n"
            "            return []\n"
            "    return 'x'\n"
        )
        assert classify(seeded, "m.py")["collapse"] == [("m.py:inner", ["[]"])]
