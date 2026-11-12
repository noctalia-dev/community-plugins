#!/usr/bin/env bash
# Social Block — install the privileged /etc/hosts helper on any Linux distro.
#
#   bash install-helper.sh                  # install / repair
#   bash install-helper.sh --update-domains # replace the domain list + rules
#   bash install-helper.sh --uninstall      # remove helper, list, allowlist and rules
#   bash install-helper.sh --check          # report what is installed; changes nothing
#   bash install-helper.sh --sudo|--doas    # force the privilege tool
#
# Installs:
#   /usr/local/bin/social-block-net   root-owned, 0755
#   /etc/social-block/domains         root-owned, 0644 (preserved by default)
#   /etc/social-block/allowed         root-owned, 0644 (per-service allowlist)
#   /etc/hosts.social-block.bak       last clean /etc/hosts before a block
#   a scoped sudoers or doas rule for:
#     on, off, status, allow <service>, block <service>
#
# Noctalia plugins cannot install system files themselves, so this one command
# is the only manual step. It is distribution-independent; bash is required.
set -euo pipefail
umask 022

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DST="/usr/local/bin/social-block-net"
DOMAINS_DIR="/etc/social-block"
DOMAINS_DST="$DOMAINS_DIR/domains"
ALLOWED_DST="$DOMAINS_DIR/allowed"
BACKUP_DST="/etc/hosts.social-block.bak"
SUDOERS="/etc/sudoers.d/social-block"
DOAS_CONF="/etc/doas.conf"

say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
warn() { printf '  warning: %s\n' "$*" >&2; }
die() { printf 'install-helper: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ACTION=install
REQUESTED_USER=""
FORCE_PRIV=""
for arg in "$@"; do
  case "$arg" in
    --update-domains) ACTION=update ;;
    --uninstall) ACTION=uninstall ;;
    --check) ACTION=check ;;
    --sudo) FORCE_PRIV=sudo ;;
    --doas) FORCE_PRIV=doas ;;
    --user=*) REQUESTED_USER="${arg#--user=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $arg (try --help)" ;;
  esac
done

# Locate the shipped helper and domain list. The plugin directory is
# self-contained; the ../bin and ../config fallbacks keep the rice checkout
# working.
HELPER_SRC="$SELF_DIR/social-block-net"
DOMAINS_SRC="$SELF_DIR/domains"
if [ ! -f "$HELPER_SRC" ]; then
  HELPER_SRC="$SELF_DIR/../bin/social-block-net"
fi
if [ ! -f "$DOMAINS_SRC" ]; then
  DOMAINS_SRC="$SELF_DIR/../config/social-block/domains"
fi
[ -f "$HELPER_SRC" ] || die "social-block-net not found next to this script"
[ -f "$DOMAINS_SRC" ] || die "domains file not found next to this script"

# Detect privilege escalation. Running the script itself as root is fine too.
IS_ROOT=0
PRIV=()
PRIV_NAME=""
if [ "$(id -u)" -eq 0 ]; then
  IS_ROOT=1
  USER_NAME="${SUDO_USER:-${DOAS_USER:-$REQUESTED_USER}}"
  [ -n "$USER_NAME" ] || die "run as your normal user (e.g. sudo bash install-helper.sh) or pass --user=NAME"
  if [ -n "$FORCE_PRIV" ]; then
    PRIV_NAME="$FORCE_PRIV"
  elif command -v sudo >/dev/null 2>&1; then
    PRIV_NAME=sudo
  elif command -v doas >/dev/null 2>&1; then
    PRIV_NAME=doas
  else
    die "need sudo or doas installed"
  fi
else
  USER_NAME="${REQUESTED_USER:-$(id -un)}"
  if [ "$FORCE_PRIV" = "doas" ]; then
    command -v doas >/dev/null 2>&1 || die "--doas requested but doas is not installed"
    PRIV=(doas); PRIV_NAME=doas
  elif [ "$FORCE_PRIV" = "sudo" ]; then
    command -v sudo >/dev/null 2>&1 || die "--sudo requested but sudo is not installed"
    PRIV=(sudo); PRIV_NAME=sudo
  elif command -v sudo >/dev/null 2>&1; then
    PRIV=(sudo); PRIV_NAME=sudo
  elif command -v doas >/dev/null 2>&1; then
    PRIV=(doas); PRIV_NAME=doas
  else
    die "need sudo or doas installed"
  fi
fi

run() {
  if [ "$IS_ROOT" -eq 1 ]; then "$@"; else "${PRIV[@]}" "$@"; fi
}

run_n() {
  if [ "$IS_ROOT" -eq 1 ]; then "$@"; else "${PRIV[@]}" -n "$@"; fi
}

services_from() {
  local file="$1"
  [ -r "$file" ] || return 0
  sed -n 's/^##[[:space:]]*\([a-z0-9-]*\)[[:space:]]*|.*/\1/p' "$file" | awk '!seen[$0]++'
}

