#!/usr/bin/env bash
# limits.sh CONFIG_DIR: print the account's plan and usage windows as
#   { subscription, tier, windows: [{ kind, group, model, percent, resets_at, severity }] }
# using Claude Code's own OAuth token, read-only. The token is passed to curl on stdin,
# so it never appears in the process list, and it is never printed or handed to Luau.
# It is never refreshed either: Claude Code owns it. Exit 2 = no token, 3 = expired
# (Claude Code refreshes it on its next start), 4 = rate limited (stdout: the seconds
# the server asked to wait, if it said), anything else = request failed.
# Derived from claude-sessions' limits.sh (lfdominguez, MIT).
creds="${1:-$HOME/.claude}/.credentials.json"
token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
[ -n "$token" ] || { echo "no Claude Code OAuth token in $creds" >&2; exit 2; }
expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$creds")
[ "$expires" -gt "$(($(date +%s) * 1000))" ] || { echo "OAuth token expired" >&2; exit 3; }
plan=$(jq -c '{ subscription: (.claudeAiOauth.subscriptionType // null), tier: (.claudeAiOauth.rateLimitTier // null) }' "$creds")
tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
  | curl -sS --max-time 15 -K - -D "$tmp/headers" -o "$tmp/body" -w '%{http_code}' \
      -H 'anthropic-beta: oauth-2025-04-20' -H 'Content-Type: application/json' \
      https://api.anthropic.com/api/oauth/usage) || exit 1
if [ "$code" = 429 ]; then
  echo "rate limited by Anthropic" >&2
  sed -n 's/^[Rr]etry-[Aa]fter: *\([0-9]*\).*/\1/p' "$tmp/headers" | head -n 1
  exit 4
fi
[ "$code" = 200 ] || { echo "HTTP $code from api/oauth/usage" >&2; exit 1; }
jq -c --argjson plan "$plan" '
      # The generic "limits" list covers per-model weekly windows (e.g. Fable); older
      # responses only have the fixed five_hour / seven_day fields.
      $plan + { windows: (
        if (.limits | type) == "array" and (.limits | length) > 0 then
          .limits | map({ kind, group,
            model: (.scope.model.display_name // .scope.surface.display_name // null),
            percent, resets_at, severity: (.severity // "normal") })
        else
          [ ["session", "session", .five_hour], ["weekly_all", "weekly", .seven_day] ]
          | map(select(.[2] != null) | { kind: .[0], group: .[1], model: null,
              percent: .[2].utilization, resets_at: .[2].resets_at, severity: "normal" })
        end) }' "$tmp/body"
