# bash completion for localsend: files and folders, plus the names of the
# devices online now.
_localsend() {
    local cur=${COMP_WORDS[COMP_CWORD]} bin
    bin=$(command -v localsend-controller) || bin="$HOME/.cargo/bin/localsend-controller"
    if [[ $cur == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W '--list --help' -- "$cur")
        return
    fi
    # Device names come from the network, so they are compared as plain
    # strings: compgen -W would expand $(...) and backticks in them.
    local name devices
    mapfile -t devices < <("$bin" send --list 2>/dev/null)
    COMPREPLY=()
    for name in "${devices[@]}"; do
        [[ $name == "$cur"* ]] && COMPREPLY+=("$name")
    done
    mapfile -t -O "${#COMPREPLY[@]}" COMPREPLY < <(compgen -f -- "$cur")
    # Also quotes what bash inserts, devices included.
    compopt -o filenames 2>/dev/null
}
complete -F _localsend localsend
