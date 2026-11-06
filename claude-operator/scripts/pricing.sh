#!/usr/bin/env bash
# pricing.sh OUT_FILE CURRENCY_API_URL
#
# Refreshes OUT_FILE with Claude model prices and USD exchange rates:
#   { updated: "YYYY-MM-DD",
#     models:   { "claude-opus-4-7": { input, output, cache_read, cache_write, cache_write_1h, max } },
#     families: { "opus": "claude-opus-5-5" },   # newest model per family, for unknown ids
#     rates:    { "GBP": 0.75, ... } }
# Prices are USD per token; cache_write is the 5-minute cache rate, cache_write_1h the
# 1-hour one. max is the context window in tokens. Model ids drop the
# -YYYYMMDD snapshot suffix, the way transcripts name them. Either half that fails to
# download keeps its previous value, so a network blip never empties the file; `updated`
# moves to today only when the prices downloaded, so a failed day is retried.
# No token or account data is involved: both sources are public.
set -u

out=${1:?usage: pricing.sh OUT_FILE CURRENCY_API_URL}
rates_url=${2:-https://api.frankfurter.dev/v1/latest}
litellm=https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json

old=$(cat "$out" 2>/dev/null) || old='{}'
printf '%s' "$old" | jq -e 'type == "object"' >/dev/null 2>&1 || old='{}'

models=$(curl -sSf --max-time 20 "$litellm" | jq -c '
  [ to_entries[]
    | select(.value.litellm_provider == "anthropic" and .value.mode == "chat"
             and (.key | test("^claude-[a-z]+-[a-z0-9-]+$"))
             and (.value.input_cost_per_token // 0) > 0)
    | { key: (.key | sub("-[0-9]{8}$"; "")),
        value: { input: .value.input_cost_per_token,
                 output: (.value.output_cost_per_token // 0),
                 cache_read: (.value.cache_read_input_token_cost // 0),
                 cache_write: (.value.cache_creation_input_token_cost // 0),
                 cache_write_1h: (.value.cache_creation_input_token_cost_above_1hr
                                  // .value.cache_creation_input_token_cost // 0),
                 max: (.value.max_input_tokens // null) } } ]
  | from_entries') || models=
updated=$(date +%F)
if ! printf '%s' "$models" | jq -e 'type == "object" and length > 0' >/dev/null 2>&1; then
  models=$(printf '%s' "$old" | jq -c '.models // {}')
  updated=$(printf '%s' "$old" | jq -r '.updated // ""')
fi

rates=$(curl -sSf --max-time 10 "$rates_url?from=USD&to=EUR,GBP,JPY,CNY,CHF,AUD,CAD,INR" | jq -c '.rates') || rates=
printf '%s' "$rates" | jq -e 'type == "object" and length > 0' >/dev/null 2>&1 \
  || rates=$(printf '%s' "$old" | jq -c '.rates // {}')

# Newest per family: compare the numeric version parts ("opus-4-10" > "opus-4-9");
# non-numeric ids such as "mythos-preview" sort first so a release always wins.
jq -n --argjson models "$models" --argjson rates "$rates" --arg updated "$updated" '
  { updated: (if $updated == "" then null else $updated end), models: $models, rates: $rates,
    families: ($models | keys
      | map({ id: ., family: split("-")[1],
              version: (split("-")[2:] | map(tonumber? // -1)) })
      | group_by(.family) | map(max_by(.version) | { key: .family, value: .id })
      | from_entries) }' > "$out.tmp" && mv -f "$out.tmp" "$out"
