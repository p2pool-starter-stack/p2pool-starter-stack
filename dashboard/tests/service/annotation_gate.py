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
    """Sort every failure return in one module into the six verdicts, exhaustively.

    ``signed`` — declares an out-of-band marker and honours it.
    ``half_fix`` — declares one and returns an empty container anyway (law 2's quarry).
    ``collapse`` — declares a type the failure value fits, so no caller can tell them apart.
    ``blind`` — unannotated, and therefore outside what this mechanism can judge.
    ``unjudged`` — annotated, declares NO out-of-band marker, and the failure value is outside
    `_EMPTY`. The gate takes no position on these, and the fifth list exists so that taking no
    position is a thing it SAYS rather than a thing it does silently.
    ``procedure`` — declared `-> None`, so there is no success value for a failure to hide inside
    and #1487's rule genuinely cannot apply. Out of scope, and SAID rather than skipped (#1581).

    Exhaustively is the load-bearing word, and the assertion at the end enforces it. Every law
    built on this result is phrased as an absence — "nothing under this module is blind" — and an
    absence is satisfied perfectly by its subject never being classified at all. That has happened
    twice now, by two different exits, and neither looked wrong where it stood.

    The fifth and sixth verdicts were both added after a measured defect of exactly this shape —
    #1556 for `unjudged`, #1581 for `procedure`. Taking the fifth: without it these functions fell
    off the end of the branch chain and appeared in no list at all, so a pin asserting "nothing
    under this module is blind" was satisfied by a function VANISHING. Dropping `| None` from a
    signed function moves it here, not to `blind` — which is the one regression #1556's ratchet
    exists to catch, and it was invisible. Two sub-cases share the verdict deliberately: the
    failure value may inhabit the declared type (`-> bool` returning `False`, a collapse that
    `_EMPTY` is too narrow to name) or fail to inhabit it (`-> dict` returning `None`, an annotation
    that is simply wrong). Both mean the same thing HERE — this mechanism cannot rule — and telling
    them apart needs a type checker, not an AST walk.
    """
    verdicts: dict[str, list] = {
        "signed": [],
        "half_fix": [],
        "collapse": [],
        "blind": [],
        "unjudged": [],
        "procedure": [],
    }
    walked = 0
    for function in ast.walk(ast.parse(source)):
        if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        failures = _failure_returns(function)
        if not failures:
            continue
        # Counted HERE, immediately under the only other early exit, and not one statement lower:
        # everything below this line is inside the invariant, so an exclusion added where a future
        # author would naturally add one cannot open a window the assert is blind to.
        walked += 1
        name = f"{where}:{function.name}"
        # A `-> None` procedure is out of scope entirely, not "signed". It has no success value for
        # a failure to hide inside, so the defect this file describes cannot occur in one. Counting
        # its bare `return` as a signed contract would inflate the cleared set with functions that
        # never made the promise, and make the category mean two things. Being out of scope is a
        # VERDICT here rather than an exit, for the reason #1556 gave the residual one (#1581): a
        # function that leaves the walk satisfies every law phrased as an absence, so the exclusion
        # has to be something this gate SAYS.
        if _returns_nothing(function.returns):
            verdicts["procedure"].append(name)
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
        else:
            # The residual, and it is REPORTED rather than dropped. Every earlier branch is a
            # position the gate is willing to defend; falling past all of them is also a position
            # and it used to be taken in silence. The values are carried unfiltered — `& _EMPTY` is
            # empty here by construction, so intersecting would record an empty tuple for every row
            # and throw away the only fact that distinguishes them.
            verdicts["unjudged"].append((name, sorted(values)))
    # TOTALITY, and not a tidiness check — the reasoning is in the docstring above. What it buys
    # that the six lists do not: a future `continue` added anywhere above trips this on the next
    # run, instead of quietly shrinking the population every law is quantified over. That is the
    # difference between a silent door being absent today and being inexpressible.
    assert sum(len(rows) for rows in verdicts.values()) == walked, (
        f"{where}: {walked} functions have a failure return but "
        f"{sum(len(rows) for rows in verdicts.values())} rows were emitted — one left the walk"
    )
    return verdicts


