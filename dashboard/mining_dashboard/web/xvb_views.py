"""XvB, earnings and top-bar badges for the dashboard: the ``/api/state`` sections that turn
raffle status, donation tiers and expected payouts into display values (Issues #12, #27, #118).

Split out of ``web/views.py`` (#1105). Everything here is presentation: the badge list the top bar
renders, the expected-XMR/XTM inputs the earnings calculator shows, the measured-vs-published
realization band, and the tier calculator's copy. ``views.py`` stays the facade — ``build_state``
assembles these sections and ``service/telegram_commands.py`` imports :func:`build_badges` from
there — so the move is invisible to consumers.

Nothing here formats HTML; it emits tokens and display strings and lets the client render.
"""

import time

from mining_dashboard.config.config import (
    DISK_CRITICAL_PERCENT,
    DISK_WARN_PERCENT,
    LOW_RAM_AVAILABLE_GB,
    XVB_MAX_DONATION_FRACTION,
    low_ram_floor_gb,
    monero_is_local,
    tari_is_local,
)
from mining_dashboard.helper.utils import (
    format_hashrate,
    format_time_abs,
    get_tier_info,
    xvb_stats_are_stale,
)
from mining_dashboard.service.earnings import (
    ATOMIC_PER_XMR,
    MICRO_PER_XTM,
    SECONDS_PER_DAY,
    confirmed_payouts_summary,
    tari_seconds_to_block_per_hs,
    xmr_per_hs_day,
    xtm_per_hs_day,
)

_LOW_HR_TITLE = (
    "Your hashrate can't sustain the selected XvB donation tier; donation will fall short of it."
)

_NOT_ELIGIBLE_TITLE = (
    "You have no share in the P2Pool PPLNS window, so you're not eligible to collect "
    'an XvB raffle win (what XvB calls being a "VIP"). If you win a round you\'re '
    "skipped and take a fail (removed from the raffle after the 3rd) — regardless of "
    "your donation tier. Keep enough hashrate on P2Pool to keep landing shares."
)

# XvB raffle auto-registration status (#263).
_XVB_REGISTERED_TITLE = (
    "This wallet is auto-registered with the XMRvsBeast raffle. Re-registration runs periodically; "
    "no manual signup is needed."
)
_XVB_INVALID_TITLE = (
    "The XvB raffle endpoint rejected your wallet as invalid, so you won't be entered. The raffle "
    "needs a standard primary Monero address (starts with 4). Check MONERO_WALLET_ADDRESS."
)
_XVB_FAILING_TITLE = (
    "XvB raffle registration keeps failing despite a PPLNS share — the endpoint may be unreachable "
    "or erroring. Check the dashboard logs and the XvB egress (Tor) path."
)


# How long the "payout wallet changed" banner stays in the top bar after a change (#375).
WALLET_CHANGED_BADGE_SEC = 72 * 3600


def recent_wallet_change(state_mgr, now=None):
    """The payout-wallet tripwire's change record (#375) if one happened within the banner
    window: ``{"old8", "new8", "ts"}`` (addresses pre-truncated to 8 chars by the alerter),
    else ``None``. Reads the kv_store keys AlertService persists; any unreadable value reads
    as "no recent change" rather than breaking ``/api/state``."""
    try:
        ts = float(state_mgr.get_kv("payout_wallet_changed_ts") or 0)
    except (TypeError, ValueError):
        return None
    if not ts or (now if now is not None else time.time()) - ts >= WALLET_CHANGED_BADGE_SEC:
        return None
    return {
        "old8": state_mgr.get_kv("payout_wallet_prev8") or "?",
        "new8": (state_mgr.get_kv("payout_wallet") or "")[:8],
        "ts": ts,
    }


