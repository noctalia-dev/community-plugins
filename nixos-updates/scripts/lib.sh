# Shared by check.sh and estimate.sh, sourced with the caller's $err (stderr
# file of the current step) set; $rc keeps the last exit code.

# Every nix and flatpak call has a time limit, so a script ends on its own: the
# service cannot stop a stream it started. No stdin, so nothing can wait for an
# answer.
limit() {
	minutes=$1
	shift
	timeout -k 30 "${minutes}m" "$@" </dev/null
	rc=$?
	return "$rc"
}

# The updated lock points at code the user has not accepted yet, and it is
# evaluated in the background. So settings that would widen what that code can
# do are off here, whatever nix.conf says: no nixConfig from the flake, no
# builtins.exec. max-jobs 0 without builders: nothing is built; a build the
# evaluation asks for (import from derivation) only comes from a binary cache,
# else the evaluation fails with an error.
run_nix() {
	minutes=$1
	shift
	limit "$minutes" nix \
		--extra-experimental-features nix-command \
		--extra-experimental-features flakes \
		--option accept-flake-config false \
		--option allow-unsafe-native-code-during-evaluation false \
		--option max-jobs 0 \
		--option builders "" \
		"$@"
}

# $dir without symlinks, set once before any nix call. With /etc/nixos as a
# link to the repository elsewhere, Nix refuses --reference-lock-file
# /etc/nixos/flake.lock ("path ... (or its ancestor) is a symlink") and copies a
# path: flake that is a link as the link itself ("... -source is a symlink").
resolve_dir() {
	[ -n "$dir" ] || return 0
	resolved=$(readlink -f -- "$dir" 2>/dev/null) || return 0
	[ -z "$resolved" ] || dir=$resolved
}

# The flake reference for $dir. As a Git repository Nix sees only files Git
# tracks; with $refmode = path, like nixos-rebuild --flake path:..., it sees and
# copies to the store every file in the directory. The service only sets path
# when the user turned that on.
flake_ref() {
	if [ "${refmode:-}" = path ]; then
		printf 'path:%s' "$dir"
	else
		printf '%s' "$dir"
	fi
}

# One line for the service, without control characters and cut to a length the
# stream takes: Nix's last error line, as Nix ends an error with a code frame
# that says little alone, else the last stderr lines. Output of a failed command
# stays in $err, only this line reaches the protocol.
fail() {
	if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
		printf 'fail %s timed out\n' "$1"
		return
	fi
	# A file the configuration imports but Git does not track: by code, with the
	# file, so the service can point at the setting that fixes it.
	untracked=$(sed -n "s/.*error: Path '\([^']*\)' in the repository .* is not tracked by Git.*/\1/p" "$err" | tail -n 1)
	if [ -n "$untracked" ]; then
		printf 'fail %s untracked %s\n' "$1" "$(printf '%s' "$untracked" | tr -d '\000-\037\177' | cut -c1-200)"
		return
	fi
	message=$(grep 'error: *[^ ]' "$err" | tail -n 1)
	[ -n "$message" ] || message=$(grep -v '^warning:' "$err" | tail -n 3)
	printf 'fail %s %s\n' "$1" "$(printf '%s\n' "$message" | tr '\n\t' '  ' | tr -d '\000-\037\177' | cut -c1-500)"
}
