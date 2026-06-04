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

XMR only for now: Tari network difficulty / block reward aren't collected anywhere yet, and the
XvB tier estimate is deferred (both per the Issue #12 discussion). Hashrate currently donated to
XvB isn't subtracted here — the estimate assumes the supplied hashrate mines Monero via P2Pool,
which the dashboard states in its disclaimer.
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
