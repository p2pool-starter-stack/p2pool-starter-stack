# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-runner provisioning domain (#1105 Phase 1, develop-v2 lane): the two sections that prove
# provision_control_runner only ever touches the systemd units belonging to the checkout invoking
# it. The unit names pithead-control.{path,service} are box-global, but a release bench holds
# several checkouts at once — live stack, e2e harness, bundle-smoke temp dirs — so a checkout with
# control disabled used to remove whatever units it found, including the live stack's runner (#33).
# The second half is the install side of the same rule: an existing unit whose ExecStart names a
# foreign directory is left alone and said so, an unparseable ExecStart is left alone, the tool's
# own drifted unit is converged in place, and a bench that wants the steal is given an explicit
# opt-in (#1190).
# Sourced by tests/stack/run.sh.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping.
#
# THIS FILE IS STANDALONE-SOURCEABLE, and that is the correct call here — the OPPOSITE of the
# spool-audit / confirm-approval disclosure precedent, which a reviewer coming from R9 will reach
# for first. Those files are pure CONSUMERS of the shared control sandbox and are position-locked
# by what a sibling section accumulated. This domain is not: it never calls build_control_sandbox
# (grepped: zero in this file, one in test-control-core.sh, where R12 moved the builder call
# out of run.sh), it reads nothing under $C/$RESULTS/$STAGED/$AUDIT,
# and every fixture it needs it builds itself under its own two trees. Run out of position it
# would still assert exactly what it asserts here.
#
# Re-derivations. $SANDBOX and $STACK come from lib.sh, both assigned at COLUMN 1 at top level,
# outside every function body — so neither is the ordering dependency the $WALLET case turned out
# to be. (Re-derive by reading the indent in lib.sh, not by line number.) Every other name is assigned here: $PCR
# and $PCI (the two scratch trees), the pcr_run/pci_run helpers, and $out. Provider functions
# called: assert_contains, assert_eq, assert_not_contains. A word-boundary sweep of all of
# tests/stack/ finds $PCR and $PCI only inside this file — nothing else in the suite reads what
# it creates. (Use a word boundary: a bare $PCR pattern also matches $PCR791 in
# test-appliance-identity.sh, which is a different variable, not a coupling.)

: "${SANDBOX:?}" "${STACK:?}"

echo "== unit: provision_control_runner only removes units this checkout owns (#33) =="
# The pithead-control.{path,service} names are box-global, but a release bench holds several
# checkouts at once (live stack + e2e harness + bundle-smoke tmp dirs). A checkout with control
# disabled used to remove whatever units were installed — including the LIVE stack's runner,
# stranding its dashboard control requests (config editor stuck at "Previewing…"). The removal
# branch keys on the service unit's ExecStart: foreign owner → leave alone; own units → remove;
# a dangling path unit with no service file → still reaped.
PCR="$SANDBOX/pcr"
mkdir -p "$PCR/units" "$PCR/bin"
# uname stub: the OS gate reads `uname -s` at source time; report Linux so the branch runs on dev
# Macs too. systemctl stub satisfies the command -v gate.
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCR/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCR/bin/systemctl"
chmod +x "$PCR/bin/uname" "$PCR/bin/systemctl"

pcr_run() { # <owner-dir|-> <run-dir> — seed units owned by owner-dir ('-' = no service file), run the removal branch from run-dir, echo sudo calls
    rm -f "$PCR/units/pithead-control.service" "$PCR/units/pithead-control.path"
    [ "$1" != "-" ] && printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$PCR/units/pithead-control.service"
    printf '[Path]\nPathExistsGlob=/x/requests/*.json\n' >"$PCR/units/pithead-control.path"
    (
        cd "$2" || exit
        PATH="$PCR/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        sudo() { echo "sudo:$*"; } # record instead of executing; the disable call's output is redirected in-function
        PITHEAD_UNIT_DIR="$PCR/units" DASHBOARD_CONTROL_ENABLED=false provision_control_runner
    )
}

assert_eq "foreign owner -> units left alone (no sudo rm)" "$(pcr_run /srv/code/other-checkout "$PCR")" ""
assert_contains "own units -> removed" "$(pcr_run "$PCR" "$PCR")" \
    "sudo:rm -f $PCR/units/pithead-control.path $PCR/units/pithead-control.service"
assert_contains "dangling path unit (no service file) -> still reaped" "$(pcr_run - "$PCR")" "sudo:rm -f"
# Versioned install dirs carry dots (pithead-v1.9.3). Ownership must compare the ExecStart path
# as an exact string, never a regex: with the dots read as "any char", a sibling whose path
# differs only at those positions would falsely match as our own — and get removed.
mkdir -p "$PCR/v1.9.3" "$PCR/v1x9y3"
assert_eq "foreign owner differing only at regex-dot positions -> left alone" \
    "$(pcr_run "$PCR/v1x9y3" "$PCR/v1.9.3")" ""
