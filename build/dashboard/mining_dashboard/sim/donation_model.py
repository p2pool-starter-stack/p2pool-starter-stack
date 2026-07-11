"""
Closed-loop simulator for the XvB donation controller (Issue #70).

The live `AlgoService` controller decides, each ~10-minute cycle, what fraction of
the cycle to donate to XMRvsBeast. It steers off the XvB API's *windowed averages*
(`avg_1h` / `avg_24h`) — but those averages are a slow, laggy function of the
controller's own past donations. That feedback loop is exactly where a single-step
unit test is blind: over-donation only manifests as a sustained overshoot that
builds up over hours and lingers for a day.

This module closes that loop so any candidate controller can be validated *before*
we ship it. It models the measurement (the rolling windows the XvB API reports),
runs a controller against it for a configurable number of cycles, and reports the
metrics that actually matter for the raffle:

  * peak / steady-state overshoot vs the target tier (waste — the raffle gives
    zero benefit above threshold, so every H/s over target is p2pool hashrate
    thrown away),
  * whether the tier is *held* (1h/24h stay at or above threshold — required to
    qualify), and
  * p2pool efficiency (the share of hashrate kept on p2pool).

A controller is just a callable ``decide(current_hr, stable_hr, avg_1h, avg_24h)
-> donated_fraction`` in ``[0, 1]``. `make_algo_controller` adapts the real
`AlgoService` so we test the shipping code path (min-dwell, remainder rules and
all), but a hand-written candidate controller can be dropped in just as easily.

Run ``python -m mining_dashboard.sim.donation_model`` for a before/after report.
"""

import math
from collections.abc import Callable
from dataclasses import dataclass, field, replace

from mining_dashboard.config.config import (
    TIER_DEFAULTS,
    XVB_SWITCH_OVERHEAD_MS,
    XVB_TIME_ALGO_MS,
)

# A 10-minute switching cycle is the simulation's time step.
CYCLES_PER_HOUR = 6
CYCLES_PER_DAY = 24 * CYCLES_PER_HOUR  # 144

# Constraint inputs that keep AlgoService.get_decision past its guard clauses so we
# exercise the donation math (a recent share, a healthy endpoint, a Main pool).
_RECENT_SHARES = [{"ts": 10**12}]  # far-future ts -> always inside the PPLNS window
_P2P_MAIN = {"type": "Main"}
_PPLNS_WINDOW = 2160

# A controller takes the rig's instantaneous + stable hashrate and the two XvB
# windowed averages, and returns the fraction of the next cycle to donate.
Controller = Callable[[float, float, float, float], float]


class _FixedTiers:
    """Minimal StateManager stand-in: the controller only needs `get_tiers()`."""

    def __init__(self, tiers=None):
        self._tiers = dict(tiers or TIER_DEFAULTS)

    def get_tiers(self):
        return dict(self._tiers)


def make_algo_controller(algo, p2pool_difficulty=0) -> Controller:
    """Adapt a real `AlgoService` into a `decide(...) -> fraction` callable.

    Routes through the actual `get_decision` path (with ``advance=True``, so the
    calibration loop steps once per simulated cycle) so the simulation reflects
    the shipping behaviour — the integral controller, the VIP/PPLNS reserve, the
    minimum dwell, and the short-remainder rule — not an idealised model of it.
    ``p2pool_difficulty`` feeds the reserve; 0 leaves it on the flat fallback cap.
    """
    pool_stats = {"pplns_window": _PPLNS_WINDOW, "difficulty": p2pool_difficulty}

    def decide(current_hr, stable_hr, avg_1h, avg_24h):
        xvb_stats = {"avg_1h": avg_1h, "avg_24h": avg_24h, "fail_count": 0}
        mode, dur_ms = algo.get_decision(
            current_hr, stable_hr, pool_stats, _P2P_MAIN, xvb_stats, _RECENT_SHARES
        )
        if mode == "P2POOL":
            return 0.0
        if mode == "XVB":
            return 1.0
        return dur_ms / XVB_TIME_ALGO_MS  # SPLIT: time slice given to XvB

    return decide


