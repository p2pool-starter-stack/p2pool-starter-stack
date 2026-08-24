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

echo "== unit: verify-healthcheck-scripts self-test (#1098) =="
# #1098: docker-compose.yml named a healthcheck script (xmrig-proxy-healthcheck.sh) that the
# pinned appliance images predated — the container reported unhealthy forever with nothing
# actually broken. This is the narrower, permanent guard: does each service's OWN Dockerfile
# actually place a file where compose's healthcheck looks for it. The self-test drives the
# parsers (WORKDIR resolution, COPY --from=, multi-source directory COPYs) against fixtures and
# reproduces the issue's own named mutation end to end: rename the script in a Dockerfile without
# touching compose, and the check must go red.
bash "$ROOT/scripts/verify-healthcheck-scripts.sh" --self-test >/dev/null 2>&1
assert_rc "verify-healthcheck-scripts self-test passes" "$?" "0"

echo "== unit: verify-healthcheck-scripts against the real tree (#1098) =="
# The self-test above proves the parsers; this proves the CURRENT docker-compose.yml and build/*
# Dockerfiles actually agree right now — the same real-tree pass release.sh and CI both get, so a
# healthcheck rename that forgets the compose side (or vice versa) fails here before it ever
# reaches an appliance.
bash "$ROOT/scripts/verify-healthcheck-scripts.sh" >/dev/null 2>&1
assert_rc "every real healthcheck script exists where its own Dockerfile promises (#1098)" "$?" "0"

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

echo "== unit: #1059 watch-report discrimination =="
# The restore leg's config.json watcher reports on PASSING runs, so its SILENCE is the load-bearing
# output — and five ways of collecting no evidence (guest unreadable, watcher never started,
# watcher killed mid-window, watch window expired) must not print what a genuinely clean window
# prints. Its --self-test drives all six outcomes, asserts each on the one sentence only it writes
# AND on the absence of the others, and runs the shipped watcher body for real against a sandbox
# file so the watcher and the report are proven against each other rather than each against an
# assumption. Lives in tests/os/ (appliance lane); driven here because tier 1 is the lowest tier
# that proves it and it needs no KVM.
bash "$ROOT/tests/os/failure-evidence.sh" --self-test >/dev/null 2>&1
assert_rc "#1059 watch-report self-test passes" "$?" "0"

echo "== unit: tor healthcheck command-dependency self-test (#1372) =="
# The #1098 pair above asks whether a healthcheck script EXISTS where its Dockerfile promises. This
# asks the other half of the same contract: whether build/tor/healthcheck.sh can still RUN on
# nothing but the commands that image ships. #1372 is the case that made the gap visible — the
# Dockerfile installed `xxd` by name for one call site that busybox already served, and nothing in
# CI could see either the need or its removal. Its --self-test drives the script for real with PATH
# stripped to an allowlist of the image's commands, and drops each declared command in turn, because
# a leaking PATH would pass every case on the host's own commands and prove nothing.
bash "$ROOT/build/tor/healthcheck-selftest.sh" --self-test >/dev/null 2>&1
assert_rc "tor healthcheck runs on the commands its own image ships (#1372)" "$?" "0"
