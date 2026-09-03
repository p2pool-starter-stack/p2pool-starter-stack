"""On-chain payout confirmation for both chains (#381, #462), and the poll-step guard (#1644).

Split out of ``data_service`` for a budget reason that is also a design one. ``data_service.py``
sits one line under its recorded ceiling, so the per-step ``try``/``except`` #1644 needs did not
fit inline; and these two steps are the only ones in the poll body proven independent enough to
isolate, which makes them a coherent thing to own rather than an arbitrary slice. The bodies below
are a pure move: byte-identical to their originals except that each now takes its collaborators as
arguments instead of reading them off ``self``.

**What #1644 is about.** ``DataService.run()``'s poll body is 33 awaited steps under a single
``except Exception``, so any one of them raising skips every step below it for that poll. A
malformed body out of the Monero wallet took the Tari payout sync, the release check and the price
feed down with it — steps that have nothing to do with Monero payouts.

**Why only these two are guarded here.** ``_sync_payouts`` and ``_sync_tari_payouts`` take no poll
locals and write no ``self`` attribute: DB and alert side-effects only. Isolating them creates no
cross-iteration edge. That is NOT true of the rest of the body, and :func:`run_isolated` is
deliberately not applied more widely — the XvB block reads poll locals (``shares_list``,
``p2pool_stats``) sourced by earlier collectors and must keep skipping as a unit, and the remaining
steps have not been cleared. Widening this guard is a separate change that owes that clearing
first; a guard whose correctness nobody has established is worse than the skip it replaces,
because it looks like the work is done.
"""

import asyncio
import logging

logger = logging.getLogger("DataService")


async def run_isolated(label, step):
    """Run one poll step so that its failure cannot skip the steps after it (#1644).

    The loop's own ``except Exception`` already keeps the service alive across a failed poll; what
    it cannot do is keep the REST OF THAT POLL running, because it sits at the bottom of the body.
    This is the same catch moved up to one step, so the poll continues past it.

    ``label`` names the step in the log. It is not cosmetic: the loop's handler logs one
    undifferentiated "Data Collection Error", and a step that now fails without ending the poll
    would otherwise be quieter than it was before it was guarded.
    """
    try:
        await step()
    except Exception as e:
        logger.error("Poll step failed, continuing with the rest of the poll — %s: %s", label, e)


async def sync_monero(state_manager, wallet_client, alert_service):
    """Confirm on-chain payouts from the view-only wallet-rpc (#381), throttled by the caller.

    Seeds the query from the highest stored Monero payout height, so a restart re-scans only
    the tip; ``add_payouts`` is idempotent on ``(chain, txid)``, so the overlap is dropped and
    nothing replays. Every genuinely-new confirmed payout fires exactly one ``payout_confirmed``
    alert. A wallet still doing its first-run scan (or briefly unreachable) returns ``[]`` — a
    quiet no-op, no error. chain="monero" here; the Tari sibling (#462) reuses the same table."""
    chain = "monero"
    min_height = await asyncio.to_thread(state_manager.get_payout_max_height, chain)
    payouts = await asyncio.to_thread(wallet_client.get_confirmed_payouts, min_height)
    if not payouts:
        return
    new_rows = await asyncio.to_thread(state_manager.add_payouts, chain, payouts)
    for r in new_rows:
        logger.info(
            "Payout confirmed on-chain: %.6f XMR (tx %s…) at height %d (#381)",
            r["amount_atomic"] / 1e12,
            r["txid"][:8],
            r["height"],
        )
        await alert_service.payout_confirmed_alert(chain, r["amount_atomic"], r["txid"])


async def sync_tari(state_manager, tari_wallet_client, alert_service):
    """Confirm Tari on-chain payouts from the view-only console wallet (#462), throttled by the
    caller — the Tari sibling of :func:`sync_monero`.

    Identical shape: seed from the highest stored Tari payout height, stream new confirmed
    payouts, persist to the shared ``payouts`` table with chain="tari" (idempotent on
    ``(chain, txid)`` so a restart replays nothing), and fire one ``payout_confirmed`` alert per
    genuinely-new payout. ``amount_atomic`` is microTari here; the shared alert divides by the
    Tari divisor. The Tari client is async (grpc.aio), so it's awaited directly rather than via
    ``asyncio.to_thread``. An empty/unreachable scan is a quiet no-op."""
    chain = "tari"
    min_height = await asyncio.to_thread(state_manager.get_payout_max_height, chain)
    payouts = await tari_wallet_client.get_confirmed_payouts(min_height)
    if not payouts:
        return
    new_rows = await asyncio.to_thread(state_manager.add_payouts, chain, payouts)
    for r in new_rows:
        logger.info(
            "Tari payout confirmed on-chain: %.6f XTM (tx %s…) at height %d (#462)",
            r["amount_atomic"] / 1e6,
            r["txid"][:8],
            r["height"],
        )
        await alert_service.payout_confirmed_alert(chain, r["amount_atomic"], r["txid"])
