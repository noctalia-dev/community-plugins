#!/usr/bin/env bash
# open-desktop.sh URL: hand a claude:// link to the Claude desktop app, then bring its
# window to the front: Hyprland and others ignore the app raising itself while it sits on
# another workspace. Exits 10 when nothing handles claude:// links; the plugin then opens
# the session in a terminal instead.
. "$(dirname "$0")/wm.sh"
[ -n "$(xdg-mime query default x-scheme-handler/claude 2>/dev/null)" ] || exit 10
# In the background: outside GNOME and KDE, xdg-open runs the handler in the foreground,
# and a cold start of the app would block until the app quits.
xdg-open "$1" >/dev/null 2>&1 &
disown
# A cold start opens a new window, which takes focus on its own; a running app needs this.
sleep 0.5
pid=$(wm_recent_pids com.anthropic.claude | head -n1)
[ -n "$pid" ] && wm_focus_pid "$pid"
exit 0
