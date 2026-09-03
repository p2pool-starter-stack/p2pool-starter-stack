# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Doctor domain (#1105 Phase 1, module 7): the doctor/status/exposure checks that run against a
# throwaway sandbox with no shared control/config state — is_public_ip and check_stratum_exposure
# (the classifier feeds doctor's own exposure warning, same dual setup/doctor reasoning module 6
# used for the release-signing split), doctor's runtime checks (egress firewall, stratum
# listening, dashboard probe, Tor clearnet egress), the upgrade-readiness and Monero-sync checks,
# clock_sync_status, the grouped disk-space check, `status`, doctor's exit code, and doctor's onion
# report. Sourced by tests/stack/run.sh after lib.sh. (Appliance-only doctor checks — engine-aware
# checks, --json/support-bundle, certificate SAN/expiry, control-unit location, the wipe note —
# live in test-doctor-appliance.sh instead.)

echo "== unit: is_public_ip classifier (#113) =="
# Globally-routable -> rc 0 (public). Includes boundaries just OUTSIDE each excluded range.
for ip in 8.8.8.8 1.1.1.1 172.15.0.1 172.32.0.1 100.128.0.1 169.1.1.1 2606:4700:4700::1111 2001:db8::1; do
    run_sourced "$SANDBOX" is_public_ip "$ip" >/dev/null 2>&1
    assert_rc "public: $ip" "$?" "0"
done
# Private / loopback / link-local / CGNAT / ULA / multicast / unspecified / garbage -> rc 1.
for ip in 10.0.0.5 172.16.0.1 172.31.255.1 192.168.1.50 127.0.0.1 169.254.1.1 100.64.0.1 0.0.0.0 \
    ::1 fe80::1 fc00::1 fd12:3456::1 ff02::1 999.1.1.1 not-an-ip ""; do
    run_sourced "$SANDBOX" is_public_ip "$ip" >/dev/null 2>&1
    assert_rc "non-public: ${ip:-<empty>}" "$?" "1"
done

echo "== unit: check_stratum_exposure warning (#113/#206) =="
# The classifier above is unit-tested; this exercises the WARNING COMPOSITION that uses it —
# the bind × public-IP × mode matrix that #206 wanted live-validated. We shadow `ip` with a stub
# emitting canned `ip -o addr show` lines, so the host's real interfaces never decide the outcome.
# STRATUM_BIND is read straight from the env when set, so no .env is needed.
IPBIN="$SANDBOX/ipbin"
mkdir -p "$IPBIN"
make_ip_stub() { # $1 = body for `ip -o addr show`
    {
        printf '#!/usr/bin/env bash\n'
        printf 'cat <<'\''ADDRS'\''\n%s\nADDRS\n' "$1"
    } >"$IPBIN/ip"
    chmod +x "$IPBIN/ip"
}
PUBLIC_IFACE='2: eth0    inet 8.8.8.8/24 scope global eth0'
PRIVATE_IFACE='1: lo    inet 127.0.0.1/8 scope host lo
2: eth0    inet 192.168.1.5/24 scope global eth0'

# Exposed: a public IP on an interface AND stratum on the default all-interfaces bind -> warn.
make_ip_stub "$PUBLIC_IFACE"
out="$(STRATUM_BIND=0.0.0.0 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure setup 2>&1)"
assert_contains "setup warns: public IP + 0.0.0.0 bind" "$out" "public IP"
out="$(STRATUM_BIND=0.0.0.0 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure doctor 2>&1)"
assert_contains "doctor WARNs: public IP + 0.0.0.0 bind" "$out" "WARN"

# No public IP on any interface -> quiet in setup; an explicit OK in doctor.
make_ip_stub "$PRIVATE_IFACE"
out="$(STRATUM_BIND=0.0.0.0 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure setup 2>&1)"
assert_eq "setup is quiet: no public IP" "$out" ""
out="$(STRATUM_BIND=0.0.0.0 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure doctor 2>&1)"
assert_contains "doctor OK: no public IP" "$out" "No public IP"

