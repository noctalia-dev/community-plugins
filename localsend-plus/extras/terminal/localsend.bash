# bash completion for localsend: files and folders, plus the names of the
# devices online now.
_localsend() {
    local cur=${COMP_WORDS[COMP_CWORD]} bin
    bin=$(command -v localsend-controller) || bin="$HOME/.cargo/bin/localsend-controller"
    if [[ $cur == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W '--list --help' -- "$cur")
        return
    fi
    local devices
    devices=$("$bin" send --list 2>/dev/null)
    mapfile -t COMPREPLY < <(IFS=$'\n' compgen -W "$devices" -- "$cur"; compgen -f -- "$cur")
    compopt -o filenames 2>/dev/null
}
complete -F _localsend localsend
