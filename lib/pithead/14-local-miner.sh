# --- local miner on the appliance (#796) ----------------------------------------------------
# The appliance honours "Mine on this machine too?" itself: the image bakes a pinned RigForge
# tree (plus a prebuilt XMRig), pithead-sync delivers it to /data/rigforge, render below writes
# its config, and the boot path runs its setup in appliance mode after the stack is up. On DIY,
# none of this fires — the operator installs RigForge by hand (announce_local_miner's values).

rigforge_dir() { printf '%s' "${PITHEAD_RIGFORGE_DIR:-/data/rigforge}"; }

# RigForge's config.json is a DERIVED file on the appliance — a pure function of pithead's
# config.json + .env + the boot-time sizing decision, rebuilt on every render like the
# Caddyfile. It carries the three values the miner needs: the stack's own stratum over
# loopback, the stratum password when one is set, and the stack's ACTUAL reservation as
# hugepages_reserve_extra_mb — the hand-off that makes RigForge the pool's single writer. Its
# grow-only sysctl sizes the whole pool (miner need + this headroom); pithead's own write
# never grows past the same decision (optimize_kernel). Declaring the budget beats maxing the
# two reservations: both sides hold pages at the same time, so only the sum survives one side
# growing into its own reservation.
#
# BE PRECISE ABOUT WHAT THIS NUMBER IS: it is the STACK's share, not a ceiling on the pool.
# RigForge adds it to its own requirement, so the pool it writes is miner-need + this value —
# larger than the sizing decision by construction, and intentionally so on the supported 16 GB
# machine, which is the case #305 co-location was measured on. On the REDUCED tier that is a
# real over-reservation, because the tier's 2560 pages were sized for the stack's two RandomX
# datasets alone with no co-resident miner in the budget. No value here fixes that: RigForge's
# grow-only write counts the stack's already-held pages as unavailable while this headroom is
# already inside its requirement, so the co-resident's pages are counted twice and no declared
# number bounds the result. Whether a degraded box should co-locate a miner at all is a product
# decision, tracked in #1103 — out of scope for the sizing fix here, which is what stopped the
# constant 6144 from re-inflating a pool the boot had just shrunk.
#
# The headroom follows hugepages_decision_pages, NOT the
# baked constant (#977): on a degraded box a constant 6144 had RigForge's sysctl re-inflate
# the shrunk pool every boot — and not the live HugePages_Total either, because a mid-run
# `apply` re-renders after RigForge has already grown the pool, and handing the grown pool
# back as headroom would ratchet it up on every apply. Healthy hardware has no marker, so the
# declared value is the same 6144 MB it has always been.

# #1103's product decision: on the REDUCED tier, do not co-locate the built-in miner at all.
# The tier's 2560 pages were budgeted for the stack's own two RandomX datasets alone, with no
# co-resident miner in the sum, and no headroom value declared here can fix that — RigForge's
# grow-only pool write counts the stack's already-held pages as unavailable while this same
# headroom sits inside its own requirement, so the co-resident's pages are counted twice and the
# result is unbounded (see the comment above render_local_miner_config for the arithmetic). The
# RELEASED tier (0 pages) is not affected: it declares zero headroom, so there is nothing left to
# double-count, and the full tier is the measured, supported case this was never wrong for.
# Blocking co-location is therefore scoped to exactly the tier where the double-count is real —
# never the two tiers either side of it, so a normal 16 GB box keeps its full reservation and a
# released box keeps mining solo exactly as it does today.
local_miner_hugepages_blocked() {
    local pages
    pages=$(hugepages_decision_pages)
    [ "$pages" -gt 0 ] && [ "$pages" -lt "$PITHEAD_HUGEPAGES" ]
}

