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

# StateManager's retained in-memory state (from its `__init__`), as opposed to the DB handle the
# mixins legitimately share. A moved method touching any of these would be reaching back into
# state that did not move with it — the second half of the ruling's question.
_RETAINED_STATE = (
    "state",
    "_lock",
    "_xvb_rewards",
    "_xvb_round_stats",
    "table_health",
    "db_healthy",
    "db_reset_count",
    "last_db_reset",
    "db_unrecoverable",
)


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


def _state_reads(method: ast.AST) -> list[str]:
    """Retained in-memory attributes this method reads or writes through ``self``."""
    return sorted(
        {
            node.attr
            for node in ast.walk(method)
            if isinstance(node, ast.Attribute)
            and isinstance(node.value, ast.Name)
            and node.value.id == "self"
            and node.attr in _RETAINED_STATE
        }
    )


@pytest.fixture(scope="module")
def split():
    """The real split: every retained method name, and every moved method by name."""
    retained = set(_methods(_SUBJECT.read_text()))
    moved = {}
    for name in _MIXIN_FILES:
        moved.update(_methods((_SERVICE / name).read_text()))
    return retained - set(moved), moved


class TestTheSplitHoldsItsAtomicityProperty:
    def test_the_two_sets_are_real_and_disjoint(self, split):
        """An empty or overlapping enumeration would make every assertion below vacuous."""
        retained, moved = split
        assert len(retained) > 20 and len(moved) > 5
        assert retained & set(moved) == set()
        # The callee the controls below lean on has to be a real retained method, not an invented
        # name that would make them pass by matching nothing.
        assert "_db_error" in retained

    def test_no_moved_method_calls_a_retained_one_under_the_db_guard(self, split):
        """Q1 — the ruling's actual test."""
        retained, moved = split
        spanning = {n: c for n, fn in moved.items() if (c := _guarded_calls(fn, retained))}
        assert spanning == {}

    def test_no_moved_method_touches_retained_in_memory_state(self, split):
        """Q2 — the mixins share the DB handle by design; they must not share anything else."""
        _, moved = split
        reaching = {n: s for n, fn in moved.items() if (s := _state_reads(fn))}
        assert reaching == {}


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
        retained, _ = split
        seeded = _methods(self._INSIDE)["write_row_and_report_inside"]
        # Arming readback: the seed is a control only if it is really there, in that shape.
        assert "with self._db_lock:" in self._INSIDE
        assert self._INSIDE.index("self._db_error") > self._INSIDE.index("with self._db_lock:")
        assert _guarded_calls(seeded, retained) == ["_db_error"]

    def test_the_same_retained_call_after_the_guard_closes_is_not_flagged(self, split):
        """NEGATIVE CONTROL. This is the shape every real moved method has — the error path runs
        after the context managers have exited — so a checker that could not tell the two apart
        would report the real split as unsafe, and its clean result would prove nothing."""
        retained, _ = split
        seeded = _methods(self._OUTSIDE)["write_row_then_report"]
        assert "self._db_error" in self._OUTSIDE  # same call, same names, only the position moved
        assert _guarded_calls(seeded, retained) == []

    def test_the_walk_finds_the_guarded_calls_that_really_are_in_the_subject(self, split):
        """Corroboration on REAL source, not a synthetic string: `_recover_corrupt_db` calls
        `_prune_quarantined` and `_apply_schema` inside `with self._db_lock:`. All three are
        retained, so these are not findings — Q1 is about moved methods — but a walk that came
        back empty here would be one that never matched anything on this file at all."""
        retained, _ = split
        subject = _methods(_SUBJECT.read_text())
        assert _guarded_calls(subject["_recover_corrupt_db"], retained) == [
            "_apply_schema",
            "_prune_quarantined",
        ]

    def test_the_state_check_flags_a_moved_method_reaching_back_into_retained_state(self):
        """POSITIVE CONTROL for Q2, in the same direction: a moved method touching `self.state`."""
        seeded = _methods("class M:\n    def f(self):\n        return self.state['x']\n")["f"]
        assert _state_reads(seeded) == ["state"]
