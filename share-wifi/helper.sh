#!/usr/bin/env bash

ACTION="${1:-status}"

# Per-user runtime directory for PID, log, and lock state files (avoids world-writable /tmp)
RUN_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/noctalia-share-wifi"
mkdir -p "$RUN_DIR" 2>/dev/null || true
PID_FILE="$RUN_DIR/pid"
LOG_FILE="$RUN_DIR/log"
LOCK_FILE="$RUN_DIR/session_lock.json"

get_active_wifi() {
    nmcli -t -f active,chan,freq dev wifi list --rescan no 2>/dev/null | grep '^yes' | head -n1 || true
}

is_dfs_freq() {
    local freq="$1"
    local chan="$2"
    if [ -n "$freq" ] && [ "$freq" -ge 5260 ] 2>/dev/null && [ "$freq" -le 5720 ] 2>/dev/null; then
        return 0
    fi
    case "$chan" in
        52|56|60|64|100|104|108|112|116|120|124|128|132|136|140|144) return 0 ;;
        *) return 1 ;;
    esac
}

run_root() {
    # If passwordless sudo is available, use sudo; otherwise fall back to pkexec (Polkit GUI)
    if sudo -n "$1" --help >/dev/null 2>&1 || sudo -n true 2>/dev/null; then
        sudo "$@"
    else
        pkexec "$@"
    fi
}

# Session Lock: lock current Wi-Fi connection to prevent Mesh Band/AP Steering during hotspot sharing
lock_wifi_session() {
    local conn_name
    conn_name=$(nmcli -t -f GENERAL.CONNECTION dev show wlan0 2>/dev/null | cut -d: -f2- | sed '/^--$/d; /^$/d' | head -n1 || true)
    [ -z "$conn_name" ] && return 0

    local orig_bssid orig_band current_bssid current_freq
    orig_bssid=$(nmcli -g 802-11-wireless.bssid connection show "$conn_name" 2>/dev/null || true)
    orig_band=$(nmcli -g 802-11-wireless.band connection show "$conn_name" 2>/dev/null || true)

    current_bssid=$(iw dev wlan0 link 2>/dev/null | awk '/Connected to/{print $3}' | head -n1 || true)
    current_freq=$(iw dev wlan0 link 2>/dev/null | awk '/freq:/{print int($2)}' | head -n1 || true)

    cat <<EOF > "$LOCK_FILE"
{
  "connection": "$conn_name",
  "orig_bssid": "$orig_bssid",
  "orig_band": "$orig_band"
}
EOF

    # If currently connected to 2.4GHz (< 5000 MHz), lock band to 'bg' to prevent Band Steering to 5GHz
    if [ -n "$current_freq" ] && [ "$current_freq" -lt 5000 ] 2>/dev/null; then
        nmcli connection modify "$conn_name" 802-11-wireless.band bg 2>/dev/null || true
    fi

    # Lock BSSID to prevent roaming across mesh nodes while single-channel AP is active
    if [ -n "$current_bssid" ]; then
        nmcli connection modify "$conn_name" 802-11-wireless.bssid "$current_bssid" 2>/dev/null || true
    fi
}

unlock_wifi_session() {
    if [ -f "$LOCK_FILE" ]; then
        local conn_name orig_bssid orig_band
        conn_name=$(grep '"connection":' "$LOCK_FILE" 2>/dev/null | cut -d'"' -f4 || true)
        orig_bssid=$(grep '"orig_bssid":' "$LOCK_FILE" 2>/dev/null | cut -d'"' -f4 || true)
        orig_band=$(grep '"orig_band":' "$LOCK_FILE" 2>/dev/null | cut -d'"' -f4 || true)

        if [ -n "$conn_name" ]; then
            nmcli connection modify "$conn_name" 802-11-wireless.band "$orig_band" 2>/dev/null || true
            nmcli connection modify "$conn_name" 802-11-wireless.bssid "$orig_bssid" 2>/dev/null || true
        fi
        rm -f "$LOCK_FILE" 2>/dev/null || true
    fi
}

# Read and validate PID from file. Returns a validated PID or empty string.
read_pid() {
    local pid=""
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null | tr -d ' \n\r' || true)
    fi
    # Must be a bare positive integer
    case "$pid" in
        ''|*[!0-9]*) echo ""; return ;;
    esac
    # Verify the process is actually create_ap (cmdline is world-readable)
    if [ -d "/proc/$pid" ] && grep -qsz 'create_ap' "/proc/$pid/cmdline" 2>/dev/null; then
        echo "$pid"
    else
        echo ""
    fi
}

