"""#1556 — a module that has been annotated stays annotated.

`test_collapsed_return_channels.py` (#1487) enforces the rule that a failure path may not return a
value inhabiting the declared success type. That rule can only judge a function that DECLARES a
return type. An unannotated function is scored `blind`: not clean, not in breach, simply outside
what the mechanism can see. At the tip this file shipped against there were **52** such failure
returns across **31** modules, and #1556 is the work of annotating them slice by slice.

This file is the ratchet that makes each slice stick. Without it a slice is undone by any edit that
drops a `| None`, and nothing goes red: the function returns to the blind set, the collapse count
does not move, and the #1487 laws have nothing to say because they only speak about functions that
made a promise.

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

from tests.service.annotation_gate import classify, classify_package

# The modules with ZERO unannotated failure returns, measured over live source. Each slice of #1556
# adds the module it finished. Measured at this tip: 2 of 33 modules that hold a failure return at
# all, `client/xvb_client.py` by slice 1 and `service/worker_config_store.py` by pre-existing work.
# **Only ever add a module you have read.** Adding one because the gate happens to score it clean
# is the baseline #1487 refused, wearing this file's name.
PINNED = (
    "client/xvb_client.py",
    "service/worker_config_store.py",
)

# One function per pinned module, as the vacuity anchor. Law 1's own guard uses this shape: a
# statement about "no blind names under this prefix" is satisfied perfectly by a module that has
# vanished from the walk, and that is the reading a deleted file, a moved package root or a broken
# `rglob` all produce. `note_worker_revision` is the deliberate choice for its module — it is the
# one signed function `_SIGNED` never named.
_ANCHORS = {
    "client/xvb_client.py": "client/xvb_client.py:get_stats",
    "service/worker_config_store.py": "service/worker_config_store.py:note_worker_revision",
}


def _blind_under(module: str, verdicts: dict[str, list]) -> list[str]:
    """Every unannotated failure return the walk found in one module."""
    return sorted(name for name in verdicts["blind"] if name.startswith(f"{module}:"))


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


class TestAnAnnotatedModuleStaysAnnotated:
    """The law. It ratchets coverage of the mechanism, never a verdict the mechanism returned."""

    @pytest.mark.parametrize("module", PINNED)
    def test_no_failure_return_in_a_pinned_module_is_unannotated(self, module, package):
        """Dropping the `| None` from one of these returns it to the blind set in silence: the
        #1487 laws stop applying to it, because they only judge a function that declared a
        contract. Nothing else in the suite notices. This is what notices."""
        assert _blind_under(module, package) == []

    @pytest.mark.parametrize("module", PINNED)
    def test_a_pinned_module_is_actually_in_the_walk(self, module, package):
        """VACUITY GUARD. `[] == []` is what a deleted file, a renamed package root and a walk that
        matched nothing all return, and each of those satisfies the law above perfectly. Both parts
        matter: the module must contribute rows, and its named anchor must still be there — the
        first catches the walk breaking, the second catches the one function whose annotation was
        the point being deleted rather than reverted."""
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

    def test_the_prefix_match_does_not_span_module_names(self, package):
        """`startswith(f"{module}:")` carries the delimiter deliberately. Without it
        `service/worker_config_store.py` would also claim any module whose path extends it, and the
        pin would silently cover files nobody read. Nothing wears that shape today; this is here so
        it cannot start to quietly."""
        assert _rows_under("client/xvb_client", package) == []
        assert _rows_under("service/worker_config_store", package) == []
