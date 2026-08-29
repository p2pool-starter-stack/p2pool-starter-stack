# --- Small Utilities ---

# Read a single KEY=value from an env file (value may contain '=').
# Tolerant of a missing key / missing file under `set -e` + `pipefail`.
env_get_file() {
    local file="$1" key="$2" line
    [ -f "$file" ] || return 0
    line=$(grep -E "^$key=" "$file" 2>/dev/null) || true
    line=${line%%$'\n'*}     # first matching line
    printf '%s' "${line#*=}" # value after the first '='
}

env_get() { env_get_file "$ENV_FILE" "$1"; }

# Normalize a config truthy value to the literal "true"/"false". Accepts 1/true/yes/on
# (case-insensitive) as true; everything else (incl. empty/absent) is false. Matches the
# dashboard's MONERO_PRUNE parsing so config booleans read the same on both sides (#183).
# ponytail: deliberately distinct from config_bool below — this normalizes an already-extracted
# STRING; config_bool does the null-aware JSON READ. Merging them risks the #294 `// false` bug.
normalize_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) printf 'true' ;;
    *) printf 'false' ;;
    esac
}

# Read a JSON boolean from $CONFIG_FILE honouring an explicit `false`. jq's `//` treats `false` (not
# just `null`) as empty, so `<path> // true` silently coerces a configured false back to the default —
# we null-check instead. Args: <jq-path-expr> <default:true|false>. Pure given $CONFIG_FILE so it
# unit-tests in isolation (#294 — this bug had broken the #270 firewall opt-out and xvb.tor=false).
config_bool() {
    jq -r "if $1 == null then $2 else $1 end" "$CONFIG_FILE"
}

# Monero pruning as the .env-style flag the dashboard reads: 1 (on) / 0 (off). Pruning is on
# unless config explicitly sets monero.prune:false — via config_bool so that explicit false is
# honoured, not coerced (#294). Tolerates a missing/unreadable config (defaults to pruned).
monero_prune_flag() {
    [ "$(config_bool '.monero.prune' true 2>/dev/null || echo true)" = "true" ] && echo 1 || echo 0
}

# p2pool outbound SOCKS flags (#165). p2pool's --onion-address only advertises an onion for INBOUND;
# without --socks5 it dials outbound sidechain peers over clearnet, exposing the home IP. Returns the
# Tor SOCKS flags by default; empty when the operator opts into clearnet (p2pool.clearnet=true) for
# max yield. Pure (args only: <clearnet-bool> <network-prefix>) so it unit-tests in isolation.
p2pool_outbound_flags() {
    [ "$(normalize_bool "${1:-}")" = "true" ] && return 0
    printf -- '--socks5 %s.25:9050 --socks5-proxy-type tor' "${2:-172.28.0}"
}

# Keys whose value differs between two env files (added, removed, or changed), one per line.
env_changed_keys() {
    comm -3 <(sort "$1") <(sort "$2") 2>/dev/null |
        sed -E 's/^[[:space:]]+//; s/=.*$//' |
        sort -u
}

# Compute the stack version + build provenance and EXPORT them for docker-compose's dashboard
# build args (Issue #58), so the built image is self-describing. Exported rather than written into
# .env on purpose: the git commit is volatile, and persisting it into the config .env would make
# every `git pull` look like a config change (and churn `apply`). VERSION is the source of truth;
# branch + short commit identify a dev build, with `-dirty` for uncommitted tracked changes. docker
# compose reads these from the environment for `dashboard.build.args`; a bare `docker compose build`
# without pithead just gets the empty fallbacks (badge shows a generic dev marker). The release
# pipeline additionally sets PITHEAD_RELEASE=1 so the badge shows the clean vX.Y.Z.
export_build_provenance() {
    local commit=""
    export PITHEAD_VERSION="" PITHEAD_GIT_COMMIT="" PITHEAD_GIT_BRANCH=""
    [ -f VERSION ] && PITHEAD_VERSION="$(tr -d ' \t\r\n' <VERSION 2>/dev/null || true)"
    if git rev-parse --git-dir >/dev/null 2>&1; then
        commit="$(git rev-parse --short HEAD 2>/dev/null || true)"
        PITHEAD_GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        if [ -n "$commit" ] && ! git diff --quiet HEAD 2>/dev/null; then
            commit="${commit}-dirty"
        fi
        PITHEAD_GIT_COMMIT="$commit"
    fi

    # Image coordinates for docker-compose's `image:` refs (#44). A source checkout (build/ present)
    # builds the first-party images locally and tags them `:dev`; a release install (no build/, just
    # the published bundle) pulls `:vX.Y.Z` from the registry. PITHEAD_REGISTRY honours an env override.
    export PITHEAD_REGISTRY STACK_VERSION
    PITHEAD_REGISTRY="${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}"
    if is_source_checkout; then
        STACK_VERSION="dev"
    elif [ -n "$PITHEAD_VERSION" ]; then
        STACK_VERSION="v$PITHEAD_VERSION"
    else
        STACK_VERSION="dev"
    fi
}

is_deployed() {
    [ -f "$ENV_FILE" ] && grep -q "^DEPLOYMENT_COMPLETED=true" "$ENV_FILE"
}

require_env() {
    [ -f "$ENV_FILE" ] || error "No $ENV_FILE found. Run '$0 setup' first."
}

require_deployed() {
    is_deployed || error "The stack isn't fully set up yet. Run '$0 setup' first."
}

