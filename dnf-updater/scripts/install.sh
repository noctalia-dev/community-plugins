#!/bin/bash
#
# DNF Updater - Privileged Helper & Polkit Policy Installer
#
# Installs or uninstalls the privileged helper and Polkit rule.
# Supports both local repository invocation and remote execution via:
#   curl -fsSL https://raw.githubusercontent.com/strob3/dnf-updater/main/scripts/install.sh | sudo bash
#

set -euo pipefail

DEST_BIN="/usr/local/bin/dnf-updater-helper"
DEST_POLKIT="/etc/polkit-1/rules.d/50-dnf-updater.rules"
REPO_RAW_URL="https://raw.githubusercontent.com/strob3/dnf-updater/main"

# Help / usage
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [install|--uninstall]"
    echo ""
    echo "Commands:"
    echo "  install        Install helper to $DEST_BIN and rule to $DEST_POLKIT (default)"
    echo "  --uninstall    Remove helper and Polkit rule from the system"
    exit 0
fi

# Verify root privileges
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: Installation requires root privileges. Please run with sudo:" >&2
    echo "  sudo $0 $@" >&2
    exit 1
fi

ACTION="${1:-install}"

case "$ACTION" in
    uninstall|--uninstall|-u)
        echo "Removing DNF Updater privileged helper and Polkit rule..."
        rm -f "$DEST_BIN" "$DEST_POLKIT"
        echo "✓ Successfully removed:"
        echo "  - $DEST_BIN"
        echo "  - $DEST_POLKIT"
        exit 0
        ;;
    install|--install|-i)
        ;;
    *)
        echo "Error: unknown argument '$ACTION'" >&2
        echo "Usage: $0 [install|--uninstall]" >&2
        exit 1
        ;;
esac

echo "==> Installing DNF Updater privileged helper and Polkit rule..."

# Determine script location if running locally
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"

SRC_HELPER=""
SRC_POLKIT=""
CLEANUP_TMP=false
TMP_DIR=""

if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/dnf-updater-helper.sh" && -f "${SCRIPT_DIR}/../polkit/50-dnf-updater.rules" ]]; then
    echo "  → Using local repository files..."
    SRC_HELPER="${SCRIPT_DIR}/dnf-updater-helper.sh"
    SRC_POLKIT="${SCRIPT_DIR}/../polkit/50-dnf-updater.rules"
elif [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/scripts/dnf-updater-helper.sh" && -f "${SCRIPT_DIR}/polkit/50-dnf-updater.rules" ]]; then
    echo "  → Using local repository files..."
    SRC_HELPER="${SCRIPT_DIR}/scripts/dnf-updater-helper.sh"
    SRC_POLKIT="${SCRIPT_DIR}/polkit/50-dnf-updater.rules"
else
    echo "  → Fetching latest files from GitHub ($REPO_RAW_URL)..."
    TMP_DIR="$(mktemp -d)"
    CLEANUP_TMP=true
    trap 'rm -rf "$TMP_DIR"' EXIT

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${REPO_RAW_URL}/scripts/dnf-updater-helper.sh" -o "${TMP_DIR}/dnf-updater-helper.sh"
        curl -fsSL "${REPO_RAW_URL}/polkit/50-dnf-updater.rules" -o "${TMP_DIR}/50-dnf-updater.rules"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${TMP_DIR}/dnf-updater-helper.sh" "${REPO_RAW_URL}/scripts/dnf-updater-helper.sh"
        wget -qO "${TMP_DIR}/50-dnf-updater.rules" "${REPO_RAW_URL}/polkit/50-dnf-updater.rules"
    else
        echo "Error: neither curl nor wget was found to download required files." >&2
        exit 1
    fi

    SRC_HELPER="${TMP_DIR}/dnf-updater-helper.sh"
    SRC_POLKIT="${TMP_DIR}/50-dnf-updater.rules"
fi

# Install privileged helper
install -Dm755 "$SRC_HELPER" "$DEST_BIN"
echo "  ✓ Installed privileged helper: $DEST_BIN (mode 0755)"

# Install Polkit rule
install -Dm644 "$SRC_POLKIT" "$DEST_POLKIT"
echo "  ✓ Installed Polkit policy:     $DEST_POLKIT (mode 0644)"

# Fix SELinux context if SELinux is available
if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$DEST_BIN" "$DEST_POLKIT" 2>/dev/null || true
fi

# Check if target user belongs to wheel or sudo
INVOKER="${SUDO_USER:-$USER}"
if [[ -n "$INVOKER" && "$INVOKER" != "root" ]]; then
    if ! id -nG "$INVOKER" 2>/dev/null | grep -Ewq "wheel|sudo"; then
        echo ""
        echo "  ⚠ Warning: User '$INVOKER' is not in the 'wheel' or 'sudo' group."
        echo "    Polkit requires administrative group membership for passwordless updates."
        echo "    Add your user with: sudo usermod -aG wheel $INVOKER"
    fi
fi

echo ""
echo "✓ Installation complete!"
echo "💡 Tip: To enable background updates without terminal popups, ensure 'Run Updates in Terminal'"
echo "   is turned off in Noctalia Settings → Plugins → DNF Updater."