def _package_files() -> list[pathlib.Path]:
    """Every module in `mining_dashboard`, with the enumeration guard both walks depend on.

    An empty scan is not a clean scan. Every law and every count built on these files is a
    statement about a set, and a set that is empty because the walk found no files satisfies all of
    them for the wrong reason. The guard belongs here rather than in any caller, and the comment
    that used to say so was advice a single caller could not enforce: a second caller inheriting
    the walk without inheriting the guard is how an empty scan starts reading as a clean one. #1604
    brought the second caller, so the advice became the shared function it was describing.
    """
    files = sorted(_PACKAGE.rglob("*.py"))
    assert len(files) > 50, "enumeration guard: the package walk found almost nothing"
    return files


def classify_package() -> dict[str, list]:
    """Every failure return in `mining_dashboard`, classified, in one pass over the real package."""
    total: dict[str, list] = {
        "signed": [],
        "half_fix": [],
        "collapse": [],
        "blind": [],
        "unjudged": [],
        "procedure": [],
    }
    for path in _package_files():
        where = str(path.relative_to(_PACKAGE))
        for verdict, rows in classify(path.read_text(), where).items():
            total[verdict].extend(rows)
    return total


def _falsy_literal(value: ast.AST | None) -> str | None:
    """The falsy value a ``return`` yields, or None if it is not one of them — the residue's set.

    Built ON `_collapsed_literal` rather than beside it: every shape that one tracks is falsy, and
    a second hand-written list of the same shapes is two definitions of one thing, free to drift
    apart in a direction nobody is measuring. A bare `return` normalises to `None` here for the
    reason `classify` gives where it does the same — the two spell a single value, and nothing this
    count is used for can turn on the spelling.

    `""` is the one addition, and it is added HERE rather than in `_collapsed_literal` because the
    two sets answer opposite questions: that one is what a law FLAGS, kept narrow so every finding
    is real and so the verdicts quoted with a sha stay put, while this is what a report DISCLOSES,
    kept wide so the disclosure cannot flatter its own number.
    """
    literal = _collapsed_literal(value)
    if literal is not None:
        return "None" if literal == "<bare>" else literal
    if isinstance(value, ast.Constant) and isinstance(value.value, str) and value.value == "":
        return '""'
    return None


def unannotated_falsy_returns(source: str, where: str) -> list[tuple[str, str, int]]:
    """``(function, literal, lineno)`` for every falsy return in a function that DECLARES NO TYPE.

    This is not a seventh verdict and it is not `blind` widened. `blind` is a function this gate
    REACHED — it has a failure return through one of the two doors — and then could not rule on for
    want of an annotation. This walk asks a question the gate never asks: which functions return a
    falsy value at all, having promised nothing about their return? Most of those returns come
    through neither door, so `classify` emits no row for them and every law built on it is silent
    about them, correctly. #1604 is that silence being read as a clean bill.

    Annotated functions are excluded on the annotation alone: a function that declared a type is
    this mechanism's subject, never its blind spot, however falsy the value it returns.
    """
    found: list[tuple[str, str, int]] = []
    for function in ast.walk(ast.parse(source)):
        if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if function.returns is not None:
            continue
        # `_own_nodes` for the same reason `_failure_returns` uses it, and it is the ONE choice
        # here that a measured sweep already got wrong: `ast.walk(function)` descends into nested
        # defs, so the enclosing function absorbs their returns AND they are counted again as
        # themselves. #1604's table read `web/xvb_views.py` as 12 sites in 6 functions for exactly
        # that reason — `build_xvb_calc` scored the returns at lines 731 and 767, which belong to
        # the nested `_odds_day` and `_face_value` and to nothing of its own. The truth is 10 in 5.
        for node in _own_nodes(function):
            if not isinstance(node, ast.Return):
                continue
            if (literal := _falsy_literal(node.value)) is not None:
                found.append((f"{where}:{function.name}", literal, node.lineno))
    return found


def unannotated_falsy_by_module() -> dict[str, list[tuple[str, str, int]]]:
    """The residue in `mining_dashboard`, keyed by module path, over the real package.

    A module holding none is present with an EMPTY LIST rather than absent. The caller's question
    is "how much residue does this pinned module hold", and a dict that answers a clean module with
    a `KeyError` gives the clean answer and the module-has-vanished answer the same shape — the
    exact absence the pin's own vacuity guards exist to refuse.
    """
    residue: dict[str, list[tuple[str, str, int]]] = {}
    for path in _package_files():
        where = str(path.relative_to(_PACKAGE))
        residue[where] = unannotated_falsy_returns(path.read_text(), where)
    return residue
