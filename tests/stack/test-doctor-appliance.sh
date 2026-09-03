# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Doctor domain, appliance half (#1105 Phase 1, module 7): engine-aware checks (container_engine /
# docker_boot_enabled), `doctor --json` + support-bundle, the wipe-note surfaced through doctor,
# and the appliance-only control-unit-location and certificate SAN/expiry checks. Sourced by
# tests/stack/run.sh after lib.sh. (Two check_appliance_cert sections — "excludes proxy_net's
# gateway live" and "WARNs when the engine can't be asked" — stay in run.sh: they sit inside, and
# share fixtures with, the appliance certificate MINT/render block (appliance_mint_cert,
# generate_caddyfile's SAN agreement, the re-mint-on-change guard) that isn't otherwise splitting,
# and extracting only the doctor-facing half of that block would fragment it. The map's
# "certificate SAN/expiry" item is still fully covered by the SAN-coverage/expiry section below.)

echo "== unit: engine-aware doctor checks (#77 phase 2) =="
# Same check names and verdict semantics on both engines; PITHEAD_ENGINE pins the appliance.
assert_eq "engine override wins" "$(PITHEAD_ENGINE=podman run_sourced "$SANDBOX" container_engine)" "podman"
assert_eq "engine defaults to docker" "$(run_sourced "$SANDBOX" container_engine)" "docker"
# podman boot persistence = podman.socket enabled (stubbed systemctl says yes for it only).
EBIN="$SANDBOX/engine-stub-bin"
mkdir -p "$EBIN"
printf '#!/bin/bash\n[ "$1" = is-enabled ] && [ "$2" = podman.socket ] && exit 0\nexit 1\n' >"$EBIN/systemctl"
chmod +x "$EBIN/systemctl"
out=$(PITHEAD_ENGINE=podman PATH="$EBIN:$PATH" run_sourced "$SANDBOX" docker_boot_enabled && echo enabled || echo disabled)
assert_eq "podman boot persistence reads podman.socket" "$out" "enabled"
out=$(PITHEAD_ENGINE=docker PATH="$EBIN:$PATH" run_sourced "$SANDBOX" docker_boot_enabled && echo enabled || echo disabled)
assert_eq "docker boot persistence ignores podman.socket" "$out" "disabled"

