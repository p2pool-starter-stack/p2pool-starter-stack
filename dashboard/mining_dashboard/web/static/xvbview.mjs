// XvB (XMRvsBeast raffle) view: the tier decision table and the tier/raffle block that hosts it.
// Split out of components.mjs (#1316) to keep components.mjs under its file-budget ceiling.

import { EstTable } from "./esttable.mjs";
import { coinFiat, fmtHashrate, formatFiat, formatXmr } from "./logic.mjs";
import { html } from "./preact.mjs";
import { computeXvbTier, xvbDecisionRows } from "./xvblogic.mjs";

// --- Small shared pieces (local copies of components.mjs's private helpers; see components.mjs
// for the shared convention — kept private there too, so each caller gets its own small copy
// rather than a shared export, following workerview.mjs's InfoCard precedent) ---------------

const StatCard = ({ label, value, cls, span, title }) => html`
    <div class=${"stat-card" + (span ? " col-span-2" : "")} title=${title || ""}>
        <h5>${label}</h5>
        <p class=${cls || ""}>${value}</p>
    </div>`;

// XvB tier decision block (#872, study-final): the analytical tool a miner decides with. Every
// donor tier gets a block — the two net verdicts (what XvB says, and what the study says) as
// coloured stat cards, with their inputs beneath: draw odds (live winners feed), cost at YOUR
// hashrate, XvB's published face value and the study estimate (face x the measured on-chain
// delivery band). This wallet's own measured wins supersede the study band when they exist.
// Unsustainable tiers stay visible but grayed with the net withheld. No dropdown: the comparison
// IS the decision, so all tiers show at once.
//
// #1316: this was a six-column table in a `.table-scroll`. It could not fit the ~308px content
// box of a `.grid-columns` card at ANY string length — the longest tier name plus a single figure
// already fills that width — so it panned sideways and never showed a whole row. Stacked blocks
// wrap instead of panning, which is the only shape that fits this card.
function XvbDecisionTable({ calc, coeffDay, hr, energy }) {
  const rows = xvbDecisionRows(calc, coeffDay, hr);
  if (!rows.length) return null;
  const measured = calc.realization_pct !== null && calc.realization_pct !== undefined;
  // One figure, not a band. Two twelve-character numbers and an ellipsis were most of the old
  // table's width, and the widest cell in every row was a Net (#1316). The midpoint is what the
  // verdict is about; the band it was drawn from stays in the cell's tooltip, so the spread is
  // still one hover away rather than gone.
  const fmtMid = (r) => (r === null ? "—" : formatXmr((r[0] + r[1]) / 2));
  const bandNote = (r) =>
    r === null || r[0] === r[1] ? "" : `Range: ${formatXmr(r[0])} … ${formatXmr(r[1])}.`;
  const estLabel = measured
    ? `Yours (${calc.realization_pct}% × ${calc.realization_wins} wins)`
    : "Study est.";
  const estTitle = measured
    ? "XvB's figure scaled by what THIS wallet's raffle wins actually paid."
    : "XvB's figure scaled by the measured delivery band (33%, CI 28–39% — on-chain single-wallet audit, 25 rounds; crawl-corroborated).";
  // Fiat mirror (#520) for the best sustainable net only — one line, never a fiat number whose
  // XMR figure is hidden.
  const best = rows.filter((r) => r.sustainable && r.net).sort((a, b) => b.net[1] - a.net[1])[0];
  return html`
        <div class="xvb-comparison">
            <label class="xvb-compare-label">Should I donate? — per-tier verdict (per year)</label>
            <p class="text-muted text-xs" id="xvb-study-note">
                XvB's figures are face value. A 25-round single-wallet on-chain audit (Jun–Aug
                2026, all three sidechains) measured winners receiving 33% of face (95% CI
                28–39%), with at most a small margin effect; a 14-winner public crawl
                corroborates (no winner near face value). The
                ${measured ? "Yours" : "Study"} figure prices that in; the Net verdict uses it.
            </p>
            <div id="xvb-decision-tiers">
            ${rows.map((r) => {
              const est = r.yours !== null ? [r.yours, r.yours] : r.study;
              const costNote = r.cost !== null ? `Cost ${formatXmr(r.cost)}.` : "";
              return html`<div class=${r.sustainable ? "" : "text-muted"}>
                <h5 class="est-heading" title=${r.sustainable ? "" : `Not sustainable at your hashrate — holding this tier needs about ${fmtHashrate(r.threshold)} donated continuously.`}>
                    ${r.name}${r.sustainable ? "" : " ⚠"}</h5>
                <div class="stat-grid">
                    <${StatCard} label="Net (XvB says)"
                        value=${r.sustainable ? fmtMid(r.netFace) : "—"}
                        cls=${r.sustainable ? r.clsFace : ""}
                        title=${`XvB's own published reward minus the P2Pool earnings given up. ${costNote} Green: profits. Amber: could go either way. Red: loses.`} />
                    <${StatCard} label=${`Net (${measured ? "yours" : "study"})`}
                        value=${r.sustainable ? fmtMid(r.net) : "—"}
                        cls=${r.sustainable ? r.cls : ""}
                        title=${`The ${measured ? "measured" : "study"} estimate minus the P2Pool earnings given up — the verdict this table is about. ${costNote} ${bandNote(r.net)} Green: profits even at the pessimistic end. Amber: the range straddles zero. Red: loses even at the optimistic end.`} />
                </div>
                <p class="text-muted text-xs mt-1">
                    <span title="P2Pool earnings forgone by donating the tier threshold for a year, at your current rate.">Cost ${r.cost !== null ? formatXmr(r.cost) : "—"}</span> ·
                    <span title="XvB's own published expected reward — face value: prices every bonus hash at full block reward.">XvB says ${r.xvbSays !== null ? formatXmr(r.xvbSays) : "—"}</span> ·
                    <span title=${`${estTitle} ${bandNote(est)}`}>${estLabel} ${fmtMid(est)}</span> ·
                    <span title="How often this tier's rounds pay out, and among how many qualifiers — from XvB's public winners feed.">Odds / 30d ${r.oddsPer30d ? `≈ ${Number(r.oddsPer30d.toPrecision(2))} wins · ${Number((r.players || 0).toPrecision(2))} players` : "—"}</span>
                </p>
              </div>`;
            })}
            </div>
            ${
              energy && energy.xmr_price > 0 && best
                ? html`<p class="text-muted text-xs mt-1" id="xvb-fiat-line">
                    ${best.name}: net ≈ ${formatFiat(coinFiat((best.net[0] + best.net[1]) / 2, energy.xmr_price), energy.currency)} per year at the current XMR price</p>`
                : null
            }
            <p class="text-muted text-xs mt-2">
                ${
                  calc.estimates_available
                    ? "XvB figures fetched over Tor from the operator's published estimates; odds from the public winners feed; the draw is random among qualifiers — donating above a threshold buys no extra odds."
                    : calc.estimates_source === "published"
                      ? `Reward figures are XvB's last published table (${calc.estimates_published_date}), not a live fetch — XvB is off, so nothing is fetched from xmrvsbeast.com. Win odds need the live winners feed and stay unavailable until XvB runs again.`
                      : "Expected reward estimate unavailable — tier costs only."
                }
            </p>
        </div>`;
}

// XvB tier / raffle block (#118), inside the earnings card and driven by the same what-if
// hashrate: the highest XMRvsBeast tier that hashrate sustains (computeXvbTier — the server's
// own auto rule), what holding it costs, and the current vs target tier for context. Labelled
// raffle status, never a payout. The draw is random above the threshold — donating more within
// a tier buys nothing — but the odds themselves ARE knowable (#872: qualifier counts from XvB's
// winners file), so the comparison dropdown shows them. Rendered with XvB disabled too (#938) —
// the block is the enable/don't-enable decision aid — but the live-credit cards (Current/Target
// tier) stand down with the flag: there is no credited donation to report.
// `coeffDay` (earnings.coeff_day) feeds the per-tier payout comparison dropdown below.
export function XvbTierBlock({ calc, hr, coeffDay, energy, est }) {
  if (!calc) return null;
  const t = computeXvbTier(hr, calc);
  return html`
    <div class="xvb-tier-block">
        <h4>XvB Tier (raffle)</h4>
        ${
          calc.enabled
            ? null
            : html`<p class="text-muted text-xs" id="xvb-disabled-note">
                XvB donation is off — this table prices what enabling it would earn and cost at
                your hashrate. Nothing is fetched from xmrvsbeast.com while it is off${
                  calc.estimates_source === "published"
                    ? html`, so the reward columns use XvB's last published table (${calc.estimates_published_date}) instead of a live read`
                    : calc.estimates_source === "live"
                      ? ", so the reward columns run from the last live read"
                      : ""
                }. The odds column needs the live winners feed, so it stays empty until
                XvB runs again.</p>`
        }
        <div class="stat-grid">
            <${StatCard} label="Sustainable Tier" value=${t ? t.tier : "None"} cls="c-purple"
                         title="The highest XvB donor tier this hashrate sustains while leaving P2Pool its share — the same auto rule the donation controller uses." />
            <${StatCard} label="Hashrate Cost" value=${t ? fmtHashrate(t.cost) : "—"}
                         title="Holding the tier means continuously donating about its threshold — hashrate that earns no P2Pool shares while donated." />
            ${
              calc.enabled
                ? html`
            <${StatCard} label="Current Tier" value=${calc.current_tier}
                         title="The tier your credited XvB donation clears right now (the lower of XvB's 1h and 24h averages)." />
            <${StatCard} label="Target Tier" value=${calc.target_tier}
                         title=${"The tier the donation controller is configured to aim for" + (calc.sustainable ? "." : " — currently NOT sustainable at your hashrate.")} />`
                : null
            }
        </div>
        ${
          // Current-tier expected reward (#712) in the same standardized Day/Month/Year table
          // every other tab shows. Only when the server sent a fresh estimate — never fabricated.
          // The server tempers the published figure by measured delivery (#902): this wallet's
          // measured win payouts when enough wins exist, else the study band's midpoint — never
          // face value. A fixed figure, NOT scaled by the what-if hashrate; the heading says so.
          est && est.xvbDay !== null
            ? html`
        <h4 class="est-heading" title="XvB's published expected reward for the tier your fleet holds now, tempered by measured delivery: scaled to what this wallet's wins measurably paid when enough wins exist, else by the midpoint of the measured delivery band (28–39% of face value). XvB's raw figure shows only in the decision table's own column. A raffle expectation across all qualifiers, not scaled by the what-if hashrate above.">
            Current Tier Expected Reward — tempered by measured delivery</h4>
        <${EstTable} unit="XMR" day=${est.xvbDay} month=${est.xvbMonth} year=${est.xvbYear}
                     price=${energy ? energy.xmr_price : 0} currency=${energy ? energy.currency : "USD"} />`
            : null
        }
        <${XvbDecisionTable} calc=${calc} coeffDay=${coeffDay} hr=${hr} energy=${energy} />
        <p class="text-muted text-xs mt-2">${calc.note}${calc.mode_note ? " " + calc.mode_note : ""}</p>
    </div>`;
}