# One checkout, two spellings: production units carry the versioned dir in ExecStart, and an
# operator's disable apply runs through the `current` symlink. Ownership compares physical
# paths, so the unit is recognized as our own and removed — a literal $PWD compare would call
# it foreign and the disable would never converge.
mkdir -p "$PCR/versions/pithead-v1.9.3"
ln -s "$PCR/versions/pithead-v1.9.3" "$PCR/current"
assert_contains "own unit under its versioned spelling, run via the current symlink -> removed" \
    "$(pcr_run "$PCR/versions/pithead-v1.9.3" "$PCR/current")" "sudo:rm -f"
unset PCR pcr_run

echo "== unit: provision_control_runner refuses to overwrite a foreign install's units (#1190) =="
# The removal branch above got its ownership check when a disable-apply deleted the live stack's
# units; the INSTALL branch had none — any sibling checkout's apply/up with control enabled
# overwrote the box-global units and silently repointed dashboard control at itself (the
# production-stranding mechanism, this time via install instead of a failed upgrade). The guard:
# foreign owner that still exists on disk → refuse and name it; owner directory gone → adopt
# (that is how a new version takes over from a removed one); own unit → converge; unparseable
# ExecStart → leave alone, fail safe; PITHEAD_STEAL_CONTROL_UNITS=1 → deliberate takeover.
#
# Mutation proof (each ran red against its assertion with the guard intact elsewhere):
#   - drop the `[ -d "$install_owner" ]` conjunct  -> "owner directory gone -> adopted" goes red
#   - flip the `!=` ownership compare to `=`       -> "foreign existing owner -> refused" goes red
#   - drop the PITHEAD_STEAL_CONTROL_UNITS conjunct -> "steal escape -> overwritten" goes red
#   - drop the `steal` argument conjunct           -> "upgrade repoint (steal arg)" goes red
PCI="$SANDBOX/pci"
mkdir -p "$PCI/units" "$PCI/bin" "$PCI/mine" "$PCI/other"
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCI/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCI/bin/systemctl"
chmod +x "$PCI/bin/uname" "$PCI/bin/systemctl"

pci_run() { # <owner-dir|-|garbage> <run-dir> [steal-env] [fn-arg] — seed a service unit, run the INSTALL branch, echo warns + recorded sudo calls
    rm -f "$PCI/units/pithead-control.service" "$PCI/units/pithead-control.path" "$PCI/calls"
    case "$1" in
    -) ;; # no pre-existing units
    garbage) printf '[Service]\nExecStart=/usr/bin/env not-ours\n' >"$PCI/units/pithead-control.service" ;;
    *) printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$PCI/units/pithead-control.service" ;;
    esac
    (
        cd "$2" || exit
        PATH="$PCI/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        # Record instead of executing — into a side file, because the install branch redirects
        # `sudo tee`'s stdout to /dev/null, so an echoing stub would be invisible there.
        sudo() { echo "sudo:$*" >>"$PCI/calls"; }
        PITHEAD_UNIT_DIR="$PCI/units" DASHBOARD_CONTROL_ENABLED=true \
            CONTROL_DIR="$2/data/control" PITHEAD_STEAL_CONTROL_UNITS="${3:-0}" \
            provision_control_runner ${4:+"$4"} 2>&1
        cat "$PCI/calls" 2>/dev/null
    )
}

out="$(pci_run "$PCI/other" "$PCI/mine")"
assert_contains "install: foreign existing owner -> refused, names the owner" "$out" "belong to the install at $PCI/other"
assert_not_contains "install: foreign existing owner -> unit not overwritten" "$out" "sudo:tee"
assert_contains "install: foreign existing owner + steal escape -> overwritten" \
    "$(pci_run "$PCI/other" "$PCI/mine" 1)" "sudo:tee $PCI/units/pithead-control.service"
# The upgrade callsite's spelling: after a successful upgrade the OLD versioned dir still exists
# (it is the rollback), so the converge MUST take the units over — via the `steal` argument, not
# the operator env var. Without it every one-click upgrade would refuse and strand the channel.
assert_contains "install: foreign existing owner + upgrade repoint (steal arg) -> overwritten" \
    "$(pci_run "$PCI/other" "$PCI/mine" 0 steal)" "sudo:tee $PCI/units/pithead-control.service"
assert_contains "install: foreign owner whose directory is gone -> adopted" \
    "$(pci_run "$PCI/long-gone" "$PCI/mine")" "sudo:tee $PCI/units/pithead-control.service"
out="$(pci_run garbage "$PCI/mine")"
assert_contains "install: unparseable ExecStart -> left alone, says so" "$out" "not one this tool wrote"
assert_not_contains "install: unparseable ExecStart -> unit not overwritten" "$out" "sudo:tee"
assert_contains "install: own drifted unit -> converged (rewritten in place)" \
    "$(pci_run "$PCI/mine" "$PCI/mine")" "sudo:tee $PCI/units/pithead-control.service"
assert_contains "install: no units at all -> fresh install unaffected by the guard" \
    "$(pci_run - "$PCI/mine")" "sudo:tee $PCI/units/pithead-control.service"
unset PCI pci_run out
