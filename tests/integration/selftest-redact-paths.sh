#!/usr/bin/env bash
#
# Self-test: every path `render_masked_config` masks is CLASSIFIED by selftest-redact.sh (#1730).
#
# WHY THIS EXISTS. The stack classifies config.json by PATH, in CONTROL_SECRET_PATHS
# (30-release-fetch-and-masked-config.sh) plus three jq array stanzas. selftest-redact.sh
# classifies the same document by a NAME screen over config.reference.json. Two classifications of
# one document, kept by hand, and nothing held them against each other — so they drifted, and the
# drift was found by someone happening to look: `xvb.standby.source` is masked by the product and
# was in none of the self-test's lists, because no suffix in either vocabulary carries the bare
# word `source` (#1723). This file is the check that fires instead of the next person looking.
#
# THE DIRECTION IS ONE-WAY, AND THAT IS DELIBERATE. This asserts product ⊆ self-test, never
# equality. The self-test classifies MORE than the product masks — public endpoints, routing ids —
# and it should; those are the rows a bundle exists to carry. What must not happen is the product
# calling something a secret that the self-test has never heard of, because such a field is
# outside the drift alarm entirely: nothing reds when it changes.
#
# THE POPULATION IS MEASURED, NOT LISTED. A parse of the CONTROL_SECRET_PATHS literal would see 12
# fixed paths and miss all three variable-length array stanzas (workers.list[].token, the
# deprecated dashboard.workers[].token, notifications.webhooks[]), which are masked in jq rather
# than in the list. So this runs the REAL masker over a populated fixture and reads back which
# paths became {"__secret__": true} — 15 of them. The four classification lists are likewise read
# out of selftest-redact.sh rather than restated here; restating them is what drifts.
#
# ⛔ THREE THINGS THAT COST ATTEMPTS — each one silently produces a GREEN.
#
# 1. `render_masked_config` RETURNS 0 WHEN ITS jq FAILS. It warns on stderr, removes the temp
#    file, and falls off the end — so its rc is the warn's. A test that reads that rc passes over
#    a document that was never written, and every "is classified" row below then passes
#    vacuously over an empty population. THE ARMING CONTROL BELOW IS NOT OPTIONAL: assert the
#    ARTIFACT exists and carries the expected number of masked paths, never the rc.
# 2. THE FIXTURE MUST GIVE EACH ARRAY THE ELEMENT TYPE ITS STANZA EXPECTS. workers.list[] and
#    dashboard.workers[] are arrays of OBJECTS — the stanzas do `.token` on each element, so a
#    string element makes jq fail, and per (1) it fails quietly. notifications.webhooks[] is an
#    array of STRINGS. config.reference.json ships all of them EMPTY and so cannot tell you this;
#    it has to be hand-specified, which is the same limitation #1723 hit from the other side.
# 3. DO NOT PIPE THE `source`. `source ./pithead 2>&1 | tail` runs it in a SUBSHELL, so
#    render_masked_config is undefined and CONFIG_FILE reads empty afterwards — which looks
#    exactly like the product being broken. Sourcing is safe (00-prelude.sh:98-101 sets
#    _STACK_SOURCED and skips the cd, the traps and main); EXECUTING ./pithead is the deploy trap.
#
# Every value in the fixture is synthetic.
#
# Run: tests/integration/selftest-redact-paths.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

REPO="$(cd "$HERE/../.." && pwd)"
REF="$REPO/config.reference.json"
CLASSIFIER="$HERE/selftest-redact.sh"

# The paths this fixture populates, in the masked-walk notation. THIS IS THE ARMING CONTROL, and
# it is a SET, not a count: the walk's result is compared against it entry-for-entry, so a masker
# that silently wrote nothing (gotcha 1) or masked a different set cannot leave the containment
# rows passing over an empty or unexpected population. It also makes this list load-bearing — a jq
# stanza added to the product without an entry here reds, rather than arriving unmeasured.
FIXTURE_PATHS="monero.node_username monero.node_password monero.view_key tari.view_key
p2pool.stratum_password xvb.standby.source dashboard.auth.password workers.api_token
healthchecks.ping_url telegram.bot_token notifications.ntfy.url notifications.ntfy.token
workers.list[].token dashboard.workers[].token notifications.webhooks[]"

echo "== render_masked_config's masked paths are all classified by selftest-redact.sh (#1730) =="

