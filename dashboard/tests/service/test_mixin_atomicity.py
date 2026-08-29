"""The mixin split's safety property, as an instrument rather than a report of one (#1369).

`plans/1105-cut-map.md` refused splitting `storage_service.py`: multi-table atomic ops need the
single DB-handle class, and a facade would put a seam between callers and that handle. A MIXIN
falls outside that refusal — same class, same instance, same `self`, same connection, same
transaction scope — but only while the property the refusal protects actually holds:

    no method that MOVED to a mixin may call a method that STAYED BEHIND while the DB lock or an
    open transaction is held.

A call that spans that boundary is the seam the cut map refused to create, and nothing else in
the suite would notice it: the code would still work, and the split would still read as safe.

This file ships with the split so the property is re-checked by CI on every later PR, not proven
once and then trusted. A proof a reviewer cannot re-run is an assertion with a table around it; a
proof that runs once cannot stop the NEXT cut regressing it silently.

**On the controls.** `test_the_checker_flags...` seeds a moved method calling a retained one
INSIDE the guard — across the moved/retained boundary, in the direction the question asks. That
shape is the one that matters: a control built only from retained methods cannot exercise the
classifier that decides the question, so a checker that always answered "not moved, skip" would
pass it cleanly and still report zero spanning calls. A control that fires proves the instrument
can see something; only a control that crosses the boundary proves it can see the thing.
"""

import ast
from pathlib import Path

import pytest

_SERVICE = Path(__file__).resolve().parents[2] / "mining_dashboard" / "service"
_SUBJECT = _SERVICE / "storage_service.py"
_MIXIN_FILES = ("telemetry_store.py", "worker_config_store.py")

# Holding either of these is what makes a call "spanning": `_db_lock` serializes DB access and
# `_conn` used as a context manager IS the transaction. A call made while one is held runs inside
# somebody else's atomic scope; the same call after the block closes does not.
_GUARDS = ("_db_lock", "_conn")

# The handle the mixins legitimately share — one connection, one lock, one logger, one path. Every
# OTHER attribute `StateManager` assigns to itself is retained in-memory state, and a moved method
# touching one would be reaching back into state that did not move with it: the second half of the
# ruling's question. That set is DERIVED from the subject below rather than listed here, because a
# hardcoded mirror of another file's `__init__` stops covering a new attribute the day someone adds
# one, and Q2 would go on reporting clean — the exact false pass this file exists to prevent.
_SHARED_HANDLE = {"_conn", "_db_lock", "logger", "db_path"}


def _methods(source: str) -> dict[str, ast.FunctionDef]:
    """Every method defined in every class in one module's source, by name."""
    return {
        item.name: item
        for node in ast.walk(ast.parse(source))
        if isinstance(node, ast.ClassDef)
        for item in node.body
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
    }


def _guarded_calls(method: ast.AST, targets: set[str]) -> list[str]:
    """Names in ``targets`` this method calls as ``self.<name>()`` while a DB guard is held.

    Walks each guard `with`'s BODY, not the whole method: position is the entire property, and
    the same call one line after the block closes is the safe shape every real method here uses.
    Nested `with`s are walked by both their own and their parent's pass, so hits are deduplicated.
    """
    hits = set()
    for node in ast.walk(method):
        if not isinstance(node, ast.With):
            continue
        if not any(
            isinstance(n, ast.Attribute) and n.attr in _GUARDS
            for item in node.items
            for n in ast.walk(item.context_expr)
        ):
            continue
        for statement in node.body:
            for call in ast.walk(statement):
                if (
                    isinstance(call, ast.Call)
                    and isinstance(call.func, ast.Attribute)
                    and isinstance(call.func.value, ast.Name)
                    and call.func.value.id == "self"
                    and call.func.attr in targets
                ):
                    hits.add(call.func.attr)
    return sorted(hits)


