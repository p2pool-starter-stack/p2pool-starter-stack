# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance media console-read bound (#1823): the confirm gate's per-second keypress read must not
# be able to freeze the poll loop, even when the underlying console read blocks past its budget.
# A getty sharing the console can leave the tty in that state, so bash's own `read -t` is not
# honoured and the read hangs — freezing media_confirm_gate on its first iteration so it never
# re-checks whether the stick was pulled (#1061 recurs; PR #1220 fixed the write path, not the
# read). The sibling test-appliance-media.sh cannot cover this: its confirm-gate rows STUB
# media_read_key, so the real read primitive never runs. This fragment drives the REAL
# media_read_key / media_confirm_gate against a no-writer FIFO — opening it blocks until a writer
# that never comes, standing in for "a read that ignores its 1s timeout". The fix keeps bash's
# `read -N 1` (which borrows the tty in one-character mode, so a bare key is delivered without
# Enter) and bounds it with an external `timeout`, so the loop keeps polling and still detects the
# pull. The keypress half is proven on a REAL pty, not the FIFO — a FIFO has no line discipline, so
# it cannot tell a one-character read from a plain byte read that would wait for Enter and turn
# the documented 'n' cancel into a silent no-op.
# Sourced by tests/stack/run.sh.
#
# Re-derivations: none. $SANDBOX and $ROOT come from lib.sh; $MCC and $STUCK_TTY/$PRESENT_STATE
# beneath it are assigned here, and the media_* functions come from
# $ROOT/os/overlay/pithead-media-config, which each block sources for itself.

echo "== unit: media confirm gate cannot be frozen by a stuck console read (#1823) =="
MCC="$SANDBOX/media-console"
mkdir -p "$MCC"
STUCK_TTY="$MCC/stuck-tty" # no writer ever opens it, so any open/read on it blocks forever
PRESENT_STATE="$MCC/present-state"
rm -f "$STUCK_TTY" "$PRESENT_STATE"
mkfifo "$STUCK_TTY"

# The gate sees the media present on its first poll and pulled on its second. If the console read
# on the first poll blocks past its budget, the loop never reaches the second poll and never sees
# the pull — the #1823 hang. A bounded read lets iteration 1 finish and iteration 2 abort. The
# whole call runs under an outer `timeout` so the UNFIXED read hanging shows as a non-zero rc and
# an empty verdict rather than wedging the suite.
mc_out=$(
    export PITHEAD_MEDIA_TTY="$STUCK_TTY"
    timeout 15 bash -c '
        source "'"$ROOT"'/os/overlay/pithead-media-config"
        _sf="'"$PRESENT_STATE"'"
        media_device_present() { [ -e "$_sf" ] && return 1; : >"$_sf"; return 0; }
        media_confirm_gate /dev/fake 3
    '
)
mc_rc=$?
assert_eq "a stuck console read does not freeze the confirm gate (it returns within the 15s bound)" "$mc_rc" "0"
assert_eq "with the media pulled, a stuck console read still aborts the pending change" "$mc_out" "abort"

# Positive control on a real pty in the kernel-default canonical mode. First the fixture itself
# (the pty IS canonical — otherwise the legs below prove nothing), then a bare 'a' and a bare 'n'
# must each come back through the REAL media_read_key at once. Last, the mechanism the getty's
# safety rests on: a read the OUTER bound kills mid-flight must leave the tty canonical (bash
# restores it on a terminating signal), or a stuck iteration would strand the login prompt in
# one-character mode. `timeout 1` around an inner `read -t 30` makes the kill the only way out.
mc_pty=$(
    PITHEAD_MEDIA_SRC="$ROOT/os/overlay/pithead-media-config" python3 - <<'PY' 2>/dev/null
import os, pty, subprocess, termios, time
src = os.environ["PITHEAD_MEDIA_SRC"]
def leg(cmd, feed):
    m, s = pty.openpty()
    canon = bool(termios.tcgetattr(s)[3] & termios.ICANON)
    env = dict(os.environ, PITHEAD_MEDIA_TTY=os.ttyname(s))
    p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    time.sleep(0.3)
    if feed:
        os.write(m, feed)
    out, _ = p.communicate(timeout=10)
    after = bool(termios.tcgetattr(s)[3] & termios.ICANON)
    os.close(m); os.close(s)
    return int(canon), out.decode(), p.returncode, int(after)
# "$1" with a "_" for $0: sourcing via $0 would satisfy the script's own run-as-main guard.
read_key = ["bash", "-c", 'source "$1"; media_read_key 2', "_", src]
c1, o1, r1, _ = leg(read_key, b"a")
_, o2, r2, _ = leg(read_key, b"n")
_, _, r3, a3 = leg(["timeout", "1", "bash", "-c", 'read -r -t 30 -N 1 k <"$PITHEAD_MEDIA_TTY"'], b"")
print(f"canon={c1} a={o1}:{r1} n={o2}:{r2} killed_rc={r3} canon_after_kill={a3}")
PY
)
assert_contains "control: the test pty is in canonical mode, where a plain byte read would wait for Enter" "$mc_pty" "canon=1 "
assert_contains "a bare 'a' on a canonical console is delivered at once by the bounded read" "$mc_pty" " a=a:0 "
assert_contains "a bare 'n' on a canonical console is delivered at once by the bounded read" "$mc_pty" " n=n:0 "
assert_contains "a read killed by the outer bound leaves the console canonical (the login prompt stays usable)" "$mc_pty" "killed_rc=124 canon_after_kill=1"
rm -f "$STUCK_TTY" "$PRESENT_STATE"
