// Pure XvB (XMRvsBeast raffle) decision logic — tier what-ifs and the per-tier donate/don't
// decision table. Split out of logic.mjs (#1316) to keep logic.mjs under its file-budget ceiling;
// kept DOM-free like its sibling so node --test covers it without a browser or a JS toolchain.

import { DAYS_PER_YEAR } from "./logic.mjs";

// Highest sustainable XvB tier for a what-if hashrate (#118): the highest tier whose threshold
// clears `hashrateHs * calc.max_fraction`. A direct transcription of the AUTO path of
// helper/utils.resolve_target_threshold (get_tier_info over stable_hr × max_fraction) — a pinned
// test shares its inputs with the Python unit test so the two can't drift silently. Cost = the
// threshold itself: XvB qualifies a tier on BOTH the 1h and 24h credited averages, so holding it
// costs ~threshold H/s of continuous donation. Null when no tier is sustainable. Not gated on
// calc.enabled: the what-if runs from local hashrate and the published thresholds, so it answers
// "which tier could I hold?" before XvB is ever turned on (#938).
export function computeXvbTier(hashrateHs, calc) {
  if (!calc || !(hashrateHs > 0)) return null;
  let best = null;
  for (const t of calc.tiers || []) {
    if (t.threshold > 0 && hashrateHs * calc.max_fraction >= t.threshold) {
      if (!best || t.threshold > best.threshold) best = t;
    }
  }
  return best && { tier: best.name, threshold: best.threshold, cost: best.threshold };
}

// XvB tier decision rows (#872, study-final). ONE row per donor tier with everything a miner
// needs to choose a direction, all from measured or operator-published data:
//   odds       — how often this tier's rounds pay out and among how many qualifiers (live feed)
//   cost       — P2Pool earnings forgone donating the threshold (threshold x coeffDay x 365)
//   xvbSays    — XvB's published face-value reward (their number, shown as theirs)
//   study      — [lo, hi]: xvbSays x the measured delivery band (server-emitted; on-chain study
//                constant, 25 rounds: 32% of face, CI 27-38%, margin-invariant)
//   yours      — xvbSays x THIS wallet's measured realization, when >=5 wins exist (supersedes)
//   net        — the actionable verdict: (yours ?? study ?? face) minus cost; [lo,hi] when a band
// A tier the what-if hashrate cannot sustain is flagged, its net withheld (an unreachable payout
// must not render as reachable). Pure + unit-tested; the component only renders these rows.
// Not gated on calc.enabled: the table is the enable/don't-enable decision aid (#938) — the
// server publishes the tiers either way, and a disabled box just has no live-credit context.
// Verdict colour for a net band: red only when even the optimistic end loses, green only when
// even the pessimistic end profits. A band that straddles zero is a real "could go either way"
// verdict, so it says so in warn amber — as plain uncoloured text it was indistinguishable from a
// cell that carries no verdict at all (#1316).
function verdictClass(net) {
  if (net === null) return "";
  if (net[1] < 0) return "status-bad";
  if (net[0] > 0) return "status-ok";
  return "status-warn";
}

export function xvbDecisionRows(calc, coeffDay, hr) {
  if (!calc) return [];
  const rows = [];
  for (const t of calc.tiers || []) {
    const cost = t.threshold > 0 && coeffDay > 0 ? t.threshold * coeffDay * DAYS_PER_YEAR : null;
    const xvbSays = Number.isFinite(t.expected_reward_year) ? t.expected_reward_year : null;
    const yours = Number.isFinite(t.realized_reward_year) ? t.realized_reward_year : null;
    const study =
      Array.isArray(t.assumed_reward_year_range) &&
      t.assumed_reward_year_range.every(Number.isFinite)
        ? t.assumed_reward_year_range
        : null;
    const sustainable = hr > 0 && t.threshold <= hr * (calc.max_fraction || 0);
    let mode = "none";
    let net = null;
    if (cost !== null && yours !== null) {
      mode = "yours";
      net = [yours - cost, yours - cost];
    } else if (cost !== null && study !== null) {
      mode = "study";
      net = [study[0] - cost, study[1] - cost];
    } else if (cost !== null && xvbSays !== null) {
      mode = "face";
      net = [xvbSays - cost, xvbSays - cost];
    }
    // XvB's own published reward minus the same cost. Computed alongside rather than only as a
    // fallback: it is the "what XvB says you'd make" answer in its own right, so the reader never
    // has to subtract two figures in their head to get it (#1316).
    const netFace = cost !== null && xvbSays !== null ? [xvbSays - cost, xvbSays - cost] : null;
    const cls = verdictClass(net);
    const clsFace = verdictClass(netFace);
    rows.push({
      name: t.name,
      threshold: t.threshold,
      sustainable,
      oddsPer30d: t.win_odds_day > 0 ? t.win_odds_day * 30 : null,
      players: t.players_avg > 0 ? t.players_avg : null,
      cost,
      xvbSays,
      study,
      yours,
      net,
      netFace,
      mode,
      cls,
      clsFace,
    });
  }
  return rows;
}
