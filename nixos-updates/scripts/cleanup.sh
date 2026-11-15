#!/bin/sh
# Cleanup for the Clean up button. Runs in a terminal, so the user sees every
# step and answers the password prompt. It removes only what nothing needs and
# follows the system's own cleanup rules where there are some:
#
# - Nix store: when NixOS cleans up on its own (nix.gc.automatic), that very
#   service runs, with the rules from the configuration (nix.gc.options, for
#   example how old a generation may get). Without it only
#   nix-collect-garbage runs, which removes unused store paths but no
#   generations, so nothing the user could roll back to.
# - nix-optimise.service (nix.optimise.automatic) when it exists.
# - Flatpak runtimes and extensions no installed app uses any more.
#
#   cleanup.sh [--dry-run]    --dry-run prints the commands without running them

set -u
dry=${1:-}

run() {
	printf '\n$ %s\n' "$*"
	if [ "$dry" != --dry-run ]; then
		"$@"
	fi
}

# A system unit exists, whether or not it is enabled.
has_unit() {
	command -v systemctl >/dev/null 2>&1 && systemctl cat "$1" >/dev/null 2>&1
}

failed=0

if has_unit nix-gc.service; then
	# Starting a system service asks for a password through polkit; a oneshot
	# unit like this one returns when it is done.
	run systemctl start nix-gc.service || failed=1
	# What it removed, if the journal is readable for this user.
	[ "$dry" = --dry-run ] || journalctl -u nix-gc.service -n 20 -o cat --no-pager 2>/dev/null | grep 'freed' | tail -n 1
elif command -v nix-collect-garbage >/dev/null 2>&1; then
	run nix-collect-garbage || failed=1
fi

if has_unit nix-optimise.service; then
	run systemctl start nix-optimise.service || failed=1
fi

if command -v flatpak >/dev/null 2>&1; then
	run flatpak uninstall --unused --noninteractive || failed=1
fi

if [ "$failed" = 0 ]; then
	printf '\nDone. '
else
	printf '\nA step failed, see above. '
fi
printf 'Press Enter to close.'
read -r _
