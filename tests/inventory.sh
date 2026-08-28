#!/usr/bin/env bash
#
# Generate a coverage inventory across every test suite in the repo and print it as Markdown.
# Answers "what is covered" (issue #54). `make test-inventory` runs this and writes
# docs/dev/test-inventory.md — a generated, git-ignored file you read on demand (#414).
#
# Static (grep-based): no test run, no dependencies, deterministic — so it never drifts from
# whether a daemon/server happens to be available.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Test functions (def test_… / async def test_…) in a python file, in source order.
py_tests() {
    grep -E '^[[:space:]]*(async[[:space:]]+)?def test_' "$1" 2>/dev/null |
        sed -E 's/^[[:space:]]*(async[[:space:]]+)?def (test_[A-Za-z0-9_]+).*/\2/'
}
# test('name' | test("name") cases in a node test file.
node_tests() { grep -oE "test\((['\"])[^'\"]+\1" "$1" 2>/dev/null | sed -E "s/^test\(['\"]//; s/['\"]$//"; }
# `== section ==` headers in a shell suite: the whole line that prints one, `echo "== ` through a
# closing ` =="` at end of line. Both anchors are load-bearing, for opposite reasons.
# Without the leading one, a bare `== [^=]+ ==` matches anywhere in the file and harvests jq
# equality expressions — `(.read_only == true) and (.x ==` — which counted 15 phantom sections
# with unreadable names in test_compose.sh and one more in run.sh.
# Without `[^"]+` between them, a header whose own text contains an `=` is dropped: the older
# `[^=]+` silently lost run.sh's `role=rig machine` section. Excluding only the quote, rather than
# using `.+`, keeps `=` legal while stopping a greedy match from swallowing two headers that share
# a line into one garbled name. No header carries code after its closing quotes, so ending the
# match at end-of-line is safe.
sh_sections() {
    grep -oE '^[[:space:]]*echo "== [^"]+ =="$' "$1" 2>/dev/null |
        sed -E 's/^[[:space:]]*echo "== //; s/ =="$//'
}
count() { grep -c . 2>/dev/null || true; }

# Print "- name" bullets for each line on stdin.
bullets() { sed 's/^/- /'; }

# --- gather ---------------------------------------------------------------
PY_DASH_FILES=$(find dashboard/tests -name 'test_*.py' | sort)
NODE_FILES=$(find dashboard/tests/frontend -name '*.test.mjs' 2>/dev/null | sort)