strip_doas_block() {
  awk -v b='# >>> social-block >>>' -v e='# <<< social-block <<<' '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$1"
}

strip_hosts_block() {
  [ -f /etc/hosts ] || return 0
  grep -qF '# >>> social-block >>>' /etc/hosts 2>/dev/null || return 0
  grep -qF '# <<< social-block <<<' /etc/hosts 2>/dev/null || return 1
  local tmp
  tmp=$(mktemp)
  awk -v b='# >>> social-block >>>' -v e='# <<< social-block <<<' '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' /etc/hosts > "$tmp"
  run tee /etc/hosts < "$tmp" >/dev/null || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  if command -v resolvectl >/dev/null 2>&1; then
    run resolvectl flush-caches >/dev/null 2>&1 || true
  fi
  return 0
}

write_doas_conf() {
  local services=("$@") tmp
  tmp=$(mktemp)
  if [ -f "$DOAS_CONF" ]; then
    strip_doas_block "$DOAS_CONF" > "$tmp"
  fi
  {
    printf '\n# >>> social-block >>>\n'
    printf 'permit nopass %s as root cmd %s args on\n' "$USER_NAME" "$HELPER_DST"
    printf 'permit nopass %s as root cmd %s args off\n' "$USER_NAME" "$HELPER_DST"
    printf 'permit nopass %s as root cmd %s args status\n' "$USER_NAME" "$HELPER_DST"
    local s
    for s in "${services[@]}"; do
      printf 'permit nopass %s as root cmd %s args allow %s\n' "$USER_NAME" "$HELPER_DST" "$s"
      printf 'permit nopass %s as root cmd %s args block %s\n' "$USER_NAME" "$HELPER_DST" "$s"
    done
    printf '# <<< social-block <<<\n'
  } >> "$tmp"
  run tee "$DOAS_CONF" < "$tmp" >/dev/null
  run chmod 0400 "$DOAS_CONF"
  rm -f "$tmp"
}

write_sudoers() {
  local services=("$@") tmp s
  command -v visudo >/dev/null 2>&1 || die "visudo not found; install sudo's tooling"
  tmp=$(mktemp)
  {
    printf '%s ALL=(root) NOPASSWD: %s on\n' "$USER_NAME" "$HELPER_DST"
    printf '%s ALL=(root) NOPASSWD: %s off\n' "$USER_NAME" "$HELPER_DST"
    printf '%s ALL=(root) NOPASSWD: %s status\n' "$USER_NAME" "$HELPER_DST"
    for s in "${services[@]}"; do
      printf '%s ALL=(root) NOPASSWD: %s allow %s\n' "$USER_NAME" "$HELPER_DST" "$s"
      printf '%s ALL=(root) NOPASSWD: %s block %s\n' "$USER_NAME" "$HELPER_DST" "$s"
    done
  } > "$tmp"
  run visudo -cf "$tmp" >/dev/null
  run install -o root -g root -m 0440 "$tmp" "$SUDOERS"
  rm -f "$tmp"
}

remove_doas_block() {
  [ -f "$DOAS_CONF" ] || return 0
  grep -qF '# >>> social-block >>>' "$DOAS_CONF" || return 0
  local tmp
  tmp=$(mktemp)
  strip_doas_block "$DOAS_CONF" > "$tmp"
  run tee "$DOAS_CONF" < "$tmp" >/dev/null
  run chmod 0400 "$DOAS_CONF"
  rm -f "$tmp"
}

