#!/bin/sh
# remote.sh CONFIG_DIR: print the account's live Remote Control sessions (on any machine) as
# [{id, title, category, needs, detail, model, context, maxContext, mode, branch, lastEventAt}],
# id being the claude.ai/code session id. Uses Claude Code's own OAuth token the same read-only way
# limits.sh does (token on curl's stdin, never printed). This is the internal endpoint Claude Code
# lists sessions with; results come newest first, so live ones are always in the first page.
# Stale records keep connection_status "connected" after they're archived, so require "active" too.
cfg=${1:-$HOME/.claude}
creds="$cfg/.credentials.json"
[ "$cfg" = "$HOME/.claude" ] && info="$HOME/.claude.json" || info="$cfg/.claude.json"
token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
[ -n "$token" ] || { echo "no Claude Code OAuth token in $creds" >&2; exit 2; }
expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$creds")
[ "$expires" -gt "$(($(date +%s) * 1000))" ] || { echo "OAuth token expired" >&2; exit 3; }
org=$(jq -r '.oauthAccount.organizationUuid // empty' "$info" 2>/dev/null)
[ -n "$org" ] || { echo "no organization in $info" >&2; exit 2; }
printf 'header = "Authorization: Bearer %s"\n' "$token" \
  | curl -sSf --max-time 15 -K - \
      -H 'anthropic-beta: ccr-byoc-2025-07-29' -H 'anthropic-version: 2023-06-01' -H "x-organization-uuid: $org" \
      'https://api.anthropic.com/v1/code/sessions?limit=100' \
  | jq -c '[.data[]
      | select(.environment_kind == "bridge" and .status == "active" and .connection_status == "connected")
      | .external_metadata as $m
      | { id: (.id | sub("^cse_"; "session_")), title,
          category: ($m.post_turn_summary.status_category // null),
          needs: ($m.post_turn_summary.needs_action // ""),
          detail: ($m.post_turn_summary.status_detail // ""),
          model: (($m.model // .config.model // null) | if . then sub("^claude-"; "") else . end),
          context: $m.context_usage.used_tokens, maxContext: $m.context_usage.max_tokens,
          mode: ($m.permission_mode // null),
          branch: ([($m.current_branches // {})[]] | first),
          lastEventAt: (.last_event_at // .updated_at) }]'
