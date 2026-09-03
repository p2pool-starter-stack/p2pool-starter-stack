// The sync-mode takeover (Gauge + SyncView): what the whole page becomes while either chain is
// still catching up, instead of a dashboard full of numbers that do not mean anything yet.
//
// Split out of components.mjs because that module holds every other component and is at its
// recorded line ceiling, so the diagnostics work had no room to register an import. This family
// is the cleanest cut available rather than an arbitrary one: Gauge is used by nothing but
// SyncView, SyncView is used at exactly one site in App, and neither touches logic.mjs — so the
// move carries no helper with it and leaves no partial family behind.

import { html } from "./preact.mjs";

export function Gauge({ percent, state }) {
  const inner =
    state === "done"
      ? html`<span class="status-ok check-big">✔</span>`
      : state === "loading"
        ? "…"
        : percent + "%";
  return html`
    <div class="loader-container">
        <div class="progress-wheel" style=${{ "--p": percent + "%" }}></div>
        <div class="progress-text">${inner}</div>
    </div>`;
}

export function SyncView({ sync }) {
  return html`
    <div id="sync-view">
        <div class="header-placeholder"><p>System is currently synchronizing with the network.</p></div>
        <div class="grid">
            <div class="card">
                <h2 class="text-accent text-center">Monero Sync</h2>
                <${Gauge} percent=${sync.monero.percent} state=${sync.monero.state} />
                <div class="status-text">
                    Synced: ${sync.monero.current} / ${sync.monero.target}<br/>
                    <small>(${sync.monero.remaining} blocks left)</small><br/>
                    <small class="text-muted">${sync.monero.mode} · DB ${sync.monero.db_size}</small>
                </div>
            </div>
            <div class="card">
                <h2 class="text-accent text-center">Tari Sync</h2>
                <${Gauge} percent=${sync.tari.percent} state=${sync.tari.state} />
                <div class="status-text">
                    Synced: ${sync.tari.current} / ${sync.tari.target}<br/>
                    <small>(${sync.tari.remaining} blocks left)</small>
                </div>
            </div>
        </div>
    </div>`;
}