def build_badges(data, metrics, mode_variant, db_healthy=True, wallet_change=None):
    """Top-bar status badges as data: ``{text, variant, title?}`` (Issues #27/#31/#35/#51/#32/#131).
    The client renders them (variant -> ``badge-<variant>``). ``wallet_change`` is the
    payout-wallet tripwire's recent-change record (#375) from :func:`recent_wallet_change`, or
    ``None``."""
    badges = []
    # Payout wallet changed within the last 72h (#375): the loudest possible tamper signal, shown
    # even during sync. Addresses are truncated to 8 chars — full addresses stay off the wire.
    if wallet_change:
        badges.append(
            {
                "text": "⚠ Payout wallet changed",
                "variant": "warn",
                "title": f"{wallet_change['old8']}… → {wallet_change['new8']}… at "
                f"{format_time_abs(wallet_change['ts'])}",
            }
        )
    # Persistence health (#131): the dashboard keeps serving live data even if its SQLite DB can't
    # be written, but history/shares/stats would silently vanish on restart — surface it loudly.
    if not db_healthy:
        badges.append(
            {
                "text": "⚠ DB write failing",
                "variant": "bad",
                "title": "The dashboard can't persist to its database — hashrate history, shares, and stats will be lost on restart. Check disk space and permissions on the dashboard data directory.",
            }
        )
    if metrics.global_syncing:
        badges.append({"text": "Syncing...", "variant": "warn"})
    else:
        badges.append({"text": metrics.mode, "variant": mode_variant})
        badges.append({"text": f"P2Pool {metrics.pool_type}", "variant": "outline"})
        if metrics.low_hr_warning:
            badges.append(
                {"text": "⚠ Hashrate low for tier", "variant": "warn", "title": _LOW_HR_TITLE}
            )
        # No PPLNS share while donating (#158): XvB wins are skipped + accrue a fail, regardless of
        # tier. A make-or-break gate worth surfacing loudly so donations aren't wasted. (This is the
        # share half of Raffle Eligible; the tier half is shown by the XvB Tier field.)
        if metrics.xvb_enabled and metrics.shares_in_window == 0:
            badges.append(
                {
                    "text": "⚠ No PPLNS share — XvB wins skipped",
                    "variant": "warn",
                    "title": _NOT_ELIGIBLE_TITLE,
                }
            )

        # XvB raffle auto-registration status (#263). Warnings take priority over the ✓ so a real
        # problem (invalid wallet / persistently failing) is never masked by a stale timestamp.
        if metrics.xvb_enabled:
            if metrics.xvb_registration_state == "invalid":
                badges.append(
                    {
                        "text": "⚠ XvB wallet rejected",
                        "variant": "bad",
                        "title": _XVB_INVALID_TITLE,
                    }
                )
            elif metrics.xvb_registration_state == "failing":
                badges.append(
                    {
                        "text": "⚠ XvB registration failing",
                        "variant": "bad",
                        "title": _XVB_FAILING_TITLE,
                    }
                )
            elif metrics.xvb_registered_at > 0:
                badges.append(
                    {
                        "text": "XvB raffle ✓",
                        "variant": "outline",
                        "title": _XVB_REGISTERED_TITLE,
                    }
                )

    # Node-down badges (Issue #31) — shown whenever a node is unreachable, regardless of sync.
    if metrics.monero.down:
        badges.append({"text": "monerod DOWN", "variant": "bad"})
    if metrics.tari.down:
        badges.append({"text": "Tari DOWN", "variant": "bad"})
    if data.get("workers_rejected"):
        badges.append(
            {
                "text": "Workers rejected",
                "variant": "bad",
                "title": "Workers rejected so they fail over to their backup pools",
            }
        )
    # Miner held until required chain(s) finish their initial sync (Issue #35).
    if data.get("miner_held"):
        badges.append(
            {
                "text": "Miner held (sync)",
                "variant": "warn",
                "title": "p2pool and xmrig-proxy are held until the required chains finish syncing",
            }
        )
    # Fail-closed miner hold on an unrecoverable health failure (Issue #490), opt-in via
    # dashboard.fail_closed. Distinct from the sync-gate badge above — this fires post-sync.
    if data.get("fail_closed_held"):
        badges.append(
            {
                "text": "Miner held (fail-closed)",
                "variant": "bad",
                "title": "dashboard.fail_closed is on and an unrecoverable health failure is "
                "holding p2pool and xmrig-proxy until it clears",
            }
        )
    # Non-blocking Tari (Issue #51): stay operational, surface a top-bar badge with the live
    # percentage once known (omitted early so it isn't a stale "0%").
    if data.get("tari_syncing_passive"):
        t_pct = metrics.tari.percent
        label = f"Tari syncing {t_pct}%" if t_pct > 0 else "Tari syncing"
        badges.append(
            {
                "text": label,
                "variant": "warn",
                "title": "Tari is still syncing — merge-mining resumes when it catches up; Monero mining continues",
            }
        )
    # Monero pruned/full badge (Issue #32) — only when known (local node).
    if metrics.monero_mode == "Pruned":
        badges.append(
            {"text": "XMR Pruned", "variant": "outline", "title": "Monero blockchain is pruned"}
        )
    elif metrics.monero_mode == "Full":
        badges.append(
            {
                "text": "XMR Full",
                "variant": "outline",
                "title": "Monero blockchain is full (not pruned)",
            }
        )

    # Low-disk badge (Issue #138). The data filesystem fills as the chains grow and logs accumulate;
    # a full disk corrupts monerod's DB mid-write. The disk *bar* shows the percentage, but it's easy
    # to miss — surface a prominent top-bar badge near full, on both the sync and main screens.
    disk_percent = (data.get("system", {}).get("disk", {}) or {}).get("percent", 0) or 0
    if disk_percent >= DISK_CRITICAL_PERCENT:
        badges.append(
            {
                "text": f"⚠ Disk {disk_percent:.0f}% full",
                "variant": "bad",
                "title": "The data disk is almost full — free space now; a full disk can corrupt the Monero database.",
            }
        )
    elif disk_percent >= DISK_WARN_PERCENT:
        badges.append(
            {
                "text": f"Disk {disk_percent:.0f}% full",
                "variant": "warn",
                "title": "The data disk is filling up — free space or move a data_dir before it runs out.",
            }
        )

    # Persistent host/performance conditions (#104), derived from live metrics so they self-correct
    # (HugePages appear after a reboot, etc.). These mirror the thresholds setup/doctor pre-flight on.
    system = data.get("system", {}) or {}
    hp_status = (system.get("hugepages") or ["Unknown"])[0]
    if hp_status == "Disabled":
        badges.append(
            {
                "text": "⚠ HugePages off",
                "variant": "warn",
                "title": "HugePages aren't reserved — RandomX hashrate is capped until they are. Run setup's tuning (or edit GRUB) and reboot to apply.",
            }
        )
    memory = system.get("memory") or {}
    ram_total = memory.get("total_gb", 0) or 0
    ram_avail = memory.get("available_gb")
    # The floor tracks what THIS machine runs locally: remote nodes take their appetite with
    # them, and a light coordinator must not be told to buy RAM for a node it does not run.
    floor = low_ram_floor_gb(monero_is_local(), tari_is_local())
    if 0 < ram_total < floor:
        badges.append(
            {
                "text": f"⚠ Low RAM ({ram_total:.0f} GB)",
                "variant": "warn",
                "title": f"Under {floor:g} GB of usable RAM for what this machine runs locally — syncing (Tari especially) is memory-heavy and can OOM. Add RAM for a stable node.",
            }
        )
    # Pressure is a LIVE signal, separate from capacity: a big box can still be out of memory,
    # and a spec box quietly idling must not wear a warning it has not earned.
    if ram_avail is not None and 0 < ram_avail < LOW_RAM_AVAILABLE_GB:
        badges.append(
            {
                "text": f"⚠ Memory pressure ({ram_avail:.1f} GB free)",
                "variant": "warn",
                "title": f"Under {LOW_RAM_AVAILABLE_GB:g} GB of memory is actually available right now — the next spike can OOM a container. Check which service is growing on the System panel.",
            }
        )
    if system.get("avx2") is False:
        badges.append(
            {
                "text": "⚠ No AVX2",
                "variant": "warn",
                "title": "This CPU lacks AVX2 — RandomX mining will be significantly slower. A hardware limit; nothing to change at runtime.",
            }
        )

    return badges


