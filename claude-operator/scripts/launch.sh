#!/usr/bin/env bash
# launch.sh DIR [CMD...]: open a new tab in the most recently focused kitty, in DIR, running CMD
# (followed by a shell so the tab survives CMD exiting) or just a shell.
# Exits 10 when no kitty with remote control is available; the plugin then falls back to
# Noctalia's configured terminal.
. "$(dirname "$0")/wm.sh"
dir=$1; shift
command -v kitty >/dev/null || exit 10
# Resolve a bare "claude" (possibly after `env CLAUDE_CONFIG_DIR=...`) to its full path: tabs and
# terminals may not have ~/.local/bin on PATH.
claude=$(command -v claude || echo "$HOME/.local/bin/claude")
for a in "$@"; do shift; [ "$a" = claude ] && a=$claude; set -- "$@" "$a"; done
[ $# -gt 0 ] && set -- sh -c '"$@"; exec "${SHELL:-sh}"' _ "$@"
# Most recently used kitty first; instances started without remote control just refuse.
# Without a compositor window list (GNOME, KDE, ...), newest kitty process first.
wm_load
kpids=$(wm_recent_pids kitty)
[ -n "$kpids" ] || kpids=$(pgrep -n -x kitty; pgrep -x kitty)
for kpid in $kpids; do
  if kitty @ --to "unix:@kitty-$kpid" launch --type=tab --cwd="$dir" "$@" >/dev/null 2>&1; then
    wm_focus_pid "$kpid"
    exit 0
  fi
done
exit 10
