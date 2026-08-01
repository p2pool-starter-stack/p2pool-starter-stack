"""Expected-earnings model (Issue #12).

A thin domain layer over ``service/metrics`` and the live Monero network figures that
answers "what should this hashrate earn?". It is deliberately small and **linear**: the
expected XMR a given hashrate earns is the standard variance-free mining expectation

    E[XMR/s] = hashrate * block_reward / network_difficulty

The network's target block time cancels out (``network_hashrate = difficulty / block_time``
and ``E = hashrate / network_hashrate * reward / block_time``), so the rate depends only on
the block reward and the network difficulty — both already collected for the XMR Network panel.

Because earnings are linear in hashrate, the server only needs to publish the **rate per H/s**;
the dashboard's *what-if* hashrate input scales that one rate to any entered hashrate on the
client (instant, no re-derivation, no round trip) — see ``web/static/logic.mjs``. Keeping the
rate here (one source of truth) is the #61 principle: presentation layers read the metrics, they
don't re-derive the math.

The same expectation covers Tari (#117): merge-mining puts the full P2Pool hashrate to work on
the Tari aux chain *alongside* Monero, so ``xtm_per_hs_day`` is the identical linear rate over the
Tari difficulty and block reward p2pool's merge-mine stats already report (``collector/pools.py``).
The XvB tier estimate is still deferred (per the Issue #12 discussion), and hashrate currently
donated to XvB isn't subtracted here — the estimate assumes the supplied hashrate mines via
P2Pool, which the dashboard states in its disclaimer.

Alongside the model sits ``confirmed_payouts_summary`` (#787): the same domain layer, but over
what the view-only wallets actually recorded (#381/#462) rather than what the model predicts.
It lives here so the dashboard card and the Telegram bot roll the running windows up exactly
once, from one implementation — the #61 principle again.
"""

import time

# Monero amounts are reported in atomic units (piconero); 1 XMR = 1e12 atomic.
ATOMIC_PER_XMR = 1_000_000_000_000
# Tari amounts are reported in microTari (µT); 1 XTM = 1e6 µT (#462).
MICRO_PER_XTM = 1_000_000
SECONDS_PER_DAY = 86_400


def xmr_per_hs_day(block_reward_atomic, network_difficulty):
    """Expected XMR earned per **1 H/s per day**.

    ``block_reward_atomic`` is the live Monero block reward in atomic units and
    ``network_difficulty`` the live network difficulty. Returns ``0.0`` when either input is
    missing or non-positive — the dashboard treats a zero rate as "unavailable" and shows
    ``—`` rather than a bogus number (graceful degradation, per the acceptance criteria).
    """
    if block_reward_atomic <= 0 or network_difficulty <= 0:
        return 0.0
    reward_xmr = block_reward_atomic / ATOMIC_PER_XMR
    return reward_xmr / network_difficulty * SECONDS_PER_DAY


def xtm_per_hs_day(block_reward_xtm, network_difficulty):
    """Expected XTM earned per **1 H/s per day** from Tari merge-mining (#117).

    Same linear expectation as :func:`xmr_per_hs_day` — the aux-chain target block time cancels
    identically. ``block_reward_xtm`` is the Tari block reward **already in XTM** (the collector
    converts p2pool's µT figure; ``collector/pools.py``) and ``network_difficulty`` the Tari
    aux-chain difficulty p2pool reports — not the P2Pool sidechain or Monero difficulty. We take
    p2pool's aux ``reward`` field as the current Tari block reward; it refreshes every poll, so
    the linear model tracks the decaying emission either way. Returns ``0.0`` when either input
    is missing or non-positive — zero is the "unavailable" signal (the card shows ``—``).
    """
    if block_reward_xtm <= 0 or network_difficulty <= 0:
        return 0.0
    return block_reward_xtm / network_difficulty * SECONDS_PER_DAY


def tari_seconds_to_block_per_hs(network_difficulty):
    """Expected **seconds to find one Tari block** per 1 H/s (#117 solo merge-mining).

    Tari merge-mining here is **solo**: the whole block reward lands at once when *your* hashrate
    finds a Tari block, not as a steady trickle. The expected time to that block is
    ``network_difficulty / hashrate`` seconds (difficulty is hashes-per-block, hashrate is
    hashes/second), so — like :func:`xtm_per_hs_day` — the per-H/s figure is difficulty itself and
    the client divides by the what-if hashrate (one source of truth, #61). At the current Tari
    difficulty a full fleet can be ~months between blocks, which is why the honest headline is this
    lumpy time-to-block, not the per-day long-run average. Returns ``0.0`` when the difficulty is
    missing or non-positive — the "unavailable" signal (the card shows ``—``)."""
    if network_difficulty <= 0:
        return 0.0
    return float(network_difficulty)


