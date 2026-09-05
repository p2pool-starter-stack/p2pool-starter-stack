// What a failed apply tells the operator (#1769).
//
// Its own module rather than more of configview.mjs: that file sits at its recorded budget ceiling
// with no headroom, and this is a self-contained concern — one host result in, display text out,
// with no fetching, sequencing or state of its own. The same split osverdict.mjs took out of
// osupdate.mjs.
//
// The defect: the host writes `tail -c 2000` of the raw `apply` log into the result's `error`
// field (43-control-approval-and-preview.sh), server.py returns the result dict to the browser
// unfiltered, and this card rendered that tail bare. An apply log names host CLI verbs — "Run
// './pithead setup' first", "then re-run './pithead apply'" — and an appliance operator has no
// shell to run them in. #1213 settled the rule for doctor's messages: an appliance is told what it
// can actually reach, and the wording NEVER invents a remedy. This is that rule on a surface
// #1213's sweep cannot see, because the text never passes through dr_* at all.
//
// The tail is KEPT on both branches. It is real diagnostic detail and dropping it would trade one
// bad outcome for another. What changes on an appliance is that it is labelled as the machine's
// own log instead of being left to read as instructions, and that the sentences around it name
// only surfaces on this page: the form above, and the Service diagnostics card beside it.
//
// The host branch is unchanged, deliberately. A host operator has a shell, so
// `config.json.bak-control` is a path they can act on, and naming it is the useful thing to do.
//
// KNOWN RESIDUAL. The caller's signal is `state.os_update`, which is the presence of a file only
// an appliance's host writes (config.py OS_UPDATE_STATE_PATH). It is the only appliance tell
// build_state carries — checked against the whole payload, not assumed — but it is a signal about
// that FILE, not about the hardware. An appliance whose host has not written it yet reads as a
// non-appliance and gets the host wording, so #1769 survives in that window. Same fail-direction
// as the header's OS-update control, which simply does not render in it. Closing it properly
// needs an explicit appliance flag in build_state, which is a bigger change than this bug.
import { html } from "./preact.mjs";

// The backup path is a host filesystem path. It is the right thing to show someone with a shell
// and a dead end for someone without one, so it is the sentence that has to branch.
function backupLine(result, appliance) {
  if (appliance) {
    return html`<p class="status-bad">Apply failed. Your change was saved but is not running, and
        the previous configuration is kept on this machine.</p>`;
  }
  return html`<p class="status-bad">Apply failed. The previous config is kept at
      <code>${result.backup || "config.json.bak-control"}</code> on the host.</p>`;
}

// On an appliance the log needs a frame, because its imperatives are addressed to someone at a
// shell prompt and the reader is not that person. It names no remedy of its own beyond the two
// surfaces this page actually has.
function logCaption(appliance) {
  if (!appliance) return null;
  return html`<p class="text-muted text-xs">Below is this machine's own log from the failed
      apply. It is diagnostic detail: any commands it names run on the machine itself and cannot
      be run from here. Correct the change in the form above and save again; Service diagnostics
      on this page can run the health check and show a recent log for each service.</p>`;
}

// The whole failed arm of the Configuration card's result state.
//
// Returned as a plain array of children rather than one `html` template: every root here is an
// interpolation, with no literal tag for htm to anchor on, and a child array is a shape both
// Preact and the tests' render probe handle without that question arising at all. A null entry
// (no log, or the host branch's absent caption) is dropped by both, as it is anywhere else.
export function applyFailure(result, appliance) {
  return [
    backupLine(result, appliance),
    logCaption(appliance),
    result.error ? html`<pre class="config-error-tail">${result.error}</pre>` : null,
  ];
}
