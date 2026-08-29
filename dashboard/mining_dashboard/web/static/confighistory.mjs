// The change-history vocabulary shared by Worker Inspect's outcome column, its apply status line,
// and — since #1345 — the provenance line above the history table.
//
// Split out of workerview.mjs when #1345 needed room there. The cut is along a real seam rather
// than a convenient one: everything here answers "what happened to this rig's config, and who did
// it", which is one subject. workerview.mjs imports these; nothing here imports back.

import { html } from "./preact.mjs";
import { configDriftNote, configOriginNote } from "./workerlogic.mjs";

// A terminal status → a display variant + label. rolled_back and rejected/failed read as bad;
// applied is good; accepted/pending are in-flight.
export const STATUS_META = {
  applied: { cls: "status-ok", label: "Applied" },
  accepted: { cls: "status-warn", label: "Queued on the rig" },
  pending: { cls: "status-warn", label: "Pending" },
  rejected: { cls: "status-bad", label: "Rejected" },
  rolled_back: { cls: "status-bad", label: "Rolled back" },
  failed: { cls: "status-bad", label: "Failed" },
  error: { cls: "status-bad", label: "Error" },
  // Worker-upgrade extras (#597): a rig already on the target is a calm no-op, and the rig's own
  // 6h anti-beacon throttle is retry-later, not a fault (the host runner maps it server-side).
  noop: { cls: "status-ok", label: "Already up to date" },
  throttled: { cls: "status-warn", label: "Throttled by the rig — retry later" },
};

// One history row: the change keys, the outcome, and when. `changes` IS the diff (we record only
// the deltas we authored), so listing its keys is the per-change diff — except a rig-upgrade row
// (#1014), whose `changes` carries `{version}` rather than a writable-key diff, shown as its own
// target version instead of the literal key name "version".
export function HistoryRow({ row }) {
  const meta = STATUS_META[row.status] || { cls: "text-muted", label: row.status };
  const keys = Object.keys(row.changes || {});
  const changed =
    row.type === "upgrade"
      ? `upgrade → ${row.changes?.version || "?"}`
      : keys.length
        ? keys.join(", ")
        : "—";
  return html`
    <tr>
        <td class="text-xs text-muted">${row.applied_at || ""}</td>
        <td class="font-mono text-xs">${changed}</td>
        <td><span class=${"text-small " + meta.cls}>${meta.label}</span></td>
        <td class="text-xs text-muted">${row.reason || ""}</td>
    </tr>`;
}

// Where the rig says its running config came from (#1345). The history table below it lists what
// THIS dashboard did; this line is the rig's own account, which is the only thing that can reveal
// a change the table cannot contain. Renders nothing at all when the rig cannot answer — a rig
// with no RigForge, or one older than the block, must not be made to look suspicious.
export function ConfigProvenance({ origin, meta, drift }) {
  const note = configOriginNote(origin, meta);
  // #1367: the drift note QUALIFIES the origin line — it is the only thing on the page that can
  // contradict a calm "Last changed from this dashboard" over a config nothing recorded. So it is
  // rendered independently rather than nested: a rig serving a config but no ``config_meta`` has no
  // origin line at all, and can still be running something other than what we applied.
  const driftNote = configDriftNote(drift);
  if (!note && !driftNote) return null;
  return html`
    ${
      note
        ? html`<p class=${"text-small " + note.cls} title=${note.title}>
        ${note.label}
        ${meta?.changed_at ? html` · <span class="text-muted text-xs">${meta.changed_at}</span>` : null}
    </p>`
        : null
    }
    ${driftNote ? html`<p class=${"text-small " + driftNote.cls} title=${driftNote.title}>${driftNote.label}</p>` : null}`;
}