# Narrowed bind short-circuits BEFORE the IP check (public stub present): quiet setup / OK doctor.
make_ip_stub "$PUBLIC_IFACE"
out="$(STRATUM_BIND=192.168.1.5 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure setup 2>&1)"
assert_eq "setup is quiet: bind narrowed to a LAN IP" "$out" ""
out="$(STRATUM_BIND=192.168.1.5 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure doctor 2>&1)"
assert_contains "doctor OK: bind narrowed to a LAN IP" "$out" "not all interfaces"

echo "== unit: doctor runtime checks — egress firewall / stratum listening / dashboard probe (#383) =="
# Each check degrades to an info skip on every can't-check path and only judges what it confirmed.
# Stub the whole toolchain: docker answers the running-container filter from RUNNING_CONTAINERS,
# sudo denies via SUDO_DENY or execs through to the iptables stub (tag presence via IPT_TAGGED),
# ss prints SS_OUT, curl exits CURL_RC.
DRBIN="$SANDBOX/drbin"
mkdir -p "$DRBIN"
cat >"$DRBIN/docker" <<'EOF'
#!/usr/bin/env bash
name=$(printf '%s' "$*" | sed -n 's/.*name=\^\([a-z0-9-]*\)\$.*/\1/p')
case " ${RUNNING_CONTAINERS:-} " in *" $name "*) echo cid123 ;; esac
exit 0
EOF
cat >"$DRBIN/sudo" <<'EOF'
#!/usr/bin/env bash
[ "${SUDO_DENY:-0}" = "1" ] && exit 1
[ "$1" = "-n" ] && shift
exec "$@"
EOF
cat >"$DRBIN/iptables" <<'EOF'
#!/usr/bin/env bash
if [ "${IPT_TAGGED:-0}" = "1" ]; then
    echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'
else
    echo '-P DOCKER-USER ACCEPT'
fi
EOF
cat >"$DRBIN/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${SS_OUT:-}"
EOF
cat >"$DRBIN/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${CURL_BODY:-}" ] && printf '%s' "$CURL_BODY"
exit "${CURL_RC:-0}"
EOF
# nft for the podman/netavark doctor path: `list tables` always answers (the sudo-readable probe);
# `list table inet pithead_egress` emits a forward-hooked, dropping ruleset only when NFT_HOOK=1,
# else exits 1 (table absent). Lets a test distinguish "installed & traversed" from "missing".
cat >"$DRBIN/nft" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"list tables") echo "table inet netavark" ;;
"list table inet pithead_egress")
    [ "${NFT_HOOK:-0}" = "1" ] || exit 1
    printf '%s\n' 'table inet pithead_egress {' '  chain forward {' \
        '    type filter hook forward priority -5; policy accept;' \
        '    ip saddr 172.28.0.0/24 drop' '  }' '}' ;;
