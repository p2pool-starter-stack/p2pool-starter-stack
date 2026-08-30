"""#1487's classifier, as a module two test files can share.

It started inside `test_collapsed_return_channels.py`, which is the file that argued the rule and
still owns it. The rule is:

    a FAILURE path may not return a value that inhabits the function's declared SUCCESS type.

`test_collapsed_return_channels.py` holds the argument, the controls, and the two hard laws.
`test_annotation_coverage.py` holds #1556's per-module pins. Both need the same walk over the
package, and a sibling test module is not importable by name here — `--import-mode=importlib` with
no `__init__.py` means `from test_collapsed_return_channels import classify` raises
`ModuleNotFoundError`. That is why this is a non-test module rather than a helper left where it was.

Import it as `from tests.service.annotation_gate import ...`. `tests` resolves as a namespace
package because pytest runs with `dashboard/` on `sys.path`; both the `make test-dashboard`
invocation (`cd dashboard && ... python -m pytest`) and the bare console script were checked.

Nothing here is a test. The verdicts it produces mean nothing without the controls in
`test_collapsed_return_channels.py`, which seed each shape ACROSS the boundary this file decides
on — a classifier that answered "safe" to everything would pass any check built only from
already-safe shapes.
"""

import ast
import pathlib

_PACKAGE = pathlib.Path(__file__).resolve().parents[2] / "mining_dashboard"

# The collapsed values an error path can hide inside a success type. `False` is deliberately NOT
# here: it was measured at 5 further instances, all of them outbound senders (`_post`/`ping`/
# `send`) where False-on-failure and False-elsewhere mean the same thing to a caller. Including it
# would add five probable false positives to a gate whose whole value is that its findings are real.
_EMPTY = {"[]", "{}", "0"}

# The DB handle. A guard testing THIS is a failure route; a guard testing a domain value is an
# early return. That distinction is what separates 32 in-scope sites from 139 deliberately excluded.
_HANDLE = "_conn"


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


def classify(source: str, where: str) -> dict[str, list]:
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


def classify_package() -> dict[str, list]:
    """Every failure return in `mining_dashboard`, classified, in one pass over the real package."""
    total: dict[str, list] = {"signed": [], "half_fix": [], "collapse": [], "blind": []}
    files = sorted(_PACKAGE.rglob("*.py"))
    # An empty scan is not a clean scan. Every law built on this result is a statement about a set,
    # and a set that is empty because the walk found no files satisfies all of them for the wrong
    # reason. The guard belongs here rather than in either caller: a second caller inheriting the
    # walk without inheriting the guard is how an empty scan starts reading as a clean one.
    assert len(files) > 50, "enumeration guard: the package walk found almost nothing"
    for path in files:
        where = str(path.relative_to(_PACKAGE))
        for verdict, rows in classify(path.read_text(), where).items():
            total[verdict].extend(rows)
    return total
