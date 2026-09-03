"""Two laws about what one failing poll step may cost: #1637 (cadence) and #1644 (siblings).

#1637 is the counter law below. #1644 is the sibling law: a raise in one step must not skip
unrelated steps beneath it for the rest of that poll. They meet in one place — the payout sync is
both the gated step whose cadence #1637 pins and the step #1644 isolates — which is why they are
tested together here rather than in two files that would each need the same 100-line harness.

`DataService.run()` counts polls in a plain local, `iteration_count`, and three steps are gated on
it with `iteration_count % 10 == 0`: the XvB stats sync, the Monero payout sync and the Tari payout
sync. The counter was incremented as the LAST statement of the `try` body, so any exception in that
body skipped it while the `except Exception` handler let the loop continue.

**The bug is a cadence inversion, not a lost count.** A frozen counter is frozen at a value that
already satisfies `% 10 == 0` — that is the only kind of poll on which a gated step can raise. So
the next poll re-runs the failing step, and the one after that: a step designed to run one poll in
ten retries a persistent failure on EVERY poll, at ten times its intended rate, never backing off.

That is why the assertions below count CALLS ACROSS POLLS rather than reading `iteration_count`.
The counter's value is an implementation detail of the throttle; the cadence is the behaviour the
issue is about, and a test that asserted `iteration_count == 1` would pass against a fix that
advanced the counter while leaving the gate wrong.

The fix is a `finally:`, not an increment at the top of the body. Incrementing first is not
equivalent: the counter starts at 0, `0 % 10 == 0` is true, so all three gated steps run on the
first poll by design — incrementing first would push their first run out to poll 10, a startup
regression this issue never asked for. `finally:` also survives the edit most likely to reintroduce
the bug, which is a `continue` being added to the loop body.

Lives in its own file rather than in `test_data_service.py`, which is at its recorded ceiling of
2538 lines with zero headroom. This file is deliberately under the 400-line target and carries no
`docs/dev/file-budget.tsv` row, because the gate fails a file that is under target AND has a row.
"""

import asyncio
import contextlib
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import mining_dashboard.service.data_service as ds_mod
from mining_dashboard.service.payout_sync import run_isolated
from tests.service.test_data_service import _FakeClientSession, _make_service

# Every collector `run()` touches before it reaches the gated steps, stubbed to something inert.
# They are here only so the poll gets that far: anything that raises on the way is swallowed by the
# loop's own `except Exception`, and the poll would end before the step under test was ever gated.
_INERT_COLLECTORS = {
    "get_stratum_stats": {},
    "get_network_stats": {"height": 100},
    "get_tari_stats": {"active": True, "status": "OK", "height": 3},
    "get_p2pool_stats": {"pool": {"last_share_time": 0, "difficulty": 0}},
    "get_disk_usage": {},
    "get_hugepages_status": ("Enabled", "ok", "1/2"),
    "get_memory_usage": {},
    "get_load_average": "0",
    "get_cpu_usage": "0%",
    "get_cpu_avx2": True,
}


@contextlib.contextmanager
def _driven_loop(sleep, enable_xvb=False):
    """Drive `run()` for a fixed number of polls, stopping it through its own `asyncio.sleep`.

    `sleep` is the mock installed over `asyncio.sleep`, which is the loop's only suspension point
    outside the `try`. A `StopAsyncIteration` as the last side effect ends the loop from OUTSIDE the
    body, so it is not swallowed by the handler and cannot be mistaken for the poll failing — the
    idiom `test_data_service.py` already uses at six sites.
    """
    worker_client = MagicMock()
    worker_client.get_stats = AsyncMock(return_value={})
    tari_client = MagicMock()
    tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False})
    tari_client.close = AsyncMock()
    with contextlib.ExitStack() as stack:
        for name, value in _INERT_COLLECTORS.items():
            stack.enter_context(patch.object(ds_mod, name, return_value=value))
        stack.enter_context(patch.object(ds_mod, "ClientSession", _FakeClientSession))
        stack.enter_context(patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client))
        stack.enter_context(patch.object(ds_mod, "TariClient", return_value=tari_client))
        stack.enter_context(
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False, "percent": 100}),
            )
        )
        # XvB off by default, so the ONLY thing standing on the `% 10 == 0` gate is the payout
        # sync under test. The coupling law below turns it on, because the block it pins is inside
        # `if ENABLE_XVB and ...` and is unreachable — silently — with the flag off.
        stack.enter_context(patch.object(ds_mod, "ENABLE_XVB", enable_xvb))
        stack.enter_context(patch("asyncio.sleep", sleep))
        yield


