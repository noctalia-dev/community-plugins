#!/bin/sh
# Print the config dir (CLAUDE_CONFIG_DIR, or ~/.claude when unset) of every running claude process.
for pid in $(pgrep -x claude); do
  dir=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p')
  echo "${dir:-$HOME/.claude}"
done | sort -u
