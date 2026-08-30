#!/usr/bin/env bash
#
# Self-test for the config.json artifact capture (#1630).
#
# THE DEFECT. `capture_artifacts` wrote the live config.json through `redact()`, which is a
# LINE-WISE stream filter keyed on field NAMES. `notifications.ntfy.url` is the bare word `url`
# and only its NESTING separates it from `xvb.url` and the other public endpoints — so no name
# rule can reach it without also eating those. The ntfy topic in that path IS the capability:
# whoever holds a captured bundle can publish to, and subscribe to, the operator's channel.
# Measured on the shipped filter before this change, `notifications.webhooks[]` survived too —
# one value more than the issue names, and the whole URL there is the bearer secret (#848).
#
# THE FIX IS ROUTING, NOT NEW MACHINERY. The stack already classifies this document by PATH:
# `render_masked_config` (lib/pithead/30-release-fetch-and-masked-config.sh) walks
# CONTROL_SECRET_PATHS *plus* three variable-length array cases the fixed-path walk cannot reach
# (workers.list[].token, the deprecated dashboard.workers[].token, and notifications.webhooks[]).
# The capture now SOURCES the box's own `./pithead` and calls that function, so there is ONE
# classification source and this harness restates neither the list nor the jq program. Sourcing is
# the shipped contract, not a trick: 00-prelude.sh sets `_STACK_SOURCED=1` when BASH_SOURCE[0]
# differs from $0 and skips every side effect — the cd, the traps, and `main`.
#
# WHY THE LIVE CONFIG AND NOT THE BOX'S PRE-RENDERED COPY: docs/dev/integration-testing.md, under
# *Artifacts & triage*. Stated once, there, rather than restated here.
#
# THE PASS IS ADDITIVE. The masked document still goes through `redact()` afterwards, so the shape
# and vocabulary rules keep their reach over anything the path list does not name; row 4 pins that.
#
# WHY THE SHIPPED LINE CARRIES ONLY ONE COMMENT LINE. tests/integration/lib.sh sits at its recorded
# 692-line ceiling with zero headroom, so the reasoning lives here and in
# docs/dev/integration-testing.md. The one comment line it does carry was paid for by deleting a
# comment that restated its own code.
#
# HOW THIS FILE MEASURES. It runs the REAL `capture_artifacts` from lib.sh against a fake box
# directory in IT_MODE=local, with the REAL built `pithead` and the REAL `jq`. Nothing about the
# masking is stubbed, so the rows exercise the text that ships rather than a paraphrase of it.
#
# PROVEN ABLE TO FAIL — the mutations and their row counts are recorded in the PR body; each was
# `cmp`-checked against an untouched copy first, so a mutation that failed to apply cannot be
# counted as a leg.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

REPO="$(cd -P "$HERE/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BOX="$TMP/box"
OUT="$TMP/out"
FAKEBIN="$TMP/bin"
mkdir -p "$BOX" "$OUT" "$FAKEBIN"

# The box runs the REAL program — the point of the fix is that nothing here restates it.
ln -s "$REPO/pithead" "$BOX/pithead"

# Sentinels are SHORT on purpose. A value of 90+ alnum characters is reached by redact()'s shape
# rule, which would make the rows below pass off the stream filter rather than off the document
# pass they exist to measure.
NTFY_TOPIC="NTFYTOPICSENTINEL"
WEBHOOK="WEBHOOKSENTINEL"
# 95 alnum characters under a benign key no path rule and no name rule reaches: only redact()'s
# shape rule can remove it, so it measures whether the stream pass still runs after the document.
LONGVAL="$(printf 'A%.0s' $(seq 1 95))"

cat >"$BOX/config.json" <<CONFIG_EOF
{
  "monero": { "mode": "local" },
  "xvb": { "url": "https://xmrvsbeast.com/p2pool/XvB" },
  "notifications": {
    "ntfy": { "url": "https://ntfy.sh/$NTFY_TOPIC" },
    "webhooks": ["https://hooks.example.com/$WEBHOOK"]
  },
  "workers": { "list": [ { "name": "rig1", "note": "$LONGVAL" } ] }
}
CONFIG_EOF

