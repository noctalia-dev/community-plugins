#!/usr/bin/env bash
# find-claude-md.sh ROOT [PRUNE_PATH...]: one absolute path per line for every CLAUDE.md
# under ROOT (symlinks too: CLAUDE.md -> AGENTS.md is common). Skips VCS, dependency and
# cache dirs, Claude Code worktrees (copies of their repo's files), plus
# every PRUNE_PATH (the remote mounts the panel found, so a stalled share never stalls
# the scan). Derived from claude-cockpit's find-claude-md (nightwatch75, MIT).
root=${1:?usage: find-claude-md.sh ROOT [PRUNE_PATH...]}; shift
# Hidden dirs at the top of ROOT hold tool caches (~/.cargo, ~/.npm, ~/.local), not
# projects; ~/.claude and ~/.config are the exceptions, minus Claude's plugin cache.
prune=(-name .git -o -name node_modules -o -name .cache -o -name .venv -o -name target
       -o -path '*/.claude/worktrees' -o -path "$root/.claude/plugins" -o -path '*/go/pkg/mod'
       -o \( -path "$root/.*" ! -path "$root/.claude" ! -path "$root/.config" -prune -false \))
for p in "$@"; do prune+=(-o -path "$p"); done
find "$root" \( "${prune[@]}" \) -prune -o \( -type f -o -type l \) -name 'CLAUDE.md' -print 2>/dev/null
exit 0
