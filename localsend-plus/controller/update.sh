#!/bin/sh
# Builds localsend-controller from the sources next to this script, then
# restarts the LocalSend Plus service so it picks the new build up. The
# plugin runs it in a terminal when the installed controller is missing or
# older than these sources, and any shell can run it the same way:
#
#   sh /path/to/localsend-plus/controller/update.sh
#
# It installs nothing but the controller. When Rust or a C compiler is
# missing, it prints the commands for this system and stops. --pause waits
# for Enter at the end, so a terminal opened for it stays readable.

set -u

PLUGIN_ID=0rgl/localsend-plus
pause=false
[ "${1:-}" = --pause ] && pause=true

case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
pl*) pl=true ;;
*) pl=false ;;
esac

# say ENGLISH POLISH
say() {
  if $pl; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}

finish() {
  if $pause; then
    echo
    say "Press Enter to close." "Naciśnij Enter, aby zamknąć."
    read -r _answer || true
  fi
  exit "$1"
}

# at_least HAVE NEED: whether version HAVE is NEED or newer.
at_least() {
  awk -v have="$1" -v need="$2" 'BEGIN {
    split(have, h, "."); split(need, n, ".")
    for (i = 1; i <= 3; i++) {
      if (h[i] + 0 > n[i] + 0) exit 0
      if (h[i] + 0 < n[i] + 0) exit 1
    }
    exit 0
  }'
}

src=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || finish 1
if [ ! -f "$src/Cargo.toml" ]; then
  say "No Cargo.toml next to $0." "Brak Cargo.toml obok $0."
  finish 1
fi
version=$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$src/Cargo.toml" | head -n 1)
rust_needed=$(sed -n 's/^rust-version *= *"\([^"]*\)".*/\1/p' "$src/Cargo.toml" | head -n 1)

# tests/update.test.sh points these at stand-ins.
os_release=${LS_OS_RELEASE:-/etc/os-release}
ostree_booted=${LS_OSTREE_BOOTED:-/run/ostree-booted}
os_id=
os_like=
if [ -r "$os_release" ]; then
  # shellcheck source=/dev/null
  os_id=$(. "$os_release" && printf '%s' "${ID:-}")
  # shellcheck source=/dev/null
  os_like=$(. "$os_release" && printf '%s' "${ID_LIKE:-}")
fi
atomic=false
[ -e "$ostree_booted" ] && atomic=true

# rustup puts cargo in ~/.cargo/bin, which a login sh started from fish or a
# desktop session often lacks. Its cargo wins over an older one from the
# distribution.
cargo_home=${CARGO_HOME:-$HOME/.cargo}
if [ -x "$cargo_home/bin/cargo" ]; then
  cargo=$cargo_home/bin/cargo
else
  cargo=$(command -v cargo 2>/dev/null || true)
fi

problems=0
rust_hint=false
rust_missing=false
if [ -z "$cargo" ]; then
  say "Rust (cargo) is not installed." "Rust (cargo) nie jest zainstalowany."
  problems=1
  rust_hint=true
  rust_missing=true
else
  rustc=$(dirname -- "$cargo")/rustc
  [ -x "$rustc" ] || rustc=rustc
  rust_have=$("$rustc" --version 2>/dev/null | awk '{ print $2 }')
  if [ -z "$rust_have" ]; then
    say "$cargo has no working rustc next to it." "$cargo nie ma obok działającego rustc."
    problems=1
    rust_hint=true
  elif [ -n "$rust_needed" ] && ! at_least "$rust_have" "$rust_needed"; then
    say "Rust $rust_have is too old; the controller needs $rust_needed or newer." \
      "Rust $rust_have jest za stary; kontroler wymaga $rust_needed lub nowszego."
    problems=1
    rust_hint=true
  fi
fi

# The ring crate compiles C. cc-rs calls `cc` unless CC names another one.
cc_hint=false
if [ -z "${CC:-}" ] && ! command -v cc >/dev/null 2>&1; then
  if command -v gcc >/dev/null 2>&1; then
    export CC=gcc
  elif command -v clang >/dev/null 2>&1; then
    export CC=clang
  else
    say "No C compiler (gcc or clang) found." "Nie znaleziono kompilatora C (gcc ani clang)."
    problems=1
    cc_hint=true
  fi
fi