class _Window:
    """Rolling average of per-cycle credited hashrate over a fixed window.

    Two measurement semantics, because the XvB API's exact behaviour materially
    changes the optimal controller and we don't want to over-fit to a guess:

      * ``"fixed"``     — divide by the *full* window. The average ramps up from 0
                          over the first hour/day after donation starts (matches
                          the observed "XvB API ramps up over the first 1h/24h").
                          This is the pessimistic, windup-prone case.
      * ``"connected"`` — divide by the number of cycles seen so far (capped at the
                          window). The average reflects the true recent rate
                          immediately; no ramp.

    A robust controller should behave well under *both*.
    """

    def __init__(self, span_cycles: int, semantics: str = "fixed"):
        self.span = span_cycles
        self.semantics = semantics
        self._samples: list[float] = []

    def push(self, credited_hr: float) -> None:
        self._samples.append(credited_hr)
        if len(self._samples) > self.span:
            self._samples = self._samples[-self.span :]

    def average(self) -> float:
        if not self._samples:
            return 0.0
        total = sum(self._samples)
        if self.semantics == "connected":
            return total / len(self._samples)
        return total / self.span  # "fixed": missing cycles count as zero


@dataclass
class Scenario:
    """A simulation setup. Times are in 10-minute cycles."""

    name: str
    target_hr: float  # tier threshold to hold (H/s)
    current_hr: float  # steady rig hashrate (H/s)
    cycles: int = 3 * CYCLES_PER_DAY
    measurement: str = "fixed"  # "fixed" | "connected" (see _Window)
    warm_avg: float = 0.0  # initial avg_1h/avg_24h (0 = cold start; >0 = warm)
    hr_noise: float = 0.0  # deterministic +/- fractional jitter on current_hr
    # Per-switch reconnect ramp: XvB credits ~0 for this long at the start of each
    # donation slice while miners reconnect to the new pool. This is exactly what
    # the controller's XVB_SWITCH_OVERHEAD_MS compensates for, so modelling it lets
    # the simulated steady state reflect the *delivered* donation rather than
    # double-counting the overhead as overshoot.
    ramp_loss_ms: float = XVB_SWITCH_OVERHEAD_MS
    # XvB's averages are computed server-side and the controller only polls them
    # every ~5 min, so the figures it steers off of lag the true window by a few
    # cycles. That lag is a windup amplifier: the controller can't see its own
    # donation land yet, so it keeps piling on. Cycles of staleness in the read.
    report_lag_cycles: int = 0
    # How much XvB credits per unit of donation, relative to the controller's
    # `credited == fraction * current_hr` assumption. 1.0 == the assumption holds.
    # >1 models XvB crediting more than we expect (e.g. a sticky server-side
    # hashrate estimate that doesn't fully decay during p2pool slices); <1 the
    # reverse. The exact value is unknown without live instrumentation, so a robust
    # controller should hold tier without large waste across a range of it.
    credit_factor: float = 1.0
    # P2Pool sidechain share difficulty (H/s-seconds). Drives the VIP/PPLNS reserve
    # (how much hashrate p2pool must keep to hold a share in the window). 0 leaves
    # the controller on its flat fallback cap. Also used to model whether p2pool
    # actually keeps a share each cycle (VIP status) in `vip_held`.
    p2pool_difficulty: float = 0.0
    # Optional sustained hashrate drop (worker disconnect) to test tier recovery.
    drop_at: int | None = None
    drop_until: int | None = None
    drop_factor: float = 1.0  # current_hr multiplier while dropped


