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
#   region-tmp                 — region capture into a plugin-owned temp file
#   fullscreen-file            — capture the focused monitor; stdout: file path
#   fullscreen-tmp             — fullscreen capture into a plugin-owned temp file
#   window-file                — click a window and snap to its geometry
#                                (Hyprland), or capture the focused window
#                                (Umbriel, no click-to-pick: same as Niri);
#                                via fullscreen + magick crop.
#                                stdout: file path
#   window-id-file             — snap the Umbriel window with the given id via
#                                fullscreen + magick crop (socket passed as $3).
#                                stdout: file path
#   edit <file>                — open <file> in the shell annotation editor
#   annotate-region [keep]     — region capture + editor; stdout: file path
#   annotate-fullscreen [keep]  — fullscreen capture + editor; stdout: file path
#                                Raw files are temporary unless "keep" is set.
#   annotate-window            — focused-window capture + editor; stdout: file path
#   annotate-window-id <id> <socket> — chosen Umbriel window + editor
#
# Per-call screenshot options force intermediate captures to temporary PNGs
# without clipboard, annotation, or pipe side effects. Older shells use the
# global policy plus file pickup, then move the file to a temporary directory.
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

# Read the directory from canonical TOML, distinguishing an explicit empty
# value (use XDG Pictures) from a missing key (try the next legacy source).
screenshot_dir_value() {
    awk '
        /^[[:space:]]*\[shell\.screenshot\]/ { in_s = 1; next }
        /^[[:space:]]*\[/ { in_s = 0 }
        in_s && /^[[:space:]]*directory[[:space:]]*=/ {
            line = $0
            sub(/^[^=]*=/, "", line)
            gsub(/^[ \t"]+|[ \t"]+$/, "", line)
            print line
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    '
}

# Match the shell's XDG Pictures fallback without sourcing user-dirs.dirs
# as executable shell code. Only absolute paths or $HOME-prefixed values
# are accepted from that file, as in Noctalia's defaultPicturesDirectory.
pictures_dir() {
    local val="${XDG_PICTURES_DIR:-}"
    case "$val" in
        '$HOME'/*) val="$HOME/${val#\$HOME/}" ;;
        '~'/*) val="$HOME/${val#\~/}" ;;
    esac
    if [[ "$val" = /* ]]; then
        printf '%s\n' "$val"
        return
    fi
    val=$(sed -n 's/^[[:space:]]*XDG_PICTURES_DIR="\([^"]*\)".*/\1/p' \
        "${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs" 2>/dev/null | head -1)
    case "$val" in
        '$HOME'/*) val="$HOME/${val#\$HOME/}" ;;
    esac
    [[ "$val" = /* ]] || val="$HOME/Pictures"
    printf '%s\n' "$val"
}

# Export uses the same merged config/include stack as the shell. Older
# builds without export retain the settings-file fallback. Never write
# these files: the running shell owns and rewrites them.
shell_dir() {
    local config f val=""
    if config=$(noctalia config export full 2>/dev/null) \
        && val=$(printf '%s\n' "$config" | screenshot_dir_value); then
        :
    else
        for f in "${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/settings.toml" \
            "${XDG_CONFIG_HOME:-$HOME/.config}/noctalia/settings.toml"; do
            [ -f "$f" ] || continue
            if val=$(screenshot_dir_value < "$f"); then break; fi
        done
    fi
    if [ -z "$val" ]; then
        pictures_dir
        return
    fi
    case "$val" in
        "~"/*) val="$HOME/${val#\~/}" ;;
        "~") val="$HOME" ;;
    esac
    printf '%s\n' "$val"
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

# Wait for $1 to appear at all and then be fully flushed — same stability
# handshake as wait_ready, for captures whose path is known up front (the
# per-call --directory/--filename-pattern flags make it deterministic).
await_file() {
    local prev="" cur="" i
    for i in $(seq 1 100); do
        cur=$(stat -c %s "$1" 2>/dev/null) || cur=""
        if [ -n "$cur" ] && [ "$cur" != "0" ] && [ "$cur" = "$prev" ]; then
            magick identify -format '%w %h\n' "$1" >/dev/null 2>&1 && return 0
        fi
        prev="$cur"
        sleep 0.1
    done
    return 1
}

# Whether this Noctalia build accepts per-call [shell.screenshot] option
# flags on the screenshot commands (save/clipboard/pipe/annotate/directory/
# filename-pattern/format). The flag list is compiled into the CLI schema,
# so --help answers without a running shell. An unknown option makes the
# command a no-op, so flags are only ever passed after this probe says yes.
# Cached in the environment for nested $0 calls (annotate-* -> *-file).
ipc_flags() {
    case "${ST_IPC_FLAGS:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    local h flag
    h=$(noctalia msg screenshot-region --help 2>/dev/null)
    ST_IPC_FLAGS=1
    for flag in --save-to-file --no-copy-to-clipboard --no-pipe-to-command \
        --no-annotate --no-confirm-region --directory --filename-pattern --format; do
        if ! printf '%s\n' "$h" | grep -q -- "$flag"; then
            ST_IPC_FLAGS=0
            break
        fi
    done
    export ST_IPC_FLAGS
    [ "$ST_IPC_FLAGS" = "1" ]
}

# Temp capture files outlive this script — the annotation editor session and
# the result panel preview keep reading them — so stale ones from earlier
# runs are pruned by age, never on exit. Scoped to our own mktemp prefix.
prune_tmp_caps() {
    find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'screen-toolkit-cap.*' \
        ! -path "$1" -mtime +0 -exec rm -rf {} + >/dev/null 2>&1
}

# Capture via $1 (screenshot-region|screenshot-fullscreen) after a $2-second
# settle (let a just-closed panel finish its animation) into a fresh temp
# dir; prints the capture path. With per-call flags the capture is forced
# to a plain saved PNG with no clipboard / annotate / pipe side effects, so
# it works even with save_to_file = false. Older shells: capture per the
# user's global policy, pick the file up, and move it into the temp dir.
tmp_capture() {
    local cmd="$1" delay="$2" tdir tfile dir before f
    sleep "$delay"
    tdir=$(mktemp -d "${TMPDIR:-/tmp}/screen-toolkit-cap.XXXXXX") || exit 11
    tfile="$tdir/capture.png"
    if ipc_flags; then
        # Noctalia appends -region to the filename pattern for region
        # captures (including frozen and multi-output regions).
        [ "$cmd" != "screenshot-region" ] || tfile="$tdir/capture-region.png"
        noctalia msg "$cmd" \
            --save-to-file --no-copy-to-clipboard --no-pipe-to-command \
            --no-annotate --no-confirm-region \
            --directory "$tdir" --filename-pattern capture \
            --format png >/dev/null 2>&1 || { rm -rf "$tdir"; exit 10; }
        await_file "$tfile" || { rm -rf "$tdir"; exit 11; }
    else
        dir=$(shell_dir)
        before=$(date +%s)
        noctalia msg "$cmd" >/dev/null 2>&1 || { rm -rf "$tdir"; exit 10; }
        f=""
        f=$(pickup "$dir" "$before") || { rm -rf "$tdir"; exit 11; }
        wait_ready "$f" || { rm -rf "$tdir"; exit 11; }
        mv -f "$f" "$tfile" || { rm -rf "$tdir"; exit 11; }
    fi
    prune_tmp_caps "$tdir"
    printf '%s\n' "$tfile"
}

_require() {
    command -v "$1" >/dev/null 2>&1 \
        || { echo "$1"; exit 1; }
}

ACTION="${1:-}"

case "$ACTION" in

    region-file|fullscreen-file)
        _require noctalia
        if [ "$ACTION" = "region-file" ]; then
            _cmd="screenshot-region"
            _settle=0.3
        else
            _cmd="screenshot-fullscreen"
            _settle=0.4
        fi
        # Let the just-closed panel finish its close animation first.
        sleep "$_settle"
        _dir=$(shell_dir)
        _before=$(date +%s)
        if ipc_flags; then
            # Force a saved file even when the user's policy is
            # clipboard-only, and keep the shell's own editor out of the
            # way — the annotate-* actions hand off to `annotate` themselves.
            noctalia msg "$_cmd" --save-to-file --no-annotate --no-confirm-region \
                --no-copy-to-clipboard --no-pipe-to-command \
                --directory "$_dir" >/dev/null 2>&1 || exit 10
        else
            noctalia msg "$_cmd" >/dev/null 2>&1 || exit 10
        fi
        _f=""
        _f=$(pickup "$_dir" "$_before") || exit 11
        wait_ready "$_f" || exit 11
        printf '%s\n' "$_f"
        ;;

    region-tmp|fullscreen-tmp)
        _require noctalia
        _require magick
        if [ "$ACTION" = "region-tmp" ]; then
            _cmd="screenshot-region"
            _settle=0.3
        else
            _cmd="screenshot-fullscreen"
            _settle=0.4
        fi
        tmp_capture "$_cmd" "$_settle"
        ;;

    window-file)
        _require noctalia
        _require jq
        _require magick
        # Click a window, snap to its geometry, capture via fullscreen crop.
        # No dimming at all: plain click-to-snap.
        # Umbriel has no click-to-pick (slurp can't run there), so it uses
        # the focused window — same deal as Niri. Socket docs: $UMBRIEL_SOCKET,
        # else $XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock; plugin runtimes
        # may not inherit the shell's env, so scan for any umbriel socket
        # as a last resort.
        if [ -z "${UMBRIEL_SOCKET:-}" ]; then
            if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] \
                && [ -S "$XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock" ]; then
                UMBRIEL_SOCKET="$XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock"
            else
                _rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
                for _s in "$_rt"/umbriel-*.sock; do
                    if [ -S "$_s" ]; then UMBRIEL_SOCKET="$_s"; break; fi
                done
            fi
            export UMBRIEL_SOCKET
        fi
        if [ -n "${UMBRIEL_SOCKET:-}" ] && command -v umbriel >/dev/null 2>&1 \
            && umbriel windows --json >/dev/null 2>&1; then
            # Focused visible window; fall back to the first visible one.
            _win=$(umbriel windows --json 2>/dev/null | jq -c '
                [ .[] | select(.visible == true and (.minimized != true)
                               and (.tab_hidden != true)
                               and (.x? != null) and (.y? != null)
                               and (.w? != null) and (.h? != null)) ]
                | ((map(select(.focused == true)) | first) // first // empty)' 2>/dev/null)
            [ -n "$_win" ] && [ "$_win" != "null" ] || { echo "ERR no visible window found"; exit 2; }
            _wx=$(printf '%s' "$_win" | jq -r '.x')
            _wy=$(printf '%s' "$_win" | jq -r '.y')
            _ww=$(printf '%s' "$_win" | jq -r '.w')
            _wh=$(printf '%s' "$_win" | jq -r '.h')
            _wout=$(printf '%s' "$_win" | jq -r '.output // empty')
            # Output under the window center, for origin + scale.
            _cx=$((_wx + _ww / 2))
            _cy=$((_wy + _wh / 2))
            _mon=$(umbriel outputs --json 2>/dev/null | jq -c --argjson x "$_cx" --argjson y "$_cy" --arg out "$_wout" '
                ([ .[] | select(.name == $out or
                                (.position.x <= $x and ($x < .position.x + .logical_size.width)
                                 and .position.y <= $y and ($y < .position.y + .logical_size.height)))
                   | {x: .position.x, y: .position.y, scale: .scale} ] | first)
                // (.[0] | {x: .position.x, y: .position.y, scale: .scale})' 2>/dev/null)
            [ -n "$_mon" ] && [ "$_mon" != "null" ] || { echo "ERR no output matches window"; exit 2; }
            _mx=$(printf '%s' "$_mon" | jq -r '.x // 0')
            _my=$(printf '%s' "$_mon" | jq -r '.y // 0')
            _scale=$(printf '%s' "$_mon" | jq -r '.scale // 1')
        else
            _require slurp
            _require hyprctl
            # Click a point, snap to the focused-first window containing it.
            _pt=""
            _rc=0
            _pt=$(slurp -p -b 00000000 2>/dev/null) || _rc=$?
            if [ "$_rc" -ne 0 ]; then exit 10; fi
            _px=$(printf '%s' "$_pt" | awk -F'[, ]+' '{print int($1)}')
            _py=$(printf '%s' "$_pt" | awk -F'[, ]+' '{print int($2)}')
            _win=$(hyprctl clients -j 2>/dev/null | jq -c --argjson x "$_px" --argjson y "$_py" '
                [ .[] | select(.mapped == true)
                  | { address: .address, at: (.at // [0, 0]), size: (.size // [0, 0]),
                      focusHistoryID: (.focusHistoryID // 9999999) }
                  | select(.at[0] <= $x and (.at[0] + .size[0]) >= $x
                       and .at[1] <= $y and (.at[1] + .size[1]) >= $y) ]
                | sort_by([.focusHistoryID, .size[0] * .size[1]]) | first' 2>/dev/null)
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
        fi
        # Only the cropped window is delivered; keep its monitor frame temporary.
        _full=""
        _rc=0
        _full=$(tmp_capture screenshot-fullscreen 0) || _rc=$?
        [ "$_rc" -eq 0 ] || exit "$_rc"
        _tdir=$(dirname "$_full")
        # Window geometry is logical pixels; the PNG is physical (x scale).
        read -r _iw _ih < <(magick identify -format '%w %h\n' "$_full" 2>/dev/null) || { rm -rf "$_tdir"; exit 3; }
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
            || { rm -rf "$_tdir"; exit 3; }
        rm -rf "$_tdir"
        printf '%s\n' "$_out"
        ;;

    window-id-file)
        _require noctalia
        _require jq
        _require magick
        _WID="${2:-}"
        [ -n "$_WID" ] || exit 2
        # Let the just-closed picker finish its close animation first.
        sleep 0.4
        # Socket passed explicitly by the service (no env guessing needed).
        if [ -n "${3:-}" ]; then export UMBRIEL_SOCKET="$3"; fi
        if ! command -v umbriel >/dev/null 2>&1; then echo "umbriel"; exit 1; fi
        _win=$(umbriel windows --json 2>/dev/null | jq -c --arg id "$_WID" '
            [ .[] | select(.id == $id and (.x? != null) and (.y? != null)
                           and (.w? != null) and (.h? != null)) ]
            | first // empty' 2>/dev/null)
        [ -n "$_win" ] && [ "$_win" != "null" ] || { echo "ERR window gone"; exit 2; }
        _wx=$(printf '%s' "$_win" | jq -r '.x')
        _wy=$(printf '%s' "$_win" | jq -r '.y')
        _ww=$(printf '%s' "$_win" | jq -r '.w')
        _wh=$(printf '%s' "$_win" | jq -r '.h')
        _wout=$(printf '%s' "$_win" | jq -r '.output // empty')
        _cx=$((_wx + _ww / 2))
        _cy=$((_wy + _wh / 2))
        _mon=$(umbriel outputs --json 2>/dev/null | jq -c --argjson x "$_cx" --argjson y "$_cy" --arg out "$_wout" '
            ([ .[] | select(.name == $out or
                            (.position.x <= $x and ($x < .position.x + .logical_size.width)
                             and .position.y <= $y and ($y < .position.y + .logical_size.height)))
               | {x: .position.x, y: .position.y, scale: .scale} ] | first)
            // (.[0] | {x: .position.x, y: .position.y, scale: .scale})' 2>/dev/null)
        [ -n "$_mon" ] && [ "$_mon" != "null" ] || { echo "ERR no output matches window"; exit 2; }
        _mx=$(printf '%s' "$_mon" | jq -r '.x // 0')
        _my=$(printf '%s' "$_mon" | jq -r '.y // 0')
        _scale=$(printf '%s' "$_mon" | jq -r '.scale // 1')
        # Only the cropped window is delivered; keep its monitor frame temporary.
        _full=""
        _rc=0
        _full=$(tmp_capture screenshot-fullscreen 0) || _rc=$?
        [ "$_rc" -eq 0 ] || exit "$_rc"
        _tdir=$(dirname "$_full")
        read -r _iw _ih < <(magick identify -format '%w %h\n' "$_full" 2>/dev/null) || { rm -rf "$_tdir"; echo "ERR unreadable screenshot"; exit 3; }
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
            || { rm -rf "$_tdir"; echo "ERR window crop failed"; exit 3; }
        rm -rf "$_tdir"
        printf '%s\n' "$_out"
        ;;

    edit)
        _require noctalia
        _file="${2:-}"
        [ -n "$_file" ] && [ -f "$_file" ] || exit 2
        # The annotate command postdates some shell builds (5.0.1 lacks it);
        # probe once so the caller reports a missing dependency instead of
        # retrying an unknown command and failing with a generic error.
        if ! noctalia msg --help 2>/dev/null | grep -q '^[[:space:]]*annotate'; then
            echo "a Noctalia shell that ships the annotate command"
            exit 1
        fi
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

    annotate-region|annotate-fullscreen|annotate-window|annotate-window-id)
        _kind="$ACTION"
        _kind="${_kind#annotate-}"
        _nested=""
        _rc=0
        # Keep Raw applies only to region/fullscreen. Window crops always use
        # temporary monitor frames; preserve the picker id and socket arguments.
        case "$_kind:${2:-}" in
            window:*|window-id:*) _sub="$_kind-file" ;;
            *:keep)              _sub="$_kind-file" ;;
            *)                   _sub="$_kind-tmp" ;;
        esac
        _nested=$("$0" "$_sub" "${@:2}") || _rc=$?
        if [ "$_rc" -ne 0 ]; then
            [ -n "$_nested" ] && printf '%s\n' "$_nested"
            exit "$_rc"
        fi
        exec "$0" edit "$_nested"
        ;;

    *)
        echo "ERROR: unknown action '${ACTION}'. Expected: region-file | region-tmp | fullscreen-file | fullscreen-tmp | window-file | window-id-file | edit | annotate-region | annotate-fullscreen | annotate-window | annotate-window-id" >&2
        exit 2
        ;;

esac
