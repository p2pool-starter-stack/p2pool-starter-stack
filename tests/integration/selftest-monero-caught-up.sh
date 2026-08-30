#!/usr/bin/env bash
#
# Self-test for `monero_caught_up`'s THREE answers (#1605, successor to #1597/#1603).
#
# THE DEFECT WAS ONE BIT OVER SEVERAL DOORS. `monero_caught_up` dials monerod's get_info with
# `curl -fsS … 2>/dev/null` and pipes the body into `jq -e`. Stderr was discarded and the body is
# EMPTY on an unreachable host, a refused connection, a timeout and a 401 alike — so `jq -e` over
# that empty body answered exactly as it does for a node that is genuinely behind. A caller could
# not tell "monerod says it is behind" from "monerod could not be asked", and #1597 established
# that this is most expensive where the bit feeds a SKIP CLASS, because a skip is an accepted hole.
#
# THE FIX IS AN rc, NOT A STRING, and it is deliberately open at the top end:
#
#     0        caught up
#     1        monerod ANSWERED and is not caught up
#     anything else   could not ask
#
# THE `[ -n "$body" ]` GUARD IS REDUNDANT WITH THE `case`, DELIBERATELY, and this is the note that
# stops a later reader deleting it as dead code or trusting it as the only mechanism. Measured:
# `jq -e` over EMPTY input exits 4, which the `case`'s `*)` arm already maps to 2 — so removing the
# guard changes no observable behaviour today. It stays because it states OUR protocol ("no body
# means we were not answered") rather than resting the classification on an entry in jq's exit
# table. The guard acts first, so the mutation that reds the empty-body rows is a mutation of the
# GUARD; the `case` is what would act if it were removed outright.
#
# The open top end is the whole safety argument. An empty body exits 2, but `rx` reaches the box
# over ssh and **ssh exits 255 when the connection itself fails** — so a mapping written as
# `!= 0 -> behind` would have booked an unreachable BOX as a node that is behind, re-creating the
# defect one layer up. Callers therefore test `= 1` for behind and let every other nonzero fall to
# could-not-ask. Part B below asserts that on the SHIPPED call-site lines, rc 255 included.
#
# HOW THIS FILE MEASURES. Part A runs the REAL snippet — `rx` in `IT_MODE=local` against a fake box
# directory, with a fake `curl` on PATH and the REAL `jq`. Nothing about `monero_caught_up` is
# stubbed, so the rows exercise the shipped text rather than a paraphrase of it. Part B lifts the
# two shipped classification lines OUT of run.sh by `grep` and `eval`s them against a stubbed
# predicate; it therefore cannot pass against a run.sh that has been rewritten back to two-valued.
#
# PROVEN ABLE TO FAIL — five mutations, each RE-RUN against the text that actually shipped, and
# each `cmp`-checked against an untouched copy first so a mutation that failed to apply cannot be
# counted as a leg. Measured, not predicted; the row counts are what the runs printed:
#   * lib.sh, revert to the old `printf … | jq -e …` (drop both the empty-body guard and the
#     explicit case)                                 -> 5 rows red, all in Part A (22/5).
#   * lib.sh, `|| exit 2` -> `|| exit 1`             -> 4 rows: the EMPTY-BODY arm only (23/4).
#     STATED, not hidden: those four are one code path behind four outside doors — ONE arm, not
#     four. The non-JSON row survives this leg, which is what proves the two arms are separate.
#   * lib.sh, `*) exit 2` -> `*) exit 1` (route jq's non-1 rcs to behind)
#                                                    -> the non-JSON row, and ONLY it (26/1).
#   * either call site -> `if …; then … else <one reason>; fi`  (re-run after the anchor change)
#                                                    -> that site's "behind and could-not-ask give
#     DIFFERENT reasons" row, and only it (25/1).
#   * site A's `elif [ $? = 1 ]` -> `elif [ $? != 2 ]`, routing 255 to the BEHIND arm and leaving
#     rc 2 alone                                     -> that site's ssh-255 row, and ONLY it (25/1).
#     That leg is what ATTRIBUTES the 255 row to its own arm rather than to the rc-2 row.
#
# The lift anchor is deliberately loose for the same reason — see the note at the grep below.
#
# A separate file because lib.sh and run.sh both sit ON their lint-file-budget ceilings (692 and
# 2551) and this change had to be line-neutral in both; the runner globs `selftest*.sh`
# (Makefile:29), so a new file needs no registration.
#
# Run: tests/integration/selftest-monero-caught-up.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

