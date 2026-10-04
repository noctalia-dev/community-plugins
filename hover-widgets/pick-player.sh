#!/bin/sh
# Picks whichever MPRIS player is actively Playing (playerctl's own default,
# used with no -p flag, doesn't prioritize this -- it can land on a paused/
# stale player over a genuinely-playing one), falling back to playerctl's own
# default ordering if none are, then prints that player's metadata in our
# pipe-delimited format.
set -eu

fmt='{{status}}|{{artist}}|{{mpris:artUrl}}|{{position}}|{{mpris:length}}|{{xesam:url}}|{{title}}'

best=""
for p in $(playerctl -l 2>/dev/null); do
    status=$(playerctl -p "$p" status 2>/dev/null || true)
    if [ "$status" = "Playing" ]; then
        best="$p"
        break
    fi
    [ -z "$best" ] && best="$p"
done

if [ -n "$best" ]; then
    printf '%s|' "$best"
    playerctl -p "$best" metadata --format "$fmt" 2>/dev/null
else
    exit 1
fi
