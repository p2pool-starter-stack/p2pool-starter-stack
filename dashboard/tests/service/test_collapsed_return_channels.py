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
(`client/xvb_client.py`) — **11**, **10**, **0**, **52**. #1556 annotates the blind layer slice by
slice; the flagged count is expected to RISE wherever a slice brings a genuine collapse into scope.

`add_payouts` is worth naming out of the 11, because it shows the class is not academic here: a
failed INSERT returns `[]`, indistinguishable from "every row was already stored", and that value
is what drives the `payout_confirmed` alert. The alert that does not fire is the failure's only
symptom.
"""

import ast
import pathlib

import pytest

_PACKAGE = pathlib.Path(__file__).resolve().parents[2] / "mining_dashboard"

# The collapsed values an error path can hide inside a success type. `False` is deliberately NOT
# here: it was measured at 5 further instances, all of them outbound senders (`_post`/`ping`/
# `send`) where False-on-failure and False-elsewhere mean the same thing to a caller. Including it
# would add five probable false positives to a gate whose whole value is that its findings are real.
_EMPTY = {"[]", "{}", "0"}

# The DB handle. A guard testing THIS is a failure route; a guard testing a domain value is an
# early return. That distinction is what separates 32 in-scope sites from 139 deliberately excluded.
_HANDLE = "_conn"

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


def _collapsed_literal(value: ast.AST | None) -> str | None:
    """The collapsed value a ``return`` yields, or None if it is not one of the shapes we track.

    An empty list/dict written as a literal, a bare `return`, `None`, and integer `0`. `False` is
    reported so the classifier can SEE it, and excluded from `_EMPTY` so it cannot be flagged — the
    two are different decisions and collapsing them here would be this file's own defect. `0` is
    guarded against `bool`, because `False == 0` is true in Python and an unguarded check would
    silently reclassify every boolean return as a numeric collapse.
    """
    if value is None:
        return "<bare>"
    if isinstance(value, ast.List) and not value.elts:
        return "[]"
    if isinstance(value, ast.Dict) and not value.keys:
        return "{}"
    if isinstance(value, ast.Constant):
        if value.value is None:
            return "None"
        if value.value is False:
            return "False"
        if value.value == 0 and isinstance(value.value, int) and not isinstance(value.value, bool):
            return "0"
    return None


def _own_nodes(function: ast.AST) -> list[ast.AST]:
    """Every node belonging to THIS function, never to a def nested inside it.

    A nested def is its own function with its own contract: folding its returns into the parent
    both double-counts and misattributes. `web/server.py:_log_filters` and the `_num` closure
    inside it are the real case — a naive walk reports them as one function and gets the answer
    wrong in both directions at once.
    """
    collected: list[ast.AST] = []

    def walk(node: ast.AST) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            collected.append(child)
            walk(child)

    walk(function)
    return collected


def _union_members(annotation: ast.AST) -> list[ast.AST]:
    """The TOP-LEVEL alternatives of a return annotation, flattened.

    Only the top level, which is the entire point. `None` nested inside a parameter — the return
    slot of a `Callable[[], None]`, the value type of a `dict[str, None]` — says nothing about
    whether THIS function can return None, and a walk of the whole annotation tree cannot tell the
    two apart. Nothing in the package wears that shape today; this is written so the gate does not
    start misreading the day something does, because the failure would be a false accusation
    against a function that never collapsed anything.
    """
    if isinstance(annotation, ast.BinOp) and isinstance(annotation.op, ast.BitOr):
        return _union_members(annotation.left) + _union_members(annotation.right)
    if isinstance(annotation, ast.Subscript):
        base = annotation.value
        name = base.id if isinstance(base, ast.Name) else getattr(base, "attr", "")
        if name == "Optional":
            # Both halves: `Optional[T]` is `T | None`, and returning only the None would make the
            # annotation indistinguishable from a bare `-> None` procedure.
            return _union_members(annotation.slice) + [ast.Constant(None)]
        if name == "Union":
            inner = annotation.slice
            elements = inner.elts if isinstance(inner, ast.Tuple) else [inner]
            return [member for element in elements for member in _union_members(element)]
    return [annotation]


def _returns_nothing(annotation: ast.AST | None) -> bool:
    """Is this declared `-> None` — a procedure with no return value at all?

    Distinct from `T | None`, which is a value type carrying an out-of-band failure marker. The
    procedure has no answer channel for an error to share, so it is neither signed nor collapsed;
    it is simply not what this file is about.
    """
    members = _union_members(annotation) if annotation is not None else []
    return len(members) == 1 and isinstance(members[0], ast.Constant) and members[0].value is None


def _admits_none(annotation: ast.AST | None) -> bool | None:
    """Does the declared return type carry an out-of-band failure marker?

    None (the return value, not the type) means UNANNOTATED — a third answer, not a false one. A
    function that declares no type declares no contract, so it can be neither signed nor in breach,
    and the reporting test counts it as blind rather than clean. Conflating "no annotation" with
    "does not admit None" would flag the whole unannotated layer as collapsed and make the gate's
    findings worthless.
    """
    if annotation is None:
        return None
    return any(
        isinstance(member, ast.Constant) and member.value is None
        for member in _union_members(annotation)
    )


def _is_handle_guard(node: ast.AST) -> bool:
    """``if not self._conn:`` or ``if self._conn is None:`` — a resource handle, not a domain value.

    Both spellings, because the same failure written the other way is the same failure and a gate
    that saw only one would be muted by a reformat.
    """
    if not isinstance(node, ast.If):
        return False
    test = node.test
    if isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not):
        test = test.operand
    if isinstance(test, ast.Compare) and len(test.ops) == 1 and isinstance(test.ops[0], ast.Is):
        test = test.left
    return (
        isinstance(test, ast.Attribute)
        and test.attr == _HANDLE
        and isinstance(test.value, ast.Name)
        and test.value.id == "self"
    )


def _failure_returns(function: ast.AST) -> list[tuple[str, str, int]]:
    """``(shape, literal, lineno)`` for every failure return in one function.

    Both doors: a return lexically inside an `except` handler, and a return that is the entire body
    of a handle guard. A guard return that is itself inside a handler is attributed to the handler
    once rather than counted twice.
    """
    nodes = _own_nodes(function)
    handler_lines: set[int] = set()
    found: list[tuple[str, str, int]] = []
    for node in nodes:
        if not isinstance(node, ast.ExceptHandler):
            continue
        for sub in ast.walk(node):
            handler_lines.add(getattr(sub, "lineno", -1))
            if isinstance(sub, ast.Return) and (literal := _collapsed_literal(sub.value)):
                found.append(("except", literal, sub.lineno))
    for node in nodes:
        if not (_is_handle_guard(node) and len(node.body) == 1):
            continue
        statement = node.body[0]
        if not isinstance(statement, ast.Return) or statement.lineno in handler_lines:
            continue
        if literal := _collapsed_literal(statement.value):
            found.append(("guard", literal, statement.lineno))
    return found


def _classify(source: str, where: str) -> dict[str, list]:
    """Sort every failure return in one module into the four verdicts.

    ``signed`` — declares an out-of-band marker and honours it.
    ``half_fix`` — declares one and returns an empty container anyway (law 2's quarry).
    ``collapse`` — declares a type the failure value fits, so no caller can tell them apart.
    ``blind`` — unannotated, and therefore outside what this mechanism can judge.
    """
    verdicts: dict[str, list] = {"signed": [], "half_fix": [], "collapse": [], "blind": []}
    for function in ast.walk(ast.parse(source)):
        if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        failures = _failure_returns(function)
        if not failures:
            continue
        name = f"{where}:{function.name}"
        # A `-> None` procedure is out of scope entirely, not "signed". It has no success value for
        # a failure to hide inside, so the defect this file describes cannot occur in one. Counting
        # its bare `return` as a signed contract would inflate the cleared set with functions that
        # never made the promise — three of them here — and make the category mean two things.
        if _returns_nothing(function.returns):
            continue
        admits = _admits_none(function.returns)
        values = {literal for _, literal, _ in failures}
        # A bare `return` and `return None` are the same value; only the spelling differs. Holding
        # them apart here would red the gate on a signed function the day someone dropped the
        # word `None`, which is a false alarm against code that honours the contract exactly.
        values = {"None" if value == "<bare>" else value for value in values}
        if admits is None:
            verdicts["blind"].append(name)
        elif admits and values <= {"None"}:
            verdicts["signed"].append(name)
        elif admits and values & _EMPTY:
            verdicts["half_fix"].append((name, sorted(values & _EMPTY)))
        elif not admits and values & _EMPTY:
            verdicts["collapse"].append((name, sorted(values & _EMPTY)))
    return verdicts


@pytest.fixture(scope="module")
def package() -> dict[str, list]:
    """Every failure return in `mining_dashboard`, classified, in one pass over the real package."""
    total: dict[str, list] = {"signed": [], "half_fix": [], "collapse": [], "blind": []}
    files = sorted(_PACKAGE.rglob("*.py"))
    # An empty scan is not a clean scan. Every assertion below is a statement about a set, and a
    # set that is empty because the walk found no files satisfies all of them for the wrong reason.
    assert len(files) > 50, "enumeration guard: the package walk found almost nothing"
    for path in files:
        where = str(path.relative_to(_PACKAGE))
        for verdict, rows in _classify(path.read_text(), where).items():
            total[verdict].extend(rows)
    return total


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
        assert _classify(self._COLLAPSE, "m.py")["collapse"] == [("m.py:get_rows", ["[]"])]

    def test_it_clears_the_same_function_once_the_failure_is_out_of_band(self):
        """NEGATIVE CONTROL, and the one that proves the classifier reads the ANNOTATION rather
        than the literal. Same function, same call, same shape — only the contract widened and the
        error value moved out of the success type. A checker keying on `return []` alone would be
        unable to tell these two apart, and would flag #1409's own fix as the defect it fixed."""
        verdicts = _classify(self._SIGNED_SHAPE, "m.py")
        assert verdicts["signed"] == ["m.py:get_rows"]
        assert verdicts["collapse"] == []

    def test_it_flags_a_signature_that_promises_out_of_band_and_collapses_anyway(self):
        """POSITIVE CONTROL for LAW 2, whose product on real source is an ABSENCE. An empty result
        there means nothing until the probe is shown able to return a non-empty one. This is the
        half-done fix exactly: handler corrected, handle guard left behind."""
        assert _classify(self._HALF_FIX, "m.py")["half_fix"] == [("m.py:get_rows", ["[]"])]

    def test_it_sees_the_handle_guard_with_no_exception_anywhere(self):
        """POSITIVE CONTROL for the silent half of #1409. Nothing in this function raises, so a
        rule anchored on `except` reports it clean — which is how the route a reader could not see
        stayed invisible in the first place."""
        assert "except" not in self._HANDLE_GUARD
        assert _classify(self._HANDLE_GUARD, "m.py")["collapse"] == [("m.py:get_rows", ["[]"])]

    def test_it_leaves_a_domain_guard_alone(self):
        """NEGATIVE CONTROL, and the sibling that pins the narrowness. Byte-for-byte the same
        `return []` under the same `if not ...`, differing only in testing a DOMAIN value instead
        of the handle. Without this, `_is_handle_guard` could widen to 'any falsiness guard' and
        every positive control above would still pass — while the gate started firing on the 139
        domain-value guards this rule deliberately leaves alone."""
        assert "        if not rows:\n            return []" in self._DOMAIN_GUARD
        assert _classify(self._DOMAIN_GUARD, "m.py") == {
            "signed": [],
            "half_fix": [],
            "collapse": [],
            "blind": [],
        }

    def test_an_unannotated_function_is_blind_rather_than_clean(self):
        """The third answer. This is the same body as the positive control with its annotation
        removed, and calling it 'clean' would let any collapse escape by deleting a type hint."""
        verdicts = _classify(self._UNANNOTATED, "m.py")
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
        assert _classify(seeded, "m.py")["collapse"] == []

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
            verdicts = _classify(seeded, "m.py")
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
            assert _classify(seeded, "m.py")["signed"] == ["m.py:get"], annotation

    def test_a_bare_return_honours_the_contract_the_same_as_return_none(self):
        """`return` and `return None` are one value in two spellings. Holding them apart would red
        law 1 against a function that keeps its promise, and a gate that cries wolf on correct code
        is one people learn to route around."""
        seeded = (
            "class C:\n    def get(self) -> list[int] | None:\n"
            "        if not self._conn:\n            return\n"
            "        return [1]\n"
        )
        assert _classify(seeded, "m.py")["signed"] == ["m.py:get"]

    def test_a_procedure_returning_nothing_is_not_counted_as_a_signed_contract(self):
        """NEGATIVE CONTROL. `reconcile_worker_config_status` and two siblings are `-> None`
        procedures whose handle guard is a bare `return`. Once bare returns were read as `None`
        they began scoring as signed — inflating the cleared set with three functions that never
        made the promise, which is the same overstatement in miniature that this file refuses to
        make about the eleven."""
        seeded = (
            "class C:\n    def do(self) -> None:\n"
            "        if not self._conn:\n            return\n"
            "        self._conn.execute('x')\n"
        )
        assert _classify(seeded, "m.py") == {
            "signed": [],
            "half_fix": [],
            "collapse": [],
            "blind": [],
        }

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
        assert _classify(seeded, "m.py")["collapse"] == [("m.py:inner", ["[]"])]