# ARMING. `lib.sh` refuses to define anything unless its siblings are present, and a `source` whose
# stderr is hidden leaves every function undefined while an absence-based sweep reads CLEAN. Assert
# the subjects EXIST before asserting anything about their behaviour.
for _fn in monero_caught_up rx; do
    if declare -F "$_fn" >/dev/null; then it_pass "armed: $_fn is defined"; else
        it_fail "armed: $_fn is defined" "lib.sh did not define it — every row below would be vacuous"
        echo "selftest-monero-caught-up: ABORTED unarmed"
        exit 1
    fi
done

# --- The fake box -----------------------------------------------------------------------------
# `rx` in local mode is `(cd "$IT_REMOTE_DIR" && bash -c "$snippet")`, so a directory holding a
# .env and a config.json IS a box as far as this function is concerned. `curl` is faked because the
# doors under test are curl's failure modes; `jq` is the REAL one, because the parse is the part we
# are trusting to tell "answered" from "answered false".
BOX="$(mktemp -d)"
FAKEBIN="$BOX/bin"
mkdir -p "$FAKEBIN"
trap 'rm -rf "$BOX"' EXIT

cat >"$FAKEBIN/curl" <<'CURL_EOF'
#!/bin/sh
# Stands in for the dial only. FAKE_CURL_BODY empty + a nonzero rc is what a refused connection, a
# timeout, a 401 under -f and any non-2xx all look like to the caller: no body on stdout.
[ -n "${FAKE_CURL_BODY:-}" ] && printf '%s' "$FAKE_CURL_BODY"
exit "${FAKE_CURL_RC:-0}"
CURL_EOF
chmod +x "$FAKEBIN/curl"

printf 'STACK_VERSION=v1.20.0\n' >"$BOX/.env"
printf '{"monero":{"mode":"local"}}\n' >"$BOX/config.json"

export PATH="$FAKEBIN:$PATH"
export IT_MODE=local
export IT_REMOTE_DIR="$BOX"

# CONTROL ON THE FAKE ITSELF. A fake that is not on PATH, or not executable, would make every
# could-not-ask row pass for the wrong reason — the real curl would dial 127.0.0.1:18081, find
# nothing, and return an empty body too. Prove the fake is the thing answering.
if [ "$(FAKE_CURL_BODY=probe-fake FAKE_CURL_RC=0 curl -fsS http://127.0.0.1:1/x 2>/dev/null)" = "probe-fake" ]; then
    it_pass "control: the fake curl is the one on PATH"
else
    it_fail "control: the fake curl is the one on PATH" "rows below would pass off the real curl's failure"
fi

# `monero_caught_up` with a chosen body/rc from the dial. Prints the rc.
_mcu_rc() { # <curl body> <curl rc>
    FAKE_CURL_BODY="$1" FAKE_CURL_RC="$2" monero_caught_up
    printf '%s' "$?"
}

echo "== monero_caught_up: three answers over the doors that produce them (#1605) =="

# --- Part A: the predicate ----------------------------------------------------------------------
# ATTRIBUTION. Rows 1-3 are the ANSWERED arm and are reached through `jq -e` exactly as before this
# change; they are here so a mutation that makes everything unanswerable cannot read as a pass.
# Rows 4-6 are the arm this issue exists for: all three carry an EMPTY body and differ only in the
# curl rc, which the function never reads — they are one door each on the outside, one code path
# inside, and they are listed separately because the ISSUE names them separately.
assert_rc "synchronized:true is caught up" "$(_mcu_rc '{"status":"OK","synchronized":true,"target_height":800000}' 0)" "0"
assert_rc "target_height 0 is caught up (the --offline disjunct)" "$(_mcu_rc '{"status":"OK","synchronized":false,"target_height":0}' 0)" "0"
assert_rc "answered and behind is 1, not 2" "$(_mcu_rc '{"status":"OK","synchronized":false,"target_height":800000}' 0)" "1"

# The one row that separates "monerod is not there" from "monerod is not OK": a body arrived, so we
# were answered, and the answer is not a synced verdict. It must NOT be filed as could-not-ask.
assert_rc "answered with status != OK is 1 (we were answered)" "$(_mcu_rc '{"status":"BUSY","synchronized":false,"target_height":800000}' 0)" "1"

