#!/usr/bin/env bash
# Tests for get-claude-usage script
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/get-claude-usage"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}
assert_match() {
    if echo "$1" | grep -qE "$2"; then pass "$3"; else fail "$3 (no match for '$2')"; fi
}

# --- Setup isolated environment ---
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

setup_env() {
    local name="$1"
    local dir="$TMPDIR_ROOT/$name"
    mkdir -p "$dir/.claude/projects/test-project"
    echo "$dir"
}

# Mock curl: always returns empty JSON (avoids real network calls)
mock_curl="$TMPDIR_ROOT/curl"
cat > "$mock_curl" << 'CURLEOF'
#!/usr/bin/env bash
echo '{}'
CURLEOF
chmod +x "$mock_curl"

run_script() {
    local home_dir="$1"
    # Override HOME and prepend mock curl to PATH
    HOME="$home_dir" PATH="$TMPDIR_ROOT:$PATH" bash "$SCRIPT" 2>/dev/null
}

# Build a JSONL fixture line
# Usage: make_jsonl_line <date> <model> <input> <output> <cache_read> <cache_write> <sessionId>
make_jsonl_line() {
    local date="$1" model="$2" inp="$3" out="$4" cr="$5" cw="$6" sess="$7"
    printf '{"type":"assistant","timestamp":"%sT12:00:00Z","sessionId":"%s","message":{"model":"%s","usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d}}}\n' \
        "$date" "$sess" "$model" "$inp" "$out" "$cr" "$cw"
}

# ============================================================
echo "=== Test 1: Output format — all 21 keys present ==="
# ============================================================
ENV1=$(setup_env "test1")
OUTPUT1=$(run_script "$ENV1")

EXPECTED_KEYS="SUBSCRIPTION_TYPE RATE_LIMIT_TIER FIVE_HOUR_UTIL FIVE_HOUR_RESET SEVEN_DAY_UTIL SEVEN_DAY_RESET EXTRA_USAGE_ENABLED WEEK_MESSAGES WEEK_SESSIONS WEEK_TOKENS WEEK_MODELS ALLTIME_SESSIONS ALLTIME_MESSAGES FIRST_SESSION DAILY MONTH_TOKENS TODAY_COST WEEK_COST MONTH_COST DAILY_COSTS USD_EUR_RATE"
for key in $EXPECTED_KEYS; do
    if echo "$OUTPUT1" | grep -q "^${key}="; then
        pass "key $key present"
    else
        fail "key $key missing"
    fi
done

# ============================================================
echo "=== Test 2: Token aggregation ==="
# ============================================================
ENV2=$(setup_env "test2")
TODAY=$(date +%Y-%m-%d)
DOW=$(date +%u)  # 1=Monday, 7=Sunday

# Pick a "second day" that's in the same calendar week as today
# If today is Monday (DOW=1), there's no earlier day this week, so use tomorrow (Tuesday)
if [ "$DOW" -eq 1 ]; then
    OTHER_DAY=$(date -d "1 day" +%Y-%m-%d)
    OTHER_IDX=1  # Tuesday = index 1
else
    OTHER_DAY=$(date -d "1 day ago" +%Y-%m-%d)
    OTHER_IDX=$((DOW - 2))  # Yesterday's index
fi
TODAY_IDX=$((DOW - 1))

# Create JSONL fixtures: 2 messages today (session A), 1 message on other day (session B)
{
    make_jsonl_line "$TODAY" "claude-opus-4-20250514" 100 200 50 30 "sess-a"
    make_jsonl_line "$TODAY" "claude-opus-4-20250514" 150 100 0 0 "sess-a"
    make_jsonl_line "$OTHER_DAY" "claude-sonnet-4-20250514" 80 60 20 10 "sess-b"
} > "$ENV2/.claude/projects/test-project/test.jsonl"

OUTPUT2=$(run_script "$ENV2")

# Total tokens: (100+200+50+30) + (150+100+0+0) + (80+60+20+10) = 380+250+170 = 800
WEEK_TOKENS=$(echo "$OUTPUT2" | grep "^WEEK_TOKENS=" | cut -d= -f2)
assert_eq "$WEEK_TOKENS" "800" "WEEK_TOKENS=800"

