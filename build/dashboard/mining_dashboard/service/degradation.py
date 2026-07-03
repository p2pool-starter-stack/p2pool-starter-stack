"""Hashrate-degradation detector (Issue #99).

Flags a **sustained significant drop** in total effective hashrate — an outage or a rig going
dark — and its recovery, as debounced edges. One detector, consumed by two sinks: an event marker
on the dashboard chart, and a Telegram alert (#121). Defining it here once keeps the thresholds and
debounce in a single place rather than duplicated per sink.

Design:

- **Self-contained baseline.** The "normal" level is a slow exponential moving average of the total
  hashrate kept in-process — no per-cycle DB read, so the detector can run every loop even when
  Telegram is off (the chart marker is a passive dashboard feature). The baseline is **frozen while
  degraded**, so a drop that persists doesn't drag the baseline down and mask itself.
- **Debounce / hysteresis.** A drop must stay below ``threshold_frac`` of the baseline for
  ``sustained_sec`` before a ``loss`` edge fires, and climb back above ``recovery_frac`` for
  ``recovery_sec`` before ``recovered`` — so a brief blip doesn't mark the chart or ping you.
- **Cold-start safe.** Until the baseline exceeds ``min_baseline`` (a tiny/just-started fleet), no
  edges fire — a stack that hasn't ramped yet can't be "degraded".

``update(current, now)`` returns ``None`` or a ``(kind, drop_frac, baseline, current)`` tuple,
``kind`` in ``{"loss", "recovered"}``.
"""

import time


class DegradationMonitor:
    def __init__(
        self,
        threshold_frac=0.5,
        sustained_sec=600,
        recovery_frac=0.8,
        recovery_sec=120,
        min_baseline=500,
        ema_alpha=0.01,
        clock=time.monotonic,
    ):
        self.threshold_frac = threshold_frac
        self.sustained_sec = sustained_sec
        self.recovery_frac = recovery_frac
        self.recovery_sec = recovery_sec
        self.min_baseline = min_baseline
        self.ema_alpha = ema_alpha
        self._clock = clock
        self._baseline = None  # EMA of total hashrate; the "normal" level
        self._degraded = False
        self._below_since = None
        self._above_since = None

    def update(self, current, now=None):
        now = self._clock() if now is None else now
        current = current or 0
        # Update the baseline only while healthy, so a sustained drop can't erode it and hide itself.
        if self._baseline is None:
            self._baseline = current
        elif not self._degraded:
            self._baseline = (1 - self.ema_alpha) * self._baseline + self.ema_alpha * current
        baseline = self._baseline

        if baseline < self.min_baseline:
            # Not enough hashrate to judge (cold start / tiny fleet) — no false alarms.
            self._below_since = self._above_since = None
            return None

        drop_frac = max(0.0, 1 - current / baseline) if baseline else 0.0

        if not self._degraded:
            if current < self.threshold_frac * baseline:
                if self._below_since is None:
                    self._below_since = now
                if now - self._below_since >= self.sustained_sec:
                    self._degraded = True
                    self._below_since = None
                    return ("loss", drop_frac, baseline, current)
            else:
                self._below_since = None
        else:
            if current >= self.recovery_frac * baseline:
                if self._above_since is None:
                    self._above_since = now
                if now - self._above_since >= self.recovery_sec:
                    self._degraded = False
                    self._above_since = None
                    return ("recovered", drop_frac, baseline, current)
            else:
                self._above_since = None
        return None
