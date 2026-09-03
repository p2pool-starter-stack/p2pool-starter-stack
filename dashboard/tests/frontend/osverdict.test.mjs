// The post-reboot OS-update verdict sentence (#1051) and the blocking-cause clause #1265 adds.
//
// The host makes every judgment; these tests only check that its verdict becomes honest display
// text. The case that matters most is the one with nothing to render: an appliance on an OS image
// older than #1671 sends no `blocking` at all, and the sentence must read exactly as it always
// did rather than growing a dangling clause or implying a cause nobody reported.
//
// Escaping is deliberately NOT asserted here. Preact escapes text interpolations in the browser,
// but tests/frontend/helpers/render.mjs is a render probe that does not escape, so an assertion
// made through it would pass or fail for a reason unrelated to the thing it names. What this file
// does hold is the sanitizer's own contract: shape, type, and a bounded length.
//
// Run with Node's built-in test runner:
//     node --test dashboard/tests/frontend/*.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  blockingCause,
  MAX_BLOCKING_LEN,
  verdictText,
} from "../../mining_dashboard/web/static/osverdict.mjs";

// #1265's own observed failing check, verbatim from the bench run in the issue.
const CERT = "the dashboard certificate does not cover an IPv6 address of the box (a ULA)";

test("verdictText covers both outcomes and stays quiet otherwise", () => {
  assert.equal(verdictText({ outcome: "updated", to: "1.19.0" }), "System updated to v1.19.0.");
  assert.match(
    verdictText({ outcome: "rolled_back", from: "1.18.1", to: "1.19.0" }),
    /v1\.19\.0 failed .* rolled back automatically — still on v1\.18\.1/,
  );
  assert.equal(verdictText(null), null);
  assert.equal(verdictText({ outcome: "weird" }), null);
});

test("a host that names no blocking check reads exactly as it did before #1265", () => {
  assert.equal(
    verdictText({ outcome: "rolled_back", from: "1.18.1", to: "1.19.0" }),
    "The update to v1.19.0 failed its health checks and was rolled back automatically" +
      " — still on v1.18.1.",
  );
  assert.equal(blockingCause({ outcome: "rolled_back" }), "");
  assert.equal(blockingCause({ blocking: [] }), "");
  assert.equal(blockingCause(null), "");
});

test("the named check reaches the sentence and the rest are counted", () => {
  assert.equal(blockingCause({ blocking: [CERT] }), ` Blocked by: ${CERT}.`);
  assert.match(
    verdictText({ outcome: "rolled_back", from: "1.18.1", to: "1.19.0", blocking: [CERT] }),
    /still on v1\.18\.1\. Blocked by: the dashboard certificate does not cover/,
  );
  assert.equal(blockingCause({ blocking: [CERT, "b", "c"] }), ` Blocked by: ${CERT} (+2 more).`);
});

test("blocking is host JSON, so every garbled shape degrades to no clause", () => {
  for (const bad of ["a bare string", 7, {}, true]) {
    assert.equal(blockingCause({ blocking: bad }), "");
  }
  assert.equal(blockingCause({ blocking: [null, 3, "", "   "] }), "");
  // Punctuation-only is junk too: it survives a raw truthiness check but names nothing once the
  // trailing period is stripped, so it must not reach the sentence as an empty cause.
  assert.equal(blockingCause({ blocking: ["..."] }), "");
  // A usable message beside the junk still gets named — degrading is not the same as giving up.
  assert.equal(blockingCause({ blocking: [null, CERT] }), ` Blocked by: ${CERT}.`);
  assert.equal(blockingCause({ blocking: ["...", CERT] }), ` Blocked by: ${CERT}.`);
});

test("one long message cannot become the whole banner", () => {
  // The literal is pinned alongside the constant on purpose: a bound test that reads its bound
  // from the module under test can never fail when someone moves the bound.
  assert.equal(MAX_BLOCKING_LEN, 120);
  const out = blockingCause({ blocking: ["x".repeat(500)] });
  assert.equal(out, ` Blocked by: ${"x".repeat(120)}.`);
});

test("a message that already ends in a period does not get a second one", () => {
  assert.equal(
    blockingCause({ blocking: ["cert coverage failed."] }),
    " Blocked by: cert coverage failed.",
  );
});
