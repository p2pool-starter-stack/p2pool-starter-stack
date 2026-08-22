#!/usr/bin/env bash
# Keep local-setup detail out of the repo WITHOUT teaching this script anything about any real
# setup: every pattern below is a GENERIC class (an address range, a path shape, a hostname
# suffix), never a specific machine. Five classes, each with its own allowlist tuned against the
# real tree (never a per-file exemption comment):
#
#   1. globally-routable IPv6 literals (2xxx:/3xxx:) — allowed only for a handful of well-known
#      public values (the RFC 3849 documentation prefix, Cloudflare/Google public resolvers).
#   2. /home/<name> literal paths — allowed only for obvious placeholder names.
#   3. .lan/.internal hostnames (outside tests/docs fixture context) and .local hostnames other
#      than pithead.local (the product's own documented mDNS name).
#   4. private-range IPv4 literals (10/8, 172.16/12, 192.168/16) — allowed in tests/docs/build
#      entrypoints/config templates, plus the compose file's documented 172.28.0.0/16 default
#      wherever that exact default is referenced.
#   5. user@host strings — allowed only for generic role placeholders, the RFC 2606 reserved
#      example domains, and technical shapes that only look like an address (a SHA-pinned GitHub
#      Action, a package@version, a Telegram bot mention).
#
# Run with --self-test to check the scanners themselves against fixtures (including the
# empty-enumeration guard below).
set -euo pipefail

# A broken `git ls-files` must never read as "no violations" — a swallowed pipe error and a
# genuinely clean tree look identical from a zero-hit scan, so an empty enumeration is always
# fatal, not just when the exit code says so.
enforce_nonempty_enumeration() {
    if [ "$(git ls-files | wc -l)" -eq 0 ]; then
        echo "FATAL: git ls-files enumerated zero tracked files. A broken enumeration and a" >&2
        echo "clean tree both scan zero hits — refusing to report either as success." >&2
        return 1
    fi
    return 0
}

# --- class patterns (grep -P) --------------------------------------------------------------
IPV6_RE='(?<![0-9A-Za-z.:])[23][0-9a-fA-F]{0,3}:[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){0,6}(?![0-9A-Za-z.])'
HOME_RE='/home/[A-Za-z0-9_-]+'
# Anchor off "not preceded by an identifier/dot char" — NOT off a quote/bracket, or a bare
# KEY=VALUE line (exactly the shape *.env / *.container Quadlet files use) never matches, since
# nothing quotes it. That wider anchor alone would also flag `google.protobuf.internal` (chained
# dotted import — the "protobuf" label sits right after another dot, which the same rule already
# excludes) and a single-letter code identifier like `n.internal` (property access) — so the label
# also has to be at least two characters, which a source-code single-letter accessor never is but
# every real hostname label always is.
LAN_RE='(?<![A-Za-z0-9_.-])[A-Za-z0-9][A-Za-z0-9-]{1,}\.(lan|internal)\b'
LOCAL_RE='(?<![A-Za-z0-9_.-])[A-Za-z0-9][A-Za-z0-9-]{1,}\.local\b'
IPV4_RE='(?<![0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})(/[0-9]{1,2})?(?![0-9])'
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9][A-Za-z0-9.-]*'

# --- per-class allow checks: exit 0 = allowed/noise (skip it), exit 1 = a real violation -------

# A [23]xxx: token that isn't on the public-value allowlist still isn't necessarily an address —
# a year ("2026:"), a clock ("20:15:30"), a Python statement colon and a CIDR range shorthand
# ("2000::/3") all match the shape above. Only flag it once it also has a hex letter, a "::"
# compression, or three-plus colons — the things a bare decimal token never has.
ipv6_allow() {
    case "$1" in
    2001:db8:* | 2001:db8) return 0 ;;
    2606:4700:4700::1111 | 2606:4700:4700::1001) return 0 ;;
    2001:4860:4860::8888 | 2001:4860:4860::8844) return 0 ;;
    esac
    case "$1" in
    *::*) return 1 ;;
    esac
    [[ $1 =~ [a-fA-F] ]] && return 1
    local colons=${1//[^:]/}
    [ "${#colons}" -ge 3 ] && return 1
    return 0
}

home_allow() {
    local name="${1#/home/}"
    case "$name" in
    ubuntu | pithead | user | miner | you | me) return 0 ;;
    *) return 1 ;;
    esac
}

