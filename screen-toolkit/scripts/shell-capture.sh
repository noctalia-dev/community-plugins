#!/usr/bin/env bash
# shell-capture.sh <action> [args...]
#
# Screen captures through the shell's own screenshot stack
# (wlr-screencopy) instead of grim/slurp. The shell owns the output policy
# (directory, filename pattern, clipboard, cursor) under [shell.screenshot];
# this script only triggers captures and picks up the resulting file.
#
# Actions:
#   region-file                — interactive region capture; stdout: file path
#   fullscreen-file            — capture the focused monitor; stdout: file path
#   window-file                — hover to aim (overlay cut from the hovered
#                                window's geometry), click to capture it via
#                                fullscreen + magick crop.
#                                stdout: file path
#   edit <file>                — open <file> in the shell annotation editor
#   annotate-region            — region capture + editor; stdout: file path
#   annotate-fullscreen        — fullscreen capture + editor; stdout: file path
#   annotate-window            — focused-window capture + editor; stdout: file path
#
# The capture commands print only "ok", so the file is picked up as the
# newest file in the screenshot dir newer than (start - 2s). The shell
# flushes the file asynchronously after printing ok, so pickup polls.
#
# Exit codes:
#   0  — ok (stdout is the file path)
#   1  — missing dependency (dep name written to stdout)
#   2  — bad / missing arguments, or no window under the click
#   3  — image processing (crop) failed
#   10 — cancelled by the user (silent)
#   11 — capture finished but nothing was saved to a file (NOFILE)
#   13 — annotation editor handoff failed
#
# Used by: service.luau

set -u