# --------------------------------------------------------------------------------------
# Earnings calculator (Issue #12): expected-XMR inputs for the Advanced view.
# --------------------------------------------------------------------------------------

_EARNINGS_DISCLAIMER = (
    "Estimated XMR from P2Pool mining only — excludes XvB donations (donated hashrate earns no "
    "P2Pool payout). Tari is merge-mined SOLO by the same hashrate: you get the whole block reward "
    "at once when your hashrate finds a Tari block — roughly every 'time to Tari block' shown — so "
    "the per-day XTM figure is a long-run average, not steady income. Expected values only; mining "
    "is variance-heavy, so real payouts swing well above and below these figures. Estimates, "
    "not guarantees."
)


def xvb_current_tier_reward_day(metrics, state_mgr):
    """XvB's published expected reward for the tier the fleet is CURRENTLY holding, as XMR/day (#712).

    Feeds the net-profit calculator (``est.xvbDay``): the whole net is already probabilistic, so
    blending the raffle's expected reward into the single figure is coherent — but it's an
    *estimate* (the draw is random among qualifiers), so the UI labels it as one. This is the
    FACE value; ``build_state`` tempers it (``xvb_tempered_day``, #902) before the payload ships.

    Uses the **current** tier (``min(xvb_1h, xvb_24h)`` — the same lower-of-two rule as
    ``metrics.current_tier``), not the target: what the fleet is actually credited now. Returns
    ``None`` — never a fabricated figure — unless XvB is on AND the fleet clears a donor tier AND
    that tier has a fresh, published ``expected_reward_year`` (same staleness gate as the XvB card,
    #311, so the two never disagree). ``expected_reward_year`` is keyed by round-type
    (``donor``/``donor_vip``/…), exactly the ``get_tiers()`` keys."""
    if not metrics.xvb_enabled:
        return None
    tiers = state_mgr.get_tiers()
    key = xvb_current_tier_key(metrics, tiers)
    if key is None:
        return None
    est_state = state_mgr.get_xvb_reward_estimates()
    estimates = (est_state or {}).get("estimates") or {}
    if xvb_stats_are_stale(est_state) or key not in estimates:
        return None
    reward_year = estimates[key]
    # 365-day year, matching logic.mjs DAYS_PER_YEAR. Guard non-positive so a zero/garbage estimate
    # degrades to None rather than folding a bogus 0 into gross.
    return float(reward_year) / 365 if reward_year and reward_year > 0 else None


def xvb_current_tier_key(metrics, tiers):
    """Round-type key of the tier the fleet is CURRENTLY credited for, or None below the lowest.

    The highest-threshold key that ``min(xvb_1h, xvb_24h)`` clears — the same lower-of-two rule as
    ``metrics.current_tier``, but yielding the KEY (``donor``/``donor_vip``/…) the estimate and
    round-stats tables are indexed by."""
    hr = min(metrics.xvb_1h, metrics.xvb_24h)
    key, best = None, 0.0
    for k, threshold in tiers.items():
        if threshold > 0 and hr >= threshold and threshold > best:
            key, best = k, threshold
    return key


# Measuring what a raffle win actually pays (#866/#872). A win's bonus round mines for up to an
# hour and its shares then ride the PPLNS window — a baseline-subtracted stream measurement on a
# production wallet (17 wins, two eras) put ~90% of the attributable excess inside 6h of the win
# timestamp, front-loaded in the first two hours. A win younger than the settle window may still
# have payouts in flight, so it is left out of the sample rather than dragging the factor down.
# Below the minimum sample the factor is noise — callers fall back to the published figure and
# the UI labels it face value.
_XVB_WIN_PAYOUT_WINDOW_S = 6 * 3600
_XVB_WIN_SETTLE_S = 12 * 3600
_XVB_REALIZATION_MIN_WINS = 5
_XVB_REALIZATION_WINDOW_S = 45 * SECONDS_PER_DAY

# Measured delivery PRIOR for boxes with no local measurement (#872): the fraction of the
# advertised prize a winner's wallet actually receives, measured ON-CHAIN (p2pool.observer,
# all three sidechains) across 25 audited won rounds, Jun–Aug 2026: point 0.33, bootstrap 95%
# CI (0.28, 0.39). At most a small margin effect (a controlled experiment pinning the credited
# margin at 2.1–2.5x the round minimum measured +5pp with overlapping CIs), so ONE band serves
# every tier and regime. Payout of delivered work measured complete, so delivery == realization.
# Supersedes the earlier (0.24, 0.42) two-era payout-window band, whose upper endpoint did not
# survive on-chain recount. A local measurement (xvb_realization) still supersedes this prior.
# ponytail: single-wallet study constant — recalibrate from the public-winners generalization.
XVB_REALIZATION_PRIOR = (0.28, 0.39)

