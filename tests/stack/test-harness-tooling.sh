# shellcheck shell=bash
#
# Repo-tooling self-tests (#1105 Phase 1 domain: harness core). Sourced by tests/stack/run.sh
# after lib.sh — the harness (ok/bad/assert_*, SANDBOX) is already loaded.
echo "== unit: lint-operator-strings self-test (#755) =="
# The operator-strings guard's frontend scanner is non-trivial awk (comment-stripping + CSS-hex-colour
# skip); a silent break would make it stop catching leaks. Its --self-test drives fixtures through the
# real scanners and fails if a planted #NNN is missed or a hex colour/comment is wrongly flagged.
bash "$ROOT/scripts/lint-operator-strings.sh" --self-test >/dev/null 2>&1
assert_rc "operator-strings guard self-test passes" "$?" "0"

echo "== unit: pin-watch self-test (#1128) =="
# The watcher's whole product is the COMPARISON: our pins do not spell versions the way upstream
# tags them (`caddy:2.11.4` vs `v2.11.4`, `minotari_node:v5.3.1-mainnet` vs `v5.6.0`), so a plain
# string compare reports two components stale every week for ever and the report gets muted — as
# useless as the scheduled workflow that lived on a non-default branch and never ran at all. Its
# --self-test drives the normalisation over the real pin spellings and drives both lookup failure
# paths, because an upstream lookup that could not run must never read as "current".
bash "$ROOT/scripts/pin-watch.sh" --self-test >/dev/null 2>&1
assert_rc "pin-watch self-test passes" "$?" "0"

echo "== unit: resolve-pins self-test (#1137) =="
# pin-watch.sh above compares VERSIONS; it does not ask whether a pinned tag@sha256 digest still
# matches what its registry serves for that tag. This is the check that does, and its --self-test
# drives the exact half-done bump #1137 is about (tag moved, old digest left in the file) red.
bash "$ROOT/scripts/resolve-pins.sh" --self-test >/dev/null 2>&1
assert_rc "resolve-pins self-test passes" "$?" "0"

echo "== unit: patch-coverage overlap self-test (#1000) =="
# diff-cover exits 0 on "No lines with coverage information" — a vacuous pass. The wrapper's
# overlap check is what turns that into a loud not-applicable pass or a real failure; its
# --self-test drives fixtures through both branches plus the file-present quiet pass.
bash "$ROOT/scripts/patch-coverage.sh" --self-test >/dev/null 2>&1
assert_rc "patch-coverage wrapper self-test passes" "$?" "0"

echo "== unit: shipped-image sweep report self-test (#1313) =="
# The weekly sweep of the PUBLISHED images renders its tracking-issue body with this script, and
# its whole job is refusing to call an image clean when it was never scanned. Every refusal —
# a missing leg, an unparseable report, an artifact that is a tag rather than a digest — is
# driven through fixtures here, with no network, no docker and no gh.
bash "$ROOT/scripts/shipped-image-sweep-report.sh" --self-test >/dev/null 2>&1
assert_rc "shipped-image sweep report self-test passes" "$?" "0"

echo "== unit: scheduled-run watch self-test (#1377) =="
# The Monday CVE sweep's reader. Its red path CANNOT be exercised live — staging it would mean
# making the default branch's CI genuinely fail — so the fixtures here are the only place the
# failure branch runs at all. They also pin the distinction the watcher exists for: a sweep that
# FAILED is reported and exits 0 (a finding), while a sweep it could not read exits 1 (UNCHECKED).
bash "$ROOT/scripts/scheduled-run-watch.sh" --self-test >/dev/null 2>&1
assert_rc "scheduled-run watch self-test passes" "$?" "0"