# 3 messages total
WEEK_MESSAGES=$(echo "$OUTPUT2" | grep "^WEEK_MESSAGES=" | cut -d= -f2)
assert_eq "$WEEK_MESSAGES" "3" "WEEK_MESSAGES=3"

# 2 sessions
WEEK_SESSIONS=$(echo "$OUTPUT2" | grep "^WEEK_SESSIONS=" | cut -d= -f2)
assert_eq "$WEEK_SESSIONS" "2" "WEEK_SESSIONS=2"

# WEEK_MODELS should contain opus and sonnet
WEEK_MODELS=$(echo "$OUTPUT2" | grep "^WEEK_MODELS=" | cut -d= -f2-)
assert_match "$WEEK_MODELS" "opus" "WEEK_MODELS contains opus"
assert_match "$WEEK_MODELS" "sonnet" "WEEK_MODELS contains sonnet"

# DAILY: calendar week (Mon=index 0 ... Sun=index 6)
DAILY=$(echo "$OUTPUT2" | grep "^DAILY=" | cut -d= -f2)
DAILY_TODAY=$(echo "$DAILY" | tr ',' '\n' | sed -n "$((TODAY_IDX + 1))p")
DAILY_OTHER=$(echo "$DAILY" | tr ',' '\n' | sed -n "$((OTHER_IDX + 1))p")
assert_eq "$DAILY_TODAY" "630" "DAILY today=630"
assert_eq "$DAILY_OTHER" "170" "DAILY other day=170"

# ============================================================
echo "=== Test 3: Cost calculation ==="
# ============================================================
ENV3=$(setup_env "test3")

# Write a pricing cache with known prices
# opus: input=0.000015, output=0.000075, cache_read=0.0000015, cache_write=0.00001875
cat > "$ENV3/.claude/pricing-cache.json" << PRICEEOF
{
    "updated": "$(date +%Y-%m-%d)",
    "models": {
        "opus": {"input": 0.000015, "output": 0.000075, "cache_read": 0.0000015, "cache_write": 0.00001875}
    },
    "usd_eur_rate": 0.92
}
PRICEEOF

# One message today: 1000 input, 500 output, 200 cache_read, 100 cache_write
{
    make_jsonl_line "$TODAY" "claude-opus-4-20250514" 1000 500 200 100 "sess-c"
} > "$ENV3/.claude/projects/test-project/test.jsonl"

OUTPUT3=$(run_script "$ENV3")

# Expected cost: 1000*0.000015 + 500*0.000075 + 200*0.0000015 + 100*0.00001875
# = 0.015 + 0.0375 + 0.0003 + 0.001875 = 0.054675
TODAY_COST=$(echo "$OUTPUT3" | grep "^TODAY_COST=" | cut -d= -f2)
assert_eq "$TODAY_COST" "0.05" "TODAY_COST=0.05 (rounded)"

WEEK_COST=$(echo "$OUTPUT3" | grep "^WEEK_COST=" | cut -d= -f2)
assert_eq "$WEEK_COST" "0.05" "WEEK_COST matches TODAY_COST"

USD_EUR_RATE=$(echo "$OUTPUT3" | grep "^USD_EUR_RATE=" | cut -d= -f2)
assert_eq "$USD_EUR_RATE" "0.92" "USD_EUR_RATE from cache"

# ============================================================
echo "=== Test 4: Missing credentials — defaults ==="
# ============================================================
ENV4=$(setup_env "test4")
# No .credentials.json
OUTPUT4=$(run_script "$ENV4")

SUB_TYPE=$(echo "$OUTPUT4" | grep "^SUBSCRIPTION_TYPE=" | cut -d= -f2)
assert_eq "$SUB_TYPE" "unknown" "SUBSCRIPTION_TYPE=unknown without credentials"

FIVE_HOUR=$(echo "$OUTPUT4" | grep "^FIVE_HOUR_UTIL=" | cut -d= -f2)
assert_eq "$FIVE_HOUR" "0" "FIVE_HOUR_UTIL=0 without credentials"

