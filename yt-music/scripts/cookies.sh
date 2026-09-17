#!/usr/bin/env bash
# Invoked via:  bash scripts/cookies.sh <fn> <args...>

open_browser() {   # $1=browser id
  local b="$1"
  case "$b" in
    chrome)   B="google-chrome"; command -v google-chrome-stable >/dev/null 2>&1 && B="google-chrome-stable" ;;
    chromium) B="chromium" ;;
    firefox)  B="firefox" ;;
    edge)     B="microsoft-edge" ;;
    brave)    B="brave-browser"; command -v brave >/dev/null 2>&1 && B="brave" ;;
    opera)    B="opera" ;;
    vivaldi)  B="vivaldi" ;;
    whale)    B="whale" ;;
    zen)      B="zen" ;;
    *)        B="" ;;
  esac
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/yt-music/profiles/$b"
  if [ -n "$B" ] && command -v "$B" >/dev/null 2>&1; then
    if [ "$b" = "firefox" ] || [ "$b" = "zen" ]; then
      "$B" "https://music.youtube.com" >/dev/null 2>&1 &
    else
      # Clean up lingering processes and locks to ensure port 9222 binds
      pkill -9 -f "yt-music/profiles/$b" 2>/dev/null || true
      rm -rf "$cache_dir" 2>/dev/null
      mkdir -p "$cache_dir"
      sleep 0.5
      "$B" --remote-debugging-port=9222 --user-data-dir="$cache_dir" "https://music.youtube.com" >/dev/null 2>&1 &
    fi
  else
    xdg-open "https://music.youtube.com" >/dev/null 2>&1 &
  fi
}

