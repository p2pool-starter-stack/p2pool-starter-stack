#!/usr/bin/env bash
#
# Protocol-level ZMQ (ZMTP 3.x) probe for monerod's block-notification PUB socket (#1497).
#
# Why a protocol probe and not a TCP dial. The installer preflight's reachability check for
# monero.remote.zmq_port is a bare TCP connect, and a bare TCP connect SUCCEEDS against a
# docker-published port with nothing behind it — docker-proxy accepts the connection itself.
# Measured on the bench 2026-08-29: a `sleep` container publishing 127.0.0.1:28099->19999
# answered the preflight's exact gesture with rc=0. Nothing downstream covers ZMQ either:
# p2pool's healthcheck is a TCP connect to its OWN stratum port, and before this file
# `git grep -niE zmq -- tests/integration/` returned ZERO. So an offline or ZMQ-dead node can
# pass the preflight, pass monero_caught_up, bring the stack up, and starve p2pool with nothing
# able to notice — a SKIPPED->PASSED with no failure mode, which is worse than the skip.
#
# An accept() cannot satisfy this probe: it speaks the ZMTP 3.x greeting and the NULL-mechanism
# READY exchange, and it reads the peer's advertised Socket-Type.
#
# The handshake alone is tier A, and it is NOT enough: MEASURED on the bench 2026-08-30, a
# permanently-silent XPUB (a peer that completes the greeting and the READY exchange, then
# publishes nothing) and a live monerod are INDISTINGUISHABLE to it — both "ok ... XPUB". So this
# file also carries tier B: SUBSCRIBE, then wait for the peer to actually send something. That
# separates the two by construction, and the controlled pair is in selftest-zmq-probe.sh.
#
# Tier B asserts the publisher is not SILENT, which is the failure class #1497 is about (an
# offline or ZMQ-dead node starving p2pool). It deliberately does NOT assert that the message was
# a BLOCK notification — that needs a new block, whose wait is minutes and unbounded, where any
# published frame arrives in seconds. The remainder stays a counted skip in run.sh, named for
# what it is rather than left in a comment.
#
# THE BUDGET IS 90s, AND THE SAMPLE COUNT IS PART OF THAT FIGURE. Time-to-first-message against
# the live node, 8 samples, sorted: 0.3 1.5 1.8 3.3 4.5 5.6 16.0 26.5 (seconds). The first three
# samples all landed under 6s and a 30s budget looked like 5x headroom; the tail arrived only as
# the sample grew, and 30s would have been a FLAKY RED in the release gate. 90s is ~3.4x the
# observed max. It is a CEILING, not a cost: the read returns on the first byte, so the happy
# path pays the median (~4s) and only a genuinely silent node pays the full budget.
#
# Split: the socket I/O runs ON THE TARGET through rx (the harness ships shell snippets, never
# files), and returns hex. Every verdict below it is a PURE function of that hex, so the
# self-test can drive each failure class from a fixture with no socket at all.
#
# shellcheck shell=bash

# The 64-byte ZMTP 3.1 greeting: signature (0xff, 8 pad, 0x7f), version 3.1, mechanism "NULL"
# NUL-padded to 20, as-server 0, 31 filler. Length is asserted by the self-test, not by eye.
ZMQ_GREETING_BYTES='\xff\x00\x00\x00\x00\x00\x00\x00\x00\x7f\x03\x01NULL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'
# A short COMMAND frame carrying READY with one property, Socket-Type=SUB (25-byte body).
ZMQ_READY_BYTES='\x04\x19\x05READY\x0bSocket-Type\x00\x00\x00\x03SUB'

# --- Pure verdicts over the hex the target returns ---------------------------

# Two hex chars at byte offset $2 of hex string $1.
zmq_hex_byte() { printf '%s' "${1:$(($2 * 2)):2}"; }

