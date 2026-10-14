#!/bin/sh
# Print the config dir (CLAUDE_CONFIG_DIR, or ~/.claude when unset) of every running claude process.
# A process in its own mount namespace with another dir bind-mounted over ~/.claude (e.g. bwrap
# --bind DIR ~/.claude) reports DIR, mapped back to a path in this namespace.
for pid in $(pgrep -x claude); do
  dir=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p')
  if [ -z "$dir" ] && [ "$(readlink "/proc/$pid/ns/mnt")" != "$(readlink /proc/self/ns/mnt)" ]; then
    # mountinfo fields: 3 = device, 4 = root of the mount within its filesystem, 5 = mount point.
    # Find the mount of this namespace on the same device whose root is the longest prefix.
    dir=$(awk -v h="$HOME/.claude" '
      FNR == NR { if ($5 == h) { dev = $3; root = $4 } next }
      $3 == dev && (root == $4 || index(root, ($4 == "/" ? "/" : $4 "/")) == 1) && length($4) > best {
        best = length($4); rel = substr(root, length($4) + ($4 == "/" ? 1 : 2))
        p = (rel == "") ? $5 : ($5 == "/" ? "/" : $5 "/") rel
      }
      END { if (best) print p }' "/proc/$pid/mountinfo" /proc/self/mountinfo 2>/dev/null)
  fi
  echo "${dir:-$HOME/.claude}"
done | sort -u
