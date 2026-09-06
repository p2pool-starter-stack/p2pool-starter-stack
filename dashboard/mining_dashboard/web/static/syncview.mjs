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

// What the screen says while it holds (#1886 gap 3). The headline alone named neither mechanism
// behind the wait, so an operator who changed a setting and saw nothing happen could not tell a
// working machine from a stuck one. Both added sentences are about a clock this page does not
// control: workers are readmitted on NodeHealthMonitor.healthy (reachable continuously for
// NODE_RECOVERY_AFTER_SEC, deliberately distinct from "not down"), and TARI_REQUIRED is read at
// import, so a change reaches the dashboard only when apply recreates the container. No durations
// are printed — both windows are env-tunable and a number here would read as a promise.
//
// The readmission sentence is scoped to a node that went away and came back, because
// _apply_worker_rejection has exactly one call site and it is guarded by `if self.miner_released:`
// — a one-way latch that is False until the sync gate first releases. On a first sync there are no
// rejected workers to readmit, so an unscoped sentence promised a wait that cannot occur on this
// screen's own primary path (found reviewing PR #1926; no test caught it).
export function SyncView({ sync }) {
  return html`
    <div id="sync-view">
        <div class="header-placeholder">
            <p>System is currently synchronizing with the network.</p>
            <p class="text-muted">This screen clears itself once the required chains are ready —
            nothing here needs a click. If the node went unreachable and is catching up again,
            workers are readmitted once the node has stayed reachable for a recovery window,
            rather than on the first check that succeeds. Whether Tari is required is read when
            the dashboard starts, so changing it takes effect once you apply the change, not
            while this screen is up.</p>
        </div>
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