def _self_attr_names(target: ast.AST) -> set[str]:
    """The ``self.<name>`` attributes one assignment target binds.

    Recursive because a target can nest: ``self.a, (self.b, self.c) = ...`` is a ``Tuple`` holding
    a ``Tuple``, and ``self.a, *self.rest = ...`` puts one of them behind a ``Starred``. Anything
    that is not an attribute on ``self`` — a bare local, an attribute on some other object —
    contributes nothing, which is what keeps the walk narrow rather than merely wide.
    """
    if isinstance(target, (ast.Tuple, ast.List)):
        return {name for element in target.elts for name in _self_attr_names(element)}
    if isinstance(target, ast.Starred):
        return _self_attr_names(target.value)
    if (
        isinstance(target, ast.Attribute)
        and isinstance(target.value, ast.Name)
        and target.value.id == "self"
    ):
        return {target.attr}
    return set()


def _retained_state(subject: str) -> set[str]:
    """Every attribute ``StateManager`` assigns to itself, minus the shared DB handle.

    Four binding shapes, not one (#1535). The first version read only ``ast.Assign`` targets that
    were themselves ``ast.Attribute``, which is blind to tuple/list unpacking, to ``ast.AnnAssign``,
    and to ``setattr(self, "x", v)`` — none of them contrived: the tuple shape is in production use
    two modules over in ``data_service.py``.

    **A shape this misses cannot be reported, and the silence is indistinguishable from a clean
    result.** Q2 below asks whether a moved method touches state that stayed behind, and it answers
    by name: a name the needle set never contains produces no finding no matter how badly a method
    reaches for it. So the failure mode of a narrow walk here is a false PASS, which is the one this
    file exists to prevent — hence the controls below covering every shape, and a near-miss sibling
    proving the widened walk did not simply become "any attribute anywhere".
    """
    state: set[str] = set()
    for node in ast.walk(ast.parse(subject)):
        if not (isinstance(node, ast.ClassDef) and node.name == "StateManager"):
            continue
        for statement in ast.walk(node):
            if isinstance(statement, ast.Assign):
                for target in statement.targets:
                    state |= _self_attr_names(target)
            elif isinstance(statement, ast.AnnAssign):
                state |= _self_attr_names(statement.target)
            elif _is_self_setattr(statement):
                state.add(statement.args[1].value)
    return state - _SHARED_HANDLE


def _self_setattr_calls(subject: str) -> list[ast.Call]:
    """Every ``setattr(self, ...)`` inside ``StateManager``, resolvable name or not."""
    return [
        statement
        for node in ast.walk(ast.parse(subject))
        if isinstance(node, ast.ClassDef) and node.name == "StateManager"
        for statement in ast.walk(node)
        if isinstance(statement, ast.Call)
        and isinstance(statement.func, ast.Name)
        and statement.func.id == "setattr"
        and statement.args
        and isinstance(statement.args[0], ast.Name)
        and statement.args[0].id == "self"
    ]


def _is_self_setattr(node: ast.AST) -> bool:
    """``setattr(self, "literal", value)`` — a static walk can only resolve a literal name."""
    return (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "setattr"
        and len(node.args) == 3
        and isinstance(node.args[0], ast.Name)
        and node.args[0].id == "self"
        and isinstance(node.args[1], ast.Constant)
        and isinstance(node.args[1].value, str)
    )


def _state_reads(method: ast.AST, retained_state: set[str]) -> list[str]:
    """Retained in-memory attributes this method reads or writes through ``self``."""
    return sorted(
        {
            node.attr
            for node in ast.walk(method)
            if isinstance(node, ast.Attribute)
            and isinstance(node.value, ast.Name)
            and node.value.id == "self"
            and node.attr in retained_state
        }
    )


@pytest.fixture(scope="module")
def split():
    """The real split: retained method names, moved methods, and retained state names."""
    subject = _SUBJECT.read_text()
    retained = set(_methods(subject))
    moved = {}
    for name in _MIXIN_FILES:
        moved.update(_methods((_SERVICE / name).read_text()))
    return retained - set(moved), moved, _retained_state(subject)