# --- #1103: the total-pool CEILING, the other half of the hand-off -----------------------------
# hugepages_reserve_extra_mb tells RigForge what the stack HOLDS; this tells it how large the pool
# may ever GET. Different levers, and only the second one bounds the measured defect. RigForge's
# grow-only write is target = current + required - avail, and a co-resident holding pages at that
# instant is subtracted from avail while the same pages already sit inside required — so they are
# counted twice and the pool is inflated by exactly the amount held.
#
# MEASURED, not reasoned (~/appliance-suite-logs/1103/RESULTS.md, two KVM legs on a 16 GiB guest):
# THE DOUBLE COUNT IS A RACE, NOT A CONSTANT. p2pool holds 1296 pages for ~6 s while it allocates
# its RandomX dataset; the sync gate then stops it and it releases them. If RigForge's setup lands
# inside that window the pool goes to 5618 pages and STAYS there until the next reboot; outside it,
# 4322. Two consecutive boots of one image gave both numbers. That is why the fix is a ceiling and
# not a re-ordering of the units: re-ordering would make the common case correct and leave the
# failure intact under load, while a ceiling bounds the pool whoever wins the race.
#
# WHY 9216 MB (4608 pages) — the three bounds it has to sit between, each re-derived from rigforge's
# own util/proposed-grub.sh at the pinned commit rather than taken from the issue text:
#   > 6144 MB   _ensure_hugepages SKIPS THE WRITE ENTIRELY when ceiling_pages <= current, and the
#               full tier's current is PITHEAD_HUGEPAGES = 3072 pages = 6144 MB. At or below that
#               the miner would get nothing beyond the boot pool — a cap that reads as a cap and
#               silently switches the reservation off.
#   >= 8592 MB  required on the supported machine is the fallback branch (the appliance reserves no
#               1G pages, so proposed-grub.sh takes it): 1168*NUMA + THREADS + 50 + (extra_mb+1)/2.
#               ⛔ THAT BOUND IS NOT A CONSTANT — IT CARRIES A NODE COUNT, and 8592 is only its
#               NUMA=1 evaluation (1168*1 + 6 + 50 + 3072 = 4296 pages). The node term is the only
#               one that scales: EXTRA_2MB_PAGES does not (proposed-grub.sh L85-88). At NUMA=2 the
#               requirement is 5464 pages = 10,928 MB and a 4608-page ceiling would cap a HEALTHY
#               box 856 pages short; at NUMA=4, 7800 pages, short by 3192. RigForge caps and
#               continues, so that under-reservation would be SILENT — the same failure direction
#               the version gate below exists to avoid. This is why the value is gated on a
#               detected single node (local_miner_numa_nodes) and not merely documented as one.
#   <  11236 MB the contended landing measured above, 5618 pages. At or above it the ceiling would
#               never bind and the over-reserve would survive the fix.
# 4608 pages clears all three AT ONE NODE, with 312 pages of slack over required.
#
# NOT the guest's 4322: that reading is a KVM artifact (4 vCPUs presented as 4 sockets -> L3 64 MiB
# -> THREADS 32). The same physical X5690 reports one 12 MiB L3 -> THREADS 6. Immaterial to the
# ceiling, wrong to quote as the requirement.
#
# THIS VALUE AND hugepages_reserve_extra_mb MOVE TOGETHER: extra_mb contributes (extra_mb+1)/2 =
# 3072 of those 4296 required pages, so raising the declared headroom raises required toward the
# ceiling and would eventually make the cap bite on a healthy box. Re-derive both if
# PITHEAD_HUGEPAGES changes.
readonly PITHEAD_HUGEPAGES_POOL_CEILING_MB=9216

# The RigForge release that first honours the key. VERSION-GATED because the failure is SILENT in
# the worse direction: rigforge's _warn_unknown_config_keys warns and never errors on a key it does
# not know ("an unknown key is at worst a no-op, and erroring would brick fleet applies on any
# future rename"), so declaring the ceiling into an older tree FAILS OPEN — the rendered config
# would read as capped and behave exactly as it does today. A config that lies about being bounded
# is worse than one that plainly is not, so declare it only where it is honoured.
readonly PITHEAD_RIGFORGE_POOL_CEILING_FLOOR=1.16.0

