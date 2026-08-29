# True if $1 is a plausible hostname or IP literal — i.e. only the characters a host can contain
# (letters, digits, dot, hyphen, colon for IPv6). Used to validate dashboard.host before it's
# rendered into the Caddyfile site address: anything with whitespace, a newline, or Caddy-significant
# characters ({ } /) could break or inject into the generated Caddyfile. Length-capped at 253 (#558),
# mirroring the worker-host charset check elsewhere in this file (resolve_worker_target's host
# guard, validate_worker_endpoints) — the max length of a DNS name.
is_valid_host() {
    [[ "$1" =~ ^[A-Za-z0-9.:_-]{1,253}$ ]]
}

# A bare TCP port, 1–65535, no leading zero. Used to validate dashboard.port (#740) before it is
# rendered into the Caddyfile site address — the digits-only shape also guarantees no space/newline/`{`
# can slip in and break the Caddyfile or inject a directive, the same threat is_valid_host guards for
# the host. The `[1-9]` lead rejects a leading zero (e.g. `0899`), which would otherwise reach `-le`
# as an invalid octal literal and error instead of cleanly failing.
is_valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]
}

# Best-effort detection of the host's IANA timezone (Linux + macOS), used as the dashboard
# default when dashboard.timezone is "auto"/unset. Falls back to Etc/UTC if it can't tell.
detect_host_timezone() {
    local tz="" link
    # 1) Explicit TZ in the environment wins.
    if [ -n "${TZ:-}" ]; then
        tz="$TZ"
    # 2) systemd hosts.
    elif command -v timedatectl >/dev/null 2>&1; then
        tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    fi
    # 3) Debian/Ubuntu file.
    [ -z "$tz" ] && [ -r /etc/timezone ] && tz=$(cat /etc/timezone 2>/dev/null || true)
    # 4) /etc/localtime symlink (works on Linux + macOS): .../zoneinfo/<Area/City>.
    if [ -z "$tz" ] && [ -L /etc/localtime ]; then
        link=$(readlink /etc/localtime 2>/dev/null || true)
        tz=${link##*/zoneinfo/}
        [ "$tz" = "$link" ] && tz="" # prefix not found -> unusable
    fi
    # Sanity-check it looks like an IANA zone (Area/City, UTC, Etc/GMT+5, ...); else UTC.
    if [ -n "$tz" ] && [[ "$tz" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]]; then
        printf '%s' "$tz"
    else
        printf '%s' "Etc/UTC"
    fi
}