class TestTheSplitHoldsItsAtomicityProperty:
    def test_the_two_sets_are_real_and_disjoint(self, split):
        """An empty or overlapping enumeration would make every assertion below vacuous."""
        retained, moved, state = split
        assert len(retained) > 20 and len(moved) > 5
        assert retained & set(moved) == set()
        # The derived state set must be real too, or Q2 below is a check against an empty needle
        # list — which passes for exactly the reason it should not.
        assert {"state", "table_health", "_lock"} <= state
        # The callee the controls below lean on has to be a real retained method, not an invented
        # name that would make them pass by matching nothing.
        assert "_db_error" in retained

    def test_no_moved_method_calls_a_retained_one_under_the_db_guard(self, split):
        """Q1 — the ruling's actual test."""
        retained, moved, _ = split
        spanning = {n: c for n, fn in moved.items() if (c := _guarded_calls(fn, retained))}
        assert spanning == {}

    def test_no_moved_method_touches_retained_in_memory_state(self, split):
        """Q2 — the mixins share the DB handle by design; they must not share anything else."""
        _, moved, state = split
        reaching = {n: s for n, fn in moved.items() if (s := _state_reads(fn, state))}
        assert reaching == {}

    def test_no_state_is_bound_through_a_name_the_walk_cannot_resolve(self):
        """The one shape a static walk cannot follow, checked rather than assumed (#1535).

        ``setattr(self, name, value)`` with a COMPUTED name puts a retained attribute outside the
        needle set, and Q2 then goes quiet about it — the same false pass the widened walk above
        exists to close, arriving by the one door the widening cannot shut. Nothing in the subject
        does this today. This asserts that, so the limit is a measured fact with a test naming it
        rather than a gap someone meets by surprise."""
        unresolvable = [
            ast.unparse(call)
            for call in _self_setattr_calls(_SUBJECT.read_text())
            if not _is_self_setattr(call)
        ]
        assert unresolvable == []


class TestTheCheckerCanSeeWhatItIsBeingAskedAbout:
    """Without these the clean result above is worth nothing."""

    _INSIDE = """
class SeededMixin:
    def write_row_and_report_inside(self):
        with self._db_lock:
            self._conn.execute("INSERT INTO t VALUES (1)")
            self._db_error("seeded", None)
"""

    _OUTSIDE = """
class SeededMixin:
    def write_row_then_report(self):
        try:
            with self._db_lock:
                self._conn.execute("INSERT INTO t VALUES (1)")
        except Exception as e:
            self._db_error("seeded", e)
"""

    def test_the_checker_flags_a_moved_method_calling_a_retained_one_inside_the_guard(self, split):
        """POSITIVE CONTROL, seeded ACROSS the moved/retained boundary — a moved method with a
        retained call inside its transaction block, which is the direction Q1 asks about."""
        retained, _, _ = split
        seeded = _methods(self._INSIDE)["write_row_and_report_inside"]
        # Arming readback: the seed is a control only if it is really there, in that shape.
        assert "with self._db_lock:" in self._INSIDE
        assert self._INSIDE.index("self._db_error") > self._INSIDE.index("with self._db_lock:")
        assert _guarded_calls(seeded, retained) == ["_db_error"]

    def test_the_same_retained_call_after_the_guard_closes_is_not_flagged(self, split):
        """NEGATIVE CONTROL. This is the shape every real moved method has — the error path runs
        after the context managers have exited — so a checker that could not tell the two apart
        would report the real split as unsafe, and its clean result would prove nothing."""
        retained, _, _ = split
        seeded = _methods(self._OUTSIDE)["write_row_then_report"]
        assert "self._db_error" in self._OUTSIDE  # same call, same names, only the position moved
        assert _guarded_calls(seeded, retained) == []

    def test_the_walk_finds_the_guarded_calls_that_really_are_in_the_subject(self, split):
        """Corroboration on REAL source, not a synthetic string: `_recover_corrupt_db` calls
        `_prune_quarantined` and `_apply_schema` inside `with self._db_lock:`. All three are
        retained, so these are not findings — Q1 is about moved methods — but a walk that came
        back empty here would be one that never matched anything on this file at all."""
        retained, _, _ = split
        subject = _methods(_SUBJECT.read_text())
        assert _guarded_calls(subject["_recover_corrupt_db"], retained) == [
            "_apply_schema",
            "_prune_quarantined",
        ]

    def test_the_state_check_flags_a_moved_method_reaching_back_into_retained_state(self, split):
        """POSITIVE CONTROL for Q2, in the same direction: a moved method touching `self.state`."""
        _, _, state = split
        seeded = _methods("class M:\n    def f(self):\n        return self.state['x']\n")["f"]
        assert _state_reads(seeded, state) == ["state"]


