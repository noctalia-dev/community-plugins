#!/usr/bin/env bash
# usage-stats.sh PRICING_JSON CACHE_DIR CONFIG_DIR...: token use and estimated cost from
# the transcripts, as the `usage` object in docs/DESIGN.md (without `updated`). Days are local calendar days; "7 days" and "30 days" end today, so the chart
# is never a lone Monday bar. Assistant lines repeat once per content block, so each
# message id + request id counts once (the last copy, which carries the final usage);
# forked sessions copy messages into a new file, so that holds across files too.
# Each transcript is reduced once per size, mtime and price-list date to one record per
# message in CACHE_DIR, so a refresh re-reads only the transcripts that changed. Claude
# Code deletes transcripts after cleanupPeriodDays (30 by default), but their records stay
# in CACHE_DIR: that is what the all-time total counts, from the first one seen.
# The five costliest sessions of the last 7 days get their title and project.
# Reads local files only: no network, no token. Replaces the counting half of
# get-claude-usage (jrohland/noctalia-v5-claudecode via claude-cockpit, MIT).
set -u
dir=$(dirname "$0")
pricing=$(cat "${1:?usage: usage-stats.sh PRICING_JSON CACHE_DIR CONFIG_DIR...}" 2>/dev/null) || pricing='{}'
printf '%s' "$pricing" | jq -e 'type == "object"' >/dev/null 2>&1 || pricing='{}'
cache=${2:?usage: usage-stats.sh PRICING_JSON CACHE_DIR CONFIG_DIR...}
shift 2
mkdir -p -- "$cache"
priced=$(printf '%s' "$pricing" | jq -r '.updated // ""')
days=$(for i in 6 5 4 3 2 1 0; do date -d "$i days ago" +%F; done | jq -Rsc 'split("\n")[:7]')
labels=$(for i in 6 5 4 3 2 1 0; do date -d "$i days ago" +%a; done | jq -Rsc 'split("\n")[:7]')

# One JSON line per billed message: {k, day, dow (1 = Monday), hour, model, session,
# tokens, cost}. Bump SCHEMA when this shape changes, so cached files are rebuilt.
SCHEMA=3
reduce_file() {
  grep -h -F '"type":"assistant"' -- "$1" 2>/dev/null | jq -L "$dir" -nRc --argjson p "$pricing" '
    include "pricing";
    def tokens: (.input_tokens // 0) + (.output_tokens // 0)
      + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0);
    def cost($m): price($m) as $r | if $r == null then 0 else usage_cost($r) end;
    reduce (inputs | fromjson? | select(.type == "assistant" and (.message.usage | type) == "object")) as $o ({};
      (($o.message.id // $o.uuid // "") + ":" + ($o.requestId // "")) as $k
      | ($o.timestamp // "" | sub("\\.[0-9]+"; "") | fromdateiso8601? // 0) as $ts
      | .[$k] = { k: $k, day: ($ts | strflocaltime("%Y-%m-%d")),
          dow: ($ts | strflocaltime("%u") | tonumber), hour: ($ts | strflocaltime("%H") | tonumber),
          model: ($o.message.model // ""), session: ($o.sessionId // ""),
          tokens: ($o.message.usage | tokens), cost: ($o.message.usage | cost($o.message.model)) })
    | .[]'
}

# Brings the cache up to date with every transcript, then prints all cached records,
# including those of transcripts Claude Code has since deleted. A record copied into
# several files (forks, a config dir listed twice) is counted once by its key below.
records() {
  local i=0 cfg size mtime f name key entry
  for cfg in "$@"; do
    i=$((i + 1))
    [ -d "$cfg/projects" ] || continue
    while IFS=$'\t' read -r size mtime f; do
      name=${f#"$cfg/projects/"}; name="$i-${name//\//_}"
      key="$size:$mtime:$priced:$SCHEMA"
      entry="$cache/$name"
      [ -f "$entry.key" ] && [ "$(< "$entry.key")" = "$key" ] && continue
      reduce_file "$f" > "$entry.tmp" && mv -f -- "$entry.tmp" "$entry" && printf '%s' "$key" > "$entry.key"
      rm -f -- "$entry.tmp"
    done < <(find "$cfg/projects" -name '*.jsonl' -printf '%s\t%T@\t%p\n' 2>/dev/null)
  done
  for entry in "$cache"/*; do
    [[ "$entry" == *.key || "$entry" == *.tmp ]] || cat -- "$entry"
  done
}

shopt -s nullglob
records "$@" \
  | jq -nc --argjson days "$days" --argjson labels "$labels" \
      --arg today "$(date +%F)" --arg month "$(date -d '29 days ago' +%F)" '
    reduce inputs as $r ({}; .[$r.k] = $r)
    | [.[]] as $all
    | ($all | map(select(.day >= $days[0]))) as $week
    | ($all | map(select(.day >= $month))) as $mon
    | ($all | map(select(.day == $today))) as $tod
    | { days: $labels,
        daily: [$days[] as $d | $week | map(select(.day == $d) | .tokens) | add // 0],
        dailyCost: [$days[] as $d | $week | map(select(.day == $d) | .cost) | add // 0],
        todayTokens: ($tod | map(.tokens) | add // 0), todayCost: ($tod | map(.cost) | add // 0),
        d7Tokens: ($week | map(.tokens) | add // 0), d7Cost: ($week | map(.cost) | add // 0),
        d30Tokens: ($mon | map(.tokens) | add // 0), d30Cost: ($mon | map(.cost) | add // 0),
        allTokens: ($all | map(.tokens) | add // 0), allCost: ($all | map(.cost) | add // 0),
        allSince: ($all | map(.day | select(. != "1970-01-01")) | min // ""),
        d7Messages: ($week | length), d7Sessions: ($week | map(.session) | unique | length),
        d7Models: ($week | group_by(.model | split("-")[1] // .)
          | map({ key: (.[0].model | split("-")[1] // .), value: (map(.tokens) | add) })
          | map(select(.key != "" and .key != "<synthetic>")) | from_entries),
        topSessions: ($week | group_by(.session)
          | map({ id: .[0].session, cost: (map(.cost) | add), tokens: (map(.tokens) | add) })
          | sort_by(-.cost) | .[:5]),
        # Cost by weekday (Monday first) and hour over 30 days: when Claude gets used.
        heat: [range(1; 8) as $d | [range(0; 24) as $h
          | $mon | map(select(.dow == $d and .hour == $h) | .cost) | add // 0]] }' \
  | { read -r usage
      # Title and project of each top session, from its transcript.
      top=$(printf '%s' "$usage" | jq -r '.topSessions[].id')
      for id in $top; do
        [[ "$id" =~ ^[0-9a-fA-F-]+$ ]] || continue
        f=$(for cfg in "$@"; do find "$cfg/projects" -mindepth 2 -maxdepth 2 -name "$id.jsonl" -print -quit 2>/dev/null; done | head -n 1)
        [ -n "$f" ] || continue
        { grep -m1 -F '"cwd":"' -- "$f"; grep -F '"type":"ai-title"' -- "$f" | tail -n 1; } \
          | jq -sc --arg id "$id" '{ id: $id, cwd: (map(select(.cwd)) | first | .cwd // ""),
              title: (map(select(.aiTitle)) | last | .aiTitle // "") }'
      done | jq -sc --argjson u "$usage" '(map({ (.id): . }) | add // {}) as $meta
        | $u | .topSessions |= map(. + ($meta[.id] // {}))'
    }