# Prints the package command for this distribution: dnf, apt, ... PACKAGES
# are given per manager, as the names differ.
package_command() {
  dnf_pkgs=$1 apt_pkgs=$2 pacman_pkgs=$3 zypper_pkgs=$4 xbps_pkgs=$5 apk_pkgs=$6
  if $atomic; then
    say "  rpm-ostree install $dnf_pkgs   (then reboot)" "  rpm-ostree install $dnf_pkgs   (potem restart systemu)"
    return
  fi
  for id in $os_id $os_like; do
    case $id in
    fedora | rhel | centos) echo "  sudo dnf install $dnf_pkgs"; return ;;
    debian | ubuntu) echo "  sudo apt install $apt_pkgs"; return ;;
    arch) echo "  sudo pacman -S --needed $pacman_pkgs"; return ;;
    opensuse* | suse) echo "  sudo zypper install $zypper_pkgs"; return ;;
    void) echo "  sudo xbps-install $xbps_pkgs"; return ;;
    alpine) echo "  sudo apk add $apk_pkgs"; return ;;
    esac
  done
  say "  (install $dnf_pkgs with your distribution's package manager)" \
    "  (zainstaluj $dnf_pkgs menedżerem pakietów swojej dystrybucji)"
}

# Distributions whose own Rust keeps up with new releases.
current_rust() {
  $atomic && return 1
  for id in $os_id $os_like; do
    case $id in
    fedora | arch | opensuse-tumbleweed) return 0 ;;
    esac
  done
  return 1
}

if [ "$problems" -ne 0 ]; then
  echo
  case " $os_id $os_like " in
  *" nixos "*)
    say "On NixOS, build it in a shell that has the tools:" "Na NixOS zbuduj go w powłoce z narzędziami:"
    echo "  nix-shell -p cargo rustc gcc --run 'sh $src/update.sh'"
    finish 1
    ;;
  esac
  if $cc_hint; then
    say "Install a C compiler:" "Zainstaluj kompilator C:"
    package_command gcc gcc gcc gcc gcc "gcc musl-dev"
  fi
  if $rust_hint; then
    if command -v rustup >/dev/null 2>&1 || [ -x "$cargo_home/bin/rustup" ]; then
      say "Update Rust with rustup:" "Zaktualizuj Rusta przez rustup:"
      echo "  rustup update stable && rustup default stable"
    else
      # A distribution that already ships too old a Rust gets rustup.
      if $rust_missing && current_rust; then
        say "Install Rust from your distribution:" "Zainstaluj Rusta z repozytorium dystrybucji:"
        package_command cargo cargo rust cargo cargo cargo
        say "or with rustup (rustup.rs):" "albo przez rustup (rustup.rs):"
      else
        say "Install Rust with rustup (rustup.rs); distribution packages are often older than $rust_needed:" \
          "Zainstaluj Rusta przez rustup (rustup.rs); pakiety dystrybucji bywają starsze niż $rust_needed:"
      fi
      echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    fi
  fi
  echo
  say "Then run this again:" "Potem uruchom to ponownie:"
  echo "  sh '$src/update.sh'"
  finish 1
fi

target=${XDG_CACHE_HOME:-$HOME/.cache}/localsend-plus/target
say "Building localsend-controller $version with Rust $rust_have..." \
  "Buduję localsend-controller $version (Rust $rust_have)..."
echo
if ! "$cargo" install --locked --path "$src" --target-dir "$target"; then
  echo
  say "The build failed; the messages above say why." "Budowanie się nie udało; powód jest w komunikatach powyżej."
  finish 1
fi

# Where cargo install put it, which the session running Noctalia may not
# know (CARGO_HOME set only in a shell's config, for example).
bin=${CARGO_INSTALL_ROOT:-$cargo_home}/bin/localsend-controller
echo
if noctalia msg plugin "$PLUGIN_ID:service" all updated "$bin" >/dev/null 2>&1; then
  say "Done. LocalSend Plus is restarting with the new controller." \
    "Gotowe. LocalSend Plus uruchamia się ponownie z nowym kontrolerem."
else
  # shellcheck disable=SC1111 # Polish quotation marks, not shell quotes
  say "Done. Open the LocalSend panel and press Retry." \
    "Gotowe. Otwórz panel LocalSend i kliknij „Spróbuj ponownie”."
fi
finish 0
