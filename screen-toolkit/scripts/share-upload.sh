#!/usr/bin/env bash
# share-upload.sh [--backend x02|uguu|zipline] [--url URL] <file> [api_key] [expiry]
# Backends:
#   (none)      — inferred: X02 with an API key, otherwise uguu.se (anonymous)
#   x02         — up.x02.me (requires api_key)
#   uguu        — uguu.se (anonymous, 3h, 128MB max)
#   zipline     — a self-hosted Zipline instance (api_key is the token; --url required)
# expiry:  1h | 1d | 7d | 30d | permanent (X02 and Zipline; default: 7d)
# Prints URL to stdout on success, exits non-zero on failure
# Exit codes:
#   1 — invalid arguments (no file given)
#   2 — file not found
#   3 — missing dependency
#   4 — upload request failed
#   5 — invalid or empty response
#   6 — file too large
#   7 — invalid backend configuration
# Used by: service.luau

set -euo pipefail

BACKEND=""
ZIPLINE_URL=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --backend|--url)
            [ "$#" -ge 2 ] || { echo "ERROR: missing option value" >&2; exit 7; }
            if [ "$1" = --backend ]; then BACKEND="$2"; else ZIPLINE_URL="$2"; fi
            shift 2;;
        --backend=*) BACKEND="${1#*=}"; shift;;
        --url=*) ZIPLINE_URL="${1#*=}"; shift;;
        --) shift; break;;
        -*) echo "ERROR: unknown option: $1" >&2; exit 7;;
        *) break;;
    esac
done
[ "$#" -le 3 ] || { echo "ERROR: too many arguments" >&2; exit 7; }
FILE="${1:-}"
API_KEY="${2:-}"
EXPIRY="${3:-7d}"

UGUU_MAX_BYTES=$((128 * 1024 * 1024))  # 128 MB

[ -n "$FILE" ] || { echo "ERROR: no file given"         >&2; exit 1; }
[ -f "$FILE" ] || { echo "ERROR: file not found: $FILE" >&2; exit 2; }

command -v curl >/dev/null 2>&1 || { echo "ERROR: missing dependency: curl" >&2; exit 3; }

# ── X02 (authenticated) ───────────────────────────────────────────────────────
upload_x02() {
    local EXPIRY_FLAG=()
    if [ "$EXPIRY" != "permanent" ] && [ -n "$EXPIRY" ]; then
        EXPIRY_FLAG=(-F "expiry=${EXPIRY}")
    fi

    local URL
    URL=$(curl -sS -f \
        -X POST "https://up.x02.me/api/upload" \
        -H "x-api-key: ${API_KEY}" \
        -F "file=@${FILE}" \
        "${EXPIRY_FLAG[@]}" \
        --connect-timeout 20 \
        --max-time 120 \
        2>/dev/null) \
        || { echo "ERROR: X02 upload request failed" >&2; exit 4; }

    if [ -n "$URL" ] && [[ "$URL" == http* ]]; then
        printf '%s\n' "$URL"
        return 0
    fi

    echo "ERROR: X02: unexpected response: $URL" >&2
    exit 5
}

# ── uguu.se (anonymous) ───────────────────────────────────────────────────────
upload_uguu() {
    command -v jq >/dev/null 2>&1 || { echo "ERROR: missing dependency: jq" >&2; exit 3; }

    local FILE_SIZE
    FILE_SIZE=$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -gt "$UGUU_MAX_BYTES" ]; then
        echo "ERROR: file too large for anonymous upload (128MB max). Add an X02 API key for larger files." >&2
        exit 6
    fi

    local RESP URL
    RESP=$(curl -sS -f -A 'Mozilla/5.0' \
        --connect-timeout 20 --max-time 60 \
        -F "files[]=@${FILE}" \
        'https://uguu.se/upload' 2>/dev/null) \
    || RESP=$(curl -sS -A 'Mozilla/5.0' \
        --connect-timeout 20 --max-time 60 \
        -F "files[]=@${FILE}" \
        'https://uguu.se/upload.php' 2>/dev/null) \
    || { echo "ERROR: uguu.se upload request failed" >&2; exit 4; }

    URL=$(printf '%s' "$RESP" | jq -r '.files[0].url // empty' 2>/dev/null)

    if [ -n "$URL" ] && [[ "$URL" == http* ]]; then
        printf '%s\n' "$URL"
        return 0
    fi

    echo "ERROR: uguu.se: no valid URL in response" >&2
    exit 5
}

# ── Zipline (authenticated) ──────────────────────────────────────────────────
upload_zipline() {
    command -v jq >/dev/null 2>&1 || { echo "ERROR: missing dependency: jq" >&2; exit 3; }
    case "$ZIPLINE_URL" in http://*|https://*) ;; *) echo "ERROR: invalid Zipline URL" >&2; exit 7;; esac
    local TOKEN="$API_KEY"
    [ -n "$TOKEN" ] && [[ "$TOKEN" != *$'\n'* ]] && [[ "$TOKEN" != *$'\r'* ]] || { echo "ERROR: invalid Zipline token" >&2; exit 7; }
    local ZIPLINE_EXPIRY
    case "$EXPIRY" in 1h|1d|7d|30d) ZIPLINE_EXPIRY="$EXPIRY";; permanent) ZIPLINE_EXPIRY=never;; *) echo "ERROR: invalid expiry" >&2; exit 7;; esac
    local RESP URL
    RESP=$(curl -sS -f --connect-timeout 20 --max-time 120 \
        -H "Authorization: $TOKEN" \
        -H "X-Zipline-Deletes-At: $ZIPLINE_EXPIRY" \
        -F "file=@${FILE}" "${ZIPLINE_URL%/}/api/upload") \
        || { echo "ERROR: Zipline upload request failed" >&2; exit 4; }
    URL=$(printf '%s' "$RESP" | jq -er '.files[0].url | select(type == "string" and test("^https?://"))') \
        || { echo "ERROR: invalid Zipline response" >&2; exit 5; }
    printf '%s\n' "$URL"
}

# When no backend is given, infer one the old way: X02 with a key, otherwise uguu
if [ -z "$BACKEND" ]; then
    if [ -n "$API_KEY" ]; then BACKEND="x02"; else BACKEND="uguu"; fi
fi

case "$BACKEND" in
    zipline) upload_zipline; exit 0;;
    x02)
        [ -n "$API_KEY" ] || { echo "ERROR: X02 backend requires an API key" >&2; exit 7; }
        upload_x02
        exit 0;;
    uguu) upload_uguu; exit 0;;
    *) echo "ERROR: invalid share backend" >&2; exit 7;;
esac