# The node count the ceiling is valid for. MIRRORS RigForge's OWN precedence, step for step
# (util/proposed-grub.sh L52-61 at the pinned ref), and that fidelity is the whole point: this
# function exists to PREDICT the node count rigforge will size against, so any disagreement between
# the two reintroduces the very defect the gate is here to stop — quietly, and in the silent
# direction. Three steps, not two: lscpu's "NUMA node(s)", then the sysfs node count, then THE
# SOCKET COUNT, then 1. The socket fallback is not hypothetical padding — the #1103 bench guest
# reports Socket(s)=4 with NUMA node(s)=1, so a mirror that stopped at sysfs would read 1 where
# rigforge read 4. rigforge's own L48-50 says the same thing from the other side: node count is not
# socket count, and a single-socket EPYC can expose 2/4/8 nodes.
# Prints its answer, so it must call nothing that writes to stdout.
local_miner_numa_nodes() {
    local n
    n=$(lscpu 2>/dev/null | awk -F: '/^NUMA node\(s\):/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
    if ! { [ -n "$n" ] && [ "$n" -gt 0 ]; } 2>/dev/null; then
        n=$(find "${PITHEAD_NODE_SYS:-/sys/devices/system/node}" -maxdepth 1 -name 'node[0-9]*' 2>/dev/null | wc -l | tr -d ' ')
    fi
    if ! { [ -n "$n" ] && [ "$n" -gt 0 ]; } 2>/dev/null; then
        n=$(lscpu 2>/dev/null | awk '/Socket\(s\):/ {print $2; exit}')
    fi
    if ! { [ -n "$n" ] && [ "$n" -gt 0 ]; } 2>/dev/null; then
        n=1
    fi
    echo "$n"
}

# The ceiling this machine may declare, in MB, or 0 for "declare nothing" — 0 is RigForge's own
# documented default for "no ceiling", so an omitted key and a declared 0 mean the same to it.
# Prints its answer, so it must never call log (stdout); warn goes to stderr and is safe here.
local_miner_pool_ceiling_mb() {
    local dir=$1 ver
    # THE FULL TIER ONLY — the one tier the value was measured on. The reduced tier never reaches
    # here (local_miner_hugepages_blocked refuses it outright, and leg B measured why: lifting that
    # refusal asks for 12.0 GiB on a 7.76 GiB box, the kernel silently grants 5.7 GiB, MemAvailable
    # falls to ~40 MB and RigForge still exits 0 saying "Deployment Complete"). The RELEASED tier
    # declares zero headroom and holds no stack pages, so it has nothing to double-count and no
    # measurement behind any value — it stays uncapped rather than guessing one.
    [ "$(hugepages_decision_pages)" = "$PITHEAD_HUGEPAGES" ] || {
        echo 0
        return 0
    }
    # ONE NODE ONLY — the regime 9216 was measured on. RigForge's requirement carries a 1168-page
    # term PER NUMA NODE, so on a multi-node box this ceiling would sit BELOW a healthy requirement
    # and rigforge would cap the write and carry on: a silent under-reservation, which is the same
    # failure direction the version gate refuses. Left uncapped instead, which is exactly today's
    # behaviour. Deliberately NOT a render-time recomputation of rigforge's formula: that would put
    # a copy of their sizing inside pithead that must stay correct across their releases, and it
    # needs THREADS (L3_MB/2, then THREADS_CAP) which pithead does not model at all.
    local nodes
    nodes=$(local_miner_numa_nodes)
    if [ "$nodes" != 1 ]; then
        warn "This machine reports $nodes NUMA nodes and the HugePages pool ceiling was measured on a single-node box — leaving the pool uncapped rather than capping it below a healthy requirement."
        echo 0
        return 0
    fi
    # The tree that will actually RUN, not the image's stamp: pithead-sync copies /opt/rigforge to
    # /data/rigforge every boot, and it is the copy under $dir whose parse_config reads this key.
    ver=$(tr -d ' \t\r\n' <"$dir/VERSION" 2>/dev/null) || ver=""
    # Fail CLOSED on anything not a plain dotted number. sort -V happily orders an unparseable
    # string against a version and would answer "new enough" for a tree that is nothing of the kind.
    case "$ver" in
    '' | *[!0-9.]*)
        warn "Could not read a RigForge version from $dir/VERSION — leaving the HugePages pool uncapped."
        echo 0
        return 0
        ;;
    esac
    if [ "$(printf '%s\n%s\n' "$PITHEAD_RIGFORGE_POOL_CEILING_FLOOR" "$ver" | sort -V | head -n 1)" \
        != "$PITHEAD_RIGFORGE_POOL_CEILING_FLOOR" ]; then
        warn "RigForge $ver at $dir predates $PITHEAD_RIGFORGE_POOL_CEILING_FLOOR and ignores the HugePages pool ceiling — leaving the pool uncapped rather than writing a cap it would not honour."
        echo 0
        return 0
    fi
    echo "$PITHEAD_HUGEPAGES_POOL_CEILING_MB"
}