class TestTheStateWalkSeesEveryShapeStateCanBeBoundIn:
    """#1535. ``_retained_state`` decides what Q2 is ABLE to report, so a shape it cannot see is a
    violation that passes silently — and a walk that reports nothing looks exactly like a split
    that touches nothing. These seed each shape rather than describing it, and the near-miss case
    is what separates a walk that is complete from one that is merely wide."""

    # Every shape a `self.` attribute can be bound in. The class must literally be named
    # `StateManager`: `_retained_state` filters on that name, so a control in a differently-named
    # class comes back empty and reads as a broken walk rather than a broken fixture.
    _EVERY_SHAPE = """
class StateManager:
    def __init__(self):
        self.plain = 1
        self.tuple_a, self.tuple_b = 1, 2
        [self.list_a, self.list_b] = [1, 2]
        self.nested_a, (self.nested_b, self.nested_c) = 1, (2, 3)
        self.starred_head, *self.starred_rest = [1, 2, 3]
        self.annotated: int = 0
        setattr(self, "by_setattr", 1)
"""

    # The same shapes aimed one step off target, so widening cannot quietly become "any attribute".
    _NEAR_MISSES = """
class StateManager:
    def __init__(self, other):
        other.on_another_object = 1
        local_only, self.mixed_with_a_local = 1, 2
        setattr(other, "on_another_object_too", 1)


class NotTheStateManager:
    def __init__(self):
        self.in_a_different_class = 1
"""

    def test_every_binding_shape_reaches_the_needle_set(self):
        """POSITIVE CONTROL, one seeded name per shape. Before #1535 this returned only ``plain``:
        tuple and list targets, the annotated assignment and the ``setattr`` were all invisible,
        and the three the issue named are in ordinary use in this codebase."""
        assert _retained_state(self._EVERY_SHAPE) == {
            "plain",
            "tuple_a",
            "tuple_b",
            "list_a",
            "list_b",
            "nested_a",
            "nested_b",
            "nested_c",
            "starred_head",
            "starred_rest",
            "annotated",
            "by_setattr",
        }

    def test_the_widened_walk_stays_narrow(self):
        """NEGATIVE CONTROL. Every name here is a near miss — another object's attribute, a bare
        local sharing a tuple target with a real one, a ``setattr`` on something else, an identical
        assignment in a class this walk is not asked about. Only the one genuine ``self.`` target
        inside ``StateManager`` survives. Without this, widening the walk could have admitted
        everything and the positive control above would still pass."""
        assert _retained_state(self._NEAR_MISSES) == {"mixed_with_a_local"}

    def test_the_shared_db_handle_is_still_subtracted_through_the_new_shapes(self):
        """The handle the mixins legitimately share must not read as retained state — through a
        tuple target as much as through a plain one, which is where widening could have leaked it
        back in."""
        seeded = (
            "class StateManager:\n"
            "    def __init__(self):\n"
            "        self._conn, self.kept = None, 1\n"
        )
        assert _retained_state(seeded) == {"kept"}

    def test_the_unresolvable_setattr_probe_can_see_one(self):
        """POSITIVE CONTROL for the subject assertion above, whose product is an ABSENCE — an
        empty result there means nothing until the probe is shown able to return a non-empty one.

        It also pins the limit honestly: the computed name is NOT in the needle set, and no static
        walk can put it there. That is why the subject test asserts none exists rather than
        pretending to cover it."""
        seeded = (
            "class StateManager:\n"
            "    def __init__(self, name):\n"
            '        setattr(self, "literal", 1)\n'
            "        setattr(self, name, 2)\n"
        )
        calls = _self_setattr_calls(seeded)
        assert len(calls) == 2
        assert [ast.unparse(c) for c in calls if not _is_self_setattr(c)] == [
            "setattr(self, name, 2)"
        ]
        assert _retained_state(seeded) == {"literal"}
