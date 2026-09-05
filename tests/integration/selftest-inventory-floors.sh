#!/usr/bin/env bash
#
# Self-test for tests/inventory.sh's aggregate FLOOR gate (#1812). #1808 gave the eight aggregate
# counters real floors instead of a zero test; the evidence that a floor FIRES was a mutation
# battery run once against that PR, and nothing re-ran it. A passing gate never demonstrates the
# one property worth pinning here — that it can still fail — so this file drives the gate and
# asserts BOTH answers.
#
# The lever: tests/inventory.sh resolves its own ROOT from ${BASH_SOURCE[0]}, not from the caller's
# cwd, so a COPY of it inside a sandbox counts that sandbox's files. The floors are read out of the
# gate rather than restated here, so a floor that moves is still the floor under test and this file
# never has to be bumped alongside it; a counter the gate declares and this file has no fixture for
# FAILS loudly rather than being skipped, which is the needle-gap shape #1777 is about.
#
# Standalone (not sourced by selftest.sh) so it carries no other file's budget. Run directly, or via
# `make test-integration-selftest`. No server, no docker, no network.
#
# NOT COVERED, deliberately: the per-file section gates and check_source_agreement further down
# tests/inventory.sh. The arming control below proves the fixture clears the WHOLE gate rc 0, so a
# seeded leg's red is attributable to the one counter it moved — but those other guards get no
# seeded leg of their own here, and #1420's own history is the argument that they deserve one.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

INV="$HERE/../inventory.sh"
TAB=$(printf '\t')
# tests/stack/run.sh plus the 20 domain files the stack pair's floor of 20 demands; the per-file
# section gate wants a header in each, so the fixture cannot render fewer stack sections than this.
STACK_DOMAINS=20
STACK_MIN=$((STACK_DOMAINS + 1))

SB_ROOT=""
cleanup() {
    if [ -n "$SB_ROOT" ]; then rm -rf "$SB_ROOT"; fi
}
# EXIT alone (#1401): an INT/TERM handler that RETURNS lets the run carry on.
trap cleanup EXIT
SB_ROOT="$(mktemp -d)" || {
    echo "selftest-inventory-floors: mktemp -d failed" >&2
    exit 1
}
[ -d "$SB_ROOT" ] || {
    echo "selftest-inventory-floors: mktemp -d returned no directory" >&2
    exit 1
}

# The gate's own declared (counter:floor) list, read from the source rather than copied.
PAIRS_RAW="$(sed -n 's/^for pair in \(.*\); do$/\1/p' "$INV")"
read -ra PAIRS <<<"$PAIRS_RAW"

floor_of() { # <counter> -> its declared floor
    local c="$1" p
    for p in "${PAIRS[@]}"; do
        if [ "${p%%:*}" = "$c" ]; then
            printf '%s' "${p##*:}"
            return 0
        fi
    done
    return 1
}

# Render <n> sections across run.sh + the domain files, one each so the per-file gate is satisfied
# and the remainder in the first, and have run.sh source every one of them.
emit_stack() { # <sandbox> <total sections over tests/stack/*.sh>
    local sb="$1" n="$2" i base
    printf 'echo "== stack run =="\n' >"$sb/tests/stack/run.sh"
    for i in $(seq 1 "$STACK_DOMAINS"); do
        base="$(printf 'd%02d' "$i")"
        printf 'source "$HERE/%s.sh"\n' "$base" >>"$sb/tests/stack/run.sh"
        printf 'echo "== %s =="\n' "$base" >"$sb/tests/stack/$base.sh"
    done
    if [ "$n" -gt "$STACK_MIN" ]; then
        seq "$((STACK_MIN + 1))" "$n" | sed 's/^/echo "== x/; s/$/ =="/' >>"$sb/tests/stack/d01.sh"
    fi
}

# scenarios.sh carries two counters, so it is written once from both.
emit_scenarios() { # <sandbox> <n_scen> <n_axes>
    local sb="$1" ns="$2" na="$3"
    {
        printf 'scenario_matrix() {\ncat <<EOF\n'
        seq 1 "$ns" | sed "s/^/st/; s/\$/${TAB}v/"
        printf 'EOF\n}\n'
        printf 'axis_coverage() {\ncat <<EOF\n'
        seq 1 "$na" | sed 's/^/axis/; s/$/=v/'
        printf 'EOF\n}\n'
    } >"$sb/tests/integration/scenarios.sh"
}

# tests/integration/run.sh must source every non-excluded *.sh beside it, and there must be at
# least the pair's floor of 5 of them.
emit_integration_sourcer() { # <sandbox>
    local sb="$1" i
    printf 'source "$HERE/scenarios.sh"\n' >"$sb/tests/integration/run.sh"
    for i in 1 2 3 4; do
        printf 'source "$HERE/dom%d.sh"\n' "$i" >>"$sb/tests/integration/run.sh"
        : >"$sb/tests/integration/dom$i.sh"
    done
}

emit_counter() { # <sandbox> <counter> <n>; rc 1 = no fixture for this counter
    local sb="$1" c="$2" n="$3"
    case "$c" in
    n_py_dash) seq 1 "$n" | sed 's/^/def test_/; s/$/():/' >"$sb/dashboard/tests/test_gen.py" ;;
    n_py_fake) seq 1 "$n" | sed 's/^/def test_/; s/$/():/' >"$sb/tests/integration/fakes/test_gen.py" ;;
    n_node) seq 1 "$n" | sed 's/^/test("c/; s/$/");/' >"$sb/dashboard/tests/frontend/gen.test.mjs" ;;
    n_selftest) seq 1 "$n" | sed 's/^/echo "== s/; s/$/ =="/' >"$sb/tests/integration/selftest-gen.sh" ;;
    n_mini) seq 1 "$n" | sed 's/^/log "scenario /; s/$/"/' >"$sb/tests/integration/mini-stack/run-mini-stack.sh" ;;
    n_stack) emit_stack "$sb" "$n" ;;
    n_scen) SCEN_N="$n" ;;
    n_axes) AXES_N="$n" ;;
    *) return 1 ;;
    esac
}