stop_hotspot() {
    local pid
    pid=$(read_pid)

    if [ -n "$pid" ]; then
        run_root create_ap --stop "$pid" >/dev/null 2>&1 || run_root kill -USR1 "$pid" >/dev/null 2>&1 || true
    elif iw dev ap0 info >/dev/null 2>&1; then
        run_root create_ap --stop ap0 >/dev/null 2>&1 || true
    fi

    # Wait up to 4s for ap0 to be dismantled and the validated process to exit
    local count=0
    while [ $count -lt 40 ]; do
        pid=$(read_pid)
        if ! iw dev ap0 info >/dev/null 2>&1 && [ -z "$pid" ]; then
            break
        fi
        sleep 0.1
        count=$((count + 1))
    done

    # Force cleanup: only remove the virtual interface as last resort
    if iw dev ap0 info >/dev/null 2>&1; then
        run_root iw dev ap0 del >/dev/null 2>&1 || true
    fi

    # Release NetworkManager session lock and clean up runtime files
    unlock_wifi_session
    rm -f "$PID_FILE" "$LOG_FILE" 2>/dev/null || true
}

case "$ACTION" in
    detect)
        INFO=$(get_active_wifi)
        if [ -n "$INFO" ]; then
            CHAN=$(echo "$INFO" | cut -d: -f2)
            FREQ_STR=$(echo "$INFO" | cut -d: -f3 | awk '{print $1}')
            FREQ=${FREQ_STR:-0}
            if [ "$FREQ" -ge 5000 ]; then
                BAND="5Ghz"
            elif [ "$FREQ" -gt 0 ]; then
                BAND="2.4Ghz"
            else
                BAND="Auto"
            fi

            IS_DFS=false
            if is_dfs_freq "$FREQ" "$CHAN"; then
                IS_DFS=true
            fi

            echo "{\"connected\": true, \"channel\": \"$CHAN\", \"band\": \"$BAND\", \"freq\": $FREQ, \"is_dfs\": $IS_DFS}"
        else
            echo '{"connected": false, "channel": "6", "band": "2.4Ghz", "freq": 2437, "is_dfs": false}'
        fi
        ;;

    status)
        is_active=false
        client_count=0

        if iw dev ap0 info >/dev/null 2>&1; then
            is_active=true
            client_count=$(iw dev ap0 station dump 2>/dev/null | grep -c "Station" || true)
            client_count=${client_count:-0}
        else
            # If hotspot is inactive but lock file still exists (e.g. from crash or unclean exit), auto-unlock
            if [ -f "$LOCK_FILE" ]; then
                unlock_wifi_session
            fi
        fi

        if [ "$is_active" = true ]; then
            echo "{\"active\": true, \"device\": \"ap0\", \"clients\": $client_count}"
        else
            echo '{"active": false, "clients": 0}'
        fi
        ;;

    start)
        SSID="$2"
        PASS="$3"
        BAND="$4"
        CHAN="$5"
        MAX_CLIENTS="${6:-0}"

        if [ -z "$SSID" ]; then
            echo '{"error": "SSID cannot be empty"}' >&2
            exit 1
        fi

        if [ -z "$PASS" ] || [ ${#PASS} -lt 8 ]; then
            echo '{"error": "Password must be at least 8 characters"}' >&2
            exit 1
        fi

        # Preemptive DFS check: Reject starting on DFS channels directly
        ACTIVE_INFO=$(get_active_wifi)
        ACTIVE_FREQ=$(echo "$ACTIVE_INFO" | cut -d: -f3 | awk '{print int($1)}')
        ACTIVE_CHAN=$(echo "$ACTIVE_INFO" | cut -d: -f2)

        TARGET_CHAN="$CHAN"
        [ -z "$TARGET_CHAN" ] || [ "$TARGET_CHAN" = "Auto" ] || [ "$TARGET_CHAN" = "default" ] && TARGET_CHAN="$ACTIVE_CHAN"

        if [ "$BAND" = "5Ghz" ] || ([ "$BAND" = "Auto" ] && [ "${ACTIVE_FREQ:-0}" -ge 5000 ]); then
            if is_dfs_freq "${ACTIVE_FREQ:-0}" "$TARGET_CHAN"; then
                echo "{\"error\": \"Channel $TARGET_CHAN is a DFS radar channel. Hotspots cannot broadcast on DFS channels. Please switch your Wi-Fi to 2.4GHz or channels 36-48.\"}" >&2
                exit 1
            fi
        fi

        # Find default internet interface
        INET_IFACE=$(ip route 2>/dev/null | awk '/default/{print $5; exit}' || echo "wlan0")
        [ -z "$INET_IFACE" ] && INET_IFACE="wlan0"

        # If already running or ap0 exists, clean it up first
        if iw dev ap0 info >/dev/null 2>&1 || [ -f "$PID_FILE" ]; then
            stop_hotspot
        fi

        # Apply Session Lock: protect current Wi-Fi connection from mesh steering/roaming
        lock_wifi_session

        # Prepare log and pid files with world-readable permissions before daemon writes
        rm -f "$LOG_FILE" "$PID_FILE" 2>/dev/null || true
        touch "$LOG_FILE" "$PID_FILE" 2>/dev/null || true
        chmod 666 "$LOG_FILE" "$PID_FILE" 2>/dev/null || true

        CMD_ARGS=(--daemon --pidfile "$PID_FILE" --logfile "$LOG_FILE" wlan0 "$INET_IFACE" "$SSID" "$PASS")

        # Add channel if specified and valid
        if [ -n "$CHAN" ] && [ "$CHAN" != "Auto" ] && [ "$CHAN" != "default" ]; then
            CMD_ARGS+=(-c "$CHAN")
        fi

        # Add band if specified
        if [ "$BAND" = "5Ghz" ]; then
            CMD_ARGS+=(--freq-band 5)
        elif [ "$BAND" = "2.4Ghz" ]; then
            CMD_ARGS+=(--freq-band 2.4)
        fi

        # Add max clients limit (strictly 1 to 8, default 2, no unlimited)
        if [ -z "$MAX_CLIENTS" ] || [ "$MAX_CLIENTS" -lt 1 ] 2>/dev/null; then
            MAX_CLIENTS=2
        elif [ "$MAX_CLIENTS" -gt 8 ] 2>/dev/null; then
            MAX_CLIENTS=8
        fi
        DRIVER_ARG=$'nl80211\nmax_num_sta='"$MAX_CLIENTS"
        CMD_ARGS+=(--driver "$DRIVER_ARG")

        # Run create_ap as daemon
        OUTPUT=$(run_root create_ap "${CMD_ARGS[@]}" 2>&1)
        EXIT_CODE=$?

        # Ensure log and pid files remain accessible
        chmod 666 "$LOG_FILE" "$PID_FILE" 2>/dev/null || true

        if [ $EXIT_CODE -ne 0 ]; then
            unlock_wifi_session
            ERR_MSG=$(echo "$OUTPUT" | grep -i "ERROR:" | head -n1)
            [ -z "$ERR_MSG" ] && ERR_MSG="$OUTPUT"
            ERR_CLEAN=$(printf '%s' "$ERR_MSG" | tr -d '\n\r' | sed 's/\\/\\\\/g; s/"/\\"/g')
            echo "{\"error\": \"$ERR_CLEAN\"}" >&2
            exit $EXIT_CODE
        fi

        # Wait up to 6s for daemon to create ap0, then verify hostapd stabilization
        started=false
        for i in $(seq 1 60); do
            sleep 0.1
            if iw dev ap0 info >/dev/null 2>&1; then
                # Interface created; now verify daemon stabilization (1.5s) to ensure hostapd doesn't crash
                stable=true
                for j in $(seq 1 15); do
                    sleep 0.1
                    check_pid=$(read_pid)
                    if [ -n "$check_pid" ] && [ ! -d "/proc/$check_pid" ]; then
                        stable=false
                        break
                    fi
                    if ! iw dev ap0 info >/dev/null 2>&1; then
                        stable=false
                        break
                    fi
                    if [ -f "$LOG_FILE" ] && grep -q -i -E "(Hardware does not support|Failed to run hostapd|die:|ERROR:)" "$LOG_FILE" 2>/dev/null; then
                        stable=false
                        break
                    fi
                done

                if [ "$stable" = true ]; then
                    started=true
                fi
                break
            fi

            # Check if PID file was created and daemon died prematurely
            if [ -f "$PID_FILE" ]; then
                raw_pid=$(cat "$PID_FILE" 2>/dev/null | tr -d ' \n\r' || true)
                case "$raw_pid" in
                    ''|*[!0-9]*) ;;
                    *) [ ! -d "/proc/$raw_pid" ] && break ;;
                esac
            fi

            # Check if log file recorded a fatal error
            if [ -f "$LOG_FILE" ] && grep -q -i -E "(ERROR:|Failed to run hostapd|die:)" "$LOG_FILE" 2>/dev/null; then
                break
            fi
        done

        if [ "$started" = true ]; then
            echo '{"success": true}'
            exit 0
        else
            ERR_MSG=""
            if [ -f "$LOG_FILE" ]; then
                ERR_MSG=$(grep -i -E "(Hardware does not support|ERROR:|Failed to|die:)" "$LOG_FILE" 2>/dev/null | tail -n1 || true)
                [ -z "$ERR_MSG" ] && ERR_MSG=$(tail -n3 "$LOG_FILE" 2>/dev/null | tr '\n' ' ' || true)
            fi
            [ -z "$ERR_MSG" ] && ERR_MSG="Failed to start hotspot daemon or channel unsupported"
            stop_hotspot
            ERR_CLEAN=$(printf '%s' "$ERR_MSG" | tr -d '\n\r' | sed 's/\\/\\\\/g; s/"/\\"/g')
            echo "{\"error\": \"$ERR_CLEAN\"}" >&2
            exit 1
        fi
        ;;

    stop)
        stop_hotspot
        echo '{"stopped": true}'
        ;;

    *)
        echo "Usage: $0 {detect|status|start|stop}"
        exit 1
        ;;
esac
