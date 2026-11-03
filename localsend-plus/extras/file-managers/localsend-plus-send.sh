#!/bin/sh
# Run by localsend-plus.nemo_action with the selected paths as arguments.
# A separate script keeps the % of printf out of the Exec line, where Nemo
# reads it as a field code. The number of paths goes first, so the plugin can
# refuse a name with a line break instead of reading it as two paths.
exec noctalia msg plugin 0rgl/localsend-plus:service all send "$(printf '%s\n' "$#" "$@")"