render_local_miner_config() {
    is_appliance || return 0
    # Not on a rig, ever. This function's "switched off" branch DELETES the miner's config, and
    # a rig with no config.json reads as switched off — so a stray render there would take out
    # the very file the rig mines from. render_rig_miner_config owns that machine's copy.
    if [ "$(machine_role)" = "rig" ]; then return 0; fi
    local dir
    dir=$(rigforge_dir)
    if [ "$(config_bool '.local_miner.enabled' false 2>/dev/null || echo false)" != "true" ]; then
        # Derived means derived: switched off, the config goes away — the boot leg then has
        # nothing to start, and a stale stratum password does not linger on /data.
        rm -f "$dir/config.json"
        return 0
    fi
    if local_miner_hugepages_blocked; then
        # Same treatment as switched off (#1103): a reduced-RAM box cannot also fit a co-located
        # miner without double-counting the stack's own reservation. provision_local_miner is
        # the one that warns the operator; this only keeps the derived file from existing.
        rm -f "$dir/config.json"
        return 0
    fi
    if [ ! -d "$dir" ]; then
        warn "Local mining is on, but there is no RigForge tree at $dir — this image does not carry the built-in miner."
        return 0
    fi
    local port secret ceiling
    port=$(stratum_port_effective)
    secret=$(env_get PROXY_STRATUM_PASSWORD 2>/dev/null || true)
    ceiling=$(local_miner_pool_ceiling_mb "$dir")
    jq -n --arg url "127.0.0.1:$port" --arg pass "$secret" --argjson reserve "$(($(hugepages_decision_pages) * 2))" \
        --argjson ceiling "$ceiling" \
        '{pools: [({url: $url} + (if $pass != "" then {pass: $pass} else {} end))], hugepages_reserve_extra_mb: $reserve}
         + (if $ceiling > 0 then {hugepages_pool_ceiling_mb: $ceiling} else {} end)' \
        >"$dir/config.json"
    log "Local miner config rendered to $dir/config.json (pool 127.0.0.1:$port)."
}

# The one place RigForge's setup is ever invoked, shared by both roles that run a miner. Same
# appliance flag, same tree on /data, same first-run narration — a rig and a coordinator that
# also mines differ in where the miner's config came from, never in how it is started.
#
# Prebuilt-first is the whole reason this is instant: pithead-sync seeds the image's baked XMRig
# into the workspace, so the binary already exists and RigForge's setup re-renders rather than
# compiles. A build here means the operator's own native rebuild replaced it or the cached one
# failed its integrity check — minutes of silence on a console with nothing else to look at, so
# say what the machine is doing. Nothing on this path clones: a Tor-only box could not.
rigforge_setup_run() {
    local dir
    dir=$(rigforge_dir)
    if [ ! -x "$dir/rigforge.sh" ]; then
        warn "There is no RigForge tree at $dir — this image does not carry the built-in miner."
        return 1
    fi
    if [ ! -x "$dir/data/worker/xmrig/build/xmrig" ]; then
        _console "Preparing the miner — building it once. This can take several minutes."
    fi
    (cd "$dir" && RIGFORGE_APPLIANCE=1 ./rigforge.sh setup)
}

# The run leg: converge the on-box miner to what this machine says it is. Runs after the stack
# is up (the miner needs the stratum listening; RigForge's setup restarts the service it
# installs), from pithead-boot on every boot and from setup on first provisioning. RigForge's
# appliance mode makes the whole run idempotent on the read-only root: units in /run with
# --runtime enablement, no package installs, GRUB untouched, grow-only HugePages.
#
# The role forks here rather than in the boot path, so both boot owners — pithead-boot on a
# provisioned machine, the first-boot wizard on the boot that accepts a role — get the right leg
# from the one command.
provision_local_miner() {
    is_appliance || return 0
    if [ "$(machine_role)" = "rig" ]; then
        provision_rig_miner
        return
    fi
    local dir
    dir=$(rigforge_dir)
    if [ "$(config_bool '.local_miner.enabled' false 2>/dev/null || echo false)" != "true" ]; then
        # Switched off: stop a still-running miner now rather than waiting for the reboot that
        # would drop its runtime unit anyway. Best-effort — absent unit, absent systemctl (tests)
        # and DIY hosts all land in the same quiet no-op.
        systemctl stop xmrig.service >/dev/null 2>&1 || true
        return 0
    fi
    if local_miner_hugepages_blocked; then
        # #1103: this machine's reduced HugePages reservation cannot also fit a co-located
        # miner without double-counting the stack's own share — refuse to start it, the same
        # way a switched-off opt-in does, rather than let RigForge's grow-only sysctl chase an
        # unbounded target on hardware already running squeezed.
        warn "Local mining opt-in is ON, but this machine's reduced HugePages reservation cannot also fit a co-located miner without risking the stack itself — the built-in miner is not started. Use a 16 GB machine for the built-in miner."
        systemctl stop xmrig.service >/dev/null 2>&1 || true
        return 0
    fi
    [ -f "$dir/config.json" ] || render_local_miner_config
    if rigforge_setup_run; then
        log "Local miner is up — it appears in the dashboard's Workers view."
    else
        warn "Local miner setup failed — the stack itself is unaffected. Details are in the log above."
        return 1
    fi
}

