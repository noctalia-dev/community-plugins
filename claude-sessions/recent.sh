#!/bin/sh
# recent.sh COUNT CONFIG_DIR...: JSON array of the COUNT most recently touched sessions across the
# given Claude config dirs: {account, sessionId, cwd, title, prompt, mtime}.
n=${1:-20}; shift
for cfg in "$@"; do [ -d "$cfg/projects" ] && printf '%s\0' "$cfg/projects"; done \
  | xargs -0 -r -I{} find {} -mindepth 2 -maxdepth 2 -name '*.jsonl' -printf '%T@ %p\n' \
  | sort -rn | head -n "$n" |
while read -r t f; do
  cfg=${f%/projects/*}
  sid=$(basename "$f" .jsonl)
  # Config dirs may share one projects dir (e.g. ~/.claude-work/projects -> ~/.claude/projects), so
  # the path alone does not say which account ran the session. Claude Code creates
  # <config dir>/session-env/<sid> in the dir a session starts (or resumes) in: prefer the one
  # created first, which is the account the session was started in. Resuming rewrites the hook
  # files inside, so the mtime moves; use the birth time when the filesystem has it.
  owner=; owner_t=
  for c in "$@"; do
    d=$c/session-env/$sid
    [ -d "$d" ] || continue
    ct=$(stat -c %W "$d" 2>/dev/null) || continue
    [ "$ct" -gt 0 ] 2>/dev/null || ct=$(stat -c %Y "$d" 2>/dev/null) || continue
    if [ -z "$owner" ] || [ "$ct" -lt "$owner_t" ]; then owner=$c; owner_t=$ct; fi
  done
  [ -n "$owner" ] && cfg=$owner
  cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$f" | cut -d'"' -f4)
  [ -n "$cwd" ] || continue
  title=$(grep -F '"type":"ai-title"' "$f" | tail -n 1 | jq -r '.aiTitle // empty')
  prompt=$(grep -F "\"sessionId\":\"$sid\"" "$cfg/history.jsonl" 2>/dev/null | tail -n 1 | jq -r '.display // empty')
  [ -n "$title$prompt" ] || continue
  jq -nc --arg a "$cfg" --arg s "$sid" --arg c "$cwd" --arg t "$title" --arg p "$prompt" --argjson m "${t%.*}" \
    '{account: $a, sessionId: $s, cwd: $c, title: $t, prompt: ($p | gsub("\\s+"; " ") | .[0:120]), mtime: ($m * 1000)}'
done | jq -sc .