extract_cookies() {   # $1=browser id
  local browser="$1"
  export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
  TMPD=$(mktemp -d /tmp/yt-music.XXXXXX 2>/dev/null)
  [ -n "$TMPD" ] || { TMPD=/tmp/yt-music; mkdir -p "$TMPD"; }
  RAW="$TMPD/raw_$browser.txt"
  OUT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/yt-music"
  mkdir -p "$OUT_DIR"
  OUT="$OUT_DIR/cookies.txt"

  logger -t "ytm/cookies" "[ytm/cookies] extract_cookies: starting extraction for browser=$browser"

  local cdp_done=0
  if [ "$browser" != "firefox" ] && [ "$browser" != "zen" ]; then
    logger -t "ytm/cookies" "[ytm/cookies] Waiting up to 5s for CDP port 9222 to open..."
    PAGE_JSON=""
    for i in 1 2 3 4 5; do
      PAGE_JSON=$(curl -s http://127.0.0.1:9222/json 2>/dev/null || echo "")
      if [ -n "$PAGE_JSON" ]; then
        logger -t "ytm/cookies" "[ytm/cookies] CDP port 9222 became ready on try $i"
        break
      fi
      sleep 1
    done

    if [ -z "$PAGE_JSON" ]; then
      logger -t "ytm/cookies" "[ytm/cookies] CDP port 9222 not reachable after 5s wait"
    else
      logger -t "ytm/cookies" "[ytm/cookies] CDP port 9222 returned JSON length=${#PAGE_JSON}"
    fi

    PAGE_WS=$(echo "$PAGE_JSON" | jq -r '.[] | select(.type == "page") | .webSocketDebuggerUrl' 2>/dev/null | head -1)
    if [ -z "$PAGE_WS" ]; then
      logger -t "ytm/cookies" "[ytm/cookies] No active page target found on port 9222"
    else
      logger -t "ytm/cookies" "[ytm/cookies] Found page WebSocket target: $PAGE_WS"
    fi

    if [ -n "$PAGE_WS" ]; then
      DEV_PATH=$(echo "$PAGE_WS" | sed 's|ws://127.0.0.1:9222||')
      REQ='{"id":1,"method":"Network.getCookies","params":{"urls":["https://music.youtube.com"]}}'
      LEN=${#REQ}
      logger -t "ytm/cookies" "[ytm/cookies] Querying Network.getCookies via nc to DEV_PATH=$DEV_PATH"
      JSON=$( (
        printf "GET %s HTTP/1.1\r\n" "$DEV_PATH"
        printf "Host: 127.0.0.1:9222\r\n"
        printf "Upgrade: websocket\r\n"
        printf "Connection: Upgrade\r\n"
        printf "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        printf "Sec-WebSocket-Version: 13\r\n\r\n"
        sleep 0.2
        printf "\x81\\x$(printf '%02x' $((LEN | 128)))\x00\x00\x00\x00%s" "$REQ"
        sleep 0.3
      ) | timeout 2 nc 127.0.0.1 9222 2>/dev/null | strings | grep "cookies" || true )

      logger -t "ytm/cookies" "[ytm/cookies] NC response length=${#JSON}"
      if echo "$JSON" | grep -q "result"; then
        echo "# Netscape HTTP Cookie File" > "$RAW"
        echo "$JSON" | jq -r '.result.cookies[] | [.domain, "TRUE", .path, (if .secure then "TRUE" else "FALSE" end), (if .expires > 0 then (.expires | floor | tostring) else "0" end), .name, .value] | join("\t")' >> "$RAW" 2>/dev/null
        if [ -s "$RAW" ]; then
          cdp_done=1
          logger -t "ytm/cookies" "[ytm/cookies] CDP extraction successful: $(grep -vc '^#' "$RAW" 2>/dev/null || echo 0) cookies saved"
        else
          logger -t "ytm/cookies" "[ytm/cookies] CDP returned empty cookies file"
        fi
      else
        logger -t "ytm/cookies" "[ytm/cookies] CDP response did not contain 'result'"
      fi
    fi
  fi

  if [ "$cdp_done" -eq 1 ]; then
    cp "$RAW" "$OUT"
    LOG="CDP extraction successful via port 9222"
    # Close debug browser instance and clean up its profile directory
    pkill -9 -f "yt-music/profiles/$browser" 2>/dev/null || true
    rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/yt-music/profiles/$browser" 2>/dev/null
  else
    if [ "$browser" = "zen" ]; then
      ZEN_P=$(awk -F= '/^Path=/{p=substr($0,6)} /^Default=1/{print p; exit}' "$HOME/.zen/profiles.ini" 2>/dev/null)
      if [ -z "$ZEN_P" ]; then
        for d in "$HOME/.zen"/*/; do
          [ -d "$d" ] && [ -f "${d}places.sqlite" ] && { ZEN_P=$(basename "$d"); break; }
        done
      fi
      case "$ZEN_P" in
        /*) CFB="firefox:$ZEN_P" ;;
        *)  CFB="firefox:$HOME/.zen/$ZEN_P" ;;
      esac
    else
      CFB="$browser"
    fi
    LOG=$(timeout 45 yt-dlp --cookies-from-browser "$CFB" --cookies "$RAW" --skip-download --no-warnings --no-playlist "https://music.youtube.com" 2>&1 | tr '\n' ' ')
    grep -iE '^#|(youtube\.com|youtu\.be|youtube-nocookie\.com|ytimg\.com|googlevideo\.com|yt\.be|youtubeeducation\.com)' "$RAW" > "$OUT" 2>/dev/null
  fi
  TOTAL=$(grep -vc '^#' "$RAW" 2>/dev/null || echo 0)
  KEPT=$(grep -vc '^#' "$OUT" 2>/dev/null || echo 0)
  rm -rf "$TMPD"
  echo "DIR=$OUT_DIR"
  echo "RAW=$RAW"
  echo "OUT=$OUT"
  echo "TOTAL=$TOTAL"
  echo "KEPT=$KEPT"
  echo "LOG=$LOG"
}

load_cached_cookies() {
  OUT="${XDG_CACHE_HOME:-$HOME/.cache}/yt-music/cookies.txt"
  if [ -s "$OUT" ]; then
    KEPT=$(grep -vc '^#' "$OUT" 2>/dev/null || echo 0)
    if [ "$KEPT" -gt 0 ]; then
      echo "FOUND=1"
      echo "KEPT=$KEPT"
      echo "OUT=$OUT"
    else
      echo "FOUND=0"
    fi
  else
    echo "FOUND=0"
  fi
}

detect_browsers() {
  check() {   # $1=browser_id $2=binary1 $3=binary2
    local id="$1" b1="$2" b2="${3:-$2}"
    if command -v "$b1" >/dev/null 2>&1 || command -v "$b2" >/dev/null 2>&1; then
      echo "FOUND=$id"
    fi
  }
  check chrome google-chrome google-chrome-stable
  check chromium chromium
  check firefox firefox
  check edge microsoft-edge
  check brave brave-browser brave
  check opera opera
  check vivaldi vivaldi
  check whale whale
  check zen zen
  echo "DONE=1"
}

fn="${1:?fn required}"; shift
type -t "$fn" >/dev/null 2>&1 || { echo "unknown fn: $fn" >&2; exit 1; }
"$fn" "$@"