EXTRA=$(echo "$OUTPUT4" | grep "^EXTRA_USAGE_ENABLED=" | cut -d= -f2)
assert_eq "$EXTRA" "false" "EXTRA_USAGE_ENABLED=false without credentials"

# ============================================================
echo "=== Test 5: Empty projects dir — all counters zero ==="
# ============================================================
ENV5=$(setup_env "test5")
# projects dir exists but has no JSONL files
OUTPUT5=$(run_script "$ENV5")

assert_eq "$(echo "$OUTPUT5" | grep "^WEEK_TOKENS=" | cut -d= -f2)" "0" "WEEK_TOKENS=0 empty"
assert_eq "$(echo "$OUTPUT5" | grep "^WEEK_MESSAGES=" | cut -d= -f2)" "0" "WEEK_MESSAGES=0 empty"
assert_eq "$(echo "$OUTPUT5" | grep "^WEEK_SESSIONS=" | cut -d= -f2)" "0" "WEEK_SESSIONS=0 empty"
assert_eq "$(echo "$OUTPUT5" | grep "^MONTH_TOKENS=" | cut -d= -f2)" "0" "MONTH_TOKENS=0 empty"
assert_eq "$(echo "$OUTPUT5" | grep "^DAILY=" | cut -d= -f2)" "0,0,0,0,0,0,0" "DAILY all zeros"

# ============================================================
echo "=== Test 6: EUR rate sanitisation ==="
# ============================================================
ENV6=$(setup_env "test6")

# Pricing cache with a non-numeric EUR rate — should be treated as 0
cat > "$ENV6/.claude/pricing-cache.json" << 'EUREOF'
{
    "updated": "2099-12-31",
    "models": {
        "opus": {"input": 0.000015, "output": 0.000075, "cache_read": 0.0000015, "cache_write": 0.00001875}
    },
    "usd_eur_rate": "not-a-number"
}
EUREOF

OUTPUT6=$(run_script "$ENV6")
# The script reads usd_eur_rate from JSON as-is via jq; the QML side validates.
# What matters is that it doesn't crash and still produces output.
if echo "$OUTPUT6" | grep -q "^USD_EUR_RATE="; then
    pass "Script runs with non-numeric EUR rate without crashing"
else
    fail "Script crashed or missing USD_EUR_RATE with non-numeric EUR rate"
fi

# ============================================================
echo "=== Test 7: Pricing validation — cache without opus family ==="
# ============================================================
ENV7=$(setup_env "test7")

# Pricing cache with only "haiku" — no opus family
cat > "$ENV7/.claude/pricing-cache.json" << 'PVEOF'
{
    "updated": "2099-12-31",
    "models": {
        "haiku": {"input": 0.0000008, "output": 0.000004, "cache_read": 0.00000008, "cache_write": 0.000001}
    }
}
PVEOF

# Message with an opus model — should not crash, cost should be 0 (no pricing match)
{
    make_jsonl_line "$TODAY" "claude-opus-4-20250514" 1000 500 0 0 "sess-d"
} > "$ENV7/.claude/projects/test-project/test.jsonl"

OUTPUT7=$(run_script "$ENV7")
TODAY_COST7=$(echo "$OUTPUT7" | grep "^TODAY_COST=" | cut -d= -f2)
assert_eq "$TODAY_COST7" "0.00" "Cost=0 when model family not in pricing cache"

# ============================================================
echo "=== Test 8: PROFILES field — default profile always present ==="
# ============================================================
ENV8=$(setup_env "test8")
OUTPUT8=$(run_script "$ENV8")

if echo "$OUTPUT8" | grep -q "^PROFILES="; then
    pass "PROFILES key present"
else
    fail "PROFILES key missing"
fi

PROFILES8=$(echo "$OUTPUT8" | grep "^PROFILES=" | cut -d= -f2)
assert_match "$PROFILES8" "default" "PROFILES contains default"

# ============================================================
echo "=== Test 9: PROFILES discovers CCS instances ==="
# ============================================================
ENV9=$(setup_env "test9")
mkdir -p "$ENV9/.ccs/instances/work/projects/proj1"
mkdir -p "$ENV9/.ccs/instances/home/projects/proj2"

make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 500 300 0 0 "sess-r" \
    > "$ENV9/.ccs/instances/work/projects/proj1/test.jsonl"