@dataclass
class SimResult:
    scenario: Scenario
    credited: list[float] = field(default_factory=list)  # XvB-credited rate/cycle
    credited_1h: list[float] = field(default_factory=list)  # XvB-reported 1h avg
    credited_24h: list[float] = field(default_factory=list)  # XvB-reported 24h avg
    fraction: list[float] = field(default_factory=list)  # donated fraction/cycle
    current_hr: list[float] = field(default_factory=list)  # rig hashrate seen

    # --- metrics ------------------------------------------------------------
    @property
    def _tail(self) -> slice:
        # Steady-state window: the final day (or the back half of short runs).
        n = len(self.fraction)
        return slice(max(n // 2, n - CYCLES_PER_DAY), n)

    @property
    def peak_overshoot(self) -> float:
        """Worst XvB-credited rate as a multiple of target (1.0 == on target)."""
        t = self.scenario.target_hr
        return (max(self.credited, default=0.0) / t) if t else 0.0

    @property
    def first_day_overshoot(self) -> float:
        """Mean XvB-credited rate over the first 24h, as a multiple of target.

        This is what a fresh start actually experiences — the window the field
        report in Issue #70 was taken from — so it is the headline before/after
        number, not the eventual steady state (which both controllers reach).
        """
        t = self.scenario.target_hr
        day = self.credited[:CYCLES_PER_DAY]
        return (sum(day) / len(day) / t) if day and t else 0.0

    @property
    def steady_overshoot_24h(self) -> float:
        t = self.scenario.target_hr
        tail = self.credited_24h[self._tail]
        return (sum(tail) / len(tail) / t) if tail and t else 0.0

    @property
    def steady_overshoot_1h(self) -> float:
        t = self.scenario.target_hr
        tail = self.credited_1h[self._tail]
        return (sum(tail) / len(tail) / t) if tail and t else 0.0

    @property
    def p2pool_efficiency(self) -> float:
        """Steady-state share of hashrate kept on p2pool (1 - donated fraction)."""
        tail = self.fraction[self._tail]
        return 1.0 - (sum(tail) / len(tail)) if tail else 1.0

    def tier_held(self, tol: float = 0.02) -> bool:
        """Did both averages stay at/above threshold across steady state?

        That is the raffle qualification condition; `tol` allows for measurement
        noise around the threshold.
        """
        t = self.scenario.target_hr * (1 - tol)
        return (
            min(self.credited_1h[self._tail], default=0.0) >= t
            and min(self.credited_24h[self._tail], default=0.0) >= t
        )

    def cycles_to_tier_24h(self) -> int | None:
        """First cycle at which the 24h average reaches the threshold (or None)."""
        for i, v in enumerate(self.credited_24h):
            if v >= self.scenario.target_hr:
                return i
        return None

    def min_expected_shares(self, window_seconds: float = _PPLNS_WINDOW * 10) -> float:
        """Worst-case expected p2pool shares in the PPLNS window across steady state.

        p2pool keeps us "VIP" only while it holds a share in the window; it finds
        ~``p2pool_hr * window / difficulty`` shares per window. This is the minimum
        of that over the steady tail — the tightest the VIP guarantee gets. Returns
        +inf when difficulty is unmodelled (0)."""
        diff = self.scenario.p2pool_difficulty
        if diff <= 0:
            return float("inf")
        tail_frac = self.fraction[self._tail]
        tail_hr = self.current_hr[self._tail]
        if not tail_frac:
            return float("inf")
        return min(
            (1 - f) * hr * window_seconds / diff for f, hr in zip(tail_frac, tail_hr, strict=False)
        )

    def vip_held(self, min_shares: float = 1.0) -> bool:
        """True if p2pool keeps at least ``min_shares`` expected shares in the window
        throughout steady state — i.e. the donation never starved VIP status."""
        return self.min_expected_shares() >= min_shares


def run_simulation(controller: Controller, scenario: Scenario) -> SimResult:
    """Drive `controller` through `scenario`, closing the measurement loop."""
    win_1h = _Window(CYCLES_PER_HOUR, scenario.measurement)
    win_24h = _Window(CYCLES_PER_DAY, scenario.measurement)
    result = SimResult(scenario=scenario)

    # Seed warm-start history so a non-cold scenario starts in steady state.
    if scenario.warm_avg > 0:
        for _ in range(CYCLES_PER_DAY):
            win_1h.push(scenario.warm_avg)
            win_24h.push(scenario.warm_avg)

    lag = max(0, scenario.report_lag_cycles)
    for cycle in range(scenario.cycles):
        # The controller steers off the averages produced by *prior* donations,
        # delayed by the API reporting lag. With lag>0 it can't yet see its own
        # recent donations land — the windup amplifier. The freshest recorded
        # average is at index -1; reading -1-lag delays it. Before enough history
        # exists, fall back to the live window (the cold-start 0, or the warm seed).
        idx = len(result.credited_1h) - 1 - lag
        if idx >= 0:
            avg_1h = result.credited_1h[idx]
            avg_24h = result.credited_24h[idx]
        else:
            avg_1h = win_1h.average()
            avg_24h = win_24h.average()

        # Effective rig hashrate this cycle: deterministic jitter + optional drop.
        base = scenario.current_hr
        if (
            scenario.drop_at is not None
            and scenario.drop_at <= cycle
            and (scenario.drop_until is None or cycle < scenario.drop_until)
        ):
            base *= scenario.drop_factor
        # Deterministic pseudo-jitter (no RNG: reproducible across runs/resumes).
        current_hr = base * (1 + scenario.hr_noise * math.sin(cycle * 1.3))
        # Tier selection uses the stable (15m) average -> the un-jittered base.
        stable_hr = base

        fraction = controller(current_hr, stable_hr, avg_1h, avg_24h)
        fraction = max(0.0, min(1.0, fraction))

        # XvB credits the full rig rate during the donated slice, minus the
        # reconnect ramp at the slice start, and nothing while on p2pool. So the
        # windowed average of credited hashrate is (effective donation time /
        # cycle) * current_hr.
        donate_ms = fraction * XVB_TIME_ALGO_MS
        effective_ms = max(0.0, donate_ms - scenario.ramp_loss_ms) if donate_ms > 0 else 0.0
        credited = (effective_ms / XVB_TIME_ALGO_MS) * current_hr * scenario.credit_factor
        win_1h.push(credited)
        win_24h.push(credited)

        result.credited.append(credited)
        result.fraction.append(fraction)
        result.current_hr.append(current_hr)
        result.credited_1h.append(win_1h.average())
        result.credited_24h.append(win_24h.average())

    return result


# --- actuated run-loop simulation (#423) ------------------------------------
# `run_simulation` models the *decision* (one fixed 10-minute step per cycle) and
# assumes a SPLIT's p2pool remainder actually runs its course. #423 proved that
# assumption can break: the remainder is `_smart_sleep`'s to honor, and its
# early-exit rules set the *actuated* donation duty. This variant replays the
# `run()` branch structure in wall-clock seconds, calling the real `get_decision`
# once per cycle and the real `_dwell_should_end` on every dwell tick — so a
# dwell-rule bug shows up here as credited overshoot, where the fixed-step sim
# is blind to it (it gave #70 a false all-clear while prod overshot 26-44%).

_SMART_SLEEP_TICK_S = 30  # UPDATE_INTERVAL default: the live _smart_sleep check cadence


class _SecondsWindow:
    """Rolling per-second average over a fixed span, pre-filled with zeros
    ("fixed" semantics: the average ramps up from 0 like a fresh XvB window)."""

    def __init__(self, span_s: int):
        from collections import deque

        self.span = span_s
        self._buf = deque([0.0] * span_s, maxlen=span_s)
        self._sum = 0.0

    def push(self, rate: float) -> None:
        self._sum += rate - self._buf[0]  # deque is always full: append evicts left
        self._buf.append(rate)

    def average(self) -> float:
        return self._sum / self.span


@dataclass
class ActuatedResult:
    """Metrics from `run_actuated`. Window averages are sampled once per minute."""

    target_hr: float
    avg_1h: list[float] = field(default_factory=list)
    avg_24h: list[float] = field(default_factory=list)
    donated_s: float = 0.0
    total_s: float = 0.0

    @property
    def _tail(self) -> slice:
        # Steady state: the final day of minute samples (or the back half of short runs).
        n = len(self.avg_1h)
        return slice(max(n // 2, n - 24 * 60), n)

    @property
    def steady_overshoot_1h(self) -> float:
        tail = self.avg_1h[self._tail]
        return (sum(tail) / len(tail) / self.target_hr) if tail and self.target_hr else 0.0

    @property
    def steady_overshoot_24h(self) -> float:
        tail = self.avg_24h[self._tail]
        return (sum(tail) / len(tail) / self.target_hr) if tail and self.target_hr else 0.0

    @property
    def donated_duty(self) -> float:
        """Share of wall-clock time actually routed to XvB (the actuated duty)."""
        return self.donated_s / self.total_s if self.total_s else 0.0

    def tier_held(self, tol: float = 0.02) -> bool:
        """Both credited averages at/above threshold across steady state — the
        raffle qualification condition (undershoot loses the tier)."""
        t = self.target_hr * (1 - tol)
        return (
            min(self.avg_1h[self._tail], default=0.0) >= t
            and min(self.avg_24h[self._tail], default=0.0) >= t
        )


def run_actuated(
    scenario: Scenario, donation_level="vip", tick_s=_SMART_SLEEP_TICK_S, **tuning
) -> ActuatedResult:
    """Drive the production `AlgoService` through `scenario` in wall-clock time,
    honoring the run() loop's actual dwell behavior (see block comment above).

    Models a steady rig only (no noise/drop/lag — the #423 overshoot reproduces
    without them); `credit_factor`, `ramp_loss_ms` and `p2pool_difficulty` from
    the scenario apply as in `run_simulation`.
    """
    algo = build_controller(donation_level, **tuning)
    cycle_s = XVB_TIME_ALGO_MS / 1000.0
    pool_stats = {"pplns_window": _PPLNS_WINDOW, "difficulty": scenario.p2pool_difficulty}
    win_1h, win_24h = _SecondsWindow(3600), _SecondsWindow(24 * 3600)
    result = ActuatedResult(target_hr=scenario.target_hr)
    total_s = scenario.cycles * cycle_s
    hr = scenario.current_hr
    ramp_s = scenario.ramp_loss_ms / 1000.0
    t = 0

    def stats():
        return {"avg_1h": win_1h.average(), "avg_24h": win_24h.average(), "fail_count": 0}

    def elapse(seconds, rate):
        nonlocal t
        for _ in range(int(round(seconds))):
            win_1h.push(rate)
            win_24h.push(rate)
            t += 1
            if t % 60 == 0:
                result.avg_1h.append(win_1h.average())
                result.avg_24h.append(win_24h.average())

    def donate(seconds):
        # XvB credits the full rig rate during a donated slice, after the
        # reconnect ramp at the slice start (nothing lands during the ramp).
        r = min(ramp_s, seconds)
        elapse(r, 0.0)
        elapse(seconds - r, hr * scenario.credit_factor)
        result.donated_s += seconds

    def dwell(seconds, held_decision):
        # The run() p2pool dwell: sleep in ticks, ending early only when the real
        # _dwell_should_end predicate says so (the shipping early-exit rules).
        elapsed = 0.0
        while elapsed < seconds:
            step = min(tick_s, seconds - elapsed)
            elapse(step, 0.0)
            elapsed += step
            if algo._dwell_should_end(
                held_decision, hr, hr, pool_stats, _P2P_MAIN, stats(), _RECENT_SHARES
            ):
                return

    while t < total_s:
        decision, dur_ms = algo.get_decision(hr, hr, pool_stats, _P2P_MAIN, stats(), _RECENT_SHARES)
        if decision == "P2POOL":
            dwell(cycle_s, "P2POOL")
        elif decision == "XVB":
            donate(cycle_s)
        else:  # SPLIT: donated slice, then the p2pool remainder dwell
            donate(dur_ms / 1000.0)
            dwell((XVB_TIME_ALGO_MS - dur_ms) / 1000.0, "SPLIT")

    result.total_s = t
    return result


def build_controller(donation_level="vip", *, gain=None, reserve_factor=None, tiers=None):
    """Construct the production `AlgoService` wired to a fixed tier table, with
    optional tuning overrides, for simulation. Returns the service so callers can
    inspect/seed its state; wrap it with `make_algo_controller` to drive a run."""
    # Imported lazily so this module stays importable without the full service graph.
    from mining_dashboard.service.algo_service import AlgoService

    algo = AlgoService(_FixedTiers(tiers), proxy_client=None, data_service=None)
    algo.donation_level = donation_level
    if gain is not None:
        algo.control_gain = gain
    if reserve_factor is not None:
        algo.p2pool_reserve_factor = reserve_factor
    return algo


def run_algo(scenario: Scenario, donation_level="vip", **tuning) -> SimResult:
    """Run the production controller through a scenario, threading the scenario's
    p2pool difficulty into both the reserve and the VIP model."""
    algo = build_controller(donation_level, **tuning)
    controller = make_algo_controller(algo, p2pool_difficulty=scenario.p2pool_difficulty)
    return run_simulation(controller, scenario)


# --- CLI report ------------------------------------------------------------
# A VIP-10k tier on a ~46k rig (the Issue #70 field case) plus stress variants.
# Difficulty 1.2e8 H/s-s ~ a real p2pool-main sidechain share difficulty, so the
# VIP reserve is exercised rather than the flat fallback.
_DIFFICULTY = 120_000_000
DEFAULT_SCENARIOS = [
    Scenario(
        name="field (VIP 10k on 46k rig, cold start)",
        target_hr=10_000,
        current_hr=46_300,
        p2pool_difficulty=_DIFFICULTY,
    ),
    Scenario(
        name="high headroom (VIP 10k on 200k rig)",
        target_hr=10_000,
        current_hr=200_000,
        p2pool_difficulty=_DIFFICULTY,
    ),
    Scenario(
        name="stale/laggy API reads (~2h reporting lag)",
        target_hr=10_000,
        current_hr=46_300,
        report_lag_cycles=12,
        p2pool_difficulty=_DIFFICULTY,
    ),
    Scenario(
        name="XvB over-credits 3x (calibration must back off)",
        target_hr=10_000,
        current_hr=46_300,
        credit_factor=3.0,
        p2pool_difficulty=_DIFFICULTY,
    ),
    Scenario(
        name="worker drop below tier mid-run, then recovery",
        target_hr=10_000,
        current_hr=46_300,
        warm_avg=10_300,
        drop_at=CYCLES_PER_DAY,
        drop_until=CYCLES_PER_DAY + 18,
        drop_factor=0.2,
        p2pool_difficulty=_DIFFICULTY,
    ),
]


def _fmt(r: SimResult) -> str:
    shares = r.min_expected_shares()
    vip = "inf" if shares == float("inf") else f"{shares:.1f}"
    return (
        f"day1 {r.first_day_overshoot:4.2f}x  "
        f"peak {r.peak_overshoot:4.2f}x  "
        f"steady {r.steady_overshoot_1h:4.2f}x  "
        f"p2pool {r.p2pool_efficiency * 100:5.1f}%  "
        f"tier {str(r.tier_held()):5}  vip_shares {vip}"
    )


def main():  # pragma: no cover - human-facing report, not a test path
    print("XvB donation controller — production closed-loop controller (Issues #9, #70)\n")
    print("Overshoot = XvB-credited rate / tier. 1.00x is on target; lower waste is better.")
    print("vip_shares = worst-case expected p2pool shares in the PPLNS window (>=1 keeps VIP).\n")
    for semantics in ("fixed", "connected"):
        print(f"--- XvB measurement semantics: {semantics} ---")
        for base in DEFAULT_SCENARIOS:
            sc = replace(base, measurement=semantics)
            print(f"{sc.name}\n  {_fmt(run_algo(sc))}")
        print()

    print("--- actuated run-loop (wall clock, real dwell rules — #423) ---")
    for base in DEFAULT_SCENARIOS[:2]:
        a = run_actuated(base)
        print(
            f"{base.name}\n"
            f"  steady 1h {a.steady_overshoot_1h:4.2f}x  24h {a.steady_overshoot_24h:4.2f}x  "
            f"duty {a.donated_duty * 100:4.1f}%  tier {a.tier_held()}"
        )


if __name__ == "__main__":  # pragma: no cover
    main()
