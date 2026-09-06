// The wizard's three presentational primitives, shared by the app and by the views that had to
// move out of it (#1318). They live here rather than in wizard.mjs because a second view module
// importing them from the app would make the two files import each other.

import { html } from "./preact.mjs";

export const Note = ({ children }) => html`<p class="text-muted wizard-note">${children}</p>`;
export const Err = ({ children }) => (children ? html`<p class="c-bad">${children}</p>` : null);

export const Field = ({ label, children }) => html`<label class="config-field">
    <span class="config-field-name">${label}</span>${children}
</label>`;