# Running-earnings windows (#787). The estimate above answers "what should this hashrate earn?";
# these answer "what did it actually earn?" from the confirmed on-chain payouts the view-only
# wallets record (#381/#462). Both the dashboard card and the Telegram bot read this one roll-up,
# so the two surfaces cannot drift apart (#61/#387).
RUNNING_WINDOWS = ("yesterday", "7d", "30d")


def previous_local_day(now):
    """``(start, end)`` unix seconds of the previous full **local** calendar day.

    "Yesterday" means the calendar day, not a trailing 24 hours — that is the figure an operator
    means by "what did I make yesterday". Local is the dashboard container's timezone
    (``dashboard.timezone``), the same clock the daily summary fires on and the chart's payout
    dates are stamped in, so all three agree on where a day ends.

    Steps back through noon rather than subtracting 86 400 from today's midnight: a DST transition
    makes a day 23 or 25 hours long, and the naive subtraction lands on the wrong date on exactly
    those two days a year."""
    lt = time.localtime(now)
    today = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    prev = time.localtime(today - 43_200)
    start = time.mktime((prev.tm_year, prev.tm_mon, prev.tm_mday, 0, 0, 0, 0, 0, -1))
    return start, today


def confirmed_payouts_summary(payouts, now=None, divisor=ATOMIC_PER_XMR, unit="xmr"):
    """Roll confirmed on-chain payouts into running totals + a count (#381/#462/#787).

    ``payouts`` is the stored-payout list (``storage.get_payouts(chain)``): each carries ``ts``
    (unix seconds) and ``amount_atomic``. Sums are converted atomic→whole-unit at this edge only,
    via ``divisor`` (piconero 1e12 for Monero, microTari 1e6 for Tari) with the amount keys prefixed
    by ``unit`` (``xmr_*`` / ``xtm_*``). ``enabled`` is False when the feature is off
    (``payouts is None``) — the UI then shows only the estimate; an empty list means "on, nothing
    confirmed yet" (shows 0.000000).

    Windows: ``24h``/``7d``/``30d`` are trailing spans from ``now``, ``yesterday`` is the previous
    full local day (:func:`previous_local_day`), ``all`` is everything stored. The 30d window also
    carries its payout **count** (``n_30d``, #808): for solo-merge-mined Tari a payout IS a found
    block, so that count is the honest actual to hold against the expected block count. Only the
    consumed window gets a count — the all-time count stays ``count``.

    ``partial`` marks each running window whose span begins before the oldest payout on record
    (``since_ts``) — the sum then covers only part of the window it is labelled with, so the UI
    says so rather than presenting it as a full one. It is deliberately a *may be incomplete*
    signal, not a *is incomplete* one: a wallet that genuinely earned nothing for six weeks reads
    as partial too, because the payouts table alone cannot tell "no payout arrived" apart from
    "we weren't watching yet". Over-warning is the safe direction — the figure is never claimed to
    be complete when it might not be."""
    if payouts is None:
        return {"enabled": False}
    now = now if now is not None else time.time()
    day, week, month = now - 86_400, now - 7 * 86_400, now - 30 * 86_400
    y_start, y_end = previous_local_day(now)
    atomic = dict.fromkeys(("24h", "yesterday", "7d", "30d", "all"), 0)
    n_30d = 0
    for p in payouts:
        amt = p.get("amount_atomic", 0) or 0
        ts = p.get("ts", 0) or 0
        atomic["all"] += amt
        if ts >= month:
            atomic["30d"] += amt
            n_30d += 1
        if ts >= week:
            atomic["7d"] += amt
        if ts >= day:
            atomic["24h"] += amt
        # Half-open [start, end) so a payout landing exactly at midnight belongs to the day it
        # starts, never to both days.
        if y_start <= ts < y_end:
            atomic["yesterday"] += amt
    # Only positive stamps: a row with a missing/zero ts can't date the history, and letting it
    # win the min would mark every window complete on the strength of a broken row.
    stamps = [t for t in (p.get("ts", 0) or 0 for p in payouts) if t > 0]
    since_ts = min(stamps, default=0)
    starts = {"yesterday": y_start, "7d": week, "30d": month}
    summary = {
        "enabled": True,
        "count": len(payouts),
        "last_ts": max(stamps, default=0),
        # Oldest payout on record — where the history these windows are drawn from begins. 0 when
        # nothing is confirmed yet, which marks every running window partial.
        "since_ts": since_ts,
        "partial": {w: since_ts <= 0 or since_ts > starts[w] for w in RUNNING_WINDOWS},
    }
    summary.update({f"{unit}_{w}": v / divisor for w, v in atomic.items()})
    summary["n_30d"] = n_30d
    return summary
