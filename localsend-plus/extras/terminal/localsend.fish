# fish completion for localsend: files and folders, plus the names of the
# devices online now.
function __localsend_devices
    set -l bin (command -s localsend-controller)
    or set bin ~/.cargo/bin/localsend-controller
    $bin send --list 2>/dev/null
end

complete -c localsend -F
complete -c localsend -a '(__localsend_devices)' -d 'LocalSend device'
complete -c localsend -l list -d 'List the devices online now'
