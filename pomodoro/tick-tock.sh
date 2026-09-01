#!/usr/bin/env bash

DIR="$HOME/Documents"
TICK_PATTERN='tick*.ogg'
TOCK_PATTERN='tock*.ogg'
TICKS_LIST=
TOCKS_LIST=
TICK_PAUSE=1
TOCK_PAUSE=1
FIND_MAXDEPTH=1
LOG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
    --dir)
        DIR="$2"
        shift 2
        ;;
    --tick)
        TICK_PATTERN="$2"
        shift 2
        ;;
    --tock)
        TOCK_PATTERN="$2"
        shift 2
        ;;
    --ticks)
        TICKS_LIST="$2"
        shift 2
        ;;
    --tocks)
        TOCKS_LIST="$2"
        shift 2
        ;;
    --tick-pause)
        TICK_PAUSE="$2"
        shift 2
        ;;
    --tock-pause)
        TOCK_PAUSE="$2"
        shift 2
        ;;
    --depth)
        FIND_MAXDEPTH="$2"
        shift 2
        ;;
    --log)
        LOG=true
        shift
        ;;
    -h | --help)
        echo "Usage: $0 [options]"
        echo
        echo "Options:"
        echo "  --dir PATH          Audio directory (default: ~/Documents)"
        echo "  --tick PATTERN      Tick filename pattern (default: tick*.ogg)"
        echo "  --tock PATTERN      Tock filename pattern (default: tock*.ogg)"
        echo "  --ticks LIST        Comma-separated tick files, e.g. tick1,tick2,tick5"
        echo "  --tocks LIST        Comma-separated tock files, e.g. tock2,tock5,tock7"
        echo "  --tick-pause SEC    Seconds from tick start to tock start (default: 1)"
        echo "  --tock-pause SEC    Seconds from tock start to next tick start (default: 1)"
        echo "  --depth N           find max depth (default: 1)"
        echo "  --log               Log played filenames"
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
done

resolve_file() {
    local name="$1"
    local candidate
    for candidate in "$DIR/$name" "$DIR/${name}.ogg" "$name"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

load_explicit() {
    local list="$1"
    local -n out=$2
    local name resolved
    out=()
    IFS=',' read -ra names <<<"$list"
    for name in "${names[@]}"; do
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        [[ -z "$name" ]] && continue
        if resolved=$(resolve_file "$name"); then
            out+=("$resolved")
        else
            echo "File not found: '$name' (searched in '$DIR')" >&2
            exit 1
        fi
    done
}

load_files() {
    local pattern="$1"
    local -n out=$2
    out=()
    while IFS= read -r -d '' f; do
        [[ -n "$f" ]] && out+=("$f")
    done < <(find "$DIR" -maxdepth "$FIND_MAXDEPTH" -name "$pattern" -print0 | shuf -z)
}

play() {
    local file="$1"
    if [[ "$LOG" == true ]]; then
        printf 'Playing: %s | ' "$file"
    fi
    ffplay -nodisp -autoexit -loglevel quiet "$file" >/dev/null 2>&1 &
}

wait_until() {
    local target=$1
    local now delta
    now=$(date +%s.%N)
    delta=$(awk -v t="$target" -v n="$now" 'BEGIN { d = t - n; if (d > 0.001) printf "%.9f\n", d; else print "0" }')
    [[ "$delta" != "0" ]] && sleep "$delta"
}

cleanup() {
    jobs -p | xargs -r kill 2>/dev/null
}

trap cleanup EXIT

TICKS=()
TOCKS=()

if [[ -n "$TICKS_LIST" ]]; then
    load_explicit "$TICKS_LIST" TICKS
else
    load_files "$TICK_PATTERN" TICKS
fi

if [[ -n "$TOCKS_LIST" ]]; then
    load_explicit "$TOCKS_LIST" TOCKS
else
    load_files "$TOCK_PATTERN" TOCKS
fi

if ((${#TICKS[@]} == 0)); then
    if [[ -n "$TICKS_LIST" ]]; then
        echo "No tick files resolved from --ticks '$TICKS_LIST'" >&2
    else
        echo "No tick files matching '$TICK_PATTERN' in '$DIR'" >&2
    fi
    exit 1
fi

if ((${#TOCKS[@]} == 0)); then
    if [[ -n "$TOCKS_LIST" ]]; then
        echo "No tock files resolved from --tocks '$TOCKS_LIST'" >&2
    else
        echo "No tock files matching '$TOCK_PATTERN' in '$DIR'" >&2
    fi
    exit 1
fi

command -v ffplay >/dev/null || {
    echo "ffplay not found" >&2
    exit 1
}

next=$(date +%s.%N)

while true; do
    for f in "${TICKS[@]}"; do
        play "$f"
        next=$(awk -v n="$next" -v p="$TICK_PAUSE" 'BEGIN { printf "%.9f\n", n + p }')
        wait_until "$next"

        f="${TOCKS[$((RANDOM % ${#TOCKS[@]}))]}"
        play "$f"
        next=$(awk -v n="$next" -v p="$TOCK_PAUSE" 'BEGIN { printf "%.9f\n", n + p }')
        wait_until "$next"
    done

    mapfile -t TICKS < <(printf '%s\n' "${TICKS[@]}" | shuf)
done