# Vendored fallback for XvB's own published per-tier reward table (#1214). ``build_xvb_calc``'s
# reward columns need XvB's face figure, but the #163 egress rule stops the live fetch entirely
# while XvB is disabled — so a box that has never enabled XvB has no cache to read and the table
# can never answer "is enabling this worth it". These four numbers are the "Player:" line for
# each donor round type in XvB's own ``reward_estimate_pub.txt`` — the PER-PLAYER expected
# reward, exactly what the live parser extracts (``_REGEX_REWARD_LINE`` in
# ``client/xvb_client.py`` matches ``Round: <type> Player: <value> XMR/year`` only; it deliberately
# skips the pool-total ``Round: <type>: <value> XMR/year`` line just above each Player line, which
# is a different, much larger figure — the whole raffle's total payout for that round type, not
# one qualifier's share of it). Using the wrong row here would make the fallback disagree with
# what any live fetch would ever show. Archived verbatim (no live fetch involved) as part of the
# delivery study on the date below:
# docs/research/xvb-delivery-study/data/sources/xmrvsbeast-reward_estimate_pub.txt
# (docs/research/xvb-delivery-study/data/sources/MANIFEST.md). Keyed by round-type, same as a
# live ``estimates`` cache, and used ONLY when the box is disabled (see ``build_xvb_calc``'s
# ``_face_value``: this must never fire for an ENABLED-but-stale box — that box's own live fetch
# is just failing right now, e.g. a transient bot-challenge, and the honest read is "estimate
# unavailable", not a claim it is "off" and using a published snapshot). It never overrides a
# live figure, and it feeds the SAME ``XVB_REALIZATION_PRIOR`` band above, never a second,
# differently-derived estimate. Static by design (option 1 of #1214): these change rarely, so a
# dated, labelled snapshot is worth more than a permanent blank on a box that has never enabled
# XvB. Refresh only by re-archiving the source file and updating the date — a test
# (TestXvbCalc.test_fallback_values_match_the_archived_source_files_player_rows) parses the
# archive with the live parser and fails if this dict ever drifts from it.
XVB_PUBLISHED_REWARD_FALLBACK = {
    "donor": 0.064,
    "donor_vip": 0.81,
    "donor_whale": 4.67,
    "donor_mega": 54.54,
}
XVB_PUBLISHED_REWARD_FALLBACK_DATE = "2026-08-10"


def xvb_forecast_tier_key(metrics, tiers):
    """The tier the expected-wins forecast should speak to: held, else targeted (#866).

    Before any tier is held — a fleet still ramping its credited average, or an operator weighing
    whether donating is worth enabling at all — the honest forecast is for the TARGET tier: "what
    would this buy", rather than a dash that reads as unknowable."""
    key = xvb_current_tier_key(metrics, tiers)
    if key is None and metrics.target_threshold > 0:
        key = next((k for k, t in tiers.items() if t == metrics.target_threshold), None)
    return key


def xvb_expected_wins_day(round_stats_state, tier_key, tiers):
    """Expected raffle wins per day for the held tier (#866), from XvB's own winners file.

    The file's players column is the qualifier count per round, so the honest forecast is
    mechanical: for each donor round type the fleet qualifies for (threshold at or under the held
    tier's), rounds-per-day ÷ average qualifiers, summed. Verified against production: predicted
    0.84 whale wins/day, measured 0.84/day over the same stretch. None when the aggregate is
    missing, stale (#311 rule), or spans no measurable time — the card shows "—", never a guess."""
    if not tier_key:
        return None
    stats = (round_stats_state or {}).get("stats") or {}
    types = stats.get("types") or {}
    span_days = stats.get("span_days") or 0.0
    if xvb_stats_are_stale(round_stats_state) or not types or span_days <= 0:
        return None
    held = tiers.get(tier_key, 0.0)
    total = 0.0
    for key, threshold in tiers.items():
        if 0 < threshold <= held:
            agg = types.get(key)
            if agg and agg.get("players_avg", 0) > 0 and agg.get("rounds", 0) > 0:
                total += (agg["rounds"] / span_days) / agg["players_avg"]
    return total if total > 0 else None


