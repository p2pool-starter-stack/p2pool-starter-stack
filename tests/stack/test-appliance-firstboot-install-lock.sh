# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# firstboot install-path lock wiring (#1482): the wizard's install paths take the mutation lock, and
# take it in the one place that is correct. Sourced by tests/stack/run.sh.
#
# SCOPE, stated so this is not read as duplicating its neighbours. test-lifecycle.sh proves the lock
# MECHANISM — the holder record, the announced wait, the refusal, the rc, the release — and says
# nothing about which verbs are wired to it. test-wizard-setup.sh proves what the wizard DOES and
# says nothing about mutual exclusion. What is asserted here is WIRING and PLACEMENT for the
# firstboot install paths, and nothing about how the lock itself behaves.
#
# THERE ARE THREE INSTALL PATHS, NOT ONE, and that is the finding this file exists to pin. Every
# call to `consume_install_request` erases and repartitions a disk, and `firstboot_wizard` makes
# three of them: the BARE KEEP-REINSTALL (no card, no handoff-ack, no human wait at all), the RIG
# install, and the COORDINATOR install+configure. Wiring only the last would leave a verb that reads
# as locked with two unlocked doors, so the coverage row at the bottom checks all three.
#
# PLACEMENT is the half a plain "does it take the lock" test would miss. `wizard_install_begin` takes
# the window and then writes `$spool/installing` — that marker is the install path's FIRST write, so
# its ABSENCE on a held machine is what pins the acquire above it. Move the acquire below the touch
# and the contended marker row fails; drop the acquire entirely and the contended rc row fails too.
#
# THE WINDOW MUST ALSO CLOSE, and on the failure exits that is load-bearing rather than cosmetic: a
# failed install does `continue` back into the wizard's polling loop, so a leaked hold would wedge
# every later attempt on the same boot. The success exit powers the machine off, where a leak cannot
# be observed by anything — which is exactly why the release rows below drive the FAILURE helper as
# well as the finish helper.
#
# `systemctl` IS OVERRIDDEN AS AN IN-PROCESS SHELL FUNCTION, NEVER A PATH STUB. `wizard_install_finish`
# ends in `systemctl poweroff`; a PATH stub that failed to resolve for any reason would power off the
# machine running the suite. A shell function is looked up before PATH and cannot be bypassed, so the
# real binary is unreachable by construction rather than by convention. `sleep` is overridden in the
# same shells for the same reason of construction, not speed — and deliberately NOT on PATH, because
# the lock holder below depends on a REAL `exec sleep` to keep owning its descriptor.
#
# Re-derivations: $SANDBOX, $STACK, $ROOT, make_stubs and the assert_* helpers come from lib.sh.
# Every other name is assigned here under an FB/fb_ prefix, because this file and its neighbours are
# sourced into ONE shell.

: "${SANDBOX:?}"
: "${STACK:?}"

FB="$SANDBOX/firstboot-lock"
FBSPOOL="$FB/data/firstboot"
FBLOG="$FB/calls.log"
mkdir -p "$FB/bin" "$FBSPOOL"
cp "$STACK" "$FB/pithead"
make_stubs "$FB/bin"

FBFREE="$SANDBOX/firstboot-lock-free.lock" # never held: the positive controls run through it
FBHELD="$SANDBOX/firstboot-lock-held.lock" # held by fb_hold for the contended cases

fb_reset() { # a clean spool before EVERY case: `installing` must be absent for its absence to mean anything
    rm -rf "$FBSPOOL"
    mkdir -p "$FBSPOOL"
    : >"$FBLOG"
}

# Runs one helper in a NESTED subshell so a lock timeout's `exit` cannot take the prober with it,
# then reports the helper's rc. The nested shell owns any descriptor the helper opened, so this
# form deliberately says nothing about whether the window stayed held — fb_window below does that.
fb_rc() { # <lock file> <fn> <args...> -> rc on stdout
    local lk="$1"
    shift
    (
        cd "$FB" || return
        export PITHEAD_LOCK_FILE="$lk" PITHEAD_LOCK_TIMEOUT=1
        PATH="$FB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$FB/pithead"
        set +e
        systemctl() { echo "[systemctl] $*" >>"$FBLOG"; }
        sleep() { :; }
        ("$@") >>"$FBLOG" 2>&1
        echo "$?"
    )
}