OUTPUT9=$(run_script "$ENV9")

PROFILES9=$(echo "$OUTPUT9" | grep "^PROFILES=" | cut -d= -f2)
assert_match "$PROFILES9" "default" "PROFILES contains default (test9)"
assert_match "$PROFILES9" "work" "PROFILES contains work"
assert_match "$PROFILES9" "home" "PROFILES contains home"

# ============================================================
echo "=== Test 10: PROFILE_WEEK_TOKENS format and values ==="
# ============================================================
ENV10=$(setup_env "test10")
mkdir -p "$ENV10/.ccs/instances/work/projects/proj1"

# default: 630 tokens (100+200+50+30+150+100)
make_jsonl_line "$TODAY" "claude-opus-4-20250514" 100 200 50 30 "sess-a" \
    > "$ENV10/.claude/projects/test-project/t.jsonl"
make_jsonl_line "$TODAY" "claude-opus-4-20250514" 150 100 0 0 "sess-a" \
    >> "$ENV10/.claude/projects/test-project/t.jsonl"

# work: 800 tokens (500+300)
make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 500 300 0 0 "sess-r" \
    > "$ENV10/.ccs/instances/work/projects/proj1/t.jsonl"

OUTPUT10=$(run_script "$ENV10")

PWT=$(echo "$OUTPUT10" | grep "^PROFILE_WEEK_TOKENS=" | cut -d= -f2)
if [ -n "$PWT" ]; then
    pass "PROFILE_WEEK_TOKENS present"
else
    fail "PROFILE_WEEK_TOKENS missing"
fi
assert_match "$PWT" "default:[0-9]+" "PROFILE_WEEK_TOKENS has default:N"
assert_match "$PWT" "work:800" "PROFILE_WEEK_TOKENS work:800"

# Aggregate WEEK_TOKENS must equal sum: 630+800=1430
AGG10=$(echo "$OUTPUT10" | grep "^WEEK_TOKENS=" | cut -d= -f2)
assert_eq "$AGG10" "1430" "WEEK_TOKENS aggregate = 1430"

# ============================================================
echo "=== Test 11: PROFILE_DAILY pipe-separated, 7 values per profile ==="
# ============================================================
ENV11=$(setup_env "test11")
mkdir -p "$ENV11/.ccs/instances/work/projects/proj1"

make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 100 50 0 0 "s1" \
    > "$ENV11/.ccs/instances/work/projects/proj1/t.jsonl"

OUTPUT11=$(run_script "$ENV11")

PD=$(echo "$OUTPUT11" | grep "^PROFILE_DAILY=" | cut -d= -f2)
if [ -n "$PD" ]; then
    pass "PROFILE_DAILY present"
else
    fail "PROFILE_DAILY missing"
fi

# Verify pipe separator exists (at least 2 profiles = 1 pipe)
assert_match "$PD" "[|]" "PROFILE_DAILY has pipe separator"

# Each block should have 7 comma-separated values
# Check work block: split on | then check count of commas in work part
WORK_BLOCK=$(echo "$PD" | tr '|' '\n' | grep "^work:")
WORK_VALS=$(echo "$WORK_BLOCK" | cut -d: -f2)
COMMA_COUNT=$(echo "$WORK_VALS" | tr -cd ',' | wc -c)
assert_eq "$COMMA_COUNT" "6" "PROFILE_DAILY work block has 7 values (6 commas)"

# ============================================================
echo "=== Test 12: PROFILE_WEEK_MODELS uses = not : for model/count ==="
# ============================================================
ENV12=$(setup_env "test12")
mkdir -p "$ENV12/.ccs/instances/work/projects/proj1"

make_jsonl_line "$TODAY" "claude-opus-4-20250514" 100 50 0 0 "s1" \
    > "$ENV12/.ccs/instances/work/projects/proj1/t.jsonl"

OUTPUT12=$(run_script "$ENV12")

PWM=$(echo "$OUTPUT12" | grep "^PROFILE_WEEK_MODELS=" | cut -d= -f2-)
if [ -n "$PWM" ]; then
    pass "PROFILE_WEEK_MODELS present"
