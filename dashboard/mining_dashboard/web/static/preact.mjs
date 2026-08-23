// Single binding point for the vendored frontend runtime. Every component module imports
// Preact + the `html` tagged-template (htm bound to Preact's `h`) from here, so there's one
// htm binding and one place that references the vendored files. All same-origin ES modules,
// no bare specifiers, no eval — loads cleanly under script-src 'self' (no unsafe-inline/eval).

import htm from "./vendor/htm.module.js";
import { Component, createRef, Fragment, h, render } from "./vendor/preact.module.js";

const html = htm.bind(h);

export { Component, createRef, Fragment, h, html, render };
