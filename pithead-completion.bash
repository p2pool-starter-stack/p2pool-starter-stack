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
_pithead_commands="setup apply up down restart upgrade logs status doctor reset-dashboard backup restore onion-client-key rotate-dashboard-onion version help"

# Service names = the top-level keys under `services:` in the docker-compose.yml next to the
# pithead being completed. $1 = path to that compose file.
_pithead_services() {
    awk '/^services:/ { in_services = 1; next }
        in_services && /^[^ ]/ { exit }
        in_services && /^  [A-Za-z0-9_-]+:/ { sub(/:.*/, ""); gsub(/ /, ""); print }' "$1" 2>/dev/null
}

_pithead() {
    local cur prev compose
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
    if [ "$prev" = "logs" ]; then
        compose="$(dirname "${COMP_WORDS[0]}")/docker-compose.yml"
        # shellcheck disable=SC2207  # service names never contain whitespace
        COMPREPLY=($(compgen -W "$(_pithead_services "$compose")" -- "$cur"))
        return
    fi
    # shellcheck disable=SC2207  # command names never contain whitespace
    COMPREPLY=($(compgen -W "$_pithead_commands" -- "$cur"))
}

complete -F _pithead pithead ./pithead