# Resolve the shell's screenshot directory. getConfig only sees plugin
# keys, so parse the shell's own files (first match wins), then default.
# Never write these files: the running shell owns and rewrites them.
shell_dir() {
    local f val
    for f in "$HOME/.local/state/noctalia/settings.toml" "$HOME/.config/noctalia/settings.toml"; do
        [ -f "$f" ] || continue
        val=$(awk '
            /^\s*\[shell\.screenshot\]/ { in_s = 1; next }
            /^\s*\[/ { in_s = 0 }
            in_s && /^\s*directory\s*=/ {
                line = $0
                sub(/^[^=]*=/, "", line)
                gsub(/^[ \t"]+|[ \t"]+$/, "", line)
                print line
                exit
            }
        ' "$f" 2>/dev/null)
        if [ -n "$val" ]; then
            case "$val" in
                "~"/*) val="$HOME/${val#\~/}" ;;
                "~") val="$HOME" ;;
            esac
            printf '%s\n' "$val"
            return 0
        fi
    done
    printf '%s\n' "$HOME/Pictures/Screenshots"
}

# Newest regular file in $1 newer than ($2 - 2s). Prints nothing when none.
newest_since() {
    local dir="$1" since="$2"
    [ -d "$dir" ] || return 0
    find "$dir" -maxdepth 1 -type f -newermt "@$((since - 2))" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-
}

# Poll for the capture the shell is still flushing. Prints the file path.
pickup() {
    local i f
    for i in $(seq 1 50); do
        f=$(newest_since "$1" "$2")
        if [ -n "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Wait until $1 is fully flushed (the shell writes the file asynchronously
# after printing ok). Cheap stat polling finds stability, then a single
# magick parse confirms it — a fresh file typically costs ~0.3s here.
wait_ready() {
    local prev="" cur="" i
    for i in $(seq 1 50); do
        cur=$(stat -c %s "$1" 2>/dev/null) || cur=""
        if [ -n "$cur" ] && [ "$cur" != "0" ] && [ "$cur" = "$prev" ]; then
            magick identify -format '%w %h\n' "$1" >/dev/null 2>&1 && return 0
        fi
        prev="$cur"
        sleep 0.1
    done
    return 1
}

_require() {
    command -v "$1" >/dev/null 2>&1 \
        || { echo "$1"; exit 1; }
}

ACTION="${1:-}"

case "$ACTION" in

    region-file)
        _require noctalia
        # Let the just-closed panel finish its close animation first.
        sleep 0.3
        _dir=$(shell_dir)
        _before=$(date +%s)
        noctalia msg screenshot-region >/dev/null 2>&1 || exit 10
        _f=""
        _f=$(pickup "$_dir" "$_before") || exit 11
        wait_ready "$_f" || exit 11
        printf '%s\n' "$_f"
        ;;

    fullscreen-file)
        _require noctalia
        sleep 0.4
        _dir=$(shell_dir)
        _before=$(date +%s)
        noctalia msg screenshot-fullscreen >/dev/null 2>&1 || exit 10
        _f=""
        _f=$(pickup "$_dir" "$_before") || exit 11
        wait_ready "$_f" || exit 11
        printf '%s\n' "$_f"
        ;;

    window-file)
        _require noctalia
        _require slurp
        _require hyprctl
        _require jq
        _require magick
        # Hover to aim, click to capture, no dragging. slurp waits for the
        # click with a fully transparent background, so the only overlay is
        # the loop below: it tracks the cursor and sets dim_around on the
        # window under it, removing the fullscreen effect from exactly that
        # window's geometry. The snap below then captures the same window.
        _hlast="/tmp/screen-toolkit-hover-$$.addr"
        : > "$_hlast"
        _hover_cleanup() {
            _off=""
            _off=$(cat "$_hlast" 2>/dev/null)
            if [ -n "$_off" ]; then
                hyprctl dispatch "hl.dsp.window.set_prop({prop='dim_around', value='0', window='address:$_off'})" >/dev/null 2>&1
            fi
            rm -f "$_hlast"
        }
        (
            _cur=""
            while true; do
                _pos=$(hyprctl cursorpos 2>/dev/null) || { sleep 0.12; continue; }
                _hx=$(printf '%s' "$_pos" | awk -F'[, ]+' '{print int($1)}')
                _hy=$(printf '%s' "$_pos" | awk -F'[, ]+' '{print int($2)}')
                _addr=""
                if [ -n "$_hx" ] && [ -n "$_hy" ]; then
                    _addr=$(hyprctl clients -j 2>/dev/null | jq -r --argjson x "$_hx" --argjson y "$_hy" '
                        [ .[] | select(.mapped == true and (.hidden != true))
                          | { address: .address, at: (.at // [0, 0]), size: (.size // [0, 0]) }
                          | select(.at[0] <= $x and (.at[0] + .size[0]) >= $x
                               and .at[1] <= $y and (.at[1] + .size[1]) >= $y) ]
                        | sort_by(.size[0] * .size[1]) | first | .address // empty' 2>/dev/null)
                fi
                if [ "$_addr" != "$_cur" ]; then
                    if [ -n "$_cur" ]; then
                        hyprctl dispatch "hl.dsp.window.set_prop({prop='dim_around', value='0', window='address:$_cur'})" >/dev/null 2>&1
                    fi
                    _cur="$_addr"
                    printf '%s' "$_cur" > "$_hlast"
                    if [ -n "$_cur" ]; then
                        hyprctl dispatch "hl.dsp.window.set_prop({prop='dim_around', value='1', window='address:$_cur'})" >/dev/null 2>&1
                    fi
                fi
                sleep 0.12
            done
        ) &
        _hoverpid=$!
        trap 'kill ${_hoverpid:-} 2>/dev/null; _hover_cleanup' EXIT
        _pt=""
        _rc=0
        _pt=$(slurp -p -b 00000000 2>/dev/null) || _rc=$?
        kill "$_hoverpid" 2>/dev/null
        wait "$_hoverpid" 2>/dev/null
        _hover_cleanup
        trap - EXIT
        if [ "$_rc" -ne 0 ]; then exit 10; fi
        _px=$(printf '%s' "$_pt" | awk -F'[, ]+' '{print int($1)}')
        _py=$(printf '%s' "$_pt" | awk -F'[, ]+' '{print int($2)}')
        _win=$(hyprctl clients -j 2>/dev/null | jq -c --argjson x "$_px" --argjson y "$_py" '
            [ .[] | select(.mapped == true)
              | { at: (.at // [0, 0]), size: (.size // [0, 0]) }
              | select(.at[0] <= $x and (.at[0] + .size[0]) >= $x
                   and .at[1] <= $y and (.at[1] + .size[1]) >= $y) ]
            | sort_by(.size[0] * .size[1]) | first' 2>/dev/null)
        [ -n "$_win" ] && [ "$_win" != "null" ] || exit 2
        _wx=$(printf '%s' "$_win" | jq -r '.at[0]')
        _wy=$(printf '%s' "$_win" | jq -r '.at[1]')
        _ww=$(printf '%s' "$_win" | jq -r '.size[0]')
        _wh=$(printf '%s' "$_win" | jq -r '.size[1]')
        # Monitor under the window center, for origin + scale.
        _cx=$((_wx + _ww / 2))
        _cy=$((_wy + _wh / 2))
        _mon=$(hyprctl monitors -j 2>/dev/null | jq -c --argjson x "$_cx" --argjson y "$_cy" '
            ([ .[] | select(.x <= $x and ($x < .x + .width)
                         and .y <= $y and ($y < .y + .height))
               | {x: .x, y: .y, scale: .scale} ] | first) // (.[0] | {x: .x, y: .y, scale: .scale})' 2>/dev/null)
        [ -n "$_mon" ] && [ "$_mon" != "null" ] || exit 2
        _mx=$(printf '%s' "$_mon" | jq -r '.x // 0')
        _my=$(printf '%s' "$_mon" | jq -r '.y // 0')
        _scale=$(printf '%s' "$_mon" | jq -r '.scale // 1')
        _dir=$(shell_dir)
        _before=$(date +%s)
        noctalia msg screenshot-fullscreen >/dev/null 2>&1 || exit 10
        _full=""
        _full=$(pickup "$_dir" "$_before") || exit 11
        wait_ready "$_full" || exit 11
        # Window geometry is logical pixels; the PNG is physical (x scale).
        read -r _iw _ih < <(magick identify -format '%w %h\n' "$_full" 2>/dev/null) || exit 3
        read -r _cx _cy _cw _ch < <(awk -v wx="$_wx" -v wy="$_wy" -v ww="$_ww" -v wh="$_wh" \
            -v mx="$_mx" -v my="$_my" -v s="$_scale" -v iw="$_iw" -v ih="$_ih" 'BEGIN {
            x = int((wx - mx) * s); y = int((wy - my) * s)
            w = int(ww * s); h = int(wh * s)
            if (x < 0) { w += x; x = 0 }
            if (y < 0) { h += y; y = 0 }
            if (x + w > iw) w = iw - x
            if (y + h > ih) h = ih - y
            if (w < 1) w = 1; if (h < 1) h = 1
            printf "%d %d %d %d", x, y, w, h
        }')
        _out="/tmp/screen-toolkit-window-$(date +%s)-$$.png"
        magick "$_full" -crop "${_cw}x${_ch}+${_cx}+${_cy}" +repage "$_out" 2>/dev/null \
            || exit 3
        printf '%s\n' "$_out"
        ;;

    edit)
        _require noctalia
        _file="${2:-}"
        [ -n "$_file" ] && [ -f "$_file" ] || exit 2
        # The handoff can race the shell flushing the fresh capture.
        _i=0
        while [ "$_i" -lt 3 ]; do
            _err=""
            if _err=$(noctalia msg annotate "$_file" 2>&1); then
                printf '%s\n' "$_file"
                exit 0
            fi
            sleep 0.5
            _i=$((_i + 1))
        done
        printf '%s\n' "$_err" >&2
        exit 13
        ;;

    annotate-region|annotate-fullscreen|annotate-window)
        _kind="$ACTION"
        _kind="${_kind#annotate-}"
        _nested=""
        _rc=0
        _nested=$("$0" "$_kind-file") || _rc=$?
        if [ "$_rc" -ne 0 ]; then
            [ -n "$_nested" ] && printf '%s\n' "$_nested"
            exit "$_rc"
        fi
        exec "$0" edit "$_nested"
        ;;

    *)
        echo "ERROR: unknown action '${ACTION}'. Expected: region-file | fullscreen-file | window-file | edit | annotate-region | annotate-fullscreen | annotate-window" >&2
        exit 2
        ;;

esac