for _door in "refused:7" "timeout:28" "401 under -f:22"; do
    assert_rc "could not ask (${_door%%:*}) is NOT 1" "$(_mcu_rc '' "${_door##*:}")" "2"
done

# A body that arrived but is not monerod's JSON. MEASURED, not assumed: `jq -e` answers 0 for true,
# 1 for false, 5 for a parse error and 127 when jq is absent — so a mapping of "anything not 0 is
# behind" reports a confident "not synchronized" for a box whose jq is broken or whose endpoint is
# something else entirely. Only 1 means answered-and-behind; every other jq rc is could-not-ask.
# This row shares the `*)` arm with the jq-absent case, which is why that case has no row of its own.
assert_rc "a non-JSON body is could-not-ask, not behind" "$(_mcu_rc 'not json at all' 0)" "2"

# The digest branch is a SECOND copy of the dial (lib.sh:385 vs :386) and the classification sits
# after both, but a future edit could easily fix one and not the other — so exercise it. This needs
# MONERO_NODE_USERNAME present in the box's .env, which is what selects that branch.
printf 'MONERO_NODE_USERNAME=rpcuser\nMONERO_NODE_PASSWORD=rpcpass\n' >>"$BOX/.env"
assert_rc "the authenticated dial classifies could-not-ask too" "$(_mcu_rc '' 7)" "2"
assert_rc "the authenticated dial still answers caught-up" "$(_mcu_rc '{"status":"OK","synchronized":true,"target_height":800000}' 0)" "0"

# --- Part B: the SHIPPED classification lines ---------------------------------------------------
# Lifted out of run.sh by grep rather than restated here. A copy of the mapping written into this
# file would be an assertion sourced from the thing it tests; lifting the real line means a run.sh
# rewritten back to two answers reds these rows instead of silently keeping them green.
_classify() { # <shipped line> <rc monero_caught_up returns>
    MC_RC="$2"
    # shellcheck disable=SC2329  # all three stubs are reached indirectly, by the `eval` below
    (
        monero_caught_up() { return "$MC_RC"; }
        it_pass() { printf 'PASS|%s|\n' "$1"; }
        it_fail() { printf 'FAIL|%s|%s\n' "$1" "${2:-}"; }
        eval "$1"
    )
}

echo "== the shipped call sites, lifted from run.sh and driven over all four rcs =="
for _site in "assert_running_state:monerod reports synced (RPC)" "readiness:Monero is synced (chain reusable by the matrix)"; do
    _name="${_site%%:*}"
    _anchor="${_site#*:}"
    # DELIBERATELY LOOSE: anchored on the call and the row's own label, NEVER on the comparison
    # under test. An anchor carrying `elif [ $? = 1 ]` would make every mutation of the mapping red
    # this presence row instead of the classification rows below — the guard would mask the
    # measurement, and a battery would read as firing while proving nothing about the mapping.
    _line="$(grep -F 'monero_caught_up' "$HERE/run.sh" | grep -F "it_pass \"$_anchor\"")"
    if [ -z "$_line" ]; then
        it_fail "$_name: the call site is present in run.sh" "no monero_caught_up line carrying: $_anchor"
        continue
    fi
    it_pass "$_name: the call site is present in run.sh"

    case "$(_classify "$_line" 0)" in
    PASS*) it_pass "$_name: rc 0 passes the row" ;;
    *) it_fail "$_name: rc 0 passes the row" "got: $(_classify "$_line" 0)" ;;
    esac

    # The DISCRIMINATING pair. Both fail the row — that was already true and is not what is being
    # measured. What is measured is that they fail it for DIFFERENT, TRUE reasons: the old code
    # gave both the "not synchronized" text, which is a false statement about an unreachable node.
    _behind="$(_classify "$_line" 1)"
    _unans2="$(_classify "$_line" 2)"
    _unans255="$(_classify "$_line" 255)"
    for _r in "behind:$_behind" "empty body:$_unans2" "ssh failure:$_unans255"; do
        case "${_r#*:}" in
        FAIL*) it_pass "$_name: ${_r%%:*} fails the row" ;;
        *) it_fail "$_name: ${_r%%:*} fails the row" "got: ${_r#*:}" ;;
        esac
    done
    assert_ne "$_name: behind and could-not-ask give DIFFERENT reasons" "$_behind" "$_unans2"

    # ⛔ THE ROW THIS FILE EXISTS FOR. `rx` returns ssh's own 255 when the BOX is unreachable. Under
    # a `!= 0 -> behind` mapping that is reported as "monerod is not caught up" — a confident false
    # statement about a node nobody managed to contact. It must classify with the empty body.
    assert_eq "$_name: an ssh failure (255) is could-not-ask, NOT behind" "$_unans255" "$_unans2"
done

echo "selftest-monero-caught-up: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
