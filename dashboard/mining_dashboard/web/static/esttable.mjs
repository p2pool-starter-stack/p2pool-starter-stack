// The Day/Month/Year estimate table, shared by the earnings tabs and the XvB tier block.
// Lifted out of components.mjs when the XvB block moved to its own module (#1316): two copies of
// "the one shape every earnings tab presents its estimate in" would have drifted apart, and the
// drift would show as two earnings tables that disagree.
import { coinFiat, coinTriplet, formatFiatAmount } from "./logic.mjs";
import { html } from "./preact.mjs";

// Standardized Day/Month/Year estimate table — the one shape every earnings tab presents its
// estimate in: coin column in accent, a ≈-fiat column appearing once the coin's price is known
// (the same visibility gate the old per-cell fiat cards used). Replaces per-tab stat-grids whose
// two-column flow paired unrelated cells (XMR/year beside ≈/day). The coin triplet shares one
// precision (coinTriplet) so the rows align.
export const EstTable = ({ unit, day, month, year, price, currency, title }) => {
  const coins = coinTriplet([day, month, year], unit);
  const haveFiat = Number.isFinite(price) && price > 0;
  const rows = [
    ["Day", day, coins[0]],
    ["Month", month, coins[1]],
    ["Year", year, coins[2]],
  ];
  return html`
    <div class="est-scroll">
    <table class="est-table" title=${title || ""}>
        <thead><tr>
            <th></th>
            <th scope="col">${unit}</th>
            ${haveFiat ? html`<th scope="col">≈ ${currency || "USD"}</th>` : null}
        </tr></thead>
        <tbody>
            ${rows.map(
              ([label, raw, coin]) => html`
            <tr>
                <th scope="row">${label}</th>
                <td class="c-accent">${coin}</td>
                ${haveFiat ? html`<td>${formatFiatAmount(coinFiat(raw, price))}</td>` : null}
            </tr>`,
            )}
        </tbody>
    </table>
    </div>`;
};