else
    fail "PROFILE_WEEK_MODELS missing"
fi
assert_match "$PWM" "opus=[0-9]+" "PROFILE_WEEK_MODELS uses = separator for model/count"

# Also verify the aggregate WEEK_MODELS field uses = (not :)
AGG_WM12=$(echo "$OUTPUT12" | sed -n 's/^WEEK_MODELS=//p')
assert_match "$AGG_WM12" "opus=[0-9]+" "aggregate WEEK_MODELS also uses = separator"

# ============================================================
echo "=== Test 13: Week boundary — previous week data excluded from WEEK_TOKENS ==="
# ============================================================
ENV13=$(setup_env "test13")

# Compute last Sunday (always before current week which starts Monday)
LAST_SUNDAY=$(date -d "last Sunday" +%Y-%m-%d)
# If today IS Sunday, "last Sunday" is today; go back 7 more days
if [ "$(date +%u)" -eq 7 ]; then
    LAST_SUNDAY=$(date -d "7 days ago" +%Y-%m-%d)
fi

{
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 100 100 0 0 "sess-w1"
    make_jsonl_line "$LAST_SUNDAY" "claude-sonnet-4-20250514" 500 500 0 0 "sess-w2"
} > "$ENV13/.claude/projects/test-project/test.jsonl"

OUTPUT13=$(run_script "$ENV13")
WEEK_TOKENS13=$(echo "$OUTPUT13" | grep "^WEEK_TOKENS=" | cut -d= -f2)
assert_eq "$WEEK_TOKENS13" "200" "Previous week data excluded from WEEK_TOKENS"

# Previous week data should still count toward MONTH_TOKENS if same month
MONTH_TOKENS13=$(echo "$OUTPUT13" | grep "^MONTH_TOKENS=" | cut -d= -f2)
LAST_SUNDAY_MONTH=$(date -d "$LAST_SUNDAY" +%Y-%m)
CURRENT_MONTH=$(date +%Y-%m)
if [ "$LAST_SUNDAY_MONTH" = "$CURRENT_MONTH" ]; then
    assert_eq "$MONTH_TOKENS13" "1200" "Previous week same-month data included in MONTH_TOKENS"
else
    assert_eq "$MONTH_TOKENS13" "200" "Previous month data excluded from MONTH_TOKENS"
fi

# ============================================================
echo "=== Test 14: Month boundary — previous month data excluded ==="
# ============================================================
ENV14=$(setup_env "test14")

# Use a date from the previous month
PREV_MONTH_DATE=$(date -d "$(date +%Y-%m-01) - 1 day" +%Y-%m-%d)

{
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 100 100 0 0 "sess-m1"
    make_jsonl_line "$PREV_MONTH_DATE" "claude-sonnet-4-20250514" 400 400 0 0 "sess-m2"
} > "$ENV14/.claude/projects/test-project/test.jsonl"

OUTPUT14=$(run_script "$ENV14")
MONTH_TOKENS14=$(echo "$OUTPUT14" | grep "^MONTH_TOKENS=" | cut -d= -f2)
assert_eq "$MONTH_TOKENS14" "200" "Previous month data excluded from MONTH_TOKENS"

# ============================================================
echo "=== Test 15: Malformed JSONL lines are skipped ==="
# ============================================================
ENV15=$(setup_env "test15")

{
    echo "this is not json"
    echo ""
    echo '{"truncated": true'
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 100 100 0 0 "sess-mf"
    echo '{"type":"assistant","timestamp":"invalid"}'
} > "$ENV15/.claude/projects/test-project/test.jsonl"

OUTPUT15=$(run_script "$ENV15")
WEEK_TOKENS15=$(echo "$OUTPUT15" | grep "^WEEK_TOKENS=" | cut -d= -f2)
assert_eq "$WEEK_TOKENS15" "200" "Malformed lines skipped, valid line counted"

# ============================================================
echo "=== Test 16: Non-assistant types excluded ==="
# ============================================================
ENV16=$(setup_env "test16")

