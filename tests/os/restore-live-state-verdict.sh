# shellcheck shell=bash
#
# Shared by tests/os/run.sh's phase_install restore leg (drives it against a real KVM guest's
# `podman ps` + `podman inspect p2pool`) and tests/stack/run.sh's fixture unit test (drives it
# against canned strings): the restore leg's closing verdict, #1091. `config.json` landing on the
# restored disk proves only that the ARCHIVE was UNPACKED — it is a grep of a file the restore
# itself just wrote, true even if the stack never came back up under the restored config, exactly
# like #971 closed on the DIY channel (tests/integration/run.sh reads .pool.type out of LIVE
# state after restore+up). This pairs two live observations instead of the archived file: the
# stack containers actually running, and a value SOURCED FROM the restored config appearing in
# live state — the --wallet argument the stack's start path rendered into the p2pool container
# (`podman inspect p2pool`'s .Config.Cmd), not a re-read of the archive. Not p2pool's stratum
# stats (/api/state's .stratum.wallet): p2pool writes those only once a SYNCED monerod hands it a
# block template, and a restored guest boots a fresh chain, so that source failed by construction
# on the first live battery run (#1662).

# $1 = `podman ps --format '{{.Names}}'` output (space/newline-joined; may be empty/unreachable)
# $2 = the running p2pool container's --wallet argument (live; empty/"Unknown"/"null" all count
#      as unreadable — the two words are what the earlier /api/state source returned when absent)
# $3 = the wallet address the ORIGINAL backup was taken from
# Prints the verdict line on stdout; exit 0 = pass, 1 = fail.
restore_live_state_verdict() {
    local names="$1" live_wallet="$2" want="$3"
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*) ;;
    *)
        echo "the stack never came up on the restored machine (podman ps: '${names:-none}') — config.json on disk is not proof the machine is RUNNING what was restored (#1091)"
        return 1
        ;;
    esac
    case "$live_wallet" in
    "" | Unknown | null)
        echo "the stack is up but live state never carried a readable stratum wallet (got '${live_wallet:-none}')"
        return 1
        ;;
    esac
    if [ "$live_wallet" != "$want" ]; then
        echo "the stack is up but live state's wallet is '$live_wallet', not the restored '$want' — the restore landed a file but the running stack does not reflect it (#1091)"
        return 1
    fi
    echo "the restored machine's LIVE state (p2pool's own running config) carries the restored wallet — not just the unpacked archive file"
    return 0
}
