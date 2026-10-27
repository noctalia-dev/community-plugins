#!/usr/bin/env bash
# details.sh TRANSCRIPT PRICING_JSON: print a JSON summary of a live Claude Code session
# (shape: `d` in docs/DESIGN.md). Titles, permission mode, todos and the last prompt can
# sit far back, so the whole file is grepped for those line types; everything else comes
# from the tail, since transcripts grow to many MB. Cost sums every billed message of the
# session and its subagents, reading only the "usage" lines.
dir=$(dirname "$0")
t=${1:?usage: details.sh TRANSCRIPT PRICING_JSON}
pricing=$(cat "$2" 2>/dev/null) || pricing='{}'
printf '%s' "$pricing" | jq -e 'type == "object"' >/dev/null 2>&1 || pricing='{}'

cost=$(cat -- "$t" "${t%.jsonl}"/subagents/*.jsonl 2>/dev/null | grep -F '"usage"' \
  | jq -L "$dir" -sc --argjson p "$pricing" -f "$dir/cost.jq" 2>/dev/null)
{ grep -h -e '"type":"ai-title"' -e '"type":"permission-mode"' -e '"type":"last-prompt"' \
    -e '"name":"TodoWrite"' -e '"subtype":"turn_duration"' -- "$t"; tail -c 300000 -- "$t" | tail -n +2; } \
  | jq -L "$dir" -sc --argjson p "$pricing" --argjson cost "${cost:-null}" -f "$dir/details.jq"