{
    # User message — should be ignored
    printf '{"type":"user","timestamp":"%sT12:00:00Z","sessionId":"sess-u","message":{"model":"claude-sonnet-4-20250514","usage":{"input_tokens":999,"output_tokens":999,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$TODAY"
    # Tool message — should be ignored
    printf '{"type":"tool","timestamp":"%sT12:00:00Z","sessionId":"sess-t","message":{"model":"claude-sonnet-4-20250514","usage":{"input_tokens":888,"output_tokens":888,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$TODAY"
    # Valid assistant message
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 50 50 0 0 "sess-a"
} > "$ENV16/.claude/projects/test-project/test.jsonl"

OUTPUT16=$(run_script "$ENV16")
WEEK_TOKENS16=$(echo "$OUTPUT16" | grep "^WEEK_TOKENS=" | cut -d= -f2)
assert_eq "$WEEK_TOKENS16" "100" "Only assistant messages counted"
WEEK_MESSAGES16=$(echo "$OUTPUT16" | grep "^WEEK_MESSAGES=" | cut -d= -f2)
assert_eq "$WEEK_MESSAGES16" "1" "Non-assistant messages excluded from count"

# ============================================================
echo "=== Test 17: Multiple projects aggregated ==="
# ============================================================
ENV17=$(setup_env "test17")
mkdir -p "$ENV17/.claude/projects/project-a"
mkdir -p "$ENV17/.claude/projects/project-b"

{
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 100 100 0 0 "sess-pa"
} > "$ENV17/.claude/projects/project-a/log.jsonl"
{
    make_jsonl_line "$TODAY" "claude-opus-4-20250514" 200 200 0 0 "sess-pb"
} > "$ENV17/.claude/projects/project-b/log.jsonl"

OUTPUT17=$(run_script "$ENV17")
WEEK_TOKENS17=$(echo "$OUTPUT17" | grep "^WEEK_TOKENS=" | cut -d= -f2)
assert_eq "$WEEK_TOKENS17" "600" "Tokens from multiple projects aggregated"
WEEK_SESSIONS17=$(echo "$OUTPUT17" | grep "^WEEK_SESSIONS=" | cut -d= -f2)
assert_eq "$WEEK_SESSIONS17" "2" "Sessions from multiple projects counted"

# ============================================================
echo "=== Test 18: Usage API cache — fresh cache used ==="
# ============================================================
ENV18=$(setup_env "test18")

# Create credentials so the API path is entered
cat > "$ENV18/.claude/.credentials.json" << 'CREDEOF'
{
    "claudeAiOauth": {
        "subscriptionType": "pro",
        "rateLimitTier": "t1_pro",
        "accessToken": "fake-token"
    }
}
CREDEOF

# Create fresh usage cache (cached_at = now)
NOW_TS=$(date +%s)
cat > "$ENV18/.claude/usage-cache.json" << CACHEEOF
{
    "cached_at": $NOW_TS,
    "data": {
        "five_hour": {"utilization": 42, "resets_at": "2099-01-01T00:00:00Z"},
        "seven_day": {"utilization": 15, "resets_at": "2099-01-07T00:00:00Z"},
        "extra_usage": {"is_enabled": true},
        "limits": [
            {"kind": "session", "group": "session", "percent": 42, "severity": "normal",
             "resets_at": "2099-01-01T00:00:00Z", "scope": null, "is_active": true},
            {"kind": "weekly_all", "group": "weekly", "percent": 15, "severity": "high",
             "resets_at": "2099-01-07T00:00:00Z", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 63, "severity": "critical",
             "resets_at": "2099-01-07T00:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Fable"}}, "is_active": false}
        ]
    }
}
CACHEEOF

OUTPUT18=$(run_script "$ENV18")
FIVE18=$(echo "$OUTPUT18" | grep "^FIVE_HOUR_UTIL=" | cut -d= -f2)
assert_eq "$FIVE18" "42" "Fresh cache: FIVE_HOUR_UTIL from cache"
SEVEN18=$(echo "$OUTPUT18" | grep "^SEVEN_DAY_UTIL=" | cut -d= -f2)
assert_eq "$SEVEN18" "15" "Fresh cache: SEVEN_DAY_UTIL from cache"
EXTRA18=$(echo "$OUTPUT18" | grep "^EXTRA_USAGE_ENABLED=" | cut -d= -f2)
assert_eq "$EXTRA18" "true" "Fresh cache: EXTRA_USAGE_ENABLED from cache"

