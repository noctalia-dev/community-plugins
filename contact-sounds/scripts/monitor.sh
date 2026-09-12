#!/usr/bin/env bash
# contact-sounds notification monitor.
#
# Watches the org.freedesktop.Notifications D-Bus interface for Notify() calls
# and prints one record per notification, fields joined with the ASCII record
# separator (\x1e), so the Luau service can safely split them even when titles
# contain tabs, pipes or commas:
#
#   <app_name> \x1e <summary> \x1e <body>
#
# The Notify() method signature is:
#   (app_name: str, replaces_id: u32, app_icon: str, summary: str, body: str,
#    actions: array, hints: dict, expire_timeout: int)
# so the 1st, 3rd and 4th "string ..." argument lines are app_name, summary,
# body respectively.

exec dbus-monitor --session "interface='org.freedesktop.Notifications',member='Notify'" | gawk '
function unquote(line,   n, i, out) {
  # strip a single pair of surrounding quotes, tolerating escaped inner quotes
  if (line !~ /^"/) { return line }
  line = substr(line, 2)
  n = length(line)
  out = ""
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (c == "\"") {
      prev = (i > 1) ? substr(line, i - 1, 1) : ""
      if (prev != "\\") { return out }
      out = out c          # escaped ("\") quote: keep it
    } else if (c == "\\") {
      nextc = substr(line, i + 1, 1)
      if (nextc == "\"")   # \" -> "
      { out = out nextc; i++ }
      else
      { out = out c }
    } else {
      out = out c
    }
  }
  return out
}

/^[^ \t]/ {
  mode = ($0 ~ /member=Notify/) ? 1 : 0
  idx = 0; app = ""; title = ""; body = ""
  next
}

mode == 1 && /^[ \t]*string[ \t]+"/ {
  line = $0
  sub(/^[ \t]*string[ \t]+/, "", line)
  idx++
  val = unquote(line)
  if (idx == 1) { app = val }
  else if (idx == 3) { title = val }
  else if (idx == 4) {
    body = val
    printf "%s\x1e%s\x1e%s\n", app, title, body
    fflush()
    idx = 0; app = ""; title = ""; body = ""
  }
}
'