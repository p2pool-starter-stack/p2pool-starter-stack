import asyncio
import logging
import time

from mining_dashboard.config.config import (
    DISK_CRITICAL_PERCENT,
    DISK_WARN_PERCENT,
    HOST_IP,
    TELEGRAM_BOT_TOKEN,
    TELEGRAM_CHAT_ID,
    TELEGRAM_DAILY_SUMMARY_TIME,
    TELEGRAM_ENABLED,
    TELEGRAM_EVENTS,
)
from mining_dashboard.service.telegram_notifier import TelegramNotifier
from mining_dashboard.service.worker_presence import WorkerPresenceMonitor

logger = logging.getLogger("AlertService")

# Trailing-1h reject rate (percent) above which the high_reject_rate alert fires (#116). Matches
# the dashboard's presentational _REJECT_FLAG_RATE (5%) so the alert and the on-screen warning
# flag agree on what "high" means.
REJECT_ALERT_PCT = 5.0


def build_default_notifier():
    """Construct the Telegram notifier from the process config (Issue #121)."""
    return TelegramNotifier(
        enabled=TELEGRAM_ENABLED,
        bot_token=TELEGRAM_BOT_TOKEN,
        chat_id=TELEGRAM_CHAT_ID,
        events=TELEGRAM_EVENTS,
    )


def _parse_hhmm(value):
    """Parse a 'HH:MM' 24-hour string to minutes-since-midnight, or None if malformed (which
    disables the daily digest rather than guessing a time)."""
    try:
        hh, mm = (value or "").strip().split(":")
        h, m = int(hh), int(mm)
        if 0 <= h < 24 and 0 <= m < 60:
            return h * 60 + m
    except (ValueError, AttributeError):
        pass
    return None


