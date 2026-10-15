#!/usr/bin/env bash
# setup-requirements.sh
# Diagnostic and automated setup script for MacBook Fan & Thermal Monitor
# Ensures applesmc driver is loaded, mbpfan daemon is configured, and sysfs fan control permissions are set.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CHECK_ONLY=false
if [ "$1" = "--check" ]; then
    CHECK_ONLY=true
fi

echo -e "${BLUE}=== MacBook Fan & Thermal Requirements Check ===${NC}"

ERRORS=0

# 1. Check Apple SMC Driver
echo -n "Checking Apple SMC driver (applesmc)... "
if ls /sys/devices/platform/applesmc.*/fan1_input >/dev/null 2>&1 || [ -f /sys/devices/platform/applesmc.768/fan1_input ]; then
    echo -e "${GREEN}[OK] Loaded and sysfs available${NC}"
else
    echo -e "${YELLOW}[MISSING]${NC}"
    ERRORS=$((ERRORS + 1))
    if [ "$CHECK_ONLY" = false ]; then
        echo "Attempting to load kernel module applesmc..."
        if sudo modprobe applesmc; then
            echo -e "${GREEN}[OK] applesmc loaded successfully!${NC}"
            ERRORS=$((ERRORS - 1))
            if [ ! -f /etc/modules-load.d/applesmc.conf ]; then
                echo "applesmc" | sudo tee /etc/modules-load.d/applesmc.conf >/dev/null
                echo "Added applesmc to /etc/modules-load.d/applesmc.conf for persistence."
            fi
        else
            echo -e "${RED}[ERROR] Failed to load applesmc module. Verify kernel compatibility.${NC}"
        fi
    else
        echo "Module applesmc is not active in sysfs."
    fi
fi

# 2. Check mbpfan Daemon
echo -n "Checking mbpfan daemon... "
if command -v mbpfan >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] Installed ($(command -v mbpfan))${NC}"
else
    echo -e "${YELLOW}[MISSING]${NC}"
    ERRORS=$((ERRORS + 1))
    if [ "$CHECK_ONLY" = false ]; then
        echo "mbpfan is not installed. Attempting installation..."
        if command -v pacman >/dev/null 2>&1; then
            echo "Installing mbpfan-git / mbpfan via pacman..."
            sudo pacman -S --noconfirm mbpfan-git || sudo pacman -S --noconfirm mbpfan || true
        elif command -v apt >/dev/null 2>&1; then
            echo "Installing mbpfan via apt..."
            sudo apt update && sudo apt install -y mbpfan || true
        elif command -v dnf >/dev/null 2>&1; then
            echo "Installing mbpfan via dnf..."
            sudo dnf install -y mbpfan || true
        else
            echo -e "${RED}Unknown package manager. Please install 'mbpfan' manually.${NC}"
        fi
        if command -v mbpfan >/dev/null 2>&1; then
            echo -e "${GREEN}[OK] mbpfan successfully installed!${NC}"
            ERRORS=$((ERRORS - 1))
        fi
    fi
fi

# 3. Check mbpfan Service Status
echo -n "Checking mbpfan systemd service... "
if systemctl is-active --quiet mbpfan 2>/dev/null; then
    echo -e "${GREEN}[OK] Active and running${NC}"
else
    STATUS=$(systemctl is-enabled mbpfan 2>/dev/null || echo "not enabled")
    echo -e "${YELLOW}[INACTIVE] (Status: $STATUS)${NC}"
    ERRORS=$((ERRORS + 1))
    if [ "$CHECK_ONLY" = false ] && command -v mbpfan >/dev/null 2>&1; then
        echo "Enabling and starting mbpfan.service..."
        if sudo systemctl enable --now mbpfan; then
            echo -e "${GREEN}[OK] mbpfan service enabled and started!${NC}"
            ERRORS=$((ERRORS - 1))
        else
            echo -e "${RED}[ERROR] Failed to start mbpfan service. Check 'journalctl -u mbpfan'.${NC}"
        fi
    fi
fi

# 4. Check Telemetry Read Permissions
echo -n "Checking sysfs fan telemetry readability... "
FAN_FILE=$(ls /sys/devices/platform/applesmc.*/fan1_input 2>/dev/null | head -n 1 || true)
if [ -n "$FAN_FILE" ] && [ -r "$FAN_FILE" ]; then
    RPM=$(cat "$FAN_FILE" 2>/dev/null || echo 0)
    echo -e "${GREEN}[OK] World-readable ($RPM RPM)${NC}"
else
    echo -e "${YELLOW}[WARN] Cannot read $FAN_FILE directly.${NC}"
fi

# 5. Check Fan Manual Control Permissions
echo -n "Checking sysfs manual fan control permissions... "
OUTPUT_FILE=$(ls /sys/devices/platform/applesmc.*/fan1_output 2>/dev/null | head -n 1 || true)
MANUAL_FILE=$(ls /sys/devices/platform/applesmc.*/fan1_manual 2>/dev/null | head -n 1 || true)

if [ -n "$OUTPUT_FILE" ] && [ -w "$OUTPUT_FILE" ] && [ -n "$MANUAL_FILE" ] && [ -w "$MANUAL_FILE" ]; then
    echo -e "${GREEN}[OK] Writable for instantaneous manual fan speed adjustments${NC}"
else
    if [ "$CHECK_ONLY" = false ]; then
        echo -e "${YELLOW}[CONFIGURING]${NC}"
        echo "Configuring permissions for sysfs fan control nodes..."
        sudo chmod 0666 /sys/devices/platform/applesmc.*/fan1_manual /sys/devices/platform/applesmc.*/fan1_output 2>/dev/null || true
        UDEV_RULE_FILE="/etc/udev/rules.d/99-macbook-fan.rules"
        if [ ! -f "$UDEV_RULE_FILE" ]; then
            echo 'ACTION=="add|bind", SUBSYSTEM=="platform", DRIVERS=="applesmc", RUN+="/bin/sh -c '\''chmod 0666 /sys/devices/platform/applesmc.*/fan1_manual /sys/devices/platform/applesmc.*/fan1_output 2>/dev/null || true'\''"' | sudo tee "$UDEV_RULE_FILE" >/dev/null
            echo "Installed persistent udev rule: $UDEV_RULE_FILE"
            sudo udevadm control --reload-rules 2>/dev/null || true
            sudo udevadm trigger --subsystem-match=platform 2>/dev/null || true
        fi
        if [ -n "$OUTPUT_FILE" ] && [ -w "$OUTPUT_FILE" ]; then
            echo -e "${GREEN}[OK] Sysfs manual control nodes are now writable!${NC}"
        fi
    else
        echo -e "${YELLOW}[REQUIRES ROOT] Run without --check to configure udev rule.${NC}"
    fi
fi

echo -e "${BLUE}================================================${NC}"
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}All prerequisites are satisfied! The Noctalia MacBook Fan plugin is ready.${NC}"
    exit 0
else
    echo -e "${RED}$ERRORS prerequisite issue(s) detected.${NC}"
    exit 1
fi