# .local is only ever fine when it names the product's own documented mDNS address, the
# well-known malformed-mDNS artifact a misconfigured device publishes when it calls itself
# "localhost" (os/KNOWN-ISSUES.md documents the failure mode generically; it's avahi's own
# behavior, not any real device's name), or the setup wizard's own remote-host placeholder hint
# text (the same wizard.mjs field also hints 192.168.1.10 — see ipv4_allow()).
local_allow() {
    case "$1" in
    pithead.local | localhost.local | my-node.local) return 0 ;;
    *) return 1 ;;
    esac
}

# The compose file's documented 172.28.0.0/16 default is repeated verbatim (config fallbacks,
# doc examples) wherever that exact default is used — that's the one private range this guard
# doesn't treat as a leak. The RFC1918 blocks' own canonical base addresses (10.0.0.0/8,
# 172.16.0.0/12, 192.168.0.0/16) are the range definitions themselves, not a host literal.
ipv4_allow() {
    case "$1" in
    172.28.* | 10.0.0.0/8 | 172.16.0.0/12 | 192.168.0.0/16) return 0 ;;
    # pithead's own suggested-alternate-subnet example in explain_subnet_collision()'s warning —
    # not a fallback default, just a second illustrative /24 offered when 172.28.0.0/24 collides.
    172.30.0.0/24) return 0 ;;
    # the setup wizard's own "Node host" field placeholder hint text (build/dashboard/.../wizard.mjs)
    192.168.1.10) return 0 ;;
    # an atypical private literal in the os/quadlet fixture set (fixture.env + the two unit files
    # rendered from it) — not the documented 172.28.* default; a prior audit flagged it for a
    # human look. Allowlisted by value, pending that review — never silently path-exempted.
    192.168.1.243) return 0 ;;
    *) return 1 ;;
    esac
}

email_allow() {
    local local_part="${1%%@*}" domain="${1#*@}"
    case "$local_part" in
    user | you | miner | root | operator) return 0 ;;
    esac
    case "$domain" in
    example.com | invalid | test | *.example.com | *.invalid | *.test) return 0 ;;
    sha256 | SHA256) return 0 ;; # a Docker/OCI digest pin (name@sha256:<hex>), truncated at the ':'
    v) return 0 ;;               # Go's own `@v` module-version pin syntax, shown generically in prose
    esac
    [[ $domain =~ ^[0-9a-fA-F]{40}$ ]] && return 0                          # a SHA-pinned GitHub Action
    [[ $domain =~ ^v?[0-9]+(\.[0-9]+){1,3}(-[A-Za-z0-9.]+)?$ ]] && return 0 # a package@version pin
    [[ "${domain,,}" == *bot ]] && return 0                                 # a Telegram /command@FooBot mention
    return 1
}

# --- scan: extract "path:line:match" from grep -HnoP output, drop what the allow-fn clears -----
scan() { # <pattern> <allow-fn> <file...>
    local pattern="$1" allow_fn="$2"
    shift 2
    [ "$#" -eq 0 ] && return 0
    local entry path line match
    while IFS= read -r entry; do
        [[ $entry =~ ^([^:]+):([0-9]+):(.*)$ ]] || continue
        path=${BASH_REMATCH[1]}
        line=${BASH_REMATCH[2]}
        match=${BASH_REMATCH[3]}
        "$allow_fn" "$match" && continue
        printf '%s:%s: %s\n' "$path" "$line" "$match"
    done < <(grep -HInoP -e "$pattern" -- "$@" 2>/dev/null)
    return 0
}

report() { # <class-message> <hits>
    if [ -n "$2" ]; then
        printf '%s\n' "$1"
        printf '%s\n' "$2"
        FAIL=1
    fi
}

# Minified/vendored bundles read as noise to every class below (a coincidental "2:e" inside a
# minified object literal is not a topology leak) — lint-operator-strings.sh draws the same line
# at *.min.js. Exclude them everywhere, not just from one class. This script's own self-test
# fixtures are excluded too, for the same reason: they deliberately spell out one violating
# example per class (see --self-test below) and would otherwise flag themselves on every run.
EXCL_VENDOR=(':(exclude,glob)**/*.min.js' ':(exclude)scripts/lint-topology-classes.sh')