class AlertService:
    """
    Turns the data loop's per-cycle signals into a small set of debounced operator alerts and
    pushes them over Telegram (Issue #121). Notifications-only — no interactive bot (#45).

    It *consumes* signals the loop already computes rather than re-collecting anything:

    - **node down / recovered** — transitions of ``NodeHealthMonitor``'s debounced ``down``
      flag per node (#31). Tari is only alerted when it's treated as required; a non-blocking
      Tari going down isn't operator-critical (we keep mining Monero), matching the
      worker-rejection rule.
    - **sync finished** — the sync gate's ``miner_released`` latch flipping open once (#35).
    - **worker offline / back online / joined / left** — a debounced :class:`WorkerPresenceMonitor`
      over the live worker rows (offline keys off the same DOWN status the dashboard shows; joined /
      left track fleet membership).
    - **disk filling / critical** — the data disk crossing the same ``DISK_WARN_PERCENT`` /
      ``DISK_CRITICAL_PERCENT`` thresholds the dashboard's low-disk badge uses (#138): a full disk
      corrupts monerod's DB mid-write.
    - **DB write failing** — ``StateManager.is_db_healthy`` flipping false (#131): the dashboard
      keeps serving but history/shares/stats stop persisting.
    - **high reject rate** — the trailing-1h reject rate (from the persisted per-poll share
      deltas, #116) crossing ``REJECT_ALERT_PCT``: sustained rejects waste hashrate (bad
      overclock, clock drift, flaky network). Recovers when the rate drops back below.
    - **payout wallet changed** — the wallet p2pool actually mines to differing from the
      kv_store baseline (#375): the highest-value tamper against the stack. Fires on every
      change, including a legitimate ``pithead apply`` — a confirmation, not only an intrusion
      signal. Addresses are truncated to 8 chars; the full address never leaves the host.

    Edge state is seeded silently on the first observation (``None`` baselines), so a dashboard
    restart can't replay a stale transition as a fresh alert. The exception is the persistent
    host-perf advisories (HugePages not reserved, low RAM — #104): a stable bad state never
    "transitions", so those fire on first observation instead of seeding silently.

    :meth:`evaluate` is pure (folds signals into the alert list, no I/O) so it's fully
    unit-testable; :meth:`process` calls it and dispatches each message off-thread so a slow or
    blocked Telegram send never stalls the data loop.
    """

    # Event keys — must match config.json's telegram.events toggles and TELEGRAM_EVENTS.
    EVT_NODE_DOWN = "node_down"
    EVT_NODE_RECOVERED = "node_recovered"
    EVT_WORKER_OFFLINE = "worker_offline"
    EVT_WORKER_RECOVERED = "worker_recovered"
    EVT_WORKER_JOINED = "worker_joined"
    EVT_WORKER_LEFT = "worker_left"
    EVT_SYNC_FINISHED = "sync_finished"
    EVT_DISK_SPACE = "disk_space"
    EVT_DB_UNHEALTHY = "db_unhealthy"
    EVT_XVB_NO_SHARE = "xvb_no_share"
    EVT_CLEARNET_EXPOSED = "clearnet_exposed"
    EVT_XVB_REGISTRATION = "xvb_registration"
    EVT_NEW_RELEASE = "new_release"
    EVT_STACK_ONLINE = "stack_online"
    EVT_DAILY_SUMMARY = "daily_summary"
    EVT_HASHRATE_LOW = "hashrate_low"
    EVT_HASHRATE_LOSS = "hashrate_loss"
    EVT_HUGEPAGES = "hugepages"
    EVT_LOW_RAM = "low_ram"
    EVT_WALLET_CHANGED = "wallet_changed"
    EVT_HIGH_REJECT_RATE = "high_reject_rate"

    # WorkerPresenceMonitor edge -> (event key, message template).
    _WORKER_EDGES = {
        "offline": (EVT_WORKER_OFFLINE, "\U0001f534 ⛏️ Worker offline: {name}"),
        "recovered": (EVT_WORKER_RECOVERED, "\U0001f7e2 ⛏️ Worker back online: {name}"),
        "joined": (EVT_WORKER_JOINED, "\U0001f389 New worker joined: {name}"),
        "left": (EVT_WORKER_LEFT, "\U0001f44b Worker left: {name}"),
    }

    def __init__(
        self,
        notifier=None,
        worker_monitor=None,
        host_label=HOST_IP,
        daily_time=TELEGRAM_DAILY_SUMMARY_TIME,
        kv_get=None,
        kv_set=None,
    ):
        self.notifier = notifier if notifier is not None else build_default_notifier()
        self.workers = worker_monitor if worker_monitor is not None else WorkerPresenceMonitor()
        # Once-daily digest: target local minute-of-day (HH:MM → h*60+m), and the day we last sent
        # (so it fires once per day). A malformed time disables it.
        self._daily_target_min = _parse_hhmm(daily_time)
        self._daily_last = None
        self._daily_seeded = False
        # "Unknown Host" is config.py's placeholder when HOST_IP isn't set — don't prefix with it.
        self.host_label = "" if host_label in (None, "", "Unknown Host") else host_label
        # None = "not yet observed": the first cycle seeds the baseline without emitting.
        self._prev_monero_down = None
        self._prev_tari_down = None
        self._prev_released = None
        self._prev_disk_level = None
        self._prev_db_healthy = None
        self._prev_xvb_has_share = None
        self._prev_clearnet_active = None
        self._prev_xvb_reg = None
        self._prev_update_available = None
        self._prev_hashrate_low = None
        self._prev_reject_high = None
        # Persistent host-perf advisories (#104): unlike the transient edges above, these fire on the
        # FIRST observation of the problem (a stable low-RAM box would never "transition"), so their
        # baseline is "no problem" (False) rather than None — a problem present on the first cycle is
        # a real edge and alerts once.
        self._prev_hugepages_problem = False
        self._prev_low_ram = False
        # Tally of problem-state transitions since the last daily digest drained it (#342). Keyed by
        # event, counted at the exact edge so recoveries / steady state don't inflate it.
        self._incidents = {}
        # One-shot "stack is online" ping, sent on the first cycle after the dashboard starts.
        self._announced_online = False
        # Payout-wallet tamper tripwire (#375): the baseline lives in the SQLite kv_store, NOT in
        # an in-memory `_prev_*` attr, because `pithead apply` recreates the dashboard container —
        # exactly the moment an attacker swaps the wallet — and an in-memory baseline would
        # silently re-seed to the attacker's address. Injected as callables so the edge stays
        # unit-testable with a plain dict. Both None => the tripwire is off.
        self._kv_get = kv_get
        self._kv_set = kv_set

    @property
    def enabled(self):
        return self.notifier.enabled

    def evaluate(
        self,
        *,
        monero_down,
        tari_down,
        tari_required,
        miner_released,
        workers,
        workers_expected,
        disk_percent=0,
        db_healthy=True,
        xvb_enabled=False,
        shares_in_window=0,
        clearnet_active=False,
        xvb_registration_state="",
        update_available=False,
        low_hr_warning=False,
        hugepages_reserved=True,
        low_ram=False,
        observed_wallet="",
        reject_rate_1h=None,
        now=None,
    ):
        """Fold this cycle's signals into the list of ``(event_key, text)`` to send, filtered to
        the events the operator left enabled. No I/O except the injected wallet-baseline kv
        callables (#375), which tests back with a plain dict."""
        alerts = []

        # --- Stack online (one-shot on the first cycle after the dashboard starts) ---
        if not self._announced_online:
            self._announced_online = True
            alerts.append(
                (
                    self.EVT_STACK_ONLINE,
                    self._fmt("\U0001f680 Pithead is online — dashboard up and monitoring."),
                )
            )

        # --- Node down / recovered (consume NodeHealthMonitor edges) ---
        alerts += self._node_edges("Monero", monero_down, "_prev_monero_down")
        if tari_required:
            alerts += self._node_edges("Tari", tari_down, "_prev_tari_down")
        else:
            # Keep the baseline current while Tari is non-blocking, so flipping it back to
            # required later doesn't fire a stale edge from a state we never alerted on.
            self._prev_tari_down = tari_down

        # --- Sync finished (one-shot when the gate first opens) ---
        if self._prev_released is None:
            self._prev_released = miner_released
        elif miner_released and not self._prev_released:
            alerts.append(
                (
                    self.EVT_SYNC_FINISHED,
                    self._fmt("✅ Node ready — required chain(s) synced; mining has started."),
                )
            )
        self._prev_released = miner_released

        # --- Worker offline / recovered / joined / left (debounced off the DOWN status) ---
        # Driven by each rig's status in the same worker rows the dashboard shows (DOWN = offline).
        # Only meaningful while workers are actually expected: when the proxy is intentionally
        # stopped (initial sync hold, or node-down failover) their absence is by design, so we
        # reset the tracker instead of aging every rig into a false "offline".
        if workers_expected:
            for name, event in self.workers.update(workers, now=now):
                evt, template = self._WORKER_EDGES[event]
                if event == "offline":
                    self._record_incident(self.EVT_WORKER_OFFLINE)
                alerts.append((evt, self._fmt(template.format(name=name))))
        else:
            self.workers.reset()

        # --- Host health: data disk filling up, dashboard DB write failing ---
        alerts += self._disk_edges(disk_percent)
        alerts += self._db_edges(db_healthy)

        # --- Payout-wallet tamper tripwire (#375) — kv-backed, so it survives container recreate ---
        alerts += self._wallet_edges(observed_wallet)

        # --- Revenue / privacy: XvB PPLNS-share gate, clearnet-sync exposure ---
        alerts += self._xvb_share_edges(xvb_enabled, shares_in_window)
        alerts += self._clearnet_edges(clearnet_active)

        # --- XvB auto-registration health, and a new Pithead release being available ---
        alerts += self._registration_edges(xvb_enabled, xvb_registration_state)
        alerts += self._release_edges(update_available)
        alerts += self._hashrate_low_edges(low_hr_warning)
        alerts += self._reject_rate_edges(reject_rate_1h)

        # --- Persistent host-perf advisories (#104): HugePages not reserved, low RAM ---
        alerts += self._advisory_edge(
            not hugepages_reserved,
            "_prev_hugepages_problem",
            self.EVT_HUGEPAGES,
            "\U0001f7e0 \U0001f9e0 HugePages not reserved — RandomX hashrate is capped. Apply "
            "setup's tuning (or edit GRUB) and reboot.",
            recovery_text="\U0001f7e2 \U0001f9e0 HugePages now reserved — RandomX is unthrottled.",
        )
        alerts += self._advisory_edge(
            low_ram,
            "_prev_low_ram",
            self.EVT_LOW_RAM,
            "\U0001f7e0 \U0001f4be Low RAM for this stack — syncing is memory-heavy (Tari can OOM). "
            "Add RAM for a stable node.",
        )

        return [(evt, text) for evt, text in alerts if self.notifier.event_enabled(evt)]

    def _node_edges(self, label, down, attr):
        prev = getattr(self, attr)
        setattr(self, attr, down)
        if prev is None or down == prev:
            return []
        if down:
            self._record_incident(self.EVT_NODE_DOWN)
            return [
                (
                    self.EVT_NODE_DOWN,
                    self._fmt(
                        f"\U0001f534 ⛓️ {label} node is DOWN — workers failing over to backup pools."
                    ),
                )
            ]
        return [
            (
                self.EVT_NODE_RECOVERED,
                self._fmt(f"\U0001f7e2 ⛓️ {label} node recovered — workers readmitted."),
            )
        ]

    def _disk_edges(self, disk_percent):
        """Alert on the data disk crossing the dashboard's own warn/critical thresholds (#138)."""
        level = (
            "critical"
            if disk_percent >= DISK_CRITICAL_PERCENT
            else "warn"
            if disk_percent >= DISK_WARN_PERCENT
            else "ok"
        )
        prev = self._prev_disk_level
        self._prev_disk_level = level
        if prev is None or level == prev:
            return []
        pct = f"{disk_percent:.0f}%"
        if level in ("critical", "warn"):
            self._record_incident(self.EVT_DISK_SPACE)
        if level == "critical":
            return [
                (
                    self.EVT_DISK_SPACE,
                    self._fmt(
                        f"\U0001f534 \U0001f4be Data disk almost full ({pct}) — free space now; a "
                        "full disk can corrupt the Monero database."
                    ),
                )
            ]
        if level == "warn":
            return [
                (
                    self.EVT_DISK_SPACE,
                    self._fmt(f"\U0001f7e0 \U0001f4be Data disk filling up ({pct})."),
                )
            ]
        return [
            (
                self.EVT_DISK_SPACE,
                self._fmt(f"\U0001f7e2 \U0001f4be Data disk back to healthy ({pct})."),
            )
        ]

    def _db_edges(self, db_healthy):
        """Alert when the dashboard can no longer persist to its SQLite DB (#131)."""
        prev = self._prev_db_healthy
        self._prev_db_healthy = db_healthy
        if prev is None or db_healthy == prev:
            return []
        if not db_healthy:
            self._record_incident(self.EVT_DB_UNHEALTHY)
            return [
                (
                    self.EVT_DB_UNHEALTHY,
                    self._fmt(
                        "\U0001f534 \U0001f5c4️ Dashboard DB write failing — hashrate history, shares "
                        "and stats won't persist. Check disk space + permissions on the data dir."
                    ),
                )
            ]
        return [
            (
                self.EVT_DB_UNHEALTHY,
                self._fmt("\U0001f7e2 \U0001f5c4️ Dashboard DB writes recovered."),
            )
        ]

    def _wallet_edges(self, observed):
        """Payout-wallet tamper tripwire (#375). ``observed`` is the wallet p2pool itself reports
        mining to (stratum stats), with the env address as fallback — ground truth of where
        rewards go. Baseline in the kv_store so an `apply`-driven container recreate can't wipe
        it (that recreate IS the attack window). Empty/Unknown observations no-op: p2pool briefly
        reports no wallet while restarting, and that must not read as "changed to ''" or re-seed.
        The first-ever observation seeds silently. Only the first 8 chars of each address are
        ever put in a message."""
        if not observed or observed == "Unknown" or self._kv_get is None or self._kv_set is None:
            return []
        baseline = self._kv_get("payout_wallet")
        if not baseline:
            self._kv_set("payout_wallet", observed)
            return []
        if observed == baseline:
            return []
        old8, new8 = baseline[:8], observed[:8]
        self._kv_set("payout_wallet", observed)
        self._kv_set("payout_wallet_prev8", old8)  # for the dashboard banner's tooltip
        self._kv_set("payout_wallet_changed_ts", time.time())
        self._record_incident(self.EVT_WALLET_CHANGED)
        return [
            (
                self.EVT_WALLET_CHANGED,
                self._fmt(
                    f"\U0001f6a8 Payout wallet CHANGED: {old8}… → {new8}… — if you did not do "
                    "this, your rewards are being redirected. Check config.json and run "
                    "'pithead status'."
                ),
            )
        ]

    def _xvb_share_edges(self, xvb_enabled, shares_in_window):
        """Alert on losing / regaining the PPLNS share XvB needs to bank a raffle win (#158).

        Only meaningful while XvB is on. A donating rig with **no** share in the PPLNS window has
        its wins skipped (and accrues a fail) regardless of tier — a make-or-break, revenue-costing
        state worth a ping."""
        if not xvb_enabled:
            # No XvB → the share gate doesn't apply; drop the baseline so turning XvB back on later
            # doesn't replay a stale edge.
            self._prev_xvb_has_share = None
            return []
        has_share = shares_in_window > 0
        prev = self._prev_xvb_has_share
        self._prev_xvb_has_share = has_share
        if prev is None or has_share == prev:
            return []
        if not has_share:
            self._record_incident(self.EVT_XVB_NO_SHARE)
            return [
                (
                    self.EVT_XVB_NO_SHARE,
                    self._fmt(
                        "⚠️ \U0001f3b0 No PPLNS share — XvB raffle wins are skipped until you land "
                        "one (donations are wasted meanwhile)."
                    ),
                )
            ]
        return [
            (
                self.EVT_XVB_NO_SHARE,
                self._fmt(
                    "\U0001f7e2 \U0001f3b0 PPLNS share restored — XvB raffle wins count again."
                ),
            )
        ]

    def _clearnet_edges(self, clearnet_active):
        """Alert while a node is doing its initial sync over CLEARNET (#183): the host IP is exposed
        to that chain's P2P network until it finishes (it reverts to Tor automatically, #234)."""
        prev = self._prev_clearnet_active
        self._prev_clearnet_active = clearnet_active
        if prev is None or clearnet_active == prev:
            return []
        if clearnet_active:
            self._record_incident(self.EVT_CLEARNET_EXPOSED)
            return [
                (
                    self.EVT_CLEARNET_EXPOSED,
                    self._fmt(
                        "⚠️ \U0001f310 Clearnet initial sync ACTIVE — this host's IP is exposed to the "
                        "chain's P2P network until it finishes syncing (reverts to Tor automatically)."
                    ),
                )
            ]
        return [
            (
                self.EVT_CLEARNET_EXPOSED,
                self._fmt(
                    "\U0001f7e2 \U0001f9c5 Back on Tor-only — clearnet sync finished, host IP no "
                    "longer exposed."
                ),
            )
        ]

    def _registration_edges(self, xvb_enabled, state):
        """Alert on XvB auto-registration going bad / recovering (#263). ``state`` is one of
        ``""`` / ``registered`` / ``invalid`` (wallet rejected — permanent) / ``failing``."""
        if not xvb_enabled:
            self._prev_xvb_reg = None
            return []
        prev = self._prev_xvb_reg
        self._prev_xvb_reg = state
        if prev is None or state == prev:
            return []
        if state in ("invalid", "failing"):
            self._record_incident(self.EVT_XVB_REGISTRATION)
        if state == "invalid":
            return [
                (
                    self.EVT_XVB_REGISTRATION,
                    self._fmt(
                        "\U0001f534 \U0001f3b0 XvB wallet rejected — auto-registration failed "
                        "(check the payout address); raffle wins won't count."
                    ),
                )
            ]
        if state == "failing":
            return [
                (
                    self.EVT_XVB_REGISTRATION,
                    self._fmt("⚠️ \U0001f3b0 XvB auto-registration failing — retrying."),
                )
            ]
        if state == "registered" and prev in ("invalid", "failing"):
            return [
                (
                    self.EVT_XVB_REGISTRATION,
                    self._fmt(
                        "\U0001f7e2 \U0001f3b0 XvB registration recovered — you're in the raffle."
                    ),
                )
            ]
        return []

    def _release_edges(self, update_available):
        """One-shot ping when a newer Pithead release becomes available (#224)."""
        prev = self._prev_update_available
        self._prev_update_available = bool(update_available)
        if prev is None or not update_available or update_available == prev:
            return []
        return [
            (
                self.EVT_NEW_RELEASE,
                self._fmt(
                    "\U0001f195 A new Pithead release is available — see the dashboard header."
                ),
            )
        ]

    def _hashrate_low_edges(self, low_hr_warning):
        """Alert when a manually-chosen XvB tier can't be sustained by the current hashrate (#158),
        and when it recovers. Edge-only (fires on the transition, not every cycle)."""
        prev = self._prev_hashrate_low
        self._prev_hashrate_low = bool(low_hr_warning)
        if prev is None or bool(low_hr_warning) == prev:
            return []
        if low_hr_warning:
            self._record_incident(self.EVT_HASHRATE_LOW)
            return [
                (
                    self.EVT_HASHRATE_LOW,
                    self._fmt(
                        "⚠️ \U0001f4c9 Hashrate too low for the chosen XvB tier — it can't be "
                        "sustained; lower the tier or add hashrate."
                    ),
                )
            ]
        return [
            (
                self.EVT_HASHRATE_LOW,
                self._fmt("\U0001f7e2 \U0001f4c8 Hashrate back above the chosen XvB tier."),
            )
        ]

    def _reject_rate_edges(self, reject_rate_pct):
        """Alert on the trailing-1h reject rate (from the #116 delta series) crossing
        ``REJECT_ALERT_PCT``, and on it dropping back. ``None`` — no shares submitted in the
        window (proxy idle or held) — is no verdict either way: stay quiet and drop the baseline
        so resumed mining seeds fresh instead of replaying a stale edge."""
        if reject_rate_pct is None:
            self._prev_reject_high = None
            return []
        high = reject_rate_pct >= REJECT_ALERT_PCT
        prev = self._prev_reject_high
        self._prev_reject_high = high
        if prev is None or high == prev:
            return []
        if high:
            self._record_incident(self.EVT_HIGH_REJECT_RATE)
            return [
                (
                    self.EVT_HIGH_REJECT_RATE,
                    self._fmt(
                        f"⚠️ ⛏️ High reject rate: {reject_rate_pct:.1f}% of shares rejected over "
                        "the last hour — check the rigs' Workers table for the ⚠ flag (bad "
                        "overclock, clock drift, flaky network)."
                    ),
                )
            ]
        return [
            (
                self.EVT_HIGH_REJECT_RATE,
                self._fmt(
                    f"\U0001f7e2 ⛏️ Reject rate back to normal "
                    f"({reject_rate_pct:.1f}% over the last hour)."
                ),
            )
        ]

    def _advisory_edge(self, problem, attr, event, problem_text, recovery_text=None):
        """Persistent host-perf advisory (#104): fires once when ``problem`` is first observed true
        (including on the first cycle — a stable bad state must still alert, unlike the seed-silent
        transient edges), stays quiet while it persists, and — if ``recovery_text`` is given — fires
        once when it clears. These are static host facts, not transient incidents, so they aren't
        tallied in the daily incident log."""
        prev = getattr(self, attr)
        setattr(self, attr, problem)
        if problem == prev:
            return []
        if problem:
            return [(event, self._fmt(problem_text))]
        return [(event, self._fmt(recovery_text))] if recovery_text else []

    def _record_incident(self, key):
        """Tally one problem-state transition for the daily incident log (#342)."""
        self._incidents[key] = self._incidents.get(key, 0) + 1

    def drain_incidents(self):
        """Return the incidents tallied since the last drain and reset the counter. Called by the
        daily digest so the count spans ~the last day (since the previous digest)."""
        incidents, self._incidents = self._incidents, {}
        return incidents

    def _fmt(self, text):
        return f"[{self.host_label}] {text}" if self.host_label else text

    async def process(self, **signals):
        """Evaluate this cycle's signals and dispatch any alerts. No-op (and cheap) when the
        notifier is disabled. Each send runs off-thread so a slow Telegram call can't stall
        the data loop. Returns the alerts that were dispatched (handy for tests/logging)."""
        if not self.notifier.enabled:
            return []
        try:
            alerts = self.evaluate(**signals)
        except Exception as exc:  # never let an alerting bug break the data loop
            logger.debug("Alert evaluation failed (%s)", type(exc).__name__)
            return []
        for _evt, text in alerts:
            await asyncio.to_thread(self.notifier.send, text)
        return alerts

    async def degradation_alert(self, kind, drop_frac):
        """Push a hashrate-loss / recovery alert for a :class:`DegradationMonitor` edge (#99). The
        detector owns the debounce + thresholds; this only formats and sends (and records the loss
        as an incident for the daily log). No-op when the event is toggled off."""
        if kind == "loss":
            self._record_incident(self.EVT_HASHRATE_LOSS)
        if not self.notifier.event_enabled(self.EVT_HASHRATE_LOSS):
            return None
        if kind == "loss":
            text = self._fmt(
                f"⚠️ \U0001f4c9 Hashrate dropped ~{drop_frac * 100:.0f}% — possible outage or a rig "
                "gone dark."
            )
        else:
            text = self._fmt("\U0001f7e2 \U0001f4c8 Hashrate recovered.")
        await asyncio.to_thread(self.notifier.send, text)
        return text

    async def maybe_daily_summary(self, now, summary_provider):
        """Push a once-daily status digest at the configured local time.

        ``summary_provider()`` builds the digest text and is called **only when a send is actually
        due**, so it isn't run every cycle. No-op when the ``daily_summary`` event is off, the time
        is malformed, or the digest has already gone out today. On a startup that's already past
        today's time it waits for tomorrow rather than firing a stale digest immediately. Returns the
        text sent (handy for tests), else ``None``.
        """
        if self._daily_target_min is None or not self.notifier.event_enabled(
            self.EVT_DAILY_SUMMARY
        ):
            return None
        lt = time.localtime(now)
        today = (lt.tm_year, lt.tm_yday)
        now_min = lt.tm_hour * 60 + lt.tm_min
        if not self._daily_seeded:
            self._daily_seeded = True
            # Started after today's send time → don't replay it now; wait for tomorrow.
            if now_min >= self._daily_target_min:
                self._daily_last = today
        if self._daily_last == today or now_min < self._daily_target_min:
            return None
        self._daily_last = today
        try:
            text = summary_provider()
        except Exception as exc:  # a bad summary build must not wedge the loop
            logger.debug("Daily summary build failed (%s)", type(exc).__name__)
            return None
        if text:
            await asyncio.to_thread(self.notifier.send, text)
        return text