n_py_dash=0
for f in $PY_DASH_FILES; do n_py_dash=$((n_py_dash + $(py_tests "$f" | count))); done
n_py_fake=0
for f in tests/integration/fakes/test_*.py; do n_py_fake=$((n_py_fake + $(py_tests "$f" | count))); done
n_node=0
for f in $NODE_FILES; do n_node=$((n_node + $(node_tests "$f" | count))); done
# Every tests/stack suite, not just run.sh — #1105 moves sections out of run.sh into per-domain
# files, and counting the one file made each split shrink the inventory in silence. See the
# per-file drift gate below for why the aggregate zero-check never noticed. The glob is iterated
# directly, never via a word-split string, so a filename containing a space stays one path
# instead of splitting into two nonexistent ones and reporting phantom drift.
n_stack=0
for f in tests/stack/*.sh; do n_stack=$((n_stack + $(sh_sections "$f" | count))); done
# Every tests/integration/selftest*.sh, not just selftest.sh. Makefile and ci.yml both glob these,
# so all of them are run and linted, while counting the one filename published a third of the
# sections and hid the rest (#1388). The self-tests grew from one file to five and the singular
# name never followed. Same enumerate-vs-glob shape the stack aggregate above was fixed for; the
# tell is a gate line naming paths one by one beside a sibling line that globs. The glob is
# iterated directly rather than through a word-split string, for the reason given above it.
n_selftest=0
for f in tests/integration/selftest*.sh; do n_selftest=$((n_selftest + $(sh_sections "$f" | count))); done
n_scen=$(awk -F'\t' 'NF>1{print $1}' <(sed -n '/scenario_matrix() {/,/^EOF/p' tests/integration/scenarios.sh | grep -E '\t') | count)
n_axes=$(grep -cE '=' <(sed -n '/axis_coverage() {/,/^EOF/p' tests/integration/scenarios.sh | grep -E '^[a-z].*='))
n_mini=$(grep -cE 'log "scenario [0-9]' tests/integration/mini-stack/run-mini-stack.sh)

total=$((n_py_dash + n_py_fake + n_node + n_stack + n_selftest + n_scen + n_mini))

# --- drift gate -----------------------------------------------------------
# The gathering above is grep-based, so a suite that moves, renames, or changes shape
# enumerates as zero without erroring. Fail loudly instead of emitting an inventory that
# silently under-counts — CI runs this on every PR (#981).
# ponytail: zero-count is the only drift detectable since #414 untracked the generated file;
# per-suite freshness would need the file back under git and its merge conflicts with it.
for c in n_py_dash n_py_fake n_node n_stack n_selftest n_scen n_axes n_mini; do
    if [ "${!c:-0}" -eq 0 ]; then # :-0 — grep -c on a deleted file emits nothing, not 0
        echo "inventory drift: $c counted 0 tests — a suite moved or its shape changed;" \
            "update the matching pattern in tests/inventory.sh" >&2
        exit 1
    fi
done

# Per-FILE zero check for the stack suites. The aggregate above cannot see a single suite go
# dark: 22 files summing to 281 sections stay comfortably non-zero when any one of them drops to
# nothing, which is exactly the drift a #1105 split causes. Counting only run.sh had already hidden
# 162 sections before this was caught, and the aggregate never complained once.
# What this does NOT catch: a file that shrinks without reaching zero. A suite going from 11
# sections to 1 still passes here.
# It also cannot catch a file that VANISHES — the glob simply stops matching it — and nothing else
# catches that either, which is why the source-target check below exists. run.sh runs under
# `set -uo pipefail` with NO `-e`, so `source` of a missing file prints to stderr and execution
# CONTINUES with $FAIL still 0; run.sh's tail exits on the $FAIL counter alone, so the suite goes
# green having silently skipped every assertion in the missing file. Verified, not assumed.
# Three files carry no section header by design, each for its own reason:
#   lib.sh                        — a library of fixtures and helpers; it holds no assertions
#   test_compose.sh               — its cases are jq filters over docker-compose.yml, not sections
#   test-control-add-only-ssrf.sh — split out of a run.sh section whose header stayed behind
SECTIONLESS="lib.sh test_compose.sh test-control-add-only-ssrf.sh"
for f in tests/stack/*.sh; do
    case " $SECTIONLESS " in *" ${f#tests/stack/} "*) continue ;; esac
    if [ "$(sh_sections "$f" | count)" -eq 0 ]; then
        echo "inventory drift: $f has no '== section ==' header — it moved, was renamed, or" \
            "changed shape; fix the file, or add it to SECTIONLESS with a reason" >&2
        exit 1
    fi
done

# The same per-FILE check for the harness self-tests, and it is the half the aggregate above cannot
# do. Now that n_selftest globs, one self-test dropping to zero sections hides inside a comfortably
# non-zero sum exactly as a stack suite did — the aggregate can see a whole tier go dark and never a
# single file. Every self-test carries headers today, so there is no SECTIONLESS counterpart here;
# if one ever legitimately has none, give it one rather than adding an exception, since these files
# exist to be enumerated.
for f in tests/integration/selftest*.sh; do
    if [ "$(sh_sections "$f" | count)" -eq 0 ]; then
        echo "inventory drift: $f has no '== section ==' header — it moved, was renamed, or" \
            "changed shape; fix the file, or fold it into a sibling self-test" >&2
        exit 1
    fi
done

# run.sh's `source` line and the file it names have to agree, and they can disagree in EITHER
# direction. Both ways end identically: `source` of a missing file does not stop run.sh (see
# above), so the suite goes green having skipped every assertion in that domain, and neither the
# aggregate nor the per-file gate can see it. The hyphen-named domain files have no standalone CI
# invocation of their own — the underscore-named test_*.sh suites do, and fail their own step — so
# for them these two checks are the whole safety net. Both read one SOURCED list, so the pattern
# cannot drift between them, and a pattern that stops matching cannot quietly satisfy both loops at
# once: direction 2 compares the list against the files on disk and reports how many are missing.
#
# The pattern is anchored to the start of the line and admits no `#` ahead of the `source`, and
# that is the load-bearing half: without it a commented-out `# source "$HERE/x.sh"` reads here as
# a live one, so the file counts as sourced while run.sh never runs it — the same silent skip by
# another route, and the likeliest thing for a conflict resolution to leave behind. It does not
# require `source` to open the line, deliberately: #1400 put a guard prefix on every domain
# stanza, and a pattern that only matched a bare `source` stopped seeing 24 of the 25. What stays
# out of reach is a line that is live text but dead code: a `source` inside a branch that never
# runs, or inside a function nothing calls, still reads as present. Telling those apart needs
# control flow rather than grep, and is not claimed.
SOURCED=$(grep -oE '^[^#]*source "\$HERE/[A-Za-z0-9_.-]+\.sh"' tests/stack/run.sh |
    sed -E 's|^.*source "\$HERE/||; s|"$||')
# The domain files run.sh is expected to source: every tests/stack/*.sh but the sourcer itself and
# the suites that carry their own CI step and fail there. Hoisted above both directions because the
# floor below needs its size, and both loops need its membership.
# Not sourced by run.sh, by design — each is invoked as its own CI step and fails there:
UNSOURCED="test_appliance_hugepages.sh test_compose.sh test_data_reset.sh \
    test_firstboot_journal.sh test_os_update_recovery.sh"
EXPECTED=""
for f in tests/stack/*.sh; do
    base="${f#tests/stack/}"
    if [ "$base" = "run.sh" ]; then continue; fi # the sourcer itself
    case " $UNSOURCED " in *" $base "*) continue ;; esac
    EXPECTED="${EXPECTED}${base}"$'\n'
done

# Direction 1 (#1336) — every file run.sh claims to source must exist. Catches a domain file
# deleted or renamed out from under a live `source` line.
while read -r want; do
    # A here-string over an empty SOURCED yields ONE blank line, not zero, so without this the
    # loop would test `tests/stack/` and report a garbled name for a pattern that matched nothing.
    if [ -z "$want" ]; then continue; fi
    if [ ! -f "tests/stack/$want" ]; then
        echo "inventory drift: run.sh sources tests/stack/$want, which does not exist — the file" \
            "was moved or renamed and the suite would still pass, silently skipping it" >&2
        exit 1
    fi
done <<<"$SOURCED"

# Direction 2 (#1357) — every domain file on disk must be sourced. The loop above can only examine
# the `source` lines that are PRESENT, so a line deleted while its file stays on disk is never
# looked at; the per-file section gate then finds the orphaned file with its headers intact and
# passes it. Nothing else asks the question in this direction.
#
# This is a FLOOR, not an emptiness test, and it collects rather than exiting on the first offender
# (#1420). It used to be guarded by `[ -z "$SOURCED" ]`, on the reasoning that the pattern going
# quiet must not read as "all present" — and that guard failed open on a real 24-of-25 breakage,
# because lib.sh's stanza is bare by design and kept matching. A fallback condition of "the set is
# empty" is defeated by a single survivor. Comparing the two sets makes one survivor as loud as
# none. Exiting on the first offender was the other half: it named one file, alphabetically first,
# for a 24-file regression, and the reader sizes the problem from that message.
MISSING=""
while read -r base; do
    if [ -z "$base" ]; then continue; fi
    # Matched between newlines, not spaces: a filename containing a space would survive the glob
    # above (it is iterated directly) only to be split apart by a space-delimited lookup here.
    case $'\n'"$SOURCED"$'\n' in *$'\n'"$base"$'\n'*) continue ;; esac
    MISSING="${MISSING}${base}"$'\n'
done <<<"$EXPECTED"
n_missing=$(printf '%s' "$MISSING" | count)
n_expected=$(printf '%s' "$EXPECTED" | count)
# Nothing to compare is itself drift, and it is the ONE case a set-difference floor cannot see. If
# every domain file and every stanza disappear TOGETHER — a botched revert of the #1105 split, or a
# merge that drops the directory — then SOURCED and EXPECTED collapse to empty at the same time,
# MISSING is empty, and the floor above is vacuously satisfied. The emptiness test this floor
# replaced DID catch that, so it is asserted explicitly rather than quietly lost with it. Its own
# sentence, not a share of the floor's: two guards on one string means either can cover for the
# other's deletion.
if [ "$n_expected" -eq 0 ]; then
    echo "inventory drift: tests/stack/ holds no sourced domain files at all — the split's shape" \
        "changed, or the directory was emptied; there is nothing for the drift floor to compare" >&2
    exit 1
fi
if [ "$n_missing" -gt 0 ]; then
    echo "inventory drift: $n_missing of $n_expected domain files on disk are not sourced by" \
        "run.sh — a 'source' line was deleted, or, the closer this count runs to $n_expected, the" \
        "pattern above stopped matching. Either way the suite would still pass, silently skipping" \
        "every section in these files. Restore the line, fix the pattern, or add the file to" \
        "UNSOURCED with a reason:" >&2
    printf '%s' "$MISSING" | sed 's/^/  /' >&2
    exit 1
fi

# --- emit -----------------------------------------------------------------
cat <<EOF
# Test Inventory

_Generated by \`make test-inventory\` ([\`tests/inventory.sh\`](../../tests/inventory.sh)). **Do not
edit by hand** — re-run the target to refresh. See [Testing Strategy](testing-strategy.md) for
how the tiers fit together._

**Totals:** ${n_py_dash} dashboard unit tests · ${n_py_fake} contract tests · ${n_node} frontend
tests · ${n_stack} \`pithead\` shell sections · ${n_selftest} harness self-test sections ·
${n_scen} live config scenarios (${n_axes} axis values) · ${n_mini} mini-stack scenarios.

> Counts are **test functions / named cases** (parametrized pytest cases expand to more at
> run time — e.g. the dashboard suite collects ~381). Generated statically by grep, so it's
> stable regardless of what's installed.

| Tier | Suite | Cases |
|---|---|---|
| 1 — Unit | dashboard pytest | ${n_py_dash} |
| 1 — Unit | frontend (node --test) | ${n_node} |
| 1 — Unit | \`pithead\` shell suite | ${n_stack} sections |
| 1 — Unit | compose interpolation + hardening (#90) | 1 |
| 2 — Contract | fake-daemon clients | ${n_py_fake} |
| 3 — Mini-stack | docker control-plane scenarios | ${n_mini} |
| 4 — Live matrix | config scenarios | ${n_scen} (${n_axes} axis values) |
| 4 — Live matrix | harness self-test | ${n_selftest} sections |

---

## Tier 1 — Unit & component

### Dashboard (pytest) — ${n_py_dash} tests
EOF

for f in $PY_DASH_FILES; do
    n=$(py_tests "$f" | count)
    printf '\n#### %s — %s\n' "${f#dashboard/}" "$n"
    py_tests "$f" | bullets
done

cat <<EOF

### Frontend logic (node --test) — ${n_node} tests
EOF
for f in $NODE_FILES; do node_tests "$f" | bullets; done

cat <<EOF

### \`pithead\` shell suite (tests/stack/) — ${n_stack} sections
EOF
for f in tests/stack/*.sh; do
    n=$(sh_sections "$f" | count)
    if [ "$n" -eq 0 ]; then continue; fi
    printf '\n#### %s — %s\n' "${f#tests/stack/}" "$n"
    sh_sections "$f" | bullets
done

cat <<EOF

### Compose validation + hardening (tests/stack/test_compose.sh)
- docker-compose.yml \`\${VAR}\` interpolation resolves against a representative .env
- #90 hardening invariants: no-new-privileges / cap_drop / read-only roots, credential-free
  healthchecks, least-privilege Docker socket proxies, and the pinned \`pithead\` project name

### Real-image data-reset repair (tests/stack/test_data_reset.sh)
- #1062 on a REAL ext4 image with the system's own e2fsprogs: the superblock-magic damage the
  battery injects is repaired with its payload intact — never reformatted — and a destroyed
  image still reaches the reformat escape
- only \`mount\` is stubbed, and its verdict is \`e2fsck -fn\` on the image itself, never a counter

## Tier 2 — Contract (real clients vs controllable fakes)

### tests/integration/fakes/test_*.py — ${n_py_fake} tests
EOF
for f in tests/integration/fakes/test_*.py; do py_tests "$f"; done | bullets

cat <<EOF

## Tier 3 — Fake-daemon mini-stack (docker)

### tests/integration/mini-stack/run-mini-stack.sh — ${n_mini} scenarios
EOF
grep -oE 'log "scenario [0-9]+: [^"]+"' tests/integration/mini-stack/run-mini-stack.sh |
    sed -E 's/^log "//; s/"$//' | bullets

cat <<EOF

## Tier 4 — Live config matrix (real synced server)

### Config scenarios (tests/integration/scenarios.sh) — ${n_scen}
EOF
sed -n '/scenario_matrix() {/,/^EOF/p' tests/integration/scenarios.sh |
    grep -E $'\t' | awk -F'\t' '{print $1}' | bullets

cat <<EOF

### Axis coverage (every value exercised at least once) — ${n_axes}
EOF
sed -n '/axis_coverage() {/,/^EOF/p' tests/integration/scenarios.sh | grep -E '^[a-z].*=' | bullets

cat <<EOF

### Per-scenario assertions (tests/integration/run.sh)
EOF
grep -hoE '(assert_[a-z_]+|it_pass) "[^"]+"' tests/integration/run.sh |
    sed -E 's/^(assert_[a-z_]+|it_pass) "//; s/"$//' |
    grep -vE '^\$[A-Za-z_]+$' | sort -u | bullets

cat <<EOF

### Harness self-test (tests/integration/selftest*.sh) — ${n_selftest} sections
EOF
for f in tests/integration/selftest*.sh; do sh_sections "$f"; done | bullets

cat <<EOF

---

_Grand total: **${total}** enumerated cases/sections across the four tiers (plus the live
lifecycle and fault-injection phases, which are exercised on a real server)._
EOF