def xvb_realization(payouts, raffle_wins, xvb_day, expected_wins_day, now=None, p2pool_day=None):
    """Measured fraction of XvB's published expectation this wallet actually collects (#866/#872).

    Numerator: mean confirmed XMR landing within the attribution window after each settled win in
    the trailing measurement window. Denominator: face value per win — the published per-day figure
    spread over the expected win rate. Production measured ~0.19 on a Whale-tier box whose credited
    average rode the round minimum; the published figures assume 1.0. Returns
    ``(fraction clamped to [0, 1], wins measured)``, or None (callers fall back to the published
    number, labeled face value) when either side is missing or fewer than
    ``_XVB_REALIZATION_MIN_WINS`` wins are measurable."""
    # ponytail: one factor across tiers and eras — per-tier factors if a tier change muddies it.
    if not payouts or not raffle_wins or not xvb_day or not expected_wins_day:
        return None
    now = now if now is not None else time.time()
    lo = now - _XVB_REALIZATION_WINDOW_S
    stamps = [
        t for t in ((w.get("ts") or 0) for w in raffle_wins) if lo <= t <= now - _XVB_WIN_SETTLE_S
    ]
    if len(stamps) < _XVB_REALIZATION_MIN_WINS:
        return None
    face_per_win = xvb_day / expected_wins_day
    if face_per_win <= 0:
        return None
    # Each payout counts once even when two win windows overlap (back-to-back wins).
    realized = (
        sum(
            (p.get("amount_atomic") or 0)
            for p in payouts
            if any(0 <= (p.get("ts") or 0) - t <= _XVB_WIN_PAYOUT_WINDOW_S for t in stamps)
        )
        / ATOMIC_PER_XMR
    )
    # Ordinary P2Pool payouts also land inside the attribution windows; left in, they inflate the
    # factor (the failure mode this whole measurement exists to prevent). Subtract the expected
    # baseline: the box's own linear P2Pool rate over the windowed hours.
    if p2pool_day and p2pool_day > 0:
        realized -= p2pool_day * (_XVB_WIN_PAYOUT_WINDOW_S / SECONDS_PER_DAY) * len(stamps)
    frac = (realized / len(stamps)) / face_per_win
    return (max(0.0, min(1.0, frac)), len(stamps))


def xvb_tempered_day(xvb_day, realization):
    """The per-day XvB figure the calculator and energy net fold in (#902) — never face value.

    Same precedence as the decision table: this wallet's measured realization when enough wins
    exist to measure it (``xvb_realization``), else the midpoint of the measured delivery prior
    (``XVB_REALIZATION_PRIOR``). ``None``/0 passes through — nothing published means nothing to
    temper, never a fabricated figure."""
    if not xvb_day:
        return xvb_day
    frac = realization[0] if realization else sum(XVB_REALIZATION_PRIOR) / 2
    return xvb_day * frac


def build_earnings(data, metrics, payouts=None, tari_payouts=None, xvb_day=None):
    """Expected-XMR-from-P2Pool calculator inputs for the Advanced view (Issue #12).

    ``payouts`` (#381), when the view-only wallet feature is on, is the stored confirmed-payout
    list; it's rolled into a ``confirmed`` block (yesterday / 24h / 7d / 30d / all-time XMR, #787)
    shown beside this estimate — the estimate is a model, the confirmed figure is ground truth from
    the wallet. ``tari_payouts`` (#462) is the same for the Tari side, rolled into
    ``tari_confirmed`` (XTM) beside the Tari time-to-block estimate.

    This is a **P2Pool** mining calculator: it estimates the XMR earned by the hashrate that is
    actually mining on your P2Pool node — *not* the rig's total output. The what-if default is
    ``p2pool_1h`` — the **same P2Pool 1h-average hashrate shown in the header / Overview / My Node
    cards** (a time-weighted average of the recorded P2Pool hashrate), so the figure here matches
    those exactly. That recorded average already excludes any XvB-donated slice (XvB hashrate is a
    separate series), which is why an active XvB split doesn't inflate the estimate.

    Tari merge-mining rides along (#117): the same P2Pool hashrate simultaneously works the Tari
    aux chain, so the payload carries a second rate — XTM per H/s per day, over the Tari
    difficulty and block reward p2pool's merge-mine stats report. ``tari_available`` is gated on
    ``tari_mining`` as well as the rate, so a dead merge-mine channel can't show phantom XTM.

    Publishes the earnings **rate** (XMR per H/s per day, from ``service/earnings``) plus that
    P2Pool hashrate and the P2Pool share difficulty. The client scales the rate to the entered
    *what-if* hashrate and formats the day/month/year figures + expected time-to-share — sending
    a rate (not pre-formatted earnings) keeps the live recompute a single source of truth with no
    duplicated math (see ``web/static/logic.mjs``).

    ``available`` is False when the network figures needed for the rate are missing; the client
    then shows ``—`` instead of a bogus estimate (graceful degradation)."""
    reward_atomic = (data.get("network", {}) or {}).get("reward", 0) or 0
    coeff_day = xmr_per_hs_day(reward_atomic, metrics.network_difficulty)
    # Reuse the displayed P2Pool 1h average (header / Overview / My Node) so the calculator's
    # hashrate is consistent with the rest of the dashboard — and because that recorded average
    # already excludes the XvB-donated portion, it's the honest basis for a P2Pool estimate.
    p2pool_hr = metrics.p2pool_1h
    # Tari rate (#117). We take p2pool's aux `reward` field as the current Tari block reward —
    # it refreshes every poll, so the linear model tracks the decaying emission.
    tari_coeff_day = xtm_per_hs_day(metrics.tari_reward, metrics.tari_difficulty)
    # Solo merge-mining pays the whole block at once (#117): the honest headline is the expected
    # time to a Tari block (difficulty / hashrate) and the per-block reward, with the per-day rate
    # kept only as a long-run average. `tari_difficulty` carries the seconds-to-block-per-H/s figure
    # (== difficulty, guarded); the client divides it by the what-if hashrate.
    tari_seconds_per_hs = tari_seconds_to_block_per_hs(metrics.tari_difficulty)
    return {
        "available": coeff_day > 0,
        "p2pool_hr": p2pool_hr,  # raw H/s — the what-if default
        "p2pool_hr_str": format_hashrate(p2pool_hr),
        "coeff_day": coeff_day,  # XMR per H/s per day
        "tari_available": tari_coeff_day > 0 and metrics.tari_mining,
        "tari_coeff_day": tari_coeff_day,  # XTM per H/s per day (long-run AVERAGE, not steady income)
        "tari_difficulty": tari_seconds_per_hs,  # seconds-to-block per H/s (client: diff / hashrate)
        "tari_reward": metrics.tari_reward,  # full XTM paid per Tari block (solo, lumpy)
        # Current-tier XvB expected reward, XMR/day, folded into the net-profit estimate (#712).
        # None unless XvB is on with a fresh published estimate for the tier the fleet holds now.
        # build_state tempers this by measured delivery (xvb_tempered_day, #902) before the
        # payload ships — clients never see the raw published figure.
        "xvb_day": xvb_day,
        "pool_difficulty": metrics.pool_difficulty,  # for expected time-to-share (diff/hr)
        "block_reward": f"{reward_atomic / 1e12:.4f} XMR",  # context, server-formatted like NetworkCard
        "disclaimer": _EARNINGS_DISCLAIMER,
        # Confirmed on-chain payouts (#381), beside the estimate above. {"enabled": False} when the
        # view-only wallet feature is off — the UI then shows only the estimate.
        "confirmed": confirmed_payouts_summary(payouts),
        # Confirmed Tari payouts (#462), beside the Tari time-to-block estimate. XTM (microTari),
        # {"enabled": False} when the Tari view-only wallet feature is off.
        "tari_confirmed": confirmed_payouts_summary(
            tari_payouts, divisor=MICRO_PER_XTM, unit="xtm"
        ),
    }