# Fixture/vendored-doc context: tests/ and docs/ (any depth — build/dashboard/tests/ counts too)
# hold synthetic hostnames and third-party research material on purpose; config.reference.json
# plays the same illustrative role as docs/ (it documents every field with an example value, the
# same "tari-node.lan" one docs/configuration.md shows).
EXCL_TESTS_DOCS=(
    ':(exclude,glob)tests/**' ':(exclude,glob)**/tests/**' ':(exclude,glob)docs/**'
    ':(exclude)config.reference.json'
)
# The RFC1918 rule additionally clears build/*/entrypoint scripts and config templates (they
# render the product's own network config) and three repo-root files that use illustrative
# addresses in prose: the compose file itself (the documented default's home), CHANGELOG.md
# (release notes narrate past examples the same way docs/ does), and the Makefile (a dev-tooling
# comment). The CLI (`pithead`) is deliberately NOT path-exempt here — it's the file most likely
# to grow a real leaked address — so every private literal it carries clears ipv4_allow() by
# value instead (see the 172.30.0.0/24 entry above).
EXCL_IPV4_EXTRA=(
    ':(exclude,glob)build/*/*entrypoint*' ':(exclude,glob)build/*/*.template'
    ':(exclude)docker-compose.yml' ':(exclude)CHANGELOG.md' ':(exclude)Makefile'
)

run() {
    local -a f_all f_noexempt f_ipv4
    mapfile -d '' -t f_all < <(git ls-files -z -- . "${EXCL_VENDOR[@]}")
    mapfile -d '' -t f_noexempt < <(git ls-files -z -- . "${EXCL_VENDOR[@]}" "${EXCL_TESTS_DOCS[@]}")
    mapfile -d '' -t f_ipv4 < <(git ls-files -z -- . "${EXCL_VENDOR[@]}" "${EXCL_TESTS_DOCS[@]}" "${EXCL_IPV4_EXTRA[@]}")

    FAIL=0
    report "topology-classes: globally-routable IPv6 literal (2xxx:/3xxx:), not on the public-value allowlist:" \
        "$(scan "$IPV6_RE" ipv6_allow "${f_all[@]}")"
    report "topology-classes: /home/<name> literal path for a name that isn't an obvious placeholder:" \
        "$(scan "$HOME_RE" home_allow "${f_all[@]}")"
    report "topology-classes: .lan/.internal hostname outside tests/docs fixture context:" \
        "$(scan "$LAN_RE" false "${f_noexempt[@]}")"
    report "topology-classes: .local hostname other than the product's own pithead.local:" \
        "$(scan "$LOCAL_RE" local_allow "${f_noexempt[@]}")"
    report "topology-classes: private-range IPv4 literal outside its allowed context:" \
        "$(scan "$IPV4_RE" ipv4_allow "${f_ipv4[@]}")"
    report "topology-classes: user@host string outside a generic placeholder or a technical pin shape:" \
        "$(scan "$EMAIL_RE" email_allow "${f_noexempt[@]}")"

    if [ "$FAIL" -ne 0 ]; then
        echo "A generic CLASS failed above — swap the real value for a placeholder from the class's own allowlist (see this script's header), never invent a new exemption inline."
        return 1
    fi
    echo "topology classes OK — no real-looking IPv6/IPv4/hostname/path/user@host literal outside its allowed context"
    return 0
}