BOX="$(mktemp -d)" || {
    it_fail "sandbox" "mktemp -d failed"
    echo "selftest-redact-paths: $IT_PASS passed, $IT_FAIL failed"
    exit 1
}
# EXIT alone. An INT/TERM handler that RETURNS does not die — the run carries on (#1401).
trap 'rm -rf "$BOX"' EXIT

# ⛔ A jq ASSIGNMENT CREATES AN ABSENT PATH, so populating the fixture cannot tell you the schema
# still HAS these leaves — drop `xvb.standby` from config.reference.json and every row below still
# passes, certifying a path the product no longer carries. Measured, not reasoned: that is exactly
# what happened when it was tried. So each populated path's presence is asserted FIRST against the
# shipped schema, and the containment rows below are only as meaningful as this row is green.
MISSING="$(
    python3 - "$REF" "$FIXTURE_PATHS" <<'SCHEMA_PROBE'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
for path in sys.argv[2].split():
    # An array path is present when its CONTAINER is: workers.list[].token -> workers.list.
    probe, node = path.split("[", 1)[0], doc
    for seg in probe.split("."):
        if isinstance(node, dict) and seg in node:
            node = node[seg]
        else:
            print(path)
            break
SCHEMA_PROBE
)"
assert_eq "every path the fixture populates is still in config.reference.json" "${MISSING:-none}" "none"

# The fixture is DERIVED from the shipped schema, then populated at exactly the leaves the masker
# claims, with each array given the element type its stanza expects (gotcha 2). Deriving rather
# than hand-writing means a schema change cannot leave this fixture describing a document the
# product no longer produces.
jq '
    .monero.node_username = "fixture-node-user"
  | .monero.node_password = "fixture-node-pass"
  | .monero.view_key      = "fixture-monero-viewkey"
  | .tari.view_key        = "fixture-tari-viewkey"
  | .p2pool.stratum_password = "fixture-stratum-pass"
  | .xvb.standby.source   = "fixture-standby-source"
  | .dashboard.auth.password = "fixture-dash-pass"
  | .workers.api_token    = "fixture-api-token"
  | .healthchecks.ping_url = "https://hc.example.invalid/fixture-ping"
  | .telegram.bot_token   = "fixture-bot-token"
  | .notifications.ntfy.url   = "https://ntfy.example.invalid/fixture"
  | .notifications.ntfy.token = "fixture-ntfy-token"
  | .workers.list      = [{"name": "w1", "token": "fixture-worker-token"}]
  | .dashboard.workers = [{"name": "w2", "token": "fixture-depr-token"}]
  | .notifications.webhooks = ["https://hook.example.invalid/fixture"]
' "$REF" >"$BOX/config.json" || {
    it_fail "fixture renders" "jq could not populate the fixture from $REF"
    echo "selftest-redact-paths: $IT_PASS passed, $IT_FAIL failed"
    exit 1
}

ln -s "$REPO/pithead" "$BOX/pithead"
CTL="$BOX/control"
mkdir -p "$CTL"

# PITHEAD_CONFIG_FILE must be exported BEFORE the source: 00-prelude.sh:50 makes CONFIG_FILE
# readonly from it, so there is no second chance. Absolute, because a sourced pithead deliberately
# skips the cd to its own dir and a relative path would resolve against OUR cwd.
export PITHEAD_CONFIG_FILE="$BOX/config.json"
# shellcheck disable=SC1091  # the product script, symlinked into the sandbox above
source "$BOX/pithead" >/dev/null 2>&1

if ! declare -F render_masked_config >/dev/null; then
    it_fail "render_masked_config is defined after sourcing ./pithead" \
        "not defined — a piped source would do this (gotcha 3)"
    echo "selftest-redact-paths: $IT_PASS passed, $IT_FAIL failed"
    exit 1
fi
it_pass "render_masked_config is defined after sourcing ./pithead"

# The rc is deliberately DISCARDED. It is 0 whether or not the document was written (gotcha 1);
# the artifact is the only honest witness.
render_masked_config "$CTL" >/dev/null 2>&1
MASKED_DOC="$CTL/masked/config.json"

if [ ! -s "$MASKED_DOC" ]; then
    it_fail "the masker wrote a masked document" \
        "$MASKED_DOC missing or empty — note render_masked_config returns 0 in this case"
    echo "selftest-redact-paths: $IT_PASS passed, $IT_FAIL failed"
    exit 1