echo "== black-box: doctor --json + support-bundle (#77 phase 1) =="
# Fresh, uniquely-named sandbox — deliberately NOT the shared $V that build_val_sandbox() (lib.sh,
# module 1b) builds: that sandbox is threaded through every domain file calling the builder —
# config validation, dashboard, secrets and monero/tari among them — all sourced into the same
# shell, so calling it again here would reset the SAME "$SANDBOX/val" directory out from under
# them wherever this file is sourced from. Mirrors build_val_sandbox's body under a non-colliding
# name instead — the same re-derive-locally move module 8 makes for the shared control sandbox.
DJ="$SANDBOX/doctor-json"
mkdir -p "$DJ/build/tari" "$DJ/dashboard"
: >"$DJ/dashboard/Dockerfile"
cp "$STACK" "$DJ/pithead"
make_stubs "$DJ/bin"
cp "$ROOT/build/tari/config.toml.template" "$DJ/build/tari/"
mkdir -p "$DJ/data/monero" "$DJ/data/tari" "$DJ/data/p2pool" "$DJ/data/tor" "$DJ/data/dashboard" "$DJ/data/p2pool/stats"
cat >"$DJ/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$VALID_PRIMARY" >"$DJ/config.json"
(cd "$DJ" && PATH="$DJ/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# doctor --json: valid JSON on stdout, the human report on stderr, counters consistent with the
# check list (info lines are context, not verdicts).
dj_out="$DJ/doctor.json"
dj_err="$DJ/doctor.err"
(cd "$DJ" && PATH="$DJ/bin:$PATH" ./pithead doctor --json >"$dj_out" 2>"$dj_err") || true
assert_eq "doctor --json has checks + summary" "$(jq -r 'has("checks") and has("summary")' "$dj_out" 2>/dev/null)" "true"
assert_eq "doctor --json counters match verdict lines" \
    "$(jq -r '(.summary.ok + .summary.warn + .summary.fail) == ([.checks[] | select(.status != "info")] | length)' "$dj_out" 2>/dev/null)" "true"
assert_contains "doctor --json human report on stderr" "$(cat "$dj_err")" "Diagnostics summary"
out=$(cd "$DJ" && PATH="$DJ/bin:$PATH" ./pithead doctor --bogus 2>&1 || true)
assert_contains "doctor rejects unknown options" "$out" "Unknown option"
# support-bundle: chmod-600 tarball; doctor.json inside; .env secrets redacted by key pattern —
# this sandbox's own PROXY_AUTH_TOKEN must never appear in the bundle.
(cd "$DJ" && PATH="$DJ/bin:$PATH" ./pithead support-bundle >/dev/null 2>&1) || true
sb_tar=$(find "$DJ" -maxdepth 1 -name 'support-bundle-*.tar.gz' | head -1)
assert_contains "support bundle written" "$sb_tar" "support-bundle-"
assert_eq "support bundle is chmod 600" "$(stat -c '%a' "$sb_tar" 2>/dev/null || stat -f '%Lp' "$sb_tar" 2>/dev/null)" "600"
mkdir -p "$DJ/sb-extract"
tar -xzf "$sb_tar" -C "$DJ/sb-extract"
assert_eq "bundle carries doctor.json" "$(jq -r 'has("summary")' "$DJ/sb-extract/bundle/doctor.json" 2>/dev/null)" "true"
assert_contains "bundle .env redacts token keys" "$(cat "$DJ/sb-extract/bundle/env.redacted")" "PROXY_AUTH_TOKEN=[redacted]"
assert_eq "no raw secret value anywhere in the bundle" "$(grep -rc "ORIGINALTOKEN" "$DJ/sb-extract" | grep -vc ":0")" "0"

echo "== unit: check_data_wipe_note — doctor surfaces the wipe note, a support conversation gets the fact (#1121) =="
# Same shape as the pre-seeding block: PITHEAD_PRESEED_DIR stands in for the ESP. Appliance-only
# (the note only ever exists on that channel), so PITHEAD_APPLIANCE has to be forced on here —
# tests run off the appliance.
CDW=$(mktemp -d)
mkdir -p "$CDW/esp"
export PITHEAD_PRESEED_DIR="$CDW/esp"

out=$(PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" check_data_wipe_note 2>&1)
assert_eq "off the appliance -> silent regardless of the note" "$out" ""

out=$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" check_data_wipe_note 2>&1)
assert_eq "no note file -> doctor says nothing (not even a section header)" "$out" ""

printf '2026-08-21T09:00:00Z unrecoverable /data reinitialized — everything on it was lost\n' >"$CDW/esp/pithead-data-wiped"
out=$(PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" check_data_wipe_note 2>&1)
assert_eq "off the appliance -> silent EVEN WITH a note present (a DIY host cannot have one)" "$out" ""

out=$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" check_data_wipe_note 2>&1)
assert_contains "a recovery wipe -> WARN" "$out" "WARN"
assert_contains "the WARN names the date" "$out" "2026-08-21T09:00:00Z"
assert_contains "the WARN points at restoring a backup" "$out" "restore from backup"
assert_not_contains "a recovery wipe is a WARN, never a FAIL (must not fail the boot health gate)" "$out" "FAIL"

printf '2026-08-19T07:30:00Z factory-reset requested\n' >"$CDW/esp/pithead-data-wiped"
out=$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" check_data_wipe_note 2>&1)
assert_not_contains "a deliberate factory-reset -> no WARN (the operator asked for it)" "$out" "WARN"
assert_contains "a deliberate factory-reset -> still named, informationally" "$out" "2026-08-19T07:30:00Z"

unset PITHEAD_PRESEED_DIR
rm -rf "$CDW"
unset CDW out

echo "== unit: doctor sees control units that do not point at this install (#33) =="
# The failure this guards is silent by construction: the dashboard writes control requests into
# its own install's spool, a box-global systemd unit watches some absolute path, and when the two
# disagree nothing reports it — the config editor and one-click upgrade just never complete.
# Seen in the field on a production box: a failed upgrade repointed the units at the half-installed
# tree, and two operator upgrade requests sat unread for a day with no error on either side.
#
# Mutation proof (each assertion below fails if the guard regresses):
#   - drop the `[ "$owner" != "$here" ]` arm      -> "units point elsewhere" goes green->red
#   - flip that `!=` to `=`                        -> mismatch AND aligned assertions both flip
#   - drop the spool comparison arm                -> "watches a different spool" goes red
#   - drop the `-z "$owner"` arm                   -> "no units installed" loses its message
#   - drop the enabled gate's `return 0`           -> "disabled" assertion sees a FAIL
CCU="$SANDBOX/ccu"
mkdir -p "$CCU/units" "$CCU/bin" "$CCU/install" "$CCU/other"
# uname/systemctl stubs: the check gates on Linux + systemctl, so dev Macs run the branch too.
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$CCU/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CCU/bin/systemctl"
chmod +x "$CCU/bin/uname" "$CCU/bin/systemctl"

ccu_run() { # <owner-dir|-> <spool-in-path-unit|-> <enabled> <run-dir> [control-dir-in-env] -> output
    rm -f "$CCU/units/pithead-control.service" "$CCU/units/pithead-control.path"
    [ "$1" != "-" ] && printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$CCU/units/pithead-control.service"
    [ "$2" != "-" ] && printf '[Path]\nPathExistsGlob=%s/requests/*.json\n' "$2" >"$CCU/units/pithead-control.path"
    printf 'DASHBOARD_CONTROL_ENABLED=%s\nCONTROL_DIR=%s\n' "$3" "${5:-$4/data/control}" >"$4/.env"
    (
        cd "$4" || exit
        PATH="$CCU/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        PITHEAD_UNIT_DIR="$CCU/units" check_control_units 2>&1
    )
}

# The production shape: units name a tree that is not this install. Must FAIL, and must name both
# paths — an operator who cannot see which directory is wrong cannot fix it.
out="$(ccu_run "$CCU/other" "$CCU/install/data/control" true "$CCU/install")"
assert_contains "units point elsewhere -> FAIL" "$out" "FAIL"
assert_contains "units point elsewhere -> names the unit's directory" "$out" "$CCU/other"
assert_contains "units point elsewhere -> names this install" "$out" "$CCU/install"

# Aligned: same install, same spool. Must be OK and must NOT fail.
out="$(ccu_run "$CCU/install" "$CCU/install/data/control" true "$CCU/install")"
assert_not_contains "aligned units -> no FAIL" "$out" "FAIL"
assert_contains "aligned units -> OK" "$out" "target this install"

# Control enabled but the units were never installed at all. Assert the DISTINCT message, not just
# that something failed: with no units the owner is empty, so the mismatch arm below would fail on
# its own and an assertion for bare "FAIL" would stay green with this arm deleted — and the operator
# would get "point at , but this install is ..." instead of being told the units are simply missing.
out="$(ccu_run - - true "$CCU/install")"
assert_contains "no units installed -> FAIL naming the real cause" "$out" "no runner units are installed"

# Service unit right, path unit watching someone else's spool: requests are still never read.
out="$(ccu_run "$CCU/install" "$CCU/other/data/control" true "$CCU/install")"
assert_contains "path unit watches a different spool -> FAIL" "$out" "FAIL"

# Control disabled: the units are irrelevant, so a mismatch must NOT be reported as a fault.
out="$(ccu_run "$CCU/other" "$CCU/other/data/control" false "$CCU/install")"
assert_not_contains "control disabled -> no FAIL" "$out" "FAIL"

# The two spellings of one checkout (versioned dir vs the `current` symlink) are the SAME install.
# A literal string compare would call this a mismatch and cry wolf on every production box.
mkdir -p "$CCU/versions/pithead-v1.9.3"
ln -sfn "$CCU/versions/pithead-v1.9.3" "$CCU/current"
# .env and the path unit both carry the versioned spelling, as one render always writes them;
# only the invocation goes through the symlink. The owner compare must resolve both to one install.
out="$(ccu_run "$CCU/versions/pithead-v1.9.3" "$CCU/versions/pithead-v1.9.3/data/control" true \
    "$CCU/current" "$CCU/versions/pithead-v1.9.3/data/control")"
assert_not_contains "versioned dir vs current symlink -> same install, no FAIL" "$out" "FAIL"

# A stranded unit usually names a directory that no longer exists; the check must still resolve a
# printable path and report the mismatch rather than going quiet on an empty answer.
out="$(ccu_run "$CCU/deleted-tree" "$CCU/install/data/control" true "$CCU/install")"
assert_contains "unit names a deleted directory -> still FAILs" "$out" "FAIL"
assert_contains "unit names a deleted directory -> still names it" "$out" "$CCU/deleted-tree"

# The documented layout keeps the PREVIOUS version dir for rollback, and the one-click upgrade runs
# in the browser, so the operator's shell is routinely still sitting in it. The units correctly name
# the live dir there. Calling that box broken would be a cry-wolf FAIL on a healthy install — and
# worse, the printed fix ('apply' from here) would repoint the units at the rollback dir and break
# the live install for real. A superseded version dir must report INFO and no verdict.
# Mutation: delete the `current`-symlink guard in check_control_units -> this goes red (FAIL returns).
mkdir -p "$CCU/deploy/pithead-v1.19.0" "$CCU/deploy/pithead-v1.19.1/data/control"
ln -sfn pithead-v1.19.1 "$CCU/deploy/current"
out="$(ccu_run "$CCU/deploy/pithead-v1.19.1" "$CCU/deploy/pithead-v1.19.1/data/control" true \
    "$CCU/deploy/pithead-v1.19.0" "$CCU/deploy/pithead-v1.19.1/data/control")"
assert_not_contains "superseded rollback dir -> no FAIL (units belong to the live install)" "$out" "FAIL"
assert_contains "superseded rollback dir -> says which dir is live" "$out" "$CCU/deploy/pithead-v1.19.1"
# ...and the live dir itself still gets a real verdict, so the guard cannot silence everything.
out="$(ccu_run "$CCU/deploy/pithead-v1.19.1" "$CCU/deploy/pithead-v1.19.1/data/control" true \
    "$CCU/deploy/pithead-v1.19.1" "$CCU/deploy/pithead-v1.19.1/data/control")"
assert_contains "the live install still gets a verdict" "$out" "target this install"
unset -f ccu_run

echo "== unit: doctor's certificate check — SAN coverage and expiry, appliance-only (#1141) =="
# doctor is the second half of pithead-boot's health gate (#1065 reboots the box on a FAIL), so an
# unreadable/corrupt certificate WARNs rather than FAILs — see check_appliance_cert's own header
# comment for why. A real, openssl-parsed problem (an uncovered host, a genuine expiry date) still
# FAILs. DIY gets no certificate section at all — it serves Caddy's own internal CA, out of scope.
#
# Mutation proof (each assertion below fails if the guard regresses):
#   - drop the SAN-coverage loop entirely      -> "an uncovered name FAILs" goes green->red
#   - drop the -checkend call (always dr_ok)   -> "near-expiry FAILs" goes red
#   - drop the -enddate readability gate       -> "an unreadable cert WARNs, not FAILs" goes red
#   - drop the `is_appliance || return 0` guard -> "DIY gets no certificate section" goes red
#
# docker is stubbed here (never left to the ambient host) so "an uncovered name FAILs" cannot go
# quietly green->WARN on a box with no docker/podman on PATH: 192.168.1.20 is an auto-expanded
# "extra", and since the reboot-leg fix, check_appliance_cert only FAILs on an uncovered extra when
# the engine can confirm BOTH compose bridges — see the dedicated WARN-path test above for the
# unreachable-engine case this test deliberately does NOT exercise.
DAC="$SANDBOX/dac"
mkdir -p "$DAC/tls" "$DAC/bin"
printf '{"dashboard":{"host":"auto"}}' >"$DAC/config.json"
cat >"$DAC/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = network ] && [ "$2" = inspect ] || exit 1
case "$3" in
mining_net) printf '%s' '[{"IPAM":{"Config":[{"Subnet":"172.28.0.0/24","Gateway":"172.28.0.1"}]}}]' ;;
proxy_net) printf '%s' '[{"IPAM":{"Config":[{"Subnet":"172.19.0.0/16","Gateway":"172.19.0.1"}]}}]' ;;
*) exit 1 ;;
esac
EOF
chmod +x "$DAC/bin/docker"
dac_run() { # <appliance rc: 0|1> -> the doctor certificate section's output
    local appliance_rc="$1"
    (
        cd "$DAC" || exit 1
        PATH="$DAC/bin:$PATH"
        export PITHEAD_ENGINE=docker
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return "$appliance_rc"; }
        appliance_tls_dir() { printf '%s' "$DAC/tls"; }
        env_get() {
            case "$1" in
            HOST_IP) printf 'rig1.local' ;;
            *) printf '' ;;
            esac
        }
        hostname() { if [ "${1:-}" = "-I" ]; then printf '192.168.1.20'; else printf 'rig1'; fi; }
        check_appliance_cert 2>&1
    )
}
dac_mint() { # <days> <SANs...> -> writes $DAC/tls/wizard.crt+key
    local days="$1"
    shift
    local alt=""
    for s in "$@"; do alt="${alt:+$alt,}$s"; done
    openssl req -x509 -newkey rsa:2048 -nodes -days "$days" \
        -keyout "$DAC/tls/wizard.key" -out "$DAC/tls/wizard.crt" \
        -subj "/CN=rig1.local" -addext "subjectAltName=$alt" \
        -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
}