# limits[] is the only place a model-scoped window appears, so it is flattened
# into its own line rather than folded into the two legacy fields.
LIMITS18=$(echo "$OUTPUT18" | grep "^LIMITS=" | cut -d= -f2-)
assert_eq "$(echo "$LIMITS18" | jq -r 'length')" "3" "Fresh cache: LIMITS carries every window"
assert_eq "$(echo "$LIMITS18" | jq -r '.[0].kind')" "session" "Fresh cache: LIMITS[0] is the session window"
assert_eq "$(echo "$LIMITS18" | jq -r '.[0].percent')" "42" "Fresh cache: LIMITS[0] percent"
assert_eq "$(echo "$LIMITS18" | jq -r '.[0].is_active')" "true" "Fresh cache: LIMITS[0] is_active"
assert_eq "$(echo "$LIMITS18" | jq -r '.[1].severity')" "high" "Fresh cache: LIMITS[1] severity passed through"
assert_eq "$(echo "$LIMITS18" | jq -r '.[2].kind')" "weekly_scoped" "Fresh cache: LIMITS[2] is the scoped window"
assert_eq "$(echo "$LIMITS18" | jq -r '.[2].model')" "Fable" "Fresh cache: LIMITS[2] carries the scoped model name"
assert_eq "$(echo "$LIMITS18" | jq -r '.[2].percent')" "63" "Fresh cache: LIMITS[2] percent"
assert_eq "$(echo "$LIMITS18" | jq -r '.[2].severity')" "critical" "Fresh cache: LIMITS[2] severity"

# A payload with no limits[] at all must still emit a valid empty array: the
# plugin passes this straight to jq --argjson, which aborts on anything else.
LIMITS19=$(run_script "$(setup_env "test18b")" | grep "^LIMITS=" | cut -d= -f2-)
assert_eq "$LIMITS19" "[]" "No API payload: LIMITS degrades to an empty array"

# ============================================================
echo "=== Test 19: Stats cache parsing ==="
# ============================================================
ENV19=$(setup_env "test19")

cat > "$ENV19/.claude/stats-cache.json" << 'STATSEOF'
{
    "totalSessions": 150,
    "totalMessages": 4200,
    "firstSessionDate": "2024-06-15T10:30:00Z"
}
STATSEOF

OUTPUT19=$(run_script "$ENV19")
AT_SESS19=$(echo "$OUTPUT19" | grep "^ALLTIME_SESSIONS=" | cut -d= -f2)
assert_eq "$AT_SESS19" "150" "Stats cache: ALLTIME_SESSIONS"
AT_MSGS19=$(echo "$OUTPUT19" | grep "^ALLTIME_MESSAGES=" | cut -d= -f2)
assert_eq "$AT_MSGS19" "4200" "Stats cache: ALLTIME_MESSAGES"
FIRST19=$(echo "$OUTPUT19" | grep "^FIRST_SESSION=" | cut -d= -f2)
assert_eq "$FIRST19" "2024-06-15" "Stats cache: ISO timestamp T-suffix stripped"

# ============================================================
echo "=== Test 20: Cost with multiple model families ==="
# ============================================================
ENV20=$(setup_env "test20")

cat > "$ENV20/.claude/pricing-cache.json" << MPEOF
{
    "updated": "$(date +%Y-%m-%d)",
    "models": {
        "opus": {"input": 0.000015, "output": 0.000075, "cache_read": 0, "cache_write": 0},
        "sonnet": {"input": 0.000003, "output": 0.000015, "cache_read": 0, "cache_write": 0}
    }
}
MPEOF

{
    make_jsonl_line "$TODAY" "claude-opus-4-20250514" 1000 1000 0 0 "sess-mp1"
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 1000 1000 0 0 "sess-mp2"
} > "$ENV20/.claude/projects/test-project/test.jsonl"