fi
it_pass "the masker wrote a masked document"

# Walk the masked document for {"__secret__": true}, in the dotted-with-[] notation
# selftest-redact.sh classifies in, and hold each against that file's four lists. The lists are
# READ OUT OF the classifier, never restated: a copy here would be one more thing to drift.
VERDICTS="$(
    python3 - "$MASKED_DOC" "$CLASSIFIER" <<'PY'
import json, re, sys

masked_doc, classifier = sys.argv[1], sys.argv[2]
src = open(classifier, encoding="utf-8").read()

# The judgement lives in these four names. A masked path in NONE of them is the finding.
LISTS = {}
for name in ("MUST_REDACT", "MUST_SURVIVE", "KNOWN_GAP", "ELEMENT_SHAPE_UNKNOWN"):
    m = re.search(r'^%s="([^"]*)"' % name, src, re.M | re.S)
    if not m:
        print("LISTFAIL %s" % name)
        sys.exit(0)
    LISTS[name] = set(m.group(1).split())

SECRET = {"__secret__": True}

def walk(node, path, out):
    if isinstance(node, dict):
        if node == SECRET:
            out.add(path)
            return
        for k, v in node.items():
            walk(v, "%s.%s" % (path, k) if path else k, out)
    elif isinstance(node, list):
        # Every element of an array collapses to one `[]` path — the notation the classifier uses,
        # and the reason an index never appears in a verdict.
        for item in node:
            walk(item, path + "[]", out)

found = set()
walk(json.load(open(masked_doc, encoding="utf-8")), "", found)
print("COUNT %d" % len(found))

def satisfied_by(p):
    for name, entries in LISTS.items():
        if p in entries:
            return name, p
    # A path inside an array is satisfied by its ENCLOSING [] path being classified: that is what
    # workers.list[].token needs, and precisely what ELEMENT_SHAPE_UNKNOWN means. Only a classified
    # entry ending in [] can enclose anything, so those are the only ones worth testing; the
    # LONGEST match wins, so the verdict names the most specific entry that covers the path.
    best = (None, None)
    for name, entries in LISTS.items():
        for entry in entries:
            if entry.endswith("[]") and p.startswith(entry) and len(entry) > len(best[1] or ""):
                best = (name, entry)
    return best

for p in sorted(found):
    name, entry = satisfied_by(p)
    print("OK %s %s %s" % (p, name, entry) if name else "UNCLASSIFIED %s" % p)
PY
)"

case "$VERDICTS" in
*LISTFAIL*)
    it_fail "the classifier's four lists parse out of selftest-redact.sh" \
        "$(printf '%s' "$VERDICTS" | grep LISTFAIL)"
    ;;
*)
    it_pass "the classifier's four lists parse out of selftest-redact.sh"
    ;;
esac

# ARMING CONTROL. Without it, a masker that wrote a document with nothing masked in it would give
# an empty walk and NO failing rows — a green built on zero measurements. Compared as a SET, so
# the row names WHICH path appeared or vanished, which a count cannot.
WALKED="$(printf '%s\n' "$VERDICTS" | awk '/^(OK|UNCLASSIFIED) /{print $2}' | sort | tr '\n' ' ')"
# shellcheck disable=SC2086  # deliberate word-splitting: FIXTURE_PATHS is a whitespace-separated set
EXPECTED="$(printf '%s\n' $FIXTURE_PATHS | sort | tr '\n' ' ')"
assert_eq "the masker masked exactly the paths this fixture populates" "$WALKED" "$EXPECTED"

while read -r verdict path list entry; do
    case "$verdict" in
    OK)
        if [ "$path" = "$entry" ]; then
            it_pass "$path is classified ($list)"
        else
            it_pass "$path is classified via its enclosing $entry ($list)"
        fi
        ;;
    UNCLASSIFIED)
        it_fail "$path is classified by selftest-redact.sh" \
            "render_masked_config masks it and the self-test has never heard of it — classify it, with a reason, in MUST_REDACT / MUST_SURVIVE / KNOWN_GAP / ELEMENT_SHAPE_UNKNOWN"
        ;;
    esac
done <<EOF
$(printf '%s\n' "$VERDICTS" | grep -E '^(OK|UNCLASSIFIED) ')
EOF

echo "selftest-redact-paths: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