# Decode a hex string to ASCII, dropping NUL padding. Pure.
zmq_hex_ascii() { printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')" | tr -d '\0'; }

# zmq_greeting_verdict <hex> -> prints "ok <major>.<minor> <mechanism>" or "<reason> <detail>".
# Returns 0 only for a well-formed ZMTP >=3 greeting. The `no-greeting` class is the one that
# matters: it is exactly what a published-but-dead port looks like.
zmq_greeting_verdict() {
    local h="${1,,}"
    if [ -z "$h" ]; then
        echo "no-greeting peer accepted the connection but sent no ZMTP greeting — a docker-published port with nothing behind it, or a listener that is not ZMQ at all"
        return 1
    fi
    if [ "${#h}" -lt 128 ]; then
        echo "short-greeting peer sent ${#h} hex chars, want 128 (64 bytes)"
        return 1
    fi
    if [ "$(zmq_hex_byte "$h" 0)" != "ff" ] || [ "$(zmq_hex_byte "$h" 9)" != "7f" ]; then
        echo "bad-signature not a ZMTP peer (signature $(zmq_hex_byte "$h" 0)…$(zmq_hex_byte "$h" 9), want ff…7f)"
        return 1
    fi
    local major minor
    major=$((16#$(zmq_hex_byte "$h" 10)))
    minor=$((16#$(zmq_hex_byte "$h" 11)))
    if [ "$major" -lt 3 ]; then
        echo "bad-version peer speaks ZMTP $major.$minor, want >=3"
        return 1
    fi
    echo "ok $major.$minor $(zmq_hex_ascii "${h:24:40}")"
}

# zmq_ready_socket_type <hex of the peer's command frame> -> prints "ok <SOCKET-TYPE>" or
# "<reason> <detail>". Walks the READY metadata rather than substring-matching it, so a
# Socket-Type appearing inside another property's value cannot be mistaken for the real one.
zmq_ready_socket_type() {
    local h="${1,,}" flags size i=0
    if [ -z "$h" ]; then
        echo "no-ready peer completed the greeting then sent no READY command"
        return 1
    fi
    flags=$((16#$(zmq_hex_byte "$h" 0)))
    if ((flags & 0x04)); then :; else
        echo "malformed-ready first frame is not a COMMAND (flags $(zmq_hex_byte "$h" 0))"
        return 1
    fi
    # Every length field below is read with `16#`, and `16#` on an EMPTY string is a fatal bash
    # arithmetic error, not a verdict — so a peer that stalls part-way through a header kills the
    # parser instead of being named (#1500). Bound each slice before reading it. A short header is
    # 2 bytes (flags, size); the long form is 9 (flags, then an 8-byte size).
    local hdr_bytes=2
    if ((flags & 0x02)); then hdr_bytes=9; fi
    if [ "${#h}" -lt $((hdr_bytes * 2)) ]; then
        echo "malformed-ready frame header is $((${#h} / 2)) bytes, want $hdr_bytes"
        return 1
    fi
    if ((flags & 0x02)); then
        size=$((16#${h:2:16}))
        i=9
    else
        size=$((16#$(zmq_hex_byte "$h" 1)))
        i=2
    fi
    # A long frame can declare a size that overflows the shell's own arithmetic and comes back
    # NEGATIVE, which then makes the substring below fatal too. Compare the declared size against
    # what actually arrived — that is the one bound an overflowed value cannot slip past.
    local avail=$(((${#h} - i * 2) / 2))
    if [ "$size" -lt 1 ] || [ "$size" -gt "$avail" ]; then
        echo "malformed-ready frame claims $size bytes, got $avail"
        return 1
    fi
    local body="${h:$((i * 2)):$((size * 2))}"
    local nlen name
    nlen=$((16#$(zmq_hex_byte "$body" 0)))
    name=$(zmq_hex_ascii "${body:2:$((nlen * 2))}")
    if [ "${name^^}" != "READY" ]; then
        echo "malformed-ready first command is [$name], want READY"
        return 1
    fi
    local p=$((1 + nlen)) klen key vlen val
    while [ "$p" -lt "$size" ]; do
        klen=$((16#$(zmq_hex_byte "$body" "$p")))
        p=$((p + 1))
        key=$(zmq_hex_ascii "${body:$((p * 2)):$((klen * 2))}")
        p=$((p + klen))
        # `p` can cross `size` INSIDE an iteration — the loop test above only bounds it on entry —
        # so a property whose 4-byte value length lands on the frame-body boundary leaves this
        # slice empty. That is the `16#` death above, reached from a well-formed READY prefix.
        if [ $(((p + 4) * 2)) -gt "${#body}" ]; then
            echo "malformed-ready property [$key] value length runs past the frame body"
            return 1
        fi
        vlen=$((16#${body:$((p * 2)):8}))
        p=$((p + 4))
        val=$(zmq_hex_ascii "${body:$((p * 2)):$((vlen * 2))}")
        p=$((p + vlen))
        # ZMTP property names are case-insensitive (RFC 23).
        if [ "${key,,}" = "socket-type" ]; then
            echo "ok ${val^^}"
            return 0
        fi
    done
    echo "no-socket-type READY carried no Socket-Type property"
    return 1
}

# --- Target-side I/O ---------------------------------------------------------

# The snippet run ON THE TARGET. Bash only — the harness cannot ship files, and python3 is not
# a dependency this harness may assume on an appliance. Reads the greeting, then the peer's
# command frame in two steps (header, then exactly the declared body) so a silent PUB socket
# does not cost a full timeout on the happy path.
# The connect is bounded SEPARATELY, and it has to be: `timeout` cannot wrap a redirection, so
# the `exec` below inherits only the kernel's SYN-retry deadline (commonly 20s-130s+). A closed
# port answers with RST in ~2ms, which is why the original never showed this — but a FILTERED or
# black-holed host, the realistic remote-mode failure, blocks far past the probe's budget with no
# attribution at all (#1500). A `timeout`-wrapped throwaway connect in a child shell is the one
# shape that bounds it without re-quoting the whole snippet: the child cannot hand its fd back, so
# the cost is a second connect on the reachable path, ~2ms against anything that answers.
zmq_probe_snippet() { # <host> <port> <timeout_s> [publish_budget_s]
    cat <<EOF
timeout $3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
case \$? in
0) ;;
124) echo "CONNECT-TIMEOUT"; exit 0 ;;
*) echo "CONNECT-FAIL"; exit 0 ;;
esac
exec 3<>/dev/tcp/$1/$2 2>/dev/null || { echo "CONNECT-FAIL"; exit 0; }
printf '$ZMQ_GREETING_BYTES' >&3
g=\$(timeout $3 head -c 64 <&3 | od -An -v -tx1 | tr -d ' \n')
echo "GREETING \$g"
# A peer that sent NO greeting cannot send a READY, and zmq_pub_verdict discards the READY
# result whenever the greeting verdict fails — so both reads below are pure cost against it.
# Skipping them cannot change a verdict, and it takes this probe's FOUNDING case, the
# published-but-dead port, from three budgets to one. Measured: 9015ms -> 3006ms at budget 3.
if [ -z "\$g" ]; then echo "READY "; exec 3<&-; exit 0; fi
printf '$ZMQ_READY_BYTES' >&3
hdr=\$(timeout $3 head -c 2 <&3 | od -An -v -tx1 | tr -d ' \n')
body=
if [ \${#hdr} -eq 4 ] && [ \$((16#\${hdr:0:2} & 2)) -eq 0 ]; then
  body=\$(timeout $3 head -c \$((16#\${hdr:2:2})) <&3 | od -An -v -tx1 | tr -d ' \n')
elif [ -n "\$hdr" ]; then
  # Only worth a second window if the peer sent SOMETHING. With an empty header a 512-byte
  # read can only return empty too (head -c 2 already drained what was there), so the
  # unconditional else burned a whole budget to re-derive the empty string it already had.
  # No backticks in this heredoc: it is unquoted, so they would run at generation time.
  body=\$(timeout $3 head -c 512 <&3 | od -An -v -tx1 | tr -d ' \n')
fi
echo "READY \$hdr\$body"
EOF
    # Generated OUTSIDE the heredoc on purpose: an interpolated `$(...)` line leaves a blank line
    # behind when it expands to nothing, so tier A's snippet text would no longer be what shipped.
    zmq_subscribe_lines "${4:-}"
    printf 'exec 3<&-\n'
}

# The tier-B half of the snippet, kept in its own generator so tier A's text is byte-identical
# when no publish budget is asked for. Emits nothing at all in that case.
#
# The subscription is a ZMTP message frame whose body is 0x01 (subscribe) + topic; an EMPTY topic
# subscribes to every topic the peer publishes, which is what makes the wait seconds rather than
# minutes. We then read exactly ONE byte. That is deliberate and not laziness: `timeout` kills
# `head` mid-buffer, so a larger read can DISCARD bytes that did arrive and report silence — a
# false red in a release gate. One byte cannot be truncated, and one byte is the whole claim:
# a peer that already passed the ZMTP handshake and advertised XPUB, and then sends data after a
# subscription, is publishing. What it published is not asserted here.
zmq_subscribe_lines() {
    [ -n "$1" ] || return 0
    cat <<EOF
printf '\x00\x01\x01' >&3
echo "PUBLISH \$(timeout $1 head -c 1 <&3 | od -An -v -tx1 | tr -d ' \n')"
EOF
}

# zmq_pub_verdict <target-output> <host> <port> — PURE. Composes the two verdicts over the raw
# text the target snippet printed, so every failure class is reachable in the self-test without a
# socket. Returns 0 only for a ZMTP peer advertising a PUBLISHER socket type.
zmq_pub_verdict() {
    local out="$1" host="$2" port="$3" greeting ready v
    case "$out" in *CONNECT-FAIL*)
        echo "connect-refused no TCP connection to $host:$port"
        return 1
        ;;
    esac
    # Distinct from connect-refused ON PURPOSE. A refusal is an answer — the host is up and the
    # port is closed. A timeout is the absence of one, and it points at a firewall, a partition or
    # a wrong address rather than at the node.
    case "$out" in *CONNECT-TIMEOUT*)
        echo "connect-timeout no answer from $host:$port within the probe budget — filtered, black-holed or the wrong address, not a refusal"
        return 1
        ;;
    esac
    greeting=$(printf '%s\n' "$out" | sed -n 's/^GREETING //p')
    ready=$(printf '%s\n' "$out" | sed -n 's/^READY //p')
    # Re-emit sub-verdicts with the endpoint attached: in a matrix log a bare reason cannot be
    # attributed to a row, and this probe runs once per scenario.
    v=$(zmq_greeting_verdict "$greeting") || {
        echo "${v%% *} $host:$port ${v#* }"
        return 1
    }
    v=$(zmq_ready_socket_type "$ready") || {
        echo "${v%% *} $host:$port ${v#* }"
        return 1
    }
    # MEASURED, not assumed: monerod's --zmq-pub block-notification socket advertises XPUB, not
    # PUB (Monero's zmq_pub is an XPUB so it can see subscriptions). Asserting PUB alone would
    # have been false-red against every real node. Both are publishers; a SUB/REQ/REP/DEALER here
    # means the port is not the block-notification feed.
    case "$v" in "ok PUB" | "ok XPUB")
        echo "ok $host:$port speaks ZMTP and advertises Socket-Type ${v#ok }"
        return 0
        ;;
    esac
    echo "socket-type-mismatch $host:$port is a ZMTP peer but advertises ${v#ok }, want PUB or XPUB"
    return 1
}

# zmq_pub_probe <host> <port> [timeout_s] — the I/O shell: run the snippet on the target, then
# hand its output to the pure verdict. Prints a one-line verdict; returns its code.
zmq_pub_probe() {
    local host="$1" port="$2" to="${3:-5}" out
    out=$(rx "$(zmq_probe_snippet "$host" "$port" "$to")" 2>/dev/null)
    zmq_pub_verdict "$out" "$host" "$port"
}

# zmq_publish_verdict <target-output> <host> <port> — PURE, over the same text the snippet
# printed. Tier B only: the caller runs the tier-A verdict first, so a handshake failure is
# already reported by the time this is reached. Returns 0 only when the peer published.
zmq_publish_verdict() {
    local out="$1" host="$2" port="$3" pub
    # A snippet run WITHOUT a publish budget prints no PUBLISH line at all. That is not silence,
    # it is an un-asked question, and reporting it as silence would be a fabricated failure.
    case "$out" in *PUBLISH*) ;;
    *)
        echo "not-probed no publish budget was given, so the peer was never asked to publish"
        return 1
        ;;
    esac
    pub=$(printf '%s\n' "$out" | sed -n 's/^PUBLISH //p')
    if [ -z "$pub" ]; then
        echo "silent $host:$port completed the ZMTP handshake and advertised a publisher socket, then published NOTHING within the budget — an offline or ZMQ-dead node looks exactly like this, and the handshake alone cannot see it"
        return 1
    fi
    echo "ok $host:$port published within the budget — the publisher is live, not silent"
    return 0
}

# zmq_publishes_probe <host> <port> [handshake_timeout_s] [publish_budget_s] — tier A THEN tier B
# over ONE connection. Returns tier A's verdict unchanged when the handshake fails, so a dead port
# is never reported as a silent publisher: those are different defects and want different fixes.
zmq_publishes_probe() {
    local host="$1" port="$2" to="${3:-5}" pub="${4:-90}" out v
    out=$(rx "$(zmq_probe_snippet "$host" "$port" "$to" "$pub")" 2>/dev/null)
    v=$(zmq_pub_verdict "$out" "$host" "$port") || {
        printf '%s\n' "$v"
        return 1
    }
    zmq_publish_verdict "$out" "$host" "$port"
}
