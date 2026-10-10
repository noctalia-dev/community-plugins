#!/bin/sh
# Streams F1's live-timing feed to stdout, one server-sent-events line per line.
# Used only by the experimental "F1 live-timing stream" source (service.luau).
#
# The feed is ASP.NET Core SignalR over server-sent events:
#   1. POST /negotiate           -> a connection token (and a load balancer cookie)
#   2. GET  ?id=<token>          -> the event stream (kept open, read by the plugin)
#   3. POST ?id=<token> twice    -> protocol handshake, then a Subscribe call
# The load balancer cookie must be sent back on every request, otherwise the
# server answers "No Connection with that ID", and noctalia.http cannot read
# response cookies. That is the only reason this is a shell script around curl.
#
# Usage: f1-live.sh <max-seconds>
# The stream is cut after <max-seconds>. A last line "closed" is printed when it
# ends, for any reason, so the plugin knows to reconnect.

MAX="${1:-3600}"
case "$MAX" in ''|*[!0-9]*) MAX=3600 ;; esac

BASE="https://livetiming.formula1.com/signalrcore"
UA="gcap0n1-noctalia-f1/0.1"
RS="$(printf '\036')"
FEEDS='"SessionInfo","SessionData","TimingData","DriverList","TrackStatus","LapCount","ExtrapolatedClock"'

JAR="$(mktemp)" || exit 1
cleanup() {
    rm -f "$JAR"
    kill $(jobs -p) 2>/dev/null
    echo "closed"
}
trap cleanup EXIT INT TERM

# -q first: without it curl reads ~/.curlrc, which could add a proxy or
# --insecure to what is otherwise a fixed request.
fetch() {
    curl -q -fsS --proto '=https' --max-time 15 -A "$UA" -c "$JAR" -b "$JAR" "$@"
}

NEGOTIATE="$(fetch -X POST "$BASE/negotiate?negotiateVersion=1")" || exit 2
TOKEN="$(printf '%s' "$NEGOTIATE" | sed -n 's/.*"connectionToken":"\([A-Za-z0-9_-]*\)".*/\1/p')"
[ -n "$TOKEN" ] || exit 3

curl -q -fsSN --proto '=https' --max-time "$MAX" -A "$UA" -c "$JAR" -b "$JAR" \
    -H "Accept: text/event-stream" "$BASE?id=$TOKEN" &
sleep 1

send() {
    fetch -X POST -H "Content-Type: text/plain;charset=UTF-8" \
        --data-binary "$1$RS" "$BASE?id=$TOKEN" >/dev/null
}

send '{"protocol":"json","version":1}' || exit 4
sleep 1
send '{"arguments":[['"$FEEDS"']],"invocationId":"1","target":"Subscribe","type":1}' || exit 5

wait