if [ "$ACTION" = "check" ]; then
  say "Sources"
  echo "  helper:  $HELPER_SRC"
  echo "  domains: $DOMAINS_SRC ($(grep -cE '^[A-Za-z0-9]' "$DOMAINS_SRC" 2>/dev/null || echo '?') entries)"
  say "Privilege escalation"
  if [ "$IS_ROOT" -eq 1 ]; then
    echo "  running as root (rule target: $USER_NAME, tool: $PRIV_NAME)"
  else
    echo "  $PRIV_NAME (user: $USER_NAME)"
  fi
  say "Installed files"
  files=("$HELPER_DST" "$DOMAINS_DST" "$ALLOWED_DST" "$BACKUP_DST")
  if [ "$PRIV_NAME" = "doas" ]; then
    files+=("$DOAS_CONF")
  else
    files+=("$SUDOERS")
  fi
  for f in "${files[@]}"; do
    if [ -e "$f" ]; then echo "  ok      $f"; else echo "  missing $f"; fi
  done
  if [ -r "$DOMAINS_DST" ]; then
    mapfile -t SERVICES < <(services_from "$DOMAINS_DST")
    [ ${#SERVICES[@]} -gt 0 ] || SERVICES=(all)
    echo "  services: ${#SERVICES[@]} (${SERVICES[*]})"
  fi
  if [ -r "$ALLOWED_DST" ]; then
    echo "  allowed: $(grep -cve '^[[:space:]]*$' "$ALLOWED_DST" 2>/dev/null || echo 0) service(s)"
  else
    echo "  allowed: none (everything blocked)"
  fi
  say "Current state"
  if [ -x "$HELPER_DST" ]; then
    if [ "$IS_ROOT" -eq 1 ]; then
      "$HELPER_DST" status || true
    else
      run_n "$HELPER_DST" status 2>/dev/null \
        || warn "cannot run the helper without a password yet (rule missing?)"
    fi
  else
    echo "  helper not installed"
  fi
  exit 0
fi

if [ "$ACTION" = "uninstall" ]; then
  say "Removing the block from /etc/hosts"
  state="unknown"
  if [ -x "$HELPER_DST" ]; then
    run "$HELPER_DST" off >/dev/null 2>&1 || true
    state=$(run_n "$HELPER_DST" status 2>/dev/null || true)
  elif strip_hosts_block; then
    # The helper was already removed; strip the marked block directly so an
    # uninstall still restores /etc/hosts.
    state=off
  else
    state=incomplete
  fi
  say "Removing helper, domain list, allowlist and privilege rule"
  run rm -f "$HELPER_DST" "$SUDOERS" "$ALLOWED_DST" "$DOMAINS_DST"
  remove_doas_block
  run rmdir "$DOMAINS_DIR" 2>/dev/null || true
  if [ "$state" = "off" ]; then
    run rm -f "$BACKUP_DST"
  else
    warn "state is '$state'; keeping $BACKUP_DST so /etc/hosts can be restored"
  fi
  echo "  done"
  exit 0
fi

[ -x "$HELPER_SRC" ] || chmod +x "$HELPER_SRC" 2>/dev/null || true

say "Installing the helper to $HELPER_DST"
run install -o root -g root -m 0755 "$HELPER_SRC" "$HELPER_DST"

say "Installing the domain list"
run install -d -o root -g root -m 0755 "$DOMAINS_DIR"
if [ -e "$DOMAINS_DST" ] && [ "$ACTION" != "update" ]; then
  echo "  keeping existing $DOMAINS_DST"
  echo "  (use --update-domains to replace it and regenerate per-service rules)"
else
  run install -o root -g root -m 0644 "$DOMAINS_SRC" "$DOMAINS_DST"
  echo "  installed $DOMAINS_DST"
fi

# Rules are generated from the installed file, so a preserved legacy list
# gets a single "all" service and still works.
mapfile -t SERVICES < <(services_from "$DOMAINS_DST")
[ ${#SERVICES[@]} -gt 0 ] || SERVICES=(all)
echo "  services: ${#SERVICES[@]}"

say "Allowing $USER_NAME to manage Social Block without a password"
if [ "$PRIV_NAME" = "doas" ]; then
  write_doas_conf "${SERVICES[@]}"
  run rm -f "$SUDOERS" 2>/dev/null || true
  echo "  $DOAS_CONF (marked social-block block)"
else
  write_sudoers "${SERVICES[@]}"
  remove_doas_block
  echo "  $SUDOERS"
fi

say "Verifying"
if [ "$IS_ROOT" -eq 1 ]; then
  state=$("$HELPER_DST" status || true)
else
  state=$(run_n "$HELPER_DST" status 2>/dev/null || true)
fi
echo "  $state"
if [ "$state" = "on" ]; then
  # Re-apply so a preserved or updated list immediately matches the new
  # service selection, even when the block was already on.
  if [ "$IS_ROOT" -eq 1 ]; then
    "$HELPER_DST" on >/dev/null || true
  else
    run_n "$HELPER_DST" on >/dev/null 2>&1 || true
  fi
  echo "  re-applied the block with the current service list"
elif [ "$state" = "incomplete" ]; then
  warn "the /etc/hosts block is incomplete; restore $BACKUP_DST before toggling"
fi

cat <<'EOF'

Done. Next:
  1. Enable the plugin: Settings → Plugins → Social Block
     (or: noctalia msg plugins enable treeonlinux/social-block)
  2. Add the bar widget: Settings → Bar → Add widget → Social Block
  3. Add the control-center tile: Control Center → Shortcuts → Social Block
  4. Open the panel: noctalia msg panel-toggle treeonlinux/social-block:panel
  5. Allow a service (e.g. Slack) by toggling it off in the panel.
  6. Optional global keybind (Hyprland):
       Lua:  hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("noctalia msg plugin treeonlinux/social-block:service all toggle"))
       conf: bind = SUPER SHIFT, B, exec, noctalia msg plugin treeonlinux/social-block:service all toggle

Edit blocked sites with: sudoedit /etc/social-block/domains
Then re-run: bash install-helper.sh --update-domains
EOF