def build_earnings_vs_actual(
    metrics, earnings, raffle_wins, now=None, expected_wins_day=None, realization=None
):
    """Expected-vs-actual summary — one row per income stream, for both views (#808).

    The comparison the operator otherwise assembles by hand across the Earnings tabs: the linear
    expectation over a trailing window beside what the view-only wallets confirmed over the SAME
    window (#381/#462). Expected uses the time-weighted routed P2Pool average over the window
    itself (``metrics.p2pool_7d``/``p2pool_30d``), not the current 1h figure — a fleet that grew
    or shrank mid-window would otherwise be judged against the wrong baseline.

    Every stream shares ONE trailing 30d window (#817 — mixed windows read as inconsistent, and
    30d is the shortest span that means something for all three). **Monero + XvB** is ONE
    combined row: an XvB win pays out through ordinary small payouts the payout table cannot
    attribute, so the confirmed actual already contains XvB XMR — comparing it against a
    P2Pool-only expectation overshoots on a winning box (#817). Both sides count XvB instead:
    expected = the P2Pool linear model + XvB's published per-day estimate × 30 (folded only when
    fresh; ``includes_xvb`` tells the client which label to draw), actual = every confirmed
    payout; ``pct`` compares like with like, and ``partial`` carries the confirmed window's
    may-be-incomplete flag. The XvB addend is TEMPERED by this wallet's measured win realization
    when enough wins exist to measure it (#866 — see ``xvb_realization``); the published face
    value stays in the tooltip via ``xvb_realization_pct``/``xvb_wins_measured``. **Tari** compares BLOCK COUNTS: solo merge-mining pays whole blocks,
    so the honest unit is blocks (expected = hashrate × window ÷ aux difficulty; actual =
    confirmed payout count, each payout being a found block), with the XTM sum alongside — no
    percent, a count that small is luck either way. **XvB** keeps only its win count and last-win
    recency — its XMR value lives in the combined row by construction.

    Raw numbers out; the client formats. ``actual``/``blocks``/``xtm`` are None while the matching
    payout-confirmation feature is off — the card then hints at the view key instead of showing a
    zero that would read as "earned nothing"."""
    now = now if now is not None else time.time()
    conf = earnings["confirmed"]
    tari_conf = earnings["tari_confirmed"]
    expected_p2pool = earnings["coeff_day"] * metrics.p2pool_30d * 30
    # Clamped: xvb_day is upstream-published (XvB's API); a hostile/corrupt negative would drag
    # the combined expectation to <= 0 while `available` stays True — an inverted pct at best, a
    # zero denominator at worst. A negative estimate is meaningless, so it folds as 0.
    expected_xvb = max(0.0, earnings["xvb_day"] or 0.0) * 30 if metrics.xvb_enabled else 0.0
    # Temper the XvB leg by what THIS wallet's wins measurably paid (#866): the published figure
    # prices bonus hashes at face value, which a production wallet realized ~19% of — folding it
    # untempered made the combined pct blame the P2Pool leg for XvB's optimism. With enough
    # measured wins (``realization``, computed once in build_state via ``xvb_realization``) the
    # leg scales down to the measured fraction; without them the published figure stands and the
    # client labels it face value.
    if realization and expected_xvb > 0:
        expected_xvb *= realization[0]
    else:
        realization = None
    xmr = {
        "available": expected_p2pool > 0,
        "expected_30d": expected_p2pool + expected_xvb,
        # True when XvB's published estimate is folded into expected — drives the row label. The
        # actual ALWAYS contains any win payouts; when XvB is on but the published figure is
        # stale, the tooltip owns the asymmetry rather than a fabricated estimate filling it.
        "includes_xvb": expected_xvb > 0,
        # Tempering context for the tooltip: the measured fraction and its sample size, or None
        # when the leg is the untempered published figure (or XvB is off).
        "xvb_realization_pct": round(realization[0] * 100) if realization else None,
        "xvb_wins_measured": realization[1] if realization else None,
        "enabled": bool(conf.get("enabled")),
        "actual_30d": conf.get("xmr_30d") if conf.get("enabled") else None,
        "partial": bool((conf.get("partial") or {}).get("30d")),
        "pct": None,
    }
    if xmr["available"] and xmr["enabled"]:
        pct = round((xmr["actual_30d"] or 0.0) / xmr["expected_30d"] * 100)
        # Withheld past 999%: a near-zero expectation (a box idle for most of the window that
        # still confirmed normal payouts) turns the ratio into a five-digit figure that reads
        # as a bug, not a comparison. pct is None only here once available+enabled hold, so
        # the client's tooltip can own the explanation without an extra flag.
        xmr["pct"] = pct if pct <= 999 else None
    # Expected Tari blocks over the window: hashrate × seconds ÷ difficulty (hashes-per-block).
    # Gated on tari_mining like the calculator, so a dead merge-mine channel shows "—", not 0.
    expected_blocks = (
        metrics.p2pool_30d * 30 * SECONDS_PER_DAY / metrics.tari_difficulty
        if metrics.tari_mining and metrics.tari_difficulty > 0
        else 0.0
    )
    tari = {
        "available": expected_blocks > 0,
        "expected_blocks_30d": expected_blocks,
        "enabled": bool(tari_conf.get("enabled")),
        "blocks_30d": tari_conf.get("n_30d") if tari_conf.get("enabled") else None,
        "xtm_30d": tari_conf.get("xtm_30d") if tari_conf.get("enabled") else None,
        "partial": bool((tari_conf.get("partial") or {}).get("30d")),
    }
    stamps = [w.get("ts", 0) or 0 for w in (raffle_wins or [])]
    xvb = {
        "enabled": metrics.xvb_enabled,
        "wins_30d": sum(1 for t in stamps if t >= now - 30 * SECONDS_PER_DAY),
        "last_win_ts": max(stamps, default=0),
        # The forecast the "—" used to stand in for (#866): win odds are computable from XvB's
        # own winners file (round-type frequency ÷ qualifier count), so publish them. None while
        # the aggregate is missing/stale — the client keeps the dash.
        "expected_wins_30d": expected_wins_day * 30 if expected_wins_day else None,
    }
    return {"xmr": xmr, "tari": tari, "xvb": xvb}