rm -f "$DAC/tls/wizard.crt" "$DAC/tls/wizard.key"
out="$(dac_run 0)"
assert_contains "no certificate yet -> informational, not a verdict" "$out" "No dashboard certificate"
assert_not_contains "no certificate yet -> no FAIL" "$out" "FAIL"
assert_not_contains "no certificate yet -> no WARN" "$out" "WARN"

dac_mint 3650 "DNS:rig1.local" "IP:192.168.1.20" "DNS:localhost"
out="$(dac_run 0)"
assert_contains "a matching certificate -> covers every name" "$out" "covers every name"
assert_contains "a matching certificate -> not expiring" "$out" "does not expire within"
assert_not_contains "a matching certificate -> no FAIL" "$out" "FAIL"

dac_mint 3650 "DNS:rig1.local" "DNS:localhost" # 192.168.1.20 dropped — the mutation #1141 names
out="$(dac_run 0)"
assert_contains "an uncovered name -> FAIL" "$out" "FAIL"
assert_contains "an uncovered name -> names it" "$out" "192.168.1.20"

dac_mint 5 "DNS:rig1.local" "IP:192.168.1.20" "DNS:localhost"
out="$(dac_run 0)"
assert_contains "a certificate expiring within 30 days -> FAIL" "$out" "expires within 30 days"

