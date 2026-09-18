#!/usr/bin/env bash

ACTION="${1:-status}"

# Per-user runtime directory for PID and log files (avoids world-writable /tmp)
RUN_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/noctalia-share-wifi"
mkdir -p "$RUN_DIR" 2>/dev/null || true
PID_FILE="$RUN_DIR/pid"
LOG_FILE="$RUN_DIR/log"

get_active_wifi() {
    nmcli -t -f active,chan,freq dev wifi list --rescan no 2>/dev/null | grep '^yes' | head -n1 || true
}

run_root() {
    # If passwordless sudo is available, use sudo; otherwise fall back to pkexec (Polkit GUI)
    if sudo -n "$1" --help >/dev/null 2>&1 || sudo -n true 2>/dev/null; then
        sudo "$@"
    else
        pkexec "$@"
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

    # Force cleanup: only remove the virtual interface as last resort (no process signalling)
    if iw dev ap0 info >/dev/null 2>&1; then
        run_root iw dev ap0 del >/dev/null 2>&1 || true
    fi

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
            echo "{\"connected\": true, \"channel\": \"$CHAN\", \"band\": \"$BAND\", \"freq\": $FREQ}"
        else
            echo '{"connected": false, "channel": "6", "band": "2.4Ghz", "freq": 2437}'
        fi
        ;;

    status)
        is_active=false
        client_count=0

        if iw dev ap0 info >/dev/null 2>&1; then
            is_active=true
            client_count=$(iw dev ap0 station dump 2>/dev/null | grep -c "Station" || true)
            client_count=${client_count:-0}
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

        # Find default internet interface
        INET_IFACE=$(ip route 2>/dev/null | awk '/default/{print $5; exit}' || echo "wlan0")
        [ -z "$INET_IFACE" ] && INET_IFACE="wlan0"

        # If already running or ap0 exists, clean it up first
        if iw dev ap0 info >/dev/null 2>&1 || [ -f "$PID_FILE" ]; then
            stop_hotspot
        fi

        rm -f "$LOG_FILE" "$PID_FILE" 2>/dev/null || true

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

        if [ $EXIT_CODE -ne 0 ]; then
            ERR_MSG=$(echo "$OUTPUT" | grep -i "ERROR:" | head -n1)
            [ -z "$ERR_MSG" ] && ERR_MSG="$OUTPUT"
            ERR_CLEAN=$(printf '%s' "$ERR_MSG" | tr -d '\n\r' | sed 's/\\/\\\\/g; s/"/\\"/g')
            echo "{\"error\": \"$ERR_CLEAN\"}" >&2
            exit $EXIT_CODE
        fi

        # Wait up to 6s for daemon to initialize and create ap0
        started=false
        for i in $(seq 1 60); do
            sleep 0.1
            if iw dev ap0 info >/dev/null 2>&1; then
                started=true
                break
            fi

            # Check if PID file was created and daemon died prematurely
            if [ -f "$PID_FILE" ]; then
                local raw_pid
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
                ERR_MSG=$(grep -i -E "(ERROR:|Failed to|die:)" "$LOG_FILE" 2>/dev/null | tail -n1 || true)
                [ -z "$ERR_MSG" ] && ERR_MSG=$(tail -n3 "$LOG_FILE" 2>/dev/null | tr '\n' ' ' || true)
            fi
            [ -z "$ERR_MSG" ] && ERR_MSG="Failed to start hotspot daemon"
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