# --- the rig role's boot leg (one stick, three machines) -------------------------------------
# A rig has no config.json, no containers, no dashboard and no chains: its entire product is the
# miner. So it rides the SAME leg the Both role rides, sourced from rig.json instead of
# config.json — one invocation contract, one prebuilt, one appliance mode.

# The rig's control token (#1836): 32 hex, minted once and kept in rig.json beside the answers
# it belongs to, so the config rebuilt at every boot carries the token the operator pasted into
# the coordinator's adopt form. The token is this function's ONLY stdout — callers capture it.
rig_access_token() {
    local tok tmp="$PWD/.rig.json.tmp"
    tok=$(jq -r '.access_token // ""' "$PWD/rig.json" 2>/dev/null)
    if ! [[ "$tok" =~ ^[0-9a-f]{32}$ ]]; then
        tok=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
        [[ "$tok" =~ ^[0-9a-f]{32}$ ]] || return 1
        if ! { (umask 077 && jq --arg t "$tok" '. + {access_token: $t}' "$PWD/rig.json" >"$tmp" 2>/dev/null) &&
            chmod 600 "$tmp" && mv -f "$tmp" "$PWD/rig.json"; }; then
            rm -f "$tmp"
            return 1
        fi
    fi
    printf '%s' "$tok"
}

# The coordinator's address for RigForge's api_allow_from pin: rig.json's pool host resolved to
# ONE IPv4. RigForge takes an address or CIDR there, never a name, and binds its API ports on
# IPv4. Prints nothing when the host has no IPv4 — an onion pool, a name mDNS does not answer —
# and the caller leaves control OFF rather than guess: RigForge refuses control without the pin.
rig_coordinator_ip() {
    local host
    host=$(jq -r '.pool // ""' "$PWD/rig.json" 2>/dev/null)
    host=${host%:*}
    host=${host#\[}
    host=${host%\]}
    [ -n "$host" ] || return 0
    getent ahostsv4 "$host" 2>/dev/null | awk '$1 ~ /^[0-9]+(\.[0-9]+){3}$/ { print $1; exit }'
}