printf 'not a certificate' >"$DAC/tls/wizard.crt"
printf 'not a key' >"$DAC/tls/wizard.key"
out="$(dac_run 0)"
assert_contains "an unreadable certificate -> WARN" "$out" "WARN"
assert_not_contains "an unreadable certificate -> never FAIL (reboot-loop safety, #1065)" "$out" "FAIL"

dac_mint 3650 "DNS:rig1.local" "IP:192.168.1.20" "DNS:localhost"
out="$(dac_run 1)"
assert_eq "DIY (not an appliance) -> no certificate section at all" "$out" ""

unset -f dac_run dac_mint
rm -rf "$DAC"
unset DAC out

echo "== unit: doctor looks for the control units where apply writes them (#1151) =="
# The appliance renders host units into /run/systemd/system — its root is read-only, so /etc cannot
# take the write (#791). `provision_control_runner` knew that; `check_control_units` and
# `control_units_owner_dir` did not, and hard-coded /etc. On a PROVISIONED appliance doctor
# therefore reported "no runner units are installed" about units that were installed and running.
# That is the doctor half of the boot health gate: it never passed, the slot never committed, the
# dashboard sat on "reboot pending" for ever. Legs 1-3 of the KVM battery cannot see it: they never
# provision the guest, so pithead-boot.service is condition-skipped and the gate never runs at all
# (those legs commit with the harness's own `rauc status mark-good`). Leg 4 is the only leg that
# provisions AND lets the boot gate do the committing.
#
# The defect was TWO rules, not a wrong constant, so this asserts the rule has exactly one home.
assert_eq "appliance -> /run/systemd/system (read-only root, #791)" \
    "$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" control_unit_dir)" "/run/systemd/system"
