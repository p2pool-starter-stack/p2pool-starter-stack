# Rolling-window + result state for donation_model.py's actuated run-loop simulation (#423),
# split out to keep that file under its file-budget ceiling (#1285). `run_actuated` (which stays
# in donation_model.py, alongside the rationale for the actuated variant itself) is the only
# caller of these.
from dataclasses import dataclass, field

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
