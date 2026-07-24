# shellcheck shell=bash
#
# bash + zsh tab-completion for the pithead CLI (#94).
#
# bash — add to ~/.bashrc:
#   source /path/to/pithead-completion.bash
# zsh — add to ~/.zshrc (bashcompinit needs compinit loaded first):
#   autoload -U +X compinit && compinit
#   autoload -U +X bashcompinit && bashcompinit
#   source /path/to/pithead-completion.bash
#
# Completes subcommands, and service names after `logs`.

# Keep in sync with PITHEAD_COMMANDS in the pithead script — tests/stack/run.sh fails if the
# two lists drift.
_pithead_commands="setup apply up down restart upgrade logs status doctor support-bundle reset-dashboard backup restore control-run-pending onion-client-key rotate-dashboard-onion rotate-secrets render-quadlet version help"

# Service names = the top-level keys under `services:` in the docker-compose.yml next to the
# pithead being completed. $1 = path to that compose file.
_pithead_services() {
    awk '/^services:/ { in_services = 1; next }
        in_services && /^[^ ]/ { exit }
        in_services && /^  [A-Za-z0-9_-]+:/ { sub(/:.*/, ""); gsub(/ /, ""); print }' "$1" 2>/dev/null
}

_pithead() {
    local cur prev compose self link i
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
    if [ "$prev" = "logs" ]; then
        # Resolve the real script path so this works when pithead is invoked by bare name from
        # $PATH, not just from the install dir (#566). Bare name (no slash) -> ask the shell where
        # it lives; fall back to the old behavior if that fails.
        self="${COMP_WORDS[0]}"
        case "$self" in
        */*) ;;
        *) self="$(command -v -- "$self" 2>/dev/null)" || self="${COMP_WORDS[0]}" ;;
        esac
        # Follow symlinks portably instead of GNU-only `readlink -f` — dev checkouts run this on
        # macOS too (see the pithead script's other GNU/BSD splits). Bounded to dodge a symlink loop.
        i=0
        while [ -L "$self" ] && [ "$i" -lt 10 ]; do
            link="$(readlink -- "$self" 2>/dev/null)" || break
            case "$link" in
            /*) self="$link" ;;
            *) self="$(dirname "$self")/$link" ;;
            esac
            i=$((i + 1))
        done
        compose="$(dirname "$self")/docker-compose.yml"
        # shellcheck disable=SC2207  # service names never contain whitespace
        COMPREPLY=($(compgen -W "$(_pithead_services "$compose")" -- "$cur"))
        return
    fi
    # `restart` takes exactly one optional argument: tor (fresh guard selection, #424).
    if [ "$prev" = "restart" ]; then
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "tor" -- "$cur"))
        return
    fi
    # shellcheck disable=SC2207  # command names never contain whitespace
    COMPREPLY=($(compgen -W "$_pithead_commands" -- "$cur"))
}

complete -F _pithead pithead ./pithead
