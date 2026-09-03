// The post-reboot OS-update verdict, turned into one sentence for the banner (#1051, #1265).
//
// Its own module rather than more of osupdate.mjs: that file is at its recorded budget ceiling
// with no headroom, and this is a self-contained concern — host verdict in, display text out,
// with no fetching, sequencing or state of its own.
//
// The rollback sentence used to say only that health checks failed, which reads as "bad release"
// and is usually wrong. The boot gate rolls a GOOD update back when doctor fails a check the
// update did not cause — #1265's cert-coverage race is exactly that shape: an address arrives
// between render's mint and doctor's check, and the box reverts a healthy payload. pithead-boot
// (#1671) now copies doctor's failing messages into the verdict as `blocking`, so the banner can
// name what actually held the gate instead of implying the release was at fault.

// One doctor message is a sentence, not a paragraph. The host writes them, but they reach an
// operator through this page, so bound them: a runaway message must not become the whole banner.
// Display-only — the full list stays in the state file for anyone reading the host.
export const MAX_BLOCKING_LEN = 120;

// The checks that held the gate, as a trailing clause, or "" when the host named none. An OS
// image older than #1671 omits `blocking` altogether, so the caller's sentence has to read
// correctly without it — absence here is "we were not told", never "nothing was wrong".
export function blockingCause(verdict) {
  const held = (verdict && Array.isArray(verdict.blocking) ? verdict.blocking : [])
    .filter((m) => typeof m === "string" && m.trim())
    .map((m) => m.trim().replace(/\.+$/, "").slice(0, MAX_BLOCKING_LEN));
  if (!held.length) return "";
  // Name the first and count the rest: the gate stops at the first failing check, and one named
  // cause an operator can act on beats a wall of them.
  return ` Blocked by: ${held[0]}${held.length > 1 ? ` (+${held.length - 1} more)` : ""}.`;
}

// One verdict line for the banner. Pure — the render just wraps it.
export function verdictText(verdict) {
  if (!verdict || !verdict.outcome) return null;
  if (verdict.outcome === "updated") return `System updated to v${verdict.to}.`;
  if (verdict.outcome !== "rolled_back") return null;
  return (
    `The update to v${verdict.to} failed its health checks and was rolled back automatically` +
    ` — still on v${verdict.from}.${blockingCause(verdict)}`
  );
}
