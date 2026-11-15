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

# One line for the service, without control characters and cut to a length the
# stream takes: Nix's last error line, as Nix ends an error with a code frame
# that says little alone, else the last stderr lines. Output of a failed command
# stays in $err, only this line reaches the protocol.
fail() {
	if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
		printf 'fail %s timed out\n' "$1"
		return
	fi
	message=$(grep 'error: *[^ ]' "$err" | tail -n 1)
	[ -n "$message" ] || message=$(grep -v '^warning:' "$err" | tail -n 3)
	printf 'fail %s %s\n' "$1" "$(printf '%s\n' "$message" | tr '\n\t' '  ' | tr -d '\000-\037\177' | cut -c1-500)"
}