# Build a tree in which every declared counter sits exactly ON its floor, except <low> which sits
# one BELOW it. With no <low> the fixture is the arming control: it must clear the gate outright.
build_fixture() { # <sandbox> [low counter]; rc 1 = a declared counter has no fixture here
    local sb="$1" low="${2:-}" p c want
    mkdir -p "$sb/tests/stack" "$sb/tests/integration/fakes" \
        "$sb/tests/integration/mini-stack" "$sb/dashboard/tests/frontend" || return 1
    cp "$INV" "$sb/tests/inventory.sh" || return 1
    SCEN_N=0
    AXES_N=0
    for p in "${PAIRS[@]}"; do
        c="${p%%:*}"
        want="${p##*:}"
        if [ "$c" = "$low" ]; then want=$((want - 1)); fi
        emit_counter "$sb" "$c" "$want" || return 1
    done
    emit_scenarios "$sb" "$SCEN_N" "$AXES_N"
    emit_integration_sourcer "$sb"
}

# Only stderr is captured: the gate writes its inventory to stdout on every run, pass or fail.
GATE_RC=0
GATE_ERR=""
run_gate() { # <path to an inventory.sh>
    GATE_ERR="$(bash "$1" 2>&1 >/dev/null)"
    GATE_RC=$?
}

echo "== the floor gate declares counter:floor pairs this file can read (#1812) =="
# An enumeration over an empty list passes every later assertion without measuring anything, so the
# parse is asserted before it is trusted, and each parsed name is checked to be a counter the gate
# actually assigns rather than whatever a drifted pattern happened to catch.
if [ "${#PAIRS[@]}" -gt 0 ]; then
    it_pass "the drift gate's floor list parses (${#PAIRS[@]} pairs)"
else
    it_fail "the drift gate's floor list parses" \
        "no 'for pair in ...; do' line in $INV — the loop moved or changed shape, and every" \
        "assertion below would pass over an empty list"
fi
for pair in "${PAIRS[@]}"; do
    counter="${pair%%:*}"
    if grep -qE "^${counter}=" "$INV"; then
        it_pass "$counter is a counter the gate assigns, not a stray parse"
    else
        it_fail "$counter is a counter the gate assigns, not a stray parse" \
            "nothing in $INV assigns $counter — the floor list parse caught the wrong line"
    fi
done

echo "== the real tree clears the floor gate — the instrument can say PASS (#1812) =="
# Without this the seeded legs below prove only that something reds; a check that has not been
# shown able to give the other answer is not evidence.
run_gate "$INV"
assert_rc "the repo's own tree passes tests/inventory.sh" "$GATE_RC" 0
case "$GATE_ERR" in
*"inventory drift:"*)
    it_fail "the repo's own tree reports no drift" "stderr carried a drift message: $GATE_ERR"
    ;;
*) it_pass "the repo's own tree reports no drift" ;;
esac

echo "== the fixture clears every floor before any counter is seeded — arming control (#1812) =="
# If the fixture were short of a floor for its own reasons, every seeded leg below would red for
# the wrong reason and the enumeration would look like proof. This is the leg that makes each red
# attributable to the ONE counter that moved.
STACK_FLOOR="$(floor_of n_stack || printf '0')"
if [ "$STACK_FLOOR" -gt "$STACK_MIN" ]; then
    it_pass "the n_stack floor ($STACK_FLOOR) leaves room for the fixture's $STACK_MIN stack files"
else
    it_fail "the n_stack floor ($STACK_FLOOR) leaves room for the fixture's $STACK_MIN stack files" \
        "the floor no longer clears one section per stack file, so the fixture cannot satisfy the" \
        "per-file section gate — lower STACK_DOMAINS in this file to match"
fi
SB_ARM="$SB_ROOT/arm"
if build_fixture "$SB_ARM"; then
    run_gate "$SB_ARM/tests/inventory.sh"
    assert_rc "the unseeded fixture passes the whole gate" "$GATE_RC" 0
    assert_eq "the unseeded fixture reports nothing on stderr" "$GATE_ERR" ""
else
    it_fail "the unseeded fixture builds" \
        "a counter in the gate's floor list has no fixture in this file — add one to emit_counter;" \
        "leaving it out is the needle gap that lets a new counter go unproven"
fi

echo "== every declared floor reds, naming its counter, when that counter falls below it (#1812) =="
# One leg per declared floor. The pair differs from the arming control by exactly one variable, and
# the assertion is on the MESSAGE, not just the rc: a non-zero rc alone would be satisfied by the
# fixture failing to build at all.
for pair in "${PAIRS[@]}"; do
    counter="${pair%%:*}"
    floor="${pair##*:}"
    seeded="$SB_ROOT/low-$counter"
    if ! build_fixture "$seeded" "$counter"; then
        it_fail "$counter below its floor of $floor reds" \
            "the fixture for $counter could not be built"
        continue
    fi
    run_gate "$seeded/tests/inventory.sh"
    assert_ne "$counter at $((floor - 1)) exits non-zero" "$GATE_RC" 0
    assert_contains "$counter at $((floor - 1)) is named in the gate's own message" \
        "$GATE_ERR" "inventory drift: $counter counted $((floor - 1)), floor $floor"
done

echo ""
echo "selftest-inventory-floors: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
