#!/bin/sh
# limits.sh CONFIG_DIR fetch: print Claude plan limits as [{label, percent, resets_at}] using Claude
# Code's own OAuth token. Read-only: we never refresh the token (Claude Code owns it); if it has
# expired we just fail until Claude Code refreshes it. The token goes to curl on stdin, so it
# never appears in the process list, and is never printed.
# limits.sh CONFIG_DIR hash: print the 16-hex-char sha256 prefix of the token, which is how the
# claude-dashboard plugin names its per-account cache file (cache-<hash>.json).
creds="${1:-$HOME/.claude}/.credentials.json"
token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
[ -n "$token" ] || { echo "no Claude Code OAuth token in $creds" >&2; exit 2; }
if [ "$2" = hash ]; then printf '%s' "$token" | sha256sum | cut -c1-16; exit 0; fi
expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$creds")
[ "$expires" -gt "$(($(date +%s) * 1000))" ] || { echo "OAuth token expired" >&2; exit 3; }
printf 'header = "Authorization: Bearer %s"\n' "$token" \
  | curl -sSf --max-time 15 -K - \
      -H 'anthropic-beta: oauth-2025-04-20' -H 'Content-Type: application/json' \
      https://api.anthropic.com/api/oauth/usage \
  | jq -c '
      # Prefer the generic "limits" list (covers per-model weekly limits like Fable); fall back
      # to the fixed five_hour / seven_day fields on older responses.
      if (.limits | type) == "array" and (.limits | length) > 0 then
        .limits | map({
          label: (if .kind == "session" then "5h"
                  elif .kind == "weekly_all" then "7d"
                  else ((.scope.model.display_name // .scope.surface.display_name // .group // "?") + " 7d") end),
          percent, resets_at })
      else
        [ ["5h", .five_hour], ["7d", .seven_day], ["Sonnet 7d", .seven_day_sonnet], ["Opus 7d", .seven_day_opus] ]
        | map(select(.[1] != null) | {label: .[0], percent: .[1].utilization, resets_at: .[1].resets_at})
      end'