# Opens the window with the real helper, CONFIRMS it actually took it, then runs the closing helper
# and reports whether the window came back. The middle step is the point: without it, "released"
# would be indistinguishable from a begin that never armed, and the two read identically.
fb_window() { # <closing fn> <args...> -> begin-did-not-hold | released | still-held
    (
        cd "$FB" || return
        export PITHEAD_LOCK_FILE="$FBFREE" PITHEAD_LOCK_TIMEOUT=1
        PATH="$FB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$FB/pithead"
        set +e
        systemctl() { echo "[systemctl] $*" >>"$FBLOG"; }
        sleep() { :; }
        wizard_install_begin "$FBSPOOL" >>"$FBLOG" 2>&1
        if flock -n "$FBFREE" true 2>/dev/null; then
            echo begin-did-not-hold
            exit 0
        fi
        "$@" >>"$FBLOG" 2>&1
        if flock -n "$FBFREE" true 2>/dev/null; then echo released; else echo still-held; fi
    )
}

# Sets FBHOLDER rather than echoing it: `$(...)` around a function that backgrounds a long-lived
# holder blocks the substitution for that holder's whole lifetime.
FBHOLDER=""
fb_hold() { # <lock file> -> sets FBHOLDER
    local lk="$1" i=0
    : >"$lk"
    (
        exec 9>>"$lk"
        flock -w 20 9 || exit 1
        exec sleep 120
    ) >/dev/null 2>&1 &
    FBHOLDER=$!
    while [ "$i" -lt 200 ]; do
        flock -n "$lk" true 2>/dev/null || break
        sleep 0.05
        i=$((i + 1))
    done
    if flock -n "$lk" true 2>/dev/null; then
        bad "the holder takes the firstboot lock window" "the lock is still free — every contended case below would prove nothing"
    fi
}

echo "== black-box: the fixture arms — uncontended, the install window opens and writes its marker (#1482) =="
# Read both rows here as the controls for their contended twins below.
fb_reset
: >"$FBFREE"
fb_rc_out=$(fb_rc "$FBFREE" wizard_install_begin "$FBSPOOL")
assert_rc "uncontended wizard_install_begin succeeds" "$fb_rc_out" "0"
assert_eq "uncontended wizard_install_begin really writes the installing marker" \
    "$([ -f "$FBSPOOL/installing" ] && echo written)" "written"

echo "== black-box: a held machine refuses the install window and writes nothing (#1482) =="
fb_hold "$FBHELD"

fb_reset
fb_rc_out=$(fb_rc "$FBHELD" wizard_install_begin "$FBSPOOL")
assert_rc "contended wizard_install_begin refuses rather than interleaving with the held window" "$fb_rc_out" "75"
# The marker is the install path's FIRST write, so its absence is what pins the acquire above it —
# not merely above consume_install_request, which is where a symmetry argument would have put it.
assert_eq "contended wizard_install_begin writes NO installing marker" \
    "$([ -f "$FBSPOOL/installing" ] || echo none)" "none"
assert_contains "contended wizard_install_begin names the operation it is waiting on" \
    "$(cat "$FBLOG")" "Another pithead operation is in progress"

kill "$FBHOLDER" 2>/dev/null || true
wait "$FBHOLDER" 2>/dev/null || true

echo "== black-box: both install exits give the window back (#1482) =="
# A failed install continues back into the wizard's polling loop, so a leak here wedges the boot.
fb_reset
assert_eq "wizard_install_failed_page gives the window back" \
    "$(fb_window wizard_install_failed_page "$FBSPOOL" "Install")" "released"
fb_reset
assert_eq "wizard_install_finish gives the window back" \
    "$(fb_window wizard_install_finish docker "Installation complete" "closing line")" "released"
assert_contains "wizard_install_finish really reaches the switch-off it holds the window across" \
    "$(cat "$FBLOG")" "[systemctl] poweroff"

echo "== structural: all three install paths sit behind the window, none excepted (#1482) =="
# STATED AS WHAT IT IS: this row reads the shipped artifact's text, so it proves WIRING COVERAGE and
# not behaviour — the behaviour is proven by the rows above, which drive the real helpers. It exists
# because those rows exercise the helpers directly and would stay green if a call site stopped using
# them. In file order the two tokens must alternate; two consecutive consume_install_request means an
# install path reaches the erase without the window.
fb_tokens=$(awk '/^firstboot_wizard\(\) \{/ { f = 1 } f { print } f && /^\}$/ { exit }' "$STACK" |
    grep -o 'wizard_install_begin\|consume_install_request' | tr '\n' ' ')
# Control: an extractor that matched nothing would make the row below vacuous, so prove it matched.
assert_eq "the artifact scan really found the firstboot install sites" \
    "$([ -n "$fb_tokens" ] && echo found)" "found"
assert_eq "every consume_install_request in firstboot_wizard is opened by wizard_install_begin" \
    "$fb_tokens" \
    "wizard_install_begin consume_install_request wizard_install_begin consume_install_request wizard_install_begin consume_install_request "
