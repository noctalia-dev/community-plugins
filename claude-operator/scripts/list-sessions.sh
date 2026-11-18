#!/usr/bin/env bash
# list-sessions.sh CACHE_DIR CONFIG_DIR...: every saved Claude Code session as a JSON array
#   [{ account, id, path, cwd, branch, mtime, size, title, prompt, model, context, empty }]
# mtime in epoch ms. A session is <projects>/<encoded cwd>/<uuid>.jsonl; the <uuid>/
# subagents/ dirs beside it are not sessions and are never reached (-maxdepth 2).
# Each file is summarised once per size+mtime into CACHE_DIR/<id>.json, so a refresh
# costs one stat per unchanged session; cache entries of deleted sessions are dropped.
# Replaces claude-cockpit's list-claude-sessions (nightwatch75, MIT), which re-read
# every transcript on every refresh.
set -u
shopt -s nullglob
SCHEMA=2 # bump when the record shape changes, so cached summaries are rebuilt
cache=${1:?usage: list-sessions.sh CACHE_DIR CONFIG_DIR...}; shift
mkdir -p -- "$cache"
declare -A seen=()

summarise() { # FILE ACCOUNT MTIME_MS SIZE
  local f=$1
  { grep -m1 -F '"cwd":"' -- "$f"
    grep -F -e '"type":"ai-title"' -e '"type":"last-prompt"' -- "$f"
    tac -- "$f" | grep -m1 -F '"type":"assistant"'
    grep -q -F '"type":"user"' -- "$f" && echo '{"type":"--has-user"}'
  } | jq -sc --arg a "$2" --arg p "$f" --argjson m "$3" --argjson s "$4" '
    (map(select(.cwd)) | first // {}) as $head
    | (map(select(.type == "assistant")) | last // {}) as $last
    | ($last.message.usage // {}) as $u
    | { account: $a, id: ($p | split("/") | last | rtrimstr(".jsonl")), path: $p,
        cwd: ($head.cwd // ""), branch: ($head.gitBranch // "" | if . == "HEAD" then "" else . end),
        mtime: $m, size: $s,
        title: (map(select(.type == "ai-title")) | last | .aiTitle // ""),
        prompt: (map(select(.type == "last-prompt")) | first | .lastPrompt // "" | gsub("\\s+"; " ") | .[0:400]),
        model: ($last.message.model // "" | sub("^claude-"; "")),
        context: (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0)),
        empty: (any(.[]; .type == "--has-user") | not),
        # Started through the Agent SDK (a hook or script), not by a person.
        auto: ($head.entrypoint // "" | startswith("sdk")) }'
}

# Prints one record per line; runs as one pipeline stage, so `seen` and the cleanup at
# its end share a shell.
records() {
for cfg in "$@"; do
  [ -d "$cfg/projects" ] || continue
  while IFS=$'\t' read -r size mtime f; do
    id=${f##*/}; id=${id%.jsonl}
    [[ "$id" =~ ^[0-9a-fA-F-]+$ ]] || continue
    seen[$id]=1
    key="$size:$mtime:$cfg:$SCHEMA"
    entry="$cache/$id.json"
    if [ -f "$entry.key" ] && [ "$(< "$entry.key")" = "$key" ] && [ -s "$entry" ]; then
      cat -- "$entry"
    else
      ms=${mtime%.*}000
      summarise "$f" "$cfg" "$ms" "$size" > "$entry.tmp" && [ -s "$entry.tmp" ] \
        && mv -f -- "$entry.tmp" "$entry" && printf '%s' "$key" > "$entry.key" && cat -- "$entry"
      rm -f -- "$entry.tmp"
    fi
  done < <(find "$cfg/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' -printf '%s\t%T@\t%p\n' 2>/dev/null)
done
for entry in "$cache"/*.json; do
  id=${entry##*/}; id=${id%.json}
  [ -n "${seen[$id]:-}" ] || rm -f -- "$entry" "$entry.key"
done
}

records "$@" | jq -sc .