def _service_with_payout_gate_open(payout_side_effect=None):
    """A service whose Monero payout sync is gated open and observable, and nothing else is."""
    svc, _state, proxy = _make_service()
    proxy.get_workers.return_value = {"workers": []}
    proxy.get_summary.return_value = {
        "results": {"accepted": 0, "rejected": 0, "invalid": 0, "expired": 0, "best": [0]}
    }
    svc.wallet_client = MagicMock()  # opens `self.wallet_client is not None`
    svc.tari_wallet_client = None  # keeps the sibling gate shut
    svc._sync_payouts = AsyncMock(side_effect=payout_side_effect)
    svc._sync_prices = AsyncMock()
    return svc


async def _run_for_polls(svc, polls, enable_xvb=False):
    """Run `svc` for exactly `polls` polls, then stop it at the sleep that follows the last one."""
    sleep = AsyncMock(side_effect=[None] * (polls - 1) + [StopAsyncIteration])
    with _driven_loop(sleep, enable_xvb=enable_xvb):
        with pytest.raises(StopAsyncIteration):
            await svc.run()
    assert sleep.await_count == polls, "the loop did not run the number of polls this test assumes"


class TestTheCounterAdvancesThroughAFailedPoll:
    """THE LAW. A gated step that raised may not be re-run by the very next poll."""

    async def test_a_raising_gated_step_does_not_run_again_on_the_next_poll(self):
        """The defect, stated as cadence. `_sync_payouts` raises on poll 1, which is a gated poll
        (`iteration_count` is 0 and `0 % 10 == 0`). With the increment inside the `try` body the
        raise skipped it, the counter stayed 0, and poll 2 satisfied the gate again — so the call
        count reached 2 across two polls and would have kept climbing on every poll after that.

        Fired against the unfixed source before being trusted: it reds there with call_count 2."""
        svc = _service_with_payout_gate_open(RuntimeError("monerod returned a malformed body"))

        await _run_for_polls(svc, 2)

        assert svc._sync_payouts.await_count == 1, (
            "the payout sync ran again on the poll immediately after it raised — the counter froze "
            "on a multiple of 10, so a one-in-ten step is retrying on every poll"
        )

    async def test_the_loop_survived_the_raise_rather_than_ending_on_it(self):
        """VACUITY GUARD for the law above. `await_count == 1` on the payout sync is ALSO what a
        loop that died on the first raise would report, and that would satisfy the law for entirely
        the wrong reason. The witness is `_sync_prices`, which sits BELOW the payout sync in the
        body, so seeing it run at all means the loop kept going.

        **Twice, and it used to be once.** The shortfall this docstring recorded as "a second defect
        this issue does not fix" is #1644, and it is now fixed: the payout sync is wrapped per-step,
        so its raise no longer skips `_sync_prices` on poll 1. Poll 1 and poll 2 both reach it.

        Two polls are still the right run even though one would now do. The count has to stay a
        statement about the loop CONTINUING, not about the guard swallowing: if the guard were
        removed and the counter fix kept, this reads 1 rather than 0, so a single-poll version
        would go green against a regression this two-poll version catches."""
        svc = _service_with_payout_gate_open(RuntimeError("monerod returned a malformed body"))

        await _run_for_polls(svc, 2)

        assert svc._sync_prices.await_count == 2, (
            "the price sync did not run on both polls — a raise in the payout sync above it is "
            "skipping the rest of the poll again (#1644), or the loop did not complete poll 2"
        )