# RigForge's config for a rig, derived from rig.json exactly the way the Both role's is derived
# from config.json — rebuilt every boot, never repaired. The pool the operator gave, the worker
# name that labels this rig there (RigForge's pools[].user, the hostname when empty), the stratum
# password when one was set — and, #1836, the rig's own token on every API, the read-only sister
# feed the coordinator probes, and the writable control path pinned to the coordinator's address,
# which is what lets the Workers view adopt this rig instead of showing "API error". Without the
# token XMRig's own API stood open on the LAN. control_upgrade stays off: an appliance rig updates
# through its own A/B bundle, never through RigForge's upgrade path. No hugepages_reserve_extra_mb:
# there is no stack on this machine to leave headroom for, so RigForge sizes the pool for the miner.
render_rig_miner_config() {
    local dir tok allow
    dir=$(rigforge_dir)
    if [ ! -d "$dir" ]; then
        warn "This machine is a rig, but there is no RigForge tree at $dir — this image does not carry the miner."
        return 1
    fi
    tok=$(rig_access_token) || {
        warn "Could not mint or keep the rig's control token in rig.json — the miner was not configured."
        return 1
    }
    allow=$(rig_coordinator_ip)
    [ -n "$allow" ] || warn "The rig's control API stays off: the pool host does not resolve to an IPv4 address to pin it to. The read-only feed still serves, token required."
    jq --arg tok "$tok" --arg allow "$allow" '{pools: [({url: .pool, user: (.worker // "")}
        + (if (.stratum_password // "") == "" then {} else {pass: .stratum_password} end))],
        ACCESS_TOKEN: $tok, api: "enabled"}
        + (if $allow == "" then {} else {control: "enabled", api_allow_from: $allow} end)' \
        "$PWD/rig.json" >"$dir/config.json" 2>/dev/null || return 1
    chmod 600 "$dir/config.json" 2>/dev/null || true
}

# Write minimization for a removable root. The rig role's stick can BE the system it runs from —
# that is the point of the run-from-USB choice — and the image's journald ships
# Storage=persistent with a 200 MB cap, whose files land on the /var overlay, whose upper lives
# on that same medium. A rig holds almost no state and its logs are read within the boot that
# produced them, so volatile is the honest setting: the journal lives in RAM and the stick sees
# no rotating writes at all.
#
# Converged every boot rather than baked, because it cannot be baked: /etc and /run are BOTH
# volatile on this appliance, so no drop-in survives a reboot and journald always starts
# persistent again. The existing-directory guard makes this one restart per boot, not a loop.
# Swap needs no code at all: the appliance declares no swap partition and creates none, so
# "no swap" is already true in every role — see os/rootfs/repart.d.
rig_minimize_writes() {
    is_appliance || return 0
    local dropin="${PITHEAD_JOURNALD_DROPIN_DIR:-/run/systemd/journald.conf.d}"
    local journal="${PITHEAD_JOURNAL_DIR:-/var/log/journal}"
    mkdir -p "$dropin" 2>/dev/null || return 0
    # Sorts after the image's own pithead.conf, and later file wins: that is how a drop-in
    # overrides a drop-in.
    printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=32M\n' >"$dropin/zz-rig-volatile.conf" 2>/dev/null || return 0
    [ -d "$journal" ] || return 0
    # Restart FIRST: journald holds the persistent files under $journal open, and a bind there
    # cannot come off while it does (umount: target is busy). Volatile, it writes under /run and
    # holds nothing here. (Before #1817 the restart came after the reclaim, which worked only
    # because unlinking an open file is allowed — taking a mount off is not.)
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    # #1817: a first boot binds the persistent journal home onto this path before the role is
    # known (pithead-journal-persist), so the reclaim meets a MOUNTPOINT. `rm -rf` on one empties
    # it — through the bind, onto /data — and then fails on the mountpoint itself. Take the bind
    # off first, so what is reclaimed is the overlay's own directory and nothing on /data is
    # touched. Every step is best-effort: this is a stick-wear optimisation, nothing downstream
    # reads its result, and the one caller that matters runs under errexit (pithead-boot's
    # `local-miner`) — a cleanup that cannot complete must never leave a slot uncommitted.
    if mountpoint -q "$journal" 2>/dev/null; then
        umount "$journal" 2>/dev/null || true
        # A bind that did not come off is left alone: `rm -rf` through it would empty the
        # persistent home on /data, the one thing this block promises not to do.
        if mountpoint -q "$journal" 2>/dev/null; then
            warn "The journal bind is still up, so nothing is reclaimed; journald is volatile for this boot anyway."
            return 0
        fi
    fi
    rm -rf "${journal:?}" || warn "The journal directory could not be reclaimed; journald is volatile for this boot anyway."
    log "Rig write minimization: the journal is in memory for this boot — the root may be the stick the miner runs from."
}

provision_rig_miner() {
    if [ ! -f "$PWD/rig.json" ]; then
        warn "This machine is marked as a rig, but its settings are missing — install it again from the stick to choose a role."
        return 1
    fi
    # `|| true` on purpose (#1817): the minimization is best-effort by construction, and this
    # function is called BARE from the boot path (pithead-boot -> `pithead local-miner`, errexit
    # armed) but under `|| true` from the wizard — a failure inside it passed first boot and
    # killed every boot after, which is the one signature a full gate is needed to see.
    rig_minimize_writes || true
    render_rig_miner_config || return 1
    if rigforge_setup_run; then
        log "The rig is mining: $(jq -r '.worker // "this machine"' "$PWD/rig.json" 2>/dev/null) -> $(jq -r '.pool // "no pool recorded"' "$PWD/rig.json" 2>/dev/null)."
        return 0
    fi
    warn "The rig's miner did not start. Details are in the log above."
    return 1
}