esac
exit 0
EOF
chmod +x "$DRBIN"/*

# container_is_running: filter answered vs not.
RUNNING_CONTAINERS="tor" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" container_is_running tor
assert_rc "container_is_running: running container" "$?" "0"
RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" container_is_running tor
assert_rc "container_is_running: stopped container" "$?" "1"

# Egress firewall: opted out -> info skip (reads the toggle from .env).
echo "TOR_EGRESS_FIREWALL=false" >"$SANDBOX/.env"
out="$(RUNNING_CONTAINERS="tor" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: opted out -> info" "$out" "opted out"
rm -f "$SANDBOX/.env"
# Stack down (tor not running) -> info skip: rules are legitimately absent after 'down'.
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: stack down -> info" "$out" "isn't running"
# The tor-down-while-mining verdict lives in the dedicated check_tor_running (#563), so the egress
# checks just info-skip when tor is down — they don't double-FAIL the same root cause.
out="$(RUNNING_CONTAINERS="p2pool" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: tor down -> info skip (dedicated check owns the verdict)" "$out" "isn't running"
# check_tor_running: the loud, dedicated privacy-outage verdict.
out="$(RUNNING_CONTAINERS="tor" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_running 2>&1)"
assert_contains "tor-running check: tor up -> OK" "$out" "privacy backbone is up"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_running 2>&1)"
assert_contains "tor-running check: whole stack down -> info" "$out" "stack is down"
out="$(RUNNING_CONTAINERS="p2pool" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_running 2>&1)"
assert_contains "tor-running check: tor down + mining up -> FAIL" "$out" "Tor container is DOWN"
# Running + tagged rules present -> OK.
out="$(RUNNING_CONTAINERS="tor" IPT_TAGGED=1 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: rules installed -> OK" "$out" "installed"
# Running + rules ABSENT -> FAIL (the post-reboot gap this check exists for).
out="$(RUNNING_CONTAINERS="tor" IPT_TAGGED=0 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: rules missing -> FAIL" "$out" "MISSING"
# sudo -n denied -> info skip with the manual command, never a prompt or a false FAIL.
out="$(RUNNING_CONTAINERS="tor" SUDO_DENY=1 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: no passwordless sudo -> info" "$out" "passwordless sudo"

# Podman/netavark doctor path (#855): the check must read the nft table it actually installs, and
# probe the HOOK — the orphaned-chain failure (a DROP no packet reaches) is exactly what a
# forward-hooked base chain can't be, so hook presence is the honest signal, not "a rule exists".
out="$(PITHEAD_ENGINE=podman RUNNING_CONTAINERS="tor" NFT_HOOK=1 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check (podman): forward-hooked drop present -> OK" "$out" "installed"
assert_contains "egress check (podman): OK verdict names nftables" "$out" "nftables"
# Table absent (post-reboot on the appliance, or the old fail-open build) -> FAIL, not a false pass.
out="$(PITHEAD_ENGINE=podman RUNNING_CONTAINERS="tor" NFT_HOOK=0 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check (podman): no nft table -> FAIL" "$out" "MISSING"
# sudo -n denied on the podman path -> info skip (the `list tables` probe tells a sudo refusal apart
# from a genuinely missing table, so it never false-FAILs).
out="$(PITHEAD_ENGINE=podman RUNNING_CONTAINERS="tor" SUDO_DENY=1 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check (podman): no passwordless sudo -> info" "$out" "passwordless sudo"

# Stratum listening: proxy not running -> info (a sync hold must not FAIL).
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: proxy down -> info" "$out" "isn't running"
# Running + a :3333 listener -> OK.
out="$(RUNNING_CONTAINERS="xmrig-proxy" SS_OUT='LISTEN 0 4096 0.0.0.0:3333 0.0.0.0:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: listening -> OK" "$out" "workers can connect"
# An IPv6-only listener ([::]:3333, what ss reports on a dual-stack box) must also read OK —
# pins the ':3333 ' match against the bracketed v6 local-address format.
out="$(RUNNING_CONTAINERS="xmrig-proxy" SS_OUT='LISTEN 0 4096 [::]:3333 [::]:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: IPv6 listener -> OK" "$out" "workers can connect"
# Running + nothing on :3333 -> FAIL.
out="$(RUNNING_CONTAINERS="xmrig-proxy" SS_OUT='LISTEN 0 4096 127.0.0.1:8000 0.0.0.0:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: nothing on :3333 -> FAIL" "$out" "NOTHING is listening"
# A custom p2pool.stratum_port (#172) moves the check: a :3333 listener no longer satisfies it,
# the configured port does.
out="$(RUNNING_CONTAINERS="xmrig-proxy" STRATUM_PORT=4444 SS_OUT='LISTEN 0 4096 0.0.0.0:3333 0.0.0.0:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: custom port not listening -> FAIL" "$out" "NOTHING is listening on :4444"
out="$(RUNNING_CONTAINERS="xmrig-proxy" STRATUM_PORT=4444 SS_OUT='LISTEN 0 4096 0.0.0.0:4444 0.0.0.0:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: custom port listening -> OK" "$out" "Stratum :4444 is listening"

# Dashboard probe: container running + app answers -> OK; running + no answer -> WARN (not FAIL).
out="$(RUNNING_CONTAINERS="dashboard" CURL_RC=0 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_dashboard_answers 2>&1)"
assert_contains "dashboard probe: answers -> OK" "$out" "answers on 127.0.0.1:8000"
out="$(RUNNING_CONTAINERS="dashboard" CURL_RC=22 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_dashboard_answers 2>&1)"
assert_contains "dashboard probe: no answer -> WARN" "$out" "WARN"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_dashboard_answers 2>&1)"
assert_contains "dashboard probe: container down -> info" "$out" "isn't running"

# Tor clearnet-egress probe (#424): a bootstrapped Tor on a failing guard breaks clearnet exits
# (Healthchecks/Telegram/XvB) while mining keeps working — the probe WARNs (never FAILs: Tor
# weather is transient) and points at a tor restart. Skips when tor is down or curl is absent.
out="$(RUNNING_CONTAINERS="tor" CURL_RC=0 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_clearnet_egress 2>&1)"
assert_contains "tor egress probe: exit works -> OK" "$out" "clearnet egress works"
out="$(RUNNING_CONTAINERS="tor" CURL_RC=28 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_clearnet_egress 2>&1)"
assert_contains "tor egress probe: exit times out -> WARN" "$out" "WARN"
assert_contains "tor egress probe: WARN names the fix" "$out" "restart tor"
out="$(
    RUNNING_CONTAINERS="tor" CURL_RC=28 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_clearnet_egress 2>&1
    echo "rc=$?"
)"
assert_contains "tor egress probe: WARN never fails doctor (rc 0)" "$out" "rc=0"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_clearnet_egress 2>&1)"
assert_contains "tor egress probe: tor down -> info skip" "$out" "isn't running"

echo "== unit: doctor answers 'can this box take an upgrade' (#1108) =="
# Each branch mirrors a refusal the one-click upgrade runner makes, so a green line here means the
# runner's preconditions hold. The last branch is the one that did not exist: the verifier is a
# digest-pinned image fetched on demand, and if THAT fetch fails the upgrade reports a *signature*
# failure — an operator reads tampering where the truth is an image the host could not pull (#1084).
DVER="$SANDBOX/doctor-verify"
mkdir -p "$DVER/bin" "$DVER/src/dashboard"
: >"$DVER/src/dashboard/Dockerfile"
printf '1.19.1\n' >"$DVER/VERSION"
printf '1.19.1\n' >"$DVER/src/VERSION"
# A docker whose daemon is up; IMAGE_CACHED decides whether the pinned verifier is already here.
cat >"$DVER/bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
case "$1 $2" in
"info ") exit "${DOCKER_DEAD:-0}" ;;
"image inspect") exit $((1 - ${IMAGE_CACHED:-0})) ;;
esac
exit 0
FAKEDOCKER
chmod +x "$DVER/bin/docker"

# A source checkout cannot take a one-click upgrade at all — the runner refuses it outright.
out="$(PATH="$DVER/bin:$PATH" run_sourced "$DVER/src" check_release_verification 2>&1)"
assert_contains "doctor: a source checkout says one-click does not apply" "$out" "one-click upgrade does not apply"
assert_contains "doctor: a source checkout names the upgrade it CAN take" "$out" "./pithead upgrade"
# A release install predating the first signed release has no key, so nothing is verified.
out="$(PATH="$DVER/bin:$PATH" run_sourced "$DVER" check_release_verification 2>&1)"
assert_contains "doctor: no cosign.pub warns that pulls are unverified" "$out" "WARN"
assert_contains "doctor: no cosign.pub says what is missing" "$out" "No cosign.pub next to pithead"
printf 'fake release public key\n' >"$DVER/cosign.pub"
out="$(DOCKER_DEAD=1 PATH="$DVER/bin:$PATH" run_sourced "$DVER" check_release_verification 2>&1)"
assert_contains "doctor: a dead docker daemon warns rather than claiming verification works" "$out" "WARN"
assert_contains "doctor: the dead-daemon line names the fix" "$out" "Start the Docker daemon"
# The verifier image is present: the box can take an upgrade today.
out="$(IMAGE_CACHED=1 PATH="$DVER/bin:$PATH" run_sourced "$DVER" check_release_verification 2>&1)"
assert_contains "doctor: a cached verifier image reports OK" "$out" "OK"
assert_contains "doctor: the OK line says nothing needs installing" "$out" "nothing to install"
# The verifier image is NOT here yet. MUTATION PROOF: collapse this branch into the OK above and
# "an absent verifier image is not reported as OK" goes red.
out="$(IMAGE_CACHED=0 PATH="$DVER/bin:$PATH" run_sourced "$DVER" check_release_verification 2>&1)"
assert_contains "doctor: an absent verifier image is not reported as OK" "$out" "WARN"
assert_contains "doctor: the absent-verifier line pre-empts the misleading signature failure" "$out" "even though nothing was tampered with"
assert_contains "doctor: the absent-verifier line names the pre-fetch command" "$out" "docker pull ghcr.io/sigstore/cosign/cosign@sha256:"

echo "== unit: doctor Monero sync check — peer-loss strand (#972) =="
# A monerod stranded by a tor restart keeps a green healthcheck while get_info reports
# synchronized:false — the check trusts the RAW flag (a stranded node can report a stale
# target_height of 0, so height math lies) and WARNs, never FAILs (initial sync reads the same).
out="$(RUNNING_CONTAINERS="monerod" CURL_BODY='{"status":"OK","synchronized":true,"target_height":0}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod sync: synchronized -> OK" "$out" "reports synchronized"
out="$(RUNNING_CONTAINERS="monerod" CURL_BODY='{"status":"OK","synchronized":false,"target_height":0,"height":3000000}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod sync: stranded (raw flag false, stale target 0) -> WARN" "$out" "NOT synchronized"
assert_contains "monerod sync: WARN names the fix" "$out" "restart monerod"
out="$(
    RUNNING_CONTAINERS="monerod" CURL_BODY='{"status":"OK","synchronized":false,"target_height":10}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1
    echo "rc=$?"
)"
assert_contains "monerod sync: WARN never fails doctor (rc 0)" "$out" "rc=0"
# RPC not answering (container mid-start) -> info skip; no monerod container (remote mode /
# stack down) -> silent skip, no verdict either way.
out="$(RUNNING_CONTAINERS="monerod" CURL_RC=7 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod sync: RPC silent -> info skip" "$out" "did not answer"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_eq "monerod sync: no container -> silent skip" "$out" ""

echo "== unit: clock_sync_status (mining is time-sensitive) =="
# doctor's NTP check classifies timedatectl's NTPSynchronized: yes→synced, no→unsynced, else unknown.
CLKBIN="$SANDBOX/clk-bin"
mkdir -p "$CLKBIN"
mk_timedatectl() {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$1" >"$CLKBIN/timedatectl"
    chmod +x "$CLKBIN/timedatectl"
}
mk_timedatectl "yes"
assert_eq "clock_sync_status: NTP yes => synced" "$(PATH="$CLKBIN:$PATH" run_sourced "$SANDBOX" clock_sync_status)" "synced"
mk_timedatectl "no"
assert_eq "clock_sync_status: NTP no => unsynced" "$(PATH="$CLKBIN:$PATH" run_sourced "$SANDBOX" clock_sync_status)" "unsynced"
mk_timedatectl ""
assert_eq "clock_sync_status: blank => unknown" "$(PATH="$CLKBIN:$PATH" run_sourced "$SANDBOX" clock_sync_status)" "unknown"

echo "== unit: disk_component_gib =="
assert_eq "monero pruned -> 120" "$(run_sourced "$SANDBOX" disk_component_gib monero 1)" "120"
assert_eq "monero full -> 320" "$(run_sourced "$SANDBOX" disk_component_gib monero 0)" "320"
assert_eq "tari -> 200" "$(run_sourced "$SANDBOX" disk_component_gib tari)" "200"
assert_eq "tor -> 1" "$(run_sourced "$SANDBOX" disk_component_gib tor)" "1"

echo "== unit: check_disk_grouped (mocked df) =="
# A df stub on PATH so check_disk_grouped sees a scripted filesystem layout. DF_MAP maps each path
# df is queried for to a mount point ("path=mount" space-separated): the data dirs (disk_fs_mount
# resolves the mount from these) AND the mount points themselves (check_disk_grouped reads free
# space via the mount, not the possibly-missing dir — #179). DF_AVAIL_KB / DF_AVAIL_H give the
# (single) free figure every mount reports. Real temp dirs make disk_fs_mount resolve without walking up.
DISK="$SANDBOX/disk"
mkdir -p "$DISK/bin"
cat >"$DISK/bin/df" <<'EOF'
#!/usr/bin/env bash
human=0; path=""
for a in "$@"; do case "$a" in -Ph) human=1 ;; -*) : ;; *) path="$a" ;; esac; done
mount=""
for kv in $DF_MAP; do [ "${kv%%=*}" = "$path" ] && mount="${kv#*=}"; done
[ -n "$mount" ] || exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
if [ "$human" = 1 ]; then echo "src 9 9 ${DF_AVAIL_H} 1% $mount"; else echo "src 9 9 ${DF_AVAIL_KB} 1% $mount"; fi
EOF
chmod +x "$DISK/bin/df"
DM="$DISK/data"
mkdir -p "$DM/monero" "$DM/tari" "$DM/p2pool" "$DM/dashboard" "$DM/tor"
md="$DM/monero" td="$DM/tari" pd="$DM/p2pool" dd="$DM/dashboard" rd="$DM/tor"

# All five dirs on ONE filesystem with plenty of space -> a SINGLE grouped OK line naming every
# component, with the combined pruned requirement (120+200+5+2+1 = 328 GB).
one_map="$md=/data $td=/data $pd=/data $dd=/data $rd=/data /data=/data"
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "one fs -> single line" "$(printf '%s\n' "$out" | grep -c 'Data on')" "1"
assert_contains "single line names all components" "$out" "(monero, tari, p2pool, dashboard, tor)"
assert_contains "single line shows combined ~328 GB" "$out" "needs ~328 GB"
assert_contains "ample space -> OK" "$out" "OK"

# Same single filesystem but too small (100 GiB < 328 GiB) -> ONE WARN line.
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=104857600 DF_AVAIL_H=100G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "one small fs -> single line" "$(printf '%s\n' "$out" | grep -c 'Data on')" "1"
assert_contains "small fs warns below need" "$out" "below the ~328 GB"

# Two filesystems: monero+tari on /big, the rest on /small -> ONE line per filesystem.
two_map="$md=/big $td=/big $pd=/small $dd=/small $rd=/small /big=/big /small=/small"
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$two_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "two fs -> two lines" "$(printf '%s\n' "$out" | grep -c 'Data on')" "2"
assert_contains "/big groups monero+tari (~320 GB)" "$out" "/big (monero, tari): 600G free — needs ~320 GB"
assert_contains "/small groups the small three (~8 GB)" "$out" "/small (p2pool, dashboard, tor): 600G free — needs ~8 GB"

# Remote node modes (#103): doctor/preflight blank the remote component's dir (its chain lives on
# the OTHER host), and an empty dir arg must drop that component from the budget entirely — here
# tari remote drops the ~200 GB Tari share, leaving monero+the small three (120+5+2+1 = 128 GB).
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "" "$pd" "$dd" "$rd" 2>&1)"
assert_contains "remote tari drops tari from the budget" "$out" "(monero, p2pool, dashboard, tor)"
assert_contains "remote tari budget excludes the 200 GB" "$out" "needs ~128 GB"

# Preflight mode is WARN-only and silent when there's enough room.
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped preflight 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "preflight silent when ample" "$out" ""
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=104857600 DF_AVAIL_H=100G \
    run_sourced "$SANDBOX" check_disk_grouped preflight 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_contains "preflight warns once when low" "$out" "Low disk on /data (hosts monero, tari, p2pool, dashboard, tor)"

# Regression #179: on first run the data dirs don't exist yet; check_disk_grouped must resolve to the
# nearest existing ancestor's mount and read free space THERE, not df the missing dir (which fails the
# pipe and trips pithead's `set -Eeuo pipefail`). Run under strict mode — NOT run_sourced, which does
# `set +e` and would mask the crash — so a re-introduced df-on-missing-dir would actually abort here.
fresh_map="$DM=/data /data=/data"
PATH="$DISK/bin:$PATH" DF_MAP="$fresh_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    bash -c 'source "$1" 2>/dev/null; check_disk_grouped preflight 1 "$2/fresh/monero" "$2/fresh/tari" "$2/fresh/p2pool" "$2/fresh/dashboard" "$2/fresh/tor"' \
    _ "$STACK" "$DM" >/dev/null 2>&1
assert_rc "check_disk_grouped survives not-yet-created data dirs under set -e (#179)" "$?" "0"

echo "== black-box: status health check =="
# A docker stub driven by FAKE_STATES ("svc=state:health ..."; state "missing" = no container)
# so we can script each service's state and assert how `status` reports it.
make_status_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
sub="$*"
case "$sub" in
  "compose config --services")
      for kv in $FAKE_STATES; do echo "${kv%%=*}"; done ;;
  "compose ps -aq "*)
      svc="${sub##* }"
      for kv in $FAKE_STATES; do
        [ "${kv%%=*}" = "$svc" ] && [ "${kv#*=}" != "missing" ] && echo "$svc"
      done ;;
  "inspect "*)
      cid="${sub##* }"
      for kv in $FAKE_STATES; do
        [ "${kv%%=*}" = "$cid" ] && echo "${kv#*=}" | tr ':' ' '
      done ;;
esac
exit 0
EOF
    chmod +x "$bin/docker"
}
ST="$SANDBOX/status"
mkdir -p "$ST/bin"
cp "$STACK" "$ST/pithead"
make_status_stub "$ST/bin"
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node,local_tari\nHOST_IP=box.lan\n' >"$ST/.env"
ALL_UP="tor=running:healthy monerod=running:healthy p2pool=running:none tari=running:healthy xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"

# All services up -> success, friendly summary.
out="$(cd "$ST" && FAKE_STATES="$ALL_UP" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: all up exits 0" "$rc" "0"
assert_contains "status: all-up summary" "$out" "All expected services are up"

# A node down + proxy stopped -> node flagged, proxy treated as intentional failover.
NODE_DOWN="${ALL_UP/monerod=running:healthy/monerod=exited:none}"
NODE_DOWN="${NODE_DOWN/xmrig-proxy=running:none/xmrig-proxy=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$NODE_DOWN" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: node down exits 1" "$rc" "1"
assert_contains "status: proxy stop is intentional" "$out" "likely intentional"

# A stopped p2pool/xmrig-proxy with healthy nodes is intentional — the nodes pass their
# healthchecks while still syncing and the dashboard holds the miner until they're synced
# (#35), so status reports it as likely-intentional (exit 0), not a fault.
PROXY_ONLY="${ALL_UP/xmrig-proxy=running:none/xmrig-proxy=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$PROXY_ONLY" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: proxy stop under sync hold exits 0" "$rc" "0"
assert_contains "status: proxy stop notes sync hold" "$out" "finish syncing"

P2POOL_ONLY="${ALL_UP/p2pool=running:none/p2pool=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$P2POOL_ONLY" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: p2pool stop under sync hold exits 0" "$rc" "0"
assert_contains "status: p2pool stop notes sync hold" "$out" "finish syncing"

# Remote-node mode: the bundled monerod is not expected even if absent.
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=\nHOST_IP=box.lan\n' >"$ST/.env"
REMOTE="tor=running:healthy monerod=missing p2pool=running:none tari=running:healthy xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"
out="$(cd "$ST" && FAKE_STATES="$REMOTE" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: remote mode ignores monerod" "$rc" "0"

# Remote Tari mode (#103): the bundled tari container is not expected even if absent, mirroring
# monerod above — COMPOSE_PROFILES carries local_node (Monero local) but no local_tari.
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' >"$ST/.env"
REMOTE_TARI="tor=running:healthy monerod=running:healthy p2pool=running:none tari=missing xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"
out="$(cd "$ST" && FAKE_STATES="$REMOTE_TARI" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: remote tari mode ignores tari" "$rc" "0"

echo "== black-box: doctor exit code (#127) =="
# doctor must EXIT NON-ZERO when a critical check fails, so it's usable as a cron/CI health gate
# (it previously always returned 0). Drive one failure via an unreachable Docker daemon; jq/openssl
# stay real on PATH so only the daemon check fails.
DOC="$SANDBOX/doctor"
mkdir -p "$DOC/bin"
cp "$STACK" "$DOC/pithead"
cat >"$DOC/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "info") exit 1 ;;   # daemon unreachable -> doctor records a critical FAIL
  *)      exit 0 ;;   # `--version`, `compose version`, etc. succeed
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$DOC/bin/sudo"
chmod +x "$DOC/bin/docker" "$DOC/bin/sudo"
printf '9.9.9\n' >"$DOC/VERSION" # #386: doctor's header must carry the stack version
out="$(cd "$DOC" && PATH="$DOC/bin:$PATH" ./pithead doctor 2>&1)"
rc=$?
assert_contains "doctor runs to the summary" "$out" "Diagnostics summary"
assert_contains "doctor flags the unreachable daemon" "$out" "Docker daemon is not reachable"
assert_rc "doctor exits 1 on a critical FAIL" "$rc" "1"
assert_contains "doctor header carries the version (#386)" "$out" "Version: pithead v9.9.9"

echo "== black-box: doctor's onion report follows node mode (#103) =="
# A node running elsewhere has no hidden service to provision, so its placeholder address is the
# correct state — doctor must not send the operator back to `setup` over it. A LOCAL node with no
# address is still a real problem and must keep warning.
DOC="$SANDBOX/doctor-onion"
mkdir -p "$DOC/build/tari" "$DOC/dashboard"
: >"$DOC/dashboard/Dockerfile"
cp "$STACK" "$DOC/pithead"
cp "$ROOT/build/tari/config.toml.template" "$DOC/build/tari/"
make_stubs "$DOC/bin"
# $VALID_PRIMARY, not $WALLET: $WALLET is only assigned inside build_val_sandbox() (lib.sh), which
# this section now runs well before in the consolidated file — same class of trap as $V/$DJ above
# and $C in module 8's re-derivation. $VALID_PRIMARY is the exact value WALLET holds in that
# function's local/checksum-valid case, and it's a lib.sh top-level fixture, so it's always bound.
printf '{"monero":{"mode":"remote","wallet_address":"%s","remote":{"host":"10.0.0.8"}},"tari":{"mode":"remote","wallet_address":"'"$VALID_TARI"'","remote":{"host":"10.0.0.9"}}}\n' "$VALID_PRIMARY" >"$DOC/config.json"
doctor_onions() { # <COMPOSE_PROFILES> -> doctor's "Tor onion addresses" section
    {
        printf 'MONERO_ONION_ADDRESS=placeholder\nTARI_ONION_ADDRESS=placeholder\nP2POOL_ONION_ADDRESS=p2pa.onion\n'
        printf 'TARI_GRPC_ADDRESS=10.0.0.9:18142\nDEPLOYMENT_COMPLETED=true\nHOST_IP=box.lan\n'
        printf 'COMPOSE_PROFILES=%s\n' "$1"
    } >"$DOC/.env"
    (cd "$DOC" && PATH="$DOC/bin:$PATH" ./pithead doctor 2>&1 | sed -n '/Tor onion addresses/,/^$/p')
}
doc_remote="$(doctor_onions "")"
assert_contains "doctor: a remote Monero node's missing onion is expected, not a warning (#103)" \
    "$doc_remote" "MONERO_ONION_ADDRESS not needed"
assert_contains "doctor: a remote Tari node's missing onion is expected, not a warning (#103)" \
    "$doc_remote" "TARI_ONION_ADDRESS not needed"
assert_contains "doctor: P2Pool's onion is still reported either way (#103)" \
    "$doc_remote" "P2POOL_ONION_ADDRESS set"
doc_local="$(doctor_onions "local_node,local_tari")"
assert_contains "doctor: a LOCAL Monero node with no onion still warns (#103)" \
    "$doc_local" "MONERO_ONION_ADDRESS is not provisioned"
assert_contains "doctor: a LOCAL Tari node with no onion still warns (#103)" \
    "$doc_local" "TARI_ONION_ADDRESS is not provisioned"
unset DOC doc_remote doc_local doctor_onions