class TestTheGateStillFiresOnSchedule:
    """A law that only ever SUPPRESSES is satisfied by a gate that never fires again. These pin the
    other half: the cadence must be restored to one-in-ten, not broken in the safe direction."""

    async def test_the_gate_fires_again_on_the_tenth_poll_after_a_raise(self):
        """POSITIVE CONTROL, and the one that separates 'throttled' from 'switched off'. Across 11
        polls with poll 1 raising, the counter must reach 10 again and re-run the step exactly
        once more — twice in total. A fix that advanced the counter incorrectly, or one that
        disabled the step after a failure, reds here while passing the law above."""
        svc = _service_with_payout_gate_open(RuntimeError("monerod returned a malformed body"))

        await _run_for_polls(svc, 11)

        assert svc._sync_payouts.await_count == 2, (
            "the payout sync did not come back on poll 11 — the throttle is no longer one in ten"
        )

    async def test_a_clean_poll_keeps_the_same_cadence_as_a_failed_one(self):
        """NEGATIVE CONTROL. The same 11 polls with the step NOT raising must produce the same two
        calls. This is what makes the law above a statement about the RAISE: if a clean run also
        drifted, the figures in these tests would be measuring the harness, not the defect."""
        svc = _service_with_payout_gate_open()

        await _run_for_polls(svc, 11)

        assert svc._sync_payouts.await_count == 2


class TestTheHarnessCanSeeTheStepAtAll:
    """A green cadence law names nothing if the step was never reachable. This seeds the gate SHUT
    across the boundary the gate decides on, so a harness that had silently stopped reaching the
    payout sync would fail here instead of passing everything above."""

    async def test_the_step_does_not_run_when_its_own_gate_is_closed(self):
        """`wallet_client` is None, which is the configured-off case. Two polls, no calls — so the
        counts above are the gate answering, not the step being unconditionally invoked."""
        svc = _service_with_payout_gate_open()
        svc.wallet_client = None

        await _run_for_polls(svc, 2)

        assert svc._sync_payouts.await_count == 0

    async def test_the_step_runs_on_the_first_poll_when_its_gate_is_open(self):
        """The other side of the same boundary, and the reason the fix is a `finally:` rather than
        an increment at the top of the body: poll 1 is a GATED poll, because the counter starts at
        0. Incrementing first would move this first call out to poll 10 and red this test."""
        svc = _service_with_payout_gate_open()

        await _run_for_polls(svc, 1)

        assert svc._sync_payouts.await_count == 1


class TestAFailedStepDoesNotSkipItsIsolatedSibling:
    """#1644's law, and the narrow half of it. Only the two payout steps are wrapped per-step, so
    only they are claimed here — the coupling law below pins the other half deliberately."""

    async def test_the_tari_sync_still_runs_on_the_poll_the_monero_sync_raised_on(self):
        """THE LAW. Both payout gates are open on poll 1. `_sync_payouts` raises; `_sync_tari_payouts`
        is the very next statement in the body and has nothing to do with Monero — it takes no poll
        local and writes no `self` attribute, which is the ground the wrap was cleared on.

        Before the wrap this read 0: the raise reached the loop's single `except Exception` at the
        bottom of the body and everything between was skipped."""
        svc = _service_with_payout_gate_open(RuntimeError("monerod returned a malformed body"))
        svc.tari_wallet_client = MagicMock()  # opens the sibling gate this helper normally shuts
        svc._sync_tari_payouts = AsyncMock()

        await _run_for_polls(svc, 1)

        assert svc._sync_payouts.await_count == 1, (
            "the step under test never ran, so nothing raised"
        )
        assert svc._sync_tari_payouts.await_count == 1, (
            "the Tari payout sync was skipped by a failure in the Monero one — the per-step wrap "
            "is not isolating them (#1644)"
        )

    async def test_a_raising_step_is_logged_rather_than_swallowed(self, caplog):
        """A guard that continues quietly is worse than the skip it replaces: the loop's own handler
        logged one line per failed poll, and a step that now fails WITHOUT ending the poll would
        otherwise disappear. Pins that the step is named, not just that something was logged."""
        svc = _service_with_payout_gate_open(RuntimeError("monerod returned a malformed body"))

        with caplog.at_level("ERROR"):
            await _run_for_polls(svc, 1)

        assert "Monero payout sync" in caplog.text, "the guarded failure did not name its step"
        assert "monerod returned a malformed body" in caplog.text, "the cause was swallowed"


