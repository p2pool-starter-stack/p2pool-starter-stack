// Config paths the Configuration view never shows at all (#1850), and the round-trip that keeps
// what it hides intact. DOM-free, dependency-free, so `node --test` covers it directly.
//
// SSH on the appliance is a DEVELOPER feature: the 2.0 ruling is that a user never shells into
// the machine, and the ways in are the configuration stick and the `--ssh` debug image, neither
// of them this page. `ssh.*` is also in the host's never-approve set — the keys no remote channel
// may touch (os/overlay/pithead-media-config) — so the control gate refuses it however it
// arrives. That refusal is what produced the bug: an operator set `ssh.enabled`, pressed Review
// changes, and was told "No configuration changes detected", because the host had dropped the
// only key they had changed.
//
// This is a DISPLAY rule, not a security control. The gate on the host remains the authority;
// hiding the keys only stops the page offering a control it knows will be refused.
//
// It is a set of its own rather than the absence of a configlogic LOGICAL_GROUPS entry, because
// an unclaimed key falls into the catch-all "Other" group by design — dropping the group entry
// alone would MOVE the toggle, not remove it. Both are done, and this set is the one that
// decides. A member matches the way a group prefix does: the exact dotted key, or that key plus
// a dot, so a whole subtree can be named by its parent.
const HIDDEN_PREFIXES = ["ssh"];

export function isHidden(key) {
  return HIDDEN_PREFIXES.some((p) => key === p || key.startsWith(`${p}.`));
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

// Hiding a key from the FORM is only half of it: the JSON pane (#785) holds the whole candidate,
// and it is the one place in this view an operator can actually type `ssh.enabled`. So the
// candidate the view carries is a PROJECTION of the fetched config — the underscore metadata
// dropped (`_core_keys` and friends are display directives, not configuration) and every hidden
// path dropped with it.
//
// The projection is a deep copy, not the aliased slice the view used to build inline. The form
// edits the candidate in place, so sharing objects with the fetched config let a field edit
// rewrite `cfg` too — and `cfg` is what the "a blanked secret returns to the sentinel the server
// sent" recovery reads back out of. A masked secret is copied as the plain object it is; the
// sentinel is a shape, not an identity, so it survives the copy.
export function editableCandidate(cfg) {
  const out = withoutHidden(cfg || {}, []);
  for (const k of Object.keys(out)) if (k.startsWith("_")) delete out[k];
  return out;
}

function withoutHidden(node, path) {
  const out = {};
  for (const [k, v] of Object.entries(node)) {
    const p = [...path, k];
    if (isHidden(p.join("."))) continue;
    out[k] = isPlainObject(v) ? withoutHidden(v, p) : v;
  }
  return out;
}

// The other half: what the pane cannot show, it must not be able to change. Committing the
// projection as it stands would be a silent regression, because the host fills a MISSING key
// from the reference default (`ssh.enabled: false`) — so any unrelated change saved from a
// machine with SSH on would turn it off. Every hidden subtree therefore comes back from
// `source`, the config the server sent, and `source` wins: a hidden key hand-typed into the
// pane, or loaded from a file, is dropped rather than honoured.
export function restoreHidden(proposed, source) {
  const out = withoutHidden(proposed || {}, []);
  graftHidden(out, source || {}, []);
  return out;
}

function graftHidden(out, src, path) {
  for (const [k, v] of Object.entries(src)) {
    const p = [...path, k];
    if (isHidden(p.join("."))) out[k] = v;
    else if (isPlainObject(v) && isPlainObject(out[k])) graftHidden(out[k], v, p);
  }
}
