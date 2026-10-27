#!/usr/bin/env bash
# recent.sh COUNT CONFIG_DIR...: JSON array of the COUNT most recently touched sessions
# across the given Claude config dirs: [{account, sessionId, cwd, title, transcript, prompt,
# mtime}],
# mtime in epoch ms. Sessions with neither a title nor a prompt (opened and closed at
# once) are skipped. Derived from claude-sessions' recent.sh (lfdominguez, MIT).
n=${1:-20}; shift
for cfg in "$@"; do [ -d "$cfg/projects" ] && printf '%s\0' "$cfg/projects"; done \
  | xargs -0 -r -I{} find {} -mindepth 2 -maxdepth 2 -name '*.jsonl' -printf '%T@ %p\n' \
  | sort -rn |
# Newest first until COUNT are kept: skipped sessions (Agent SDK runs, empty ones) must
# not eat into the count.
{ kept=0
while [ "$kept" -lt "$n" ] && read -r t f; do
  cfg=${f%/projects/*}
  sid=$(basename "$f" .jsonl)
  # Config dirs may share one projects dir (e.g. ~/.claude-work/projects -> ~/.claude/projects),
  # so the path alone does not say which account ran the session. Claude Code creates
  # <config dir>/session-env/<sid> in the dir a session starts (or resumes) in: prefer the
  # one created first. Use birth times when every candidate has one, else mtimes for all.
  owner=; owner_t=; fmt=%W
  for c in "$@"; do
    d=$c/session-env/$sid
    [ -d "$d" ] && [ "$(stat -c %W "$d" 2>/dev/null || echo 0)" -eq 0 ] && fmt=%Y
  done
  for c in "$@"; do
    d=$c/session-env/$sid
    [ -d "$d" ] || continue
    ct=$(stat -c $fmt "$d" 2>/dev/null) || continue
    if [ -z "$owner" ] || [ "$ct" -lt "$owner_t" ]; then owner=$c; owner_t=$ct; fi
  done
  [ -n "$owner" ] && cfg=$owner
  line=$({ grep -m1 -F '"cwd":"' -- "$f"; grep -F -e '"type":"ai-title"' -e '"type":"last-prompt"' -- "$f"; } \
    | jq -sc --arg a "$cfg" --arg s "$sid" --arg f "$f" --argjson m "${t%.*}" '
        (map(select(.cwd)) | first) as $head
        | ($head.cwd // "") as $cwd
        | (map(select(.type == "ai-title")) | last | .aiTitle // "") as $title
        | (map(select(.type == "last-prompt")) | last | .lastPrompt // "") as $prompt
        # Sessions started through the Agent SDK (hooks, scripts) are not offered.
        | select($cwd != "" and ($title + $prompt) != "" and (($head.entrypoint // "") | startswith("sdk") | not))
        | { account: $a, sessionId: $s, cwd: $cwd, title: $title, transcript: $f,
            prompt: ($prompt | gsub("\\s+"; " ") | .[0:160]), mtime: ($m * 1000) }')
  [ -n "$line" ] && { printf '%s\n' "$line"; kept=$((kept + 1)); }
done; } | jq -sc .