# --- self-test ----------------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    st_fail=0
    expect() { # <desc> <hit|clean> <actual-output>
        if [ "$2" = hit ] && [ -z "$3" ]; then
            echo "  self-test FAIL: $1 (expected a hit, got none)"
            st_fail=1
        elif [ "$2" = clean ] && [ -n "$3" ]; then
            echo "  self-test FAIL: $1 (expected clean, got: $3)"
            st_fail=1
        else echo "  self-test ok: $1"; fi
    }

    printf 'contact reachable at 2001:dead:beef::1 for status\n' >"$tmp/v6-hit.txt"
    expect "a non-allowlisted global IPv6 literal is flagged" hit "$(scan "$IPV6_RE" ipv6_allow "$tmp/v6-hit.txt")"
    printf 'doc example: 2001:db8::1234, resolver: 2606:4700:4700::1111\n' >"$tmp/v6-clean.txt"
    expect "the documentation prefix and a public resolver are not flagged" clean "$(scan "$IPV6_RE" ipv6_allow "$tmp/v6-clean.txt")"
    printf 'released 2026: point 0.33, window 20:15:30, range 2000::/3\n' >"$tmp/v6-noise.txt"
    expect "a year, a clock, and a CIDR range shorthand are not flagged" clean "$(scan "$IPV6_RE" ipv6_allow "$tmp/v6-noise.txt")"

    printf 'data_dir: /home/johndoe/.bitmonero\n' >"$tmp/home-hit.txt"
    expect "a /home/<name> path for a non-placeholder name is flagged" hit "$(scan "$HOME_RE" home_allow "$tmp/home-hit.txt")"
    printf 'data_dir: /home/ubuntu/.bitmonero, or set $HOME/data or ~/data\n' >"$tmp/home-clean.txt"
    expect "an allowlisted placeholder name, \$HOME, and ~ are not flagged" clean "$(scan "$HOME_RE" home_allow "$tmp/home-clean.txt")"

    printf 'NODE_HOST=storage-box.internal\n' >"$tmp/lan-hit.txt"
    expect "a bare unquoted KEY=VALUE .internal hostname (the *.env/*.container shape) is flagged" hit \
        "$(scan "$LAN_RE" false "$tmp/lan-hit.txt")"
    printf 'const ok = topology.nodes.internal; // imported from google.protobuf.internal\n' >"$tmp/lan-clean.txt"
    expect "a chained property access and a dotted import path are not hostnames and are not flagged" clean \
        "$(scan "$LAN_RE" false "$tmp/lan-clean.txt")"
    printf 'return !n.internal;\n' >"$tmp/lan-clean2.txt"
    expect "a single-letter code identifier before .internal is not flagged" clean "$(scan "$LAN_RE" false "$tmp/lan-clean2.txt")"

    printf 'NODE_HOST=storage-box.local\n' >"$tmp/local-hit.txt"
    expect "a bare unquoted .local hostname other than pithead.local is flagged" hit "$(scan "$LOCAL_RE" local_allow "$tmp/local-hit.txt")"
    printf 'reach it at pithead.local, or the known localhost.local mDNS artifact, or my-node.local\n' >"$tmp/local-clean.txt"
    expect "pithead.local, the documented localhost.local artifact, and the wizard's my-node.local hint are not flagged" clean \
        "$(scan "$LOCAL_RE" local_allow "$tmp/local-clean.txt")"

    printf 'NODE_IP=10.4.5.6\n' >"$tmp/v4-hit.txt"
    expect "a private IPv4 literal outside its allowed context is flagged" hit "$(scan "$IPV4_RE" ipv4_allow "$tmp/v4-hit.txt")"
    printf 'default subnet 172.28.0.0/16, RFC1918 space 10.0.0.0/8, alt subnet 172.30.0.0/24,\nwizard hint 192.168.1.10, quadlet fixture 192.168.1.243\n' >"$tmp/v4-clean.txt"
    expect "the documented default, a canonical range base, and the two named pending-review/hint values are not flagged" clean \
        "$(scan "$IPV4_RE" ipv4_allow "$tmp/v4-clean.txt")"

    printf 'reach jsmith@homebox42 for access\n' >"$tmp/email-hit.txt"
    expect "a real-looking user@host string is flagged" hit "$(scan "$EMAIL_RE" email_allow "$tmp/email-hit.txt")"
    printf 'ssh as user@10.0.0.5, or root@, mail admin@example.com, pin actions/checkout@%s, biome@2.5.0, /status@PitheadBot, go get X@v Y@v\n' \
        "$(printf 'a%.0s' $(seq 1 40))" >"$tmp/email-clean.txt"
    expect "placeholders, example.com, a SHA pin, a package pin, a bot mention, and Go's bare @v syntax are not flagged" clean \
        "$(scan "$EMAIL_RE" email_allow "$tmp/email-clean.txt")"

    SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    emptyrepo="$tmp/emptyrepo"
    mkdir -p "$emptyrepo"
    git init -q "$emptyrepo"
    if (cd "$emptyrepo" && bash "$SELF") >/dev/null 2>"$tmp/empty-stderr.txt"; then
        echo "  self-test FAIL: an empty git-ls-files enumeration did not fail loudly"
        st_fail=1
    elif grep -q FATAL "$tmp/empty-stderr.txt"; then
        echo "  self-test ok: an empty git-ls-files enumeration fails loudly instead of reading as clean"
    else
        echo "  self-test FAIL: the empty-enumeration run failed, but not with the FATAL guard message"
        st_fail=1
    fi

    [ "$st_fail" -eq 0 ] && {
        echo "lint-topology-classes self-test OK"
        exit 0
    }
    echo "lint-topology-classes self-test FAILED"
    exit 1
fi

enforce_nonempty_enumeration
run