OUTPUT20=$(run_script "$ENV20")
# opus: 1000*0.000015 + 1000*0.000075 = 0.015 + 0.075 = 0.09
# sonnet: 1000*0.000003 + 1000*0.000015 = 0.003 + 0.015 = 0.018
# total: 0.108
TODAY_COST20=$(echo "$OUTPUT20" | grep "^TODAY_COST=" | cut -d= -f2)
assert_eq "$TODAY_COST20" "0.11" "Multi-model cost summed correctly"

# ============================================================
echo "=== Test 21: Pricing cache without EUR rate — USD_EUR_RATE=0 ==="
# ============================================================
ENV21=$(setup_env "test21")

cat > "$ENV21/.claude/pricing-cache.json" << 'NOEUREOF'
{
    "updated": "2099-12-31",
    "models": {
        "sonnet": {"input": 0.000003, "output": 0.000015, "cache_read": 0, "cache_write": 0}
    }
}
NOEUREOF

OUTPUT21=$(run_script "$ENV21")
EUR21=$(echo "$OUTPUT21" | grep "^USD_EUR_RATE=" | cut -d= -f2)
assert_eq "$EUR21" "0" "Missing usd_eur_rate defaults to 0"

# ============================================================
echo "=== Test 22: Session deduplication — same session counted once ==="
# ============================================================
ENV22=$(setup_env "test22")

{
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 10 10 0 0 "same-sess"
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 20 20 0 0 "same-sess"
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 30 30 0 0 "same-sess"
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 40 40 0 0 "other-sess"
} > "$ENV22/.claude/projects/test-project/test.jsonl"

OUTPUT22=$(run_script "$ENV22")
WEEK_SESSIONS22=$(echo "$OUTPUT22" | grep "^WEEK_SESSIONS=" | cut -d= -f2)
assert_eq "$WEEK_SESSIONS22" "2" "Same sessionId counted as 1 session"
WEEK_MESSAGES22=$(echo "$OUTPUT22" | grep "^WEEK_MESSAGES=" | cut -d= -f2)
assert_eq "$WEEK_MESSAGES22" "4" "All messages counted regardless of session"

# ============================================================
echo "=== Test 23: DAILY_COSTS aligns with DAILY indices ==="
# ============================================================
ENV23=$(setup_env "test23")

cat > "$ENV23/.claude/pricing-cache.json" << DCEOF
{
    "updated": "$(date +%Y-%m-%d)",
    "models": {
        "sonnet": {"input": 0.000003, "output": 0.000015, "cache_read": 0, "cache_write": 0}
    }
}
DCEOF

{
    make_jsonl_line "$TODAY" "claude-sonnet-4-20250514" 1000 1000 0 0 "sess-dc"
} > "$ENV23/.claude/projects/test-project/test.jsonl"

OUTPUT23=$(run_script "$ENV23")
DAILY23=$(echo "$OUTPUT23" | grep "^DAILY=" | cut -d= -f2)
DAILY_COSTS23=$(echo "$OUTPUT23" | grep "^DAILY_COSTS=" | cut -d= -f2)

# Today's index in calendar week
TODAY_IDX23=$((DOW - 1))

# Verify tokens and costs are at the same index
DAILY_TOK=$(echo "$DAILY23" | tr ',' '\n' | sed -n "$((TODAY_IDX23 + 1))p")
DAILY_CST=$(echo "$DAILY_COSTS23" | tr ',' '\n' | sed -n "$((TODAY_IDX23 + 1))p")
assert_eq "$DAILY_TOK" "2000" "DAILY tokens at today's index"
if [ "$DAILY_CST" != "0" ] && [ "$DAILY_CST" != "0.00" ]; then
    pass "DAILY_COSTS at today's index is non-zero"
else
    fail "DAILY_COSTS at today's index should be non-zero (got '$DAILY_CST')"
fi

# Verify all other indices are zero
for i in $(seq 0 6); do
    if [ "$i" -ne "$TODAY_IDX23" ]; then
        val=$(echo "$DAILY_COSTS23" | tr ',' '\n' | sed -n "$((i + 1))p")
        if [ "$val" = "0.00" ] || [ "$val" = "0" ]; then
            pass "DAILY_COSTS[$i] is zero (not today)"
        else
            fail "DAILY_COSTS[$i] should be zero, got '$val'"
        fi
    fi
done

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