# XvB tier calculator copy (#118). A tier is RAFFLE status, never an XMR payout, and the winner is
# drawn at random among qualifiers — donating above the threshold buys zero extra win chance, so
# the honest framing is cost, not reward.
_XVB_TIER_NOTE = (
    "An XvB tier is raffle status, not an XMR payout. Donated hashrate earns no P2Pool shares; "
    "holding a tier costs about its threshold in continuous donation (XvB qualifies a tier on "
    "both the 1h and 24h credited averages), and donating above the threshold adds nothing — "
    "the raffle winner is drawn at random among qualifiers."
)

_XVB_SIDECHAIN_NOTE = (
    "Note: switching the P2Pool sidechain resets your PPLNS shares, and collecting an XvB win "
    "needs a share in the window."
)


def build_xvb_calc(metrics, state_mgr, realization=None):
    """XvB tier/raffle calculator inputs for the Advanced view (Issue #118).

    Same pattern as ``build_earnings``'s ``coeff_day``: the server publishes the tier table and
    the sustainability rule once (single source of truth — ``state_mgr.get_tiers()``, so a
    ``TIER_CONFIG`` override flows through, plus ``XVB_MAX_DONATION_FRACTION``), and the client
    does the what-if math (``computeXvbTier`` in ``logic.mjs``, a transcription of
    ``resolve_target_threshold``'s auto rule). Current/target tier state comes straight off
    ``Metrics`` — no tier math is re-derived here.

    The draw is random among qualifiers, but the winners file publishes the qualifier count per
    round (#872), so each tier carries its measurable draw context: ``win_odds_day`` (that round
    type's frequency ÷ its average qualifiers — per-round-type, unlike the earnings card's
    cumulative forecast) and ``players_avg`` (which also makes a single-qualifier artifact like
    Mega's self-evident). ``realized_reward_year`` scales the published figure by this wallet's
    measured win realization (``realization``, from ``xvb_realization``) — None when unmeasured,
    so the client falls back to the study band; face value shows only in its own column.

    Published with XvB DISABLED too (#938): the table is the enable/don't-enable decision aid, so
    hiding it behind the flag defeated its purpose. Everything here is computable from local
    config plus the cached public feeds; disabling XvB stops the fetches (the egress rule, #726).
    The reward columns still light up on a box that is DISABLED — never enabled, or turned off
    after its cache aged out (#1214): when nothing live/cached is usable AND ``metrics.xvb_enabled``
    is False, they fall back to ``XVB_PUBLISHED_REWARD_FALLBACK``, a static, dated, labelled
    snapshot of XvB's own published table (never a live fetch, so the egress rule is untouched) —
    ``estimates_source``/``estimates_published_date`` tell the client which one it got. The
    fallback deliberately does NOT fire for an ENABLED-but-stale box (e.g. a transient fetch
    failure such as a bot-challenge): that box's live estimate is momentarily unavailable, not
    "off", so it keeps the honest pre-existing degradation instead — ``estimates_source`` reads
    "none" and the client shows the same "estimate unavailable" text it always has. The odds
    column has no fallback at all, disabled or not: qualifier counts are live competitive data
    with no stable published table to vendor, so it stays honestly empty until XvB runs and the
    winners feed populates the cache. The live-credit context goes quiet on its own: ``build_state``
    computes ``realization`` only while enabled, and ``Metrics`` reports current/target tier as
    "Disabled" — the client keys every live-donation surface (and the current/target cards here)
    off ``enabled``."""
    tiers = state_mgr.get_tiers()
    round_state = state_mgr.get_xvb_round_stats()
    round_types = (
        {}
        if xvb_stats_are_stale(round_state)
        else ((round_state.get("stats") or {}).get("types") or {})
    )
    span_days = ((round_state.get("stats") or {}).get("span_days") or 0.0) if round_types else 0.0

    def _odds_day(key):
        agg = round_types.get(key)
        if not agg or span_days <= 0 or agg.get("players_avg", 0) <= 0:
            return None
        return (agg["rounds"] / span_days) / agg["players_avg"]

    # XvB's published per-tier expected reward (XMR/year), fetched over Tor and cached (#118). The
    # tier KEY is exactly the round-type in the file (donor / donor_vip / donor_whale / donor_mega),
    # so a tier maps to its estimate by key. A stale or empty cache degrades to None per tier +
    # estimates_available False (reusing the stats staleness rule so the two never disagree, #311)
    # — ``_face_value`` below then tries the vendored fallback before giving up.
    est_state = state_mgr.get_xvb_reward_estimates()
    estimates = (est_state or {}).get("estimates") or {}
    estimates_stale = xvb_stats_are_stale(est_state)
    estimates_available = bool(estimates) and not estimates_stale
    # #1214: one static fallback figure per tier, tried only when the box is DISABLED (never
    # enabled, or turned off after its cache aged out) — an enabled box with a merely-stale or
    # not-yet-populated cache (a transient fetch failure, e.g. a bot-challenge) is NOT "off"; it
    # keeps the honest pre-existing "estimate unavailable" degradation instead of a fallback that
    # would falsely read as "XvB is off, using its last published table". Only tried for tiers the
    # archived table actually names — a custom TIER_CONFIG round-type it doesn't recognise just
    # stays None, same as before this fix.
    fallback_eligible = not metrics.xvb_enabled
    fallback_used = False

    def _face_value(key):
        """XvB's own face figure for a tier — live estimate first, vendored fallback second.

        ``realized_reward_year`` deliberately does NOT use this: mixing THIS wallet's own
        measured delivery factor with a dated, generic fallback would overstate precision the
        wallet has no basis for, and ``realization`` is only ever non-None while XvB is enabled
        (``build_state``), when a live estimate is normally available anyway. It keeps requiring
        a live, fresh figure, same as before this fix."""
        nonlocal fallback_used
        if estimates_available and key in estimates:
            return float(estimates[key])
        if not estimates_available and fallback_eligible and key in XVB_PUBLISHED_REWARD_FALLBACK:
            fallback_used = True
            return XVB_PUBLISHED_REWARD_FALLBACK[key]
        return None

    tier_rows = []
    for key, t in tiers.items():
        if t <= 0:
            continue
        face = _face_value(key)
        live_face = float(estimates[key]) if estimates_available and key in estimates else None
        tier_rows.append(
            {
                "name": get_tier_info(t, tiers)[0],
                "threshold": float(t),
                "expected_reward_year": face,
                # Published figure × measured realization (#872) — the net the panel can
                # honestly act on. None until enough wins measure the factor; LIVE face value
                # only (see ``_face_value``'s docstring) — a stale/fallback figure can't be
                # "realized" against.
                "realized_reward_year": (
                    live_face * realization[0] if live_face is not None and realization else None
                ),
                # Unmeasured boxes still get a calculable band (#872): the published figure
                # (live or vendored fallback) scaled by the measured realization PRIOR below.
                # None once a local measurement exists (realized_reward_year supersedes it) or no
                # face value is available at all — the two never show together.
                "assumed_reward_year_range": (
                    [face * XVB_REALIZATION_PRIOR[0], face * XVB_REALIZATION_PRIOR[1]]
                    if face is not None and not realization
                    else None
                ),
                "win_odds_day": _odds_day(key),
                "players_avg": (round_types.get(key) or {}).get("players_avg"),
            }
        )
    return {
        "enabled": metrics.xvb_enabled,
        # Ascending tier table for the client's what-if; names via get_tier_info so they read
        # exactly like the tier strings everywhere else (threshold already embedded in the name).
        "tiers": sorted(tier_rows, key=lambda entry: entry["threshold"]),
        "estimates_available": estimates_available,
        "estimates_stale": estimates_stale,
        # #1214: "live" when a fresh fetch backs the reward columns, "published" when the vendored
        # fallback filled them instead (with the date it was archived, so the client can label how
        # old it is), "none" when neither had anything for any tier.
        "estimates_source": "live"
        if estimates_available
        else ("published" if fallback_used else "none"),
        "estimates_published_date": XVB_PUBLISHED_REWARD_FALLBACK_DATE if fallback_used else None,
        # Measurement context for the realized figures: the factor and its sample size, or None
        # while unmeasured (the client then labels the published number face value).
        "realization_pct": round(realization[0] * 100) if realization else None,
        "realization_wins": realization[1] if realization else None,
        "max_fraction": XVB_MAX_DONATION_FRACTION,  # donation headroom rule (sustainability)
        "current_tier": metrics.current_tier,
        "target_tier": metrics.target_tier,
        "target_threshold": metrics.target_threshold,
        "sustainable": metrics.target_sustainable,
        "note": _XVB_TIER_NOTE,
        # #33 mode context, display-only: off the Main sidechain a pool switch costs your PPLNS
        # shares — and with them XvB win collectability. None on Main (nothing to warn about).
        "mode_note": _XVB_SIDECHAIN_NOTE if metrics.pool_type != "Main" else None,
    }
