// The wizard's two opt-in mining questions: whether this machine merge-mines Tari (#1855) and
// whether it joins the XvB raffle (#1848). They live here rather than in wizard.mjs because that
// file is at its budget ceiling, and because the Tari answer is not a boolean — it decides
// whether a whole block of the form exists — so the mapping from a stored `tari.mode` to the
// answer shown is worth proving without a browser.

import { html } from "./preact.mjs";
import { Field, Note } from "./wizardparts.mjs";

// Which of the three answers a stored `tari.mode` is, for the select to show.
//
// Only the literal "off" reads as declined. Everything else — a missing key included — is a yes,
// because that is what the host does with a config written before the question existed
// (`lib/pithead/28-parse-and-validate-config.sh`: no key means `local`). Reading an absent key as
// "off" would show an upgraded 1.x install as having declined merge-mining, and submitting that
// screen would then write the decline back.
//
// The opposite coercion is what this replaces: the select used to be `remoteTari ? "remote" :
// "local"`, which had no way to say "off" at all — a machine that had declined rendered as
// "local" and submit wrote `local` back, silently re-enabling the merge-mining its operator
// turned down.
export function tariAnswer(mode) {
  if (mode === "off") return "off";
  return mode === "remote" ? "remote" : "local";
}

// The Tari merge-mining question and everything that hangs off a yes.
//
// The payout address moved in here from the Payout addresses section: a machine that does not
// merge-mine has nowhere to be paid in Tari, and the field carried `required`, so leaving it up
// there would have blocked submit on a form that never asks the question. `required` stays on it
// for a yes — that is the same bar the Monero address holds.
export const TariSection = ({ answer, v, on }) => html`<h3>Tari merge-mining</h3>
    <${Field} label="Merge-mine Tari?">
        <select value=${answer} onChange=${on("tariMode")}>
            <option value="off">No — mine Monero only (default)</option>
            <option value="local">Yes — run a Tari node on this machine</option>
            <option value="remote">Yes — use a Tari node I already run</option>
        </select>
    <//>
    <${Note}>Merge-mining earns Tari from the same work that mines Monero, so it costs no
    hashrate — but it needs its own payout address and a node of its own, and the bundled node
    wants about 170 GB of disk on top of Monero's. Turning it on later means setting this machine
    up again from the boot menu — the Configuration view does not carry this switch.<//>
    ${
      answer !== "off" &&
      html`<div class="wizard-when">
        <${Field} label="Tari payout address">
            <input class="wizard-mono" value=${v("tariWallet") || ""} onInput=${on("tariWallet")}
                autocomplete="off" autocapitalize="off" spellcheck=${false} required />
        <//>
        <${Note}>Paste it — like the Monero address, it is far too long to type, and a typo pays
        a stranger.<//>
        ${
          answer === "remote" &&
          html`<${Field} label="Node host">
            <input value=${v("tariRemoteHost") || ""} onInput=${on("tariRemoteHost")}
                placeholder="192.168.1.10 or my-node.local" autocomplete="off" spellcheck=${false} />
        <//>
        <${Field} label="gRPC port">
            <input value=${v("tariRemoteGrpc") ?? 18142} onInput=${on("tariRemoteGrpc")}
                inputmode="numeric" pattern="[0-9]+" />
        <//>
        <${Note}>An IP or a hostname both work. Only over a network you trust — this connection
        is not encrypted.<//>`
        }
      </div>`
    }`;

// The raffle switch (#1848). Opt-OUT, unlike Tari: `xvb.enabled` is true in the reference, so the
// default answer here is the one a machine already had, and only a No changes anything. There is
// no follow-up question by design — the donor id and tier keep their defaults and stay editable
// from the dashboard, which is where the raffle's own decision table lives.
export const XvbField = ({ v, on }) => html`<${Field} label="Join the XMRvsBeast raffle?">
        <select value=${String(v("xvb") ?? true)} onChange=${on("xvb")}>
            <option value="true">Yes — donate a slice of hashrate to the raffle (default)</option>
            <option value="false">No — send everything to P2Pool</option>
        </select>
    <//>
    <${Note}>The switching engine donates only enough hashrate to hold your target tier and routes
    everything else to P2Pool. Donating above a tier's threshold earns nothing extra, because the
    raffle picks its winners at random.<//>`;
