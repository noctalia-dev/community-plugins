#!/bin/sh
# details.sh TRANSCRIPT SESSION_ID CONFIG_DIR: print a JSON summary of a Claude transcript.
# Titles/mode/todos can be far back, so grep the whole file for them; everything else comes from
# the tail (transcripts grow to many MB). The last typed prompt comes from the account's
# history.jsonl, since tool/agent traffic buries it in the transcript. Cost sums every billed
# message of the session and its subagents (only "usage" lines, so it stays fast).
dir=$(dirname "$0"); cfg=${3:-$HOME/.claude}
pricing="$cfg/pricing-cache.json"; [ -f "$pricing" ] || pricing="$HOME/.claude/pricing-cache.json"
prompt=$(grep -F "\"sessionId\":\"$2\"" "$cfg/history.jsonl" 2>/dev/null | tail -n 1 | jq -r '.display // empty')
cost=$(cat "$1" "${1%.jsonl}"/subagents/*.jsonl 2>/dev/null | grep -F '"usage"' \
  | jq -sc --slurpfile p "$pricing" -f "$dir/cost.jq" 2>/dev/null)
{ grep -h -e '"type":"ai-title"' -e '"type":"permission-mode"' -e '"name":"TodoWrite"' "$1"; tail -c 300000 "$1" | tail -n +2; } \
  | jq -sc --arg prompt "$prompt" --argjson cost "${cost:-null}" -f "$dir/details.jq"