# Refuse data directories that would be catastrophic to chown -R / rm -rf.
assert_safe_dir() {
    local d="$1"
    # 1) System + top-level roots, the invoking and real user's homes, and the bare mount/parent
    #    dirs people most often fat-finger a data_dir to. A dedicated SUBfolder of any of these
    #    (e.g. /srv/pithead, /mnt/disk/monero) is still allowed — only the bare root is refused (#91).
    case "$d" in
    "" | / | // | /. | /root | /home | /etc | /usr | /var | /var/lib | /opt | /srv | /mnt | /media | /tmp | /bin | /sbin | /lib | /lib64 | /boot | /dev | /proc | /sys | /Users | /Applications | "${HOME:-/root}" | "/home/$REAL_USER" | "/Users/$REAL_USER")
        error "Refusing to use '$d' as a data directory — it's a system, home, or bare mount root. Choose a dedicated subfolder in $CONFIG_FILE (e.g. .../pithead-data)."
        ;;
    esac
    # 2) Data dirs are stored as ABSOLUTE paths in .env; reject anything relative or containing a
    #    '..' traversal so a malformed config.json value can't resolve somewhere unexpected before
    #    a chown -R / rm -rf runs against it (#91).
    case "$d" in
    /*) ;;
    *) error "Refusing non-absolute data directory '$d' — set an absolute path in $CONFIG_FILE." ;;
    esac
    case "$d" in
    *..*) error "Refusing data directory '$d' — '..' path traversal is not allowed." ;;
    esac
    # 3) A ':' would split the compose bind-mount short syntax it renders into
    #    (`${MONERO_DATA_DIR}:/dest`) — e.g. a dir ending ':ro' forges a third MODE field, turning a
    #    read-write data mount read-only or breaking `compose up`. It's operator-set but, since #728,
    #    also dashboard-committable, so charset-guard it here. No legitimate data-dir path needs a colon.
    case "$d" in
    *:*) error "Refusing data directory '$d' — ':' is not allowed (it would corrupt the container's volume mount)." ;;
    esac
}

safe_sed() {
    local pattern="$1"
    local file="$2"
    if [ "$OS_TYPE" == "Darwin" ]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi
}

# Like safe_sed, but with sudo — for editing root-owned system files such as /etc/default/grub.
# Same GNU/BSD in-place (-i) portability split as safe_sed.
# ponytail: kept as a separate twin of safe_sed on purpose. Collapsing the two onto a shared
# helper needs an unquoted `${1:+sudo}` (shellcheck disable) or an empty-array sudo toggle that's
# fragile under `set -u` on macOS bash 3.2 — more risk than the 5 trivial duplicated lines is worth.
sudo_sed() {
    if [ "$OS_TYPE" == "Darwin" ]; then
        sudo sed -i '' "$1" "$2"
    else
        sudo sed -i "$1" "$2"
    fi
}

# Resolve a config value, treating "auto"/empty (and the legacy DYNAMIC_* sentinels) as
# "use the stack default". $1 = configured value, $2 = default.
resolve_default() {
    case "$1" in
    "" | auto | DYNAMIC_DATA | DYNAMIC_HOST | DYNAMIC_ID) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
    esac
}

# True if $1 is a syntactically valid dotted-quad IPv4 address (each octet 0-255). Used to
# validate user-supplied bind addresses before they reach docker-compose port mappings.
is_ipv4() {
    local o
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [ "$o" -le 255 ] || return 1
    done
    return 0
}

# True if $1 is a globally-routable (public) IP literal — i.e. NOT loopback/private/link-local/
# CGNAT/ULA. Pure + testable (#113): the stratum port is unauthenticated, so setup/doctor warn when
# the host is publicly addressable. IPv4 excluded ranges: 0/8, 10/8, 127/8, 169.254/16, 172.16/12,
# 192.168/16, 100.64/10 (CGNAT). IPv6: only 2000::/3 (global unicast) is treated as public.
is_public_ip() {
    local addr="$1" a b h
    case "$addr" in
    *:*) # IPv6 — public only within 2000::/3 (first hextet 0x2000-0x3fff).
        h="${addr%%:*}"
        case "$h" in "" | *[!0-9a-fA-F]*) return 1 ;; esac
        h=$((16#$h))
        [ "$h" -ge 8192 ] && [ "$h" -le 16383 ]
        ;;
    *.*) # IPv4 dotted-quad.
        is_ipv4 "$addr" || return 1
        IFS=. read -r a b _ _ <<<"$addr"
        case "$a" in
        0 | 10 | 127) return 1 ;;
        169) [ "$b" = 254 ] && return 1 ;;
        172) { [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } && return 1 ;;
        192) [ "$b" = 168 ] && return 1 ;;
        100) { [ "$b" -ge 64 ] && [ "$b" -le 127 ]; } && return 1 ;;
        esac
        return 0
        ;;
    *) return 1 ;;
    esac
}

# Echo the host's globally-routable IP addresses, one per line (empty if none, or if `ip` is absent
# — it's Linux-only). Parses `ip -o addr show`; used by check_stratum_exposure (#113).
host_public_ips() {
    command -v ip >/dev/null 2>&1 || return 0
    local fam addr
    while read -r _ _ fam addr _; do
        case "$fam" in inet | inet6) ;; *) continue ;; esac
        addr="${addr%%/*}"
        if is_public_ip "$addr"; then printf '%s\n' "$addr"; fi
    done < <(ip -o addr show 2>/dev/null)
}
