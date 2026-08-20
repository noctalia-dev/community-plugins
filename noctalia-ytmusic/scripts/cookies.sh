#!/usr/bin/env bash
# Invoked via:  bash scripts/cookies.sh <fn> <args...>

open_browser() {   # $1=browser id
  local b="$1"
  case "$b" in
    chrome)   B="google-chrome"; command -v google-chrome-stable >/dev/null 2>&1 && B="google-chrome-stable" ;;
    chromium) B="chromium" ;;
    firefox)  B="firefox" ;;
    edge)     B="microsoft-edge" ;;
    brave)    B="brave-browser" ;;
    opera)    B="opera" ;;
    vivaldi)  B="vivaldi" ;;
    whale)    B="whale" ;;
    zen)      B="zen" ;;
    *)        B="" ;;
  esac
  if [ -n "$B" ] && command -v "$B" >/dev/null 2>&1; then
    "$B" "https://music.youtube.com" >/dev/null 2>&1 &
  else
    xdg-open "https://music.youtube.com" >/dev/null 2>&1 &
  fi
}

extract_cookies() {   # $1=browser id
  local browser="$1"
  export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
  TMPD=$(mktemp -d /tmp/noctalia-ytmusic.XXXXXX 2>/dev/null)
  [ -n "$TMPD" ] || { TMPD=/tmp/noctalia-ytmusic; mkdir -p "$TMPD"; }
  RAW="$TMPD/raw_$browser.txt"
  OUT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic"
  mkdir -p "$OUT_DIR"
  OUT="$OUT_DIR/cookies.txt"
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
  OUT="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic/cookies.txt"
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
  check() { [ -d "$1" ] && echo "FOUND=$2"; }
  check "$HOME/.config/google-chrome" chrome
  check "$HOME/.config/chromium" chromium
  check "$HOME/.mozilla/firefox" firefox
  check "$HOME/.config/microsoft-edge" edge
  check "$HOME/.config/BraveSoftware/Brave-Browser" brave
  check "$HOME/.config/opera" opera
  check "$HOME/.config/vivaldi" vivaldi
  check "$HOME/.config/whale" whale
  check "$HOME/.zen" zen
  echo "DONE=1"
}

fn="${1:?fn required}"; shift
type -t "$fn" >/dev/null 2>&1 || { echo "unknown fn: $fn" >&2; exit 1; }
"$fn" "$@"