assert_eq "DIY host -> /etc/systemd/system" \
    "$(PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" control_unit_dir)" "/etc/systemd/system"
assert_eq "an explicit PITHEAD_UNIT_DIR wins on the appliance" \
    "$(PITHEAD_APPLIANCE=1 PITHEAD_UNIT_DIR=/tmp/u run_sourced "$SANDBOX" control_unit_dir)" "/tmp/u"
assert_eq "an explicit PITHEAD_UNIT_DIR wins on a DIY host" \
    "$(PITHEAD_APPLIANCE=0 PITHEAD_UNIT_DIR=/tmp/u run_sourced "$SANDBOX" control_unit_dir)" "/tmp/u"

# A SECOND copy of the default is how the two rules drifted apart in the first place, and no runtime
# test can see a copy that does not exist yet — so this one is static. Every consumer being bound to
# the rule is covered behaviourally instead: the two readers below, and provision_control_runner by
# the #791 writer assertion further up. (-F: the pattern carries no regex intent.)
# Mutation run: put `unit_dir="${PITHEAD_UNIT_DIR:-/etc/systemd/system}"` back in check_control_units
# -> this goes 0 -> 1 and red.
assert_eq "no second copy of the /etc default survives outside control_unit_dir" \
    "$(grep -cF 'PITHEAD_UNIT_DIR:-/etc/systemd/system' "$STACK")" "0"