class TestTheXvbBlockStillSkipsAsAUnit:
    """The coupling that was KEPT, pinned so a later widening has to argue with a red test.

    `_maybe_register_xvb(shares_list, p2pool_stats)` reads two poll locals written by collectors
    near the top of the body. Wrapping the XvB steps individually would let a later one run on a
    poll where those locals are stale or unset, so the block must keep failing whole.
    """

    async def test_a_raise_in_the_xvb_stats_sync_skips_the_rest_of_its_block(self):
        """XvB on, poll 1 gated open, `_sync_xvb_stats` raises. The three steps below it in the same
        `if ENABLE_XVB` block must not run. This is the assertion that reds if someone extends the
        per-step wrap past the two cleared steps without doing the clearing work first."""
        svc = _service_with_payout_gate_open()
        svc._sync_xvb_stats = AsyncMock(side_effect=RuntimeError("xvb stats endpoint returned 502"))
        svc._sync_xvb_reward_estimates = AsyncMock()
        svc._maybe_register_xvb = AsyncMock()
        svc._sync_xvb_winners = AsyncMock()

        await _run_for_polls(svc, 1, enable_xvb=True)

        assert svc._sync_xvb_stats.await_count == 1, "the XvB block never ran, so nothing raised"
        assert svc._sync_xvb_reward_estimates.await_count == 0
        assert svc._maybe_register_xvb.await_count == 0, (
            "the XvB registration ran after its sibling raised — it reads poll locals and must stay "
            "coupled; see the ruling on #1644"
        )
        assert svc._sync_xvb_winners.await_count == 0

    async def test_the_block_runs_whole_when_nothing_raises(self):
        """FIRING CONTROL for the law above. Four zeroes are also what an unreachable block reports,
        and `ENABLE_XVB` plus a `% 10` gate is two ways to be silently unreachable. With no raise all
        four must run, so the zeroes above are the coupling answering rather than the harness."""
        svc = _service_with_payout_gate_open()
        svc._sync_xvb_stats = AsyncMock()
        svc._sync_xvb_reward_estimates = AsyncMock()
        svc._maybe_register_xvb = AsyncMock()
        svc._sync_xvb_winners = AsyncMock()

        await _run_for_polls(svc, 1, enable_xvb=True)

        assert svc._sync_xvb_stats.await_count == 1
        assert svc._sync_xvb_reward_estimates.await_count == 1
        assert svc._maybe_register_xvb.await_count == 1
        assert svc._sync_xvb_winners.await_count == 1


class TestTheGuardDoesNotOutrankShutdown:
    """`run_isolated` catches `Exception`, and the width of that catch is load-bearing."""

    async def test_task_cancellation_is_not_swallowed(self):
        """A poll step is cancelled when the service shuts down. `CancelledError` derives from
        `BaseException`, not `Exception`, so the guard lets it through and the task ends — but that
        is a property of the spelling, not of the intent, and `except BaseException` would read as
        a harmless widening while hanging shutdown behind an in-flight payout sync."""

        async def cancelled():
            raise asyncio.CancelledError()

        with pytest.raises(asyncio.CancelledError):
            await run_isolated("a step being torn down", cancelled)
