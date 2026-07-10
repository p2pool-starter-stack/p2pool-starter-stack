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
"""

# Monero amounts are reported in atomic units (piconero); 1 XMR = 1e12 atomic.
ATOMIC_PER_XMR = 1_000_000_000_000
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