# The behavioural half: the readers must actually USE what control_unit_dir returns. /run/systemd/
# system is root-owned, so no tier-1 test can plant a unit in the real appliance directory — the
# path is proven as two links instead:
#   link 1 (above) — control_unit_dir answers /run/systemd/system when is_appliance is true;
#   link 2 (here)  — the readers read whatever it answers, with PITHEAD_UNIT_DIR deliberately
#                    UNSET, so neither can reach the units by the override arm instead.
# check_control_units calls control_units_owner_dir, so one run covers both readers: a reader that
# ignores the helper looks in /etc, finds nothing, and the verdict flips to the "no runner units"
# FAIL — which is #1151 itself.
# Mutation run: `[ -n "${PITHEAD_UNIT_DIR:-}" ] || unit_dir=/etc/systemd/system` inserted after the
# helper call in check_control_units, in control_units_owner_dir, and in both. Each spelling leaves
# every other assertion in the suite green and goes red only here.
ccu_bind() { # <install-dir> -> output. Reuses $CCU's stubs and unit dir; PITHEAD_UNIT_DIR never set.
    printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$CCU/units/pithead-control.service"
    printf '[Path]\nPathExistsGlob=%s/data/control/requests/*.json\n' "$1" >"$CCU/units/pithead-control.path"
    printf 'DASHBOARD_CONTROL_ENABLED=true\nCONTROL_DIR=%s/data/control\n' "$1" >"$1/.env"
    (
        cd "$1" || exit
        PATH="$CCU/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        unset PITHEAD_UNIT_DIR
        # Stands in for the appliance's /run/systemd/system, which this tier cannot write to.
        control_unit_dir() { printf '%s' "$CCU/units"; }
        check_control_units 2>&1
    )
}
out="$(ccu_bind "$CCU/install")"
assert_contains "the readers find units only control_unit_dir knows the directory of" "$out" "target this install"
assert_not_contains "...and report no fault for units that are correctly installed" "$out" "FAIL"
unset -f ccu_bind
unset CCU out