# capture_artifacts also shells out to docker and the dashboard API; stub them so this file tests
# the config route and nothing else. IT_PITHEAD is `true` so the status/doctor captures cannot
# EXECUTE the real pithead sitting in the fake box.
printf '#!/bin/sh\nexit 0\n' >"$FAKEBIN/docker"
printf '#!/bin/sh\nexit 1\n' >"$FAKEBIN/curl"
chmod +x "$FAKEBIN/docker" "$FAKEBIN/curl"

export PATH="$FAKEBIN:$PATH"
export IT_MODE=local
export IT_REMOTE_DIR="$BOX"
export IT_PITHEAD=true

echo "== capture_artifacts: config.json is masked BY PATH before the stream filter (#1630) =="

# ATTRIBUTION. Before anything else, prove the stream filter ALONE leaves the ntfy topic standing.
# Without this row, a green "the topic is absent" below could be redact()'s doing and the document
# pass would be untested — the borrowed green this lane has shipped before.
RAW_THROUGH_REDACT="$(redact <"$BOX/config.json")"
assert_contains "attribution: redact() ALONE leaves the ntfy topic — the gap is real and unfixed in the stream filter" \
    "$RAW_THROUGH_REDACT" "$NTFY_TOPIC"
assert_contains "attribution: redact() ALONE leaves the webhook URL too — one value more than the issue names" \
    "$RAW_THROUGH_REDACT" "$WEBHOOK"

capture_artifacts "cfg" "$OUT" >/dev/null 2>&1
ART="$(cat "$OUT/cfg/config.json" 2>/dev/null)"

# ARMING. Every row below is an ABSENCE, and an empty or missing artifact makes all of them pass.
# This row is what makes those absences mean anything: the capture produced a real document that
# still carries its non-secret content.
assert_contains "control: the capture produced a config-shaped document (absences below are earned)" \
    "$ART" '"mode"'
assert_contains "control: a public endpoint is NOT masked — the path walk is selective, not a blanket" \
    "$ART" "xmrvsbeast.com"

# THE ROW THIS FILE EXISTS FOR. Assert the RAW value is ABSENT — never that a marker appeared. A
# marker can arrive from another field on the same line, and partial redaction is worse than none.
case "$ART" in
*"$NTFY_TOPIC"*) it_fail "the ntfy topic is absent from the captured config" "raw capability value survived the capture" ;;
*) it_pass "the ntfy topic is absent from the captured config" ;;
esac
case "$ART" in
*"$WEBHOOK"*) it_fail "the webhook URL is absent from the captured config" "raw bearer value survived the capture" ;;
*) it_pass "the webhook URL is absent from the captured config" ;;
esac
# ADDITIVE, not a replacement. `workers.list[].note` is in no path rule and no name vocabulary, so
# only redact()'s >=90-character shape rule can reach it. If this reds, the document pass has
# REPLACED the stream pass instead of preceding it, which would be a coverage regression.
case "$ART" in
*"$LONGVAL"*) it_fail "the stream rules still run over the masked document" "a shape-reached value survived — the document pass replaced redact() instead of preceding it" ;;
*) it_pass "the stream rules still run over the masked document" ;;
esac

# FAIL CLOSED. If the box's program cannot be reached the capture must produce NO config rather
# than fall back to the raw file. The snippet never `cat`s config.json, so this holds by
# construction — and a later edit that adds a convenience fallback reds here.
rm -f "$BOX/pithead"
capture_artifacts "closed" "$OUT" >/dev/null 2>&1
ART_CLOSED="$(cat "$OUT/closed/config.json" 2>/dev/null)"
case "$ART_CLOSED" in
*"$NTFY_TOPIC"*) it_fail "an unreachable masking program captures no config, not the raw one" "raw capability value was captured when the program was gone" ;;
*) it_pass "an unreachable masking program captures no config, not the raw one" ;;
esac

echo "selftest-capture-config: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
