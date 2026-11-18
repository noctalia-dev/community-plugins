#!/bin/sh
# Full verification sweep. Run from inside the plugin directory.
#
# luau-analyze runs first and is not optional: the `luau` CLI returns a
# module's compile error as the module's *value* instead of raising, so a
# syntax error shows up as a baffling "attempt to call a nil value" three
# frames away. Analyze reports it at the right line.
#
# The CLI has no --definitions flag (that is luau-lsp), so it cannot know the
# host globals the entry scripts use. Nor does it pick up the repo-root
# .luaurc that community-plugins ships, which is what normally silences
# FunctionUnused -- entry points like update() and onClick() are called by the
# host, not from Luau. Both of those diagnostics are filtered; everything else,
# syntax errors included, still fails the build.
set -e

echo "== luau-analyze =="
analysis=$(luau-analyze $(find . -name '*.luau' -not -name 'noctalia.d.luau' | sort) 2>&1 || true)
filtered=$(printf '%s\n' "$analysis" \
  | grep -v "Unknown global 'noctalia'" \
  | grep -v "Unknown global 'ui'" \
  | grep -v "Unknown global 'barWidget'" \
  | grep -v "Unknown global 'shortcut'" \
  | grep -v "Unknown global 'panel'" \
  | grep -v "FunctionUnused" \
  | grep -v '^[[:space:]]*$' || true)
if [ -n "$filtered" ]; then
  printf '%s\n' "$filtered"
  echo "analysis failed"
  exit 1
fi
echo "clean"

echo "== tests =="
luau tests/run.luau

if command -v noctalia >/dev/null 2>&1; then
  echo "== manifest lint =="
  noctalia plugins lint .
fi

echo "== store limits =="
files=$(find . -type f -not -path './.git/*' | wc -l)
echo "files: $files (limit 200)"
[ "$files" -le 200 ] || { echo "too many files"; exit 1; }

desc=$(awk -F'"' '/^description = / {print $2}' plugin.toml)
echo "description: ${#desc} chars (limit 120)"
[ "${#desc}" -le 120 ] || { echo "description too long"; exit 1; }

[ -f catalog.toml ] && { echo "catalog.toml must not be committed"; exit 1; }

echo "all checks passed"
