#!/usr/bin/env sh
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/setup-deps.sh [--check] [--yes]

Install or check runtime dependencies for the Noctalia Lyrics plugin.

Options:
  --check   Only report missing commands; do not install anything.
  --yes     Skip the confirmation prompt before installing packages.
  --help    Show this help text.
EOF
}

CHECK_ONLY=0
ASSUME_YES=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      ;;
    -y|--yes)
      ASSUME_YES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

need_command() {
  command -v "$1" >/dev/null 2>&1 || MISSING_COMMANDS="$MISSING_COMMANDS $1"
}

MISSING_COMMANDS=""
need_command playerctl
need_command python3
need_command cp
need_command chmod

if [ -z "$MISSING_COMMANDS" ]; then
  echo "All runtime commands are installed: playerctl python3 cp chmod"
  exit 0
fi

echo "Missing runtime command(s):$MISSING_COMMANDS"

if [ "$CHECK_ONLY" -eq 1 ]; then
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "sudo is required to install packages as a non-root user." >&2
  exit 1
fi

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  elif command -v pacman >/dev/null 2>&1; then
    echo pacman
  elif command -v zypper >/dev/null 2>&1; then
    echo zypper
  elif command -v apk >/dev/null 2>&1; then
    echo apk
  elif command -v xbps-install >/dev/null 2>&1; then
    echo xbps
  else
    echo unknown
  fi
}

PM="$(detect_pm)"

case "$PM" in
  apt)
    INSTALL_CMD="$SUDO apt-get update && $SUDO apt-get install -y playerctl python3 coreutils"
    ;;
  dnf)
    INSTALL_CMD="$SUDO dnf install -y playerctl python3 coreutils"
    ;;
  pacman)
    INSTALL_CMD="$SUDO pacman -S --needed playerctl python coreutils"
    ;;
  zypper)
    INSTALL_CMD="$SUDO zypper install -y playerctl python3 coreutils"
    ;;
  apk)
    INSTALL_CMD="$SUDO apk add playerctl python3 coreutils"
    ;;
  xbps)
    INSTALL_CMD="$SUDO xbps-install -Sy playerctl python3 coreutils"
    ;;
  *)
    cat >&2 <<'EOF'
Could not detect a supported package manager.
Install these packages manually with your distribution package manager:
  playerctl python3 coreutils
EOF
    exit 1
    ;;
esac

echo "Detected package manager: $PM"
echo "Install command: $INSTALL_CMD"

if [ "$ASSUME_YES" -ne 1 ]; then
  printf "Proceed with installation? [y/N] "
  read -r answer
  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Cancelled."
      exit 1
      ;;
  esac
fi

sh -c "$INSTALL_CMD"

MISSING_COMMANDS=""
need_command playerctl
need_command python3
need_command cp
need_command chmod

if [ -n "$MISSING_COMMANDS" ]; then
  echo "Still missing after installation:$MISSING_COMMANDS" >&2
  exit 1
fi

echo "Dependencies installed successfully."
