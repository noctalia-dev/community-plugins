#!/bin/sh
# Update check for the nixos-updates service. Changes nothing on the system:
# the updated lock file goes to the plugin data directory, flake.lock and the
# installed Flatpaks stay as they are.
#
#   check.sh <out_dir> <flake_dir> <nixos_configuration> <packages 0|1> <flatpak 0|1> [<token_file> [<home_configuration>]]
#
# Prints one line per event for the service (runStream has no exit callback):
#   step <name>             a step starts
#   fail <step> <message>   a step failed, the check goes on where it can
#   done                    finished; the results are in <out_dir>
#
# Result files: new.lock (the lock `nix flake update` would write),
# packages-old.json / packages-new.json (name and version of every
# environment.systemPackages entry, the kernel and the home.packages of Home
# Manager users, with changelog and homepage), home-old.json / home-new.json
# (the same for a standalone Home Manager configuration), flatpak-installed.tsv,
# flatpak-updates.tsv (installation, application, branch, new version).

set -u
umask 077
out=$1
dir=$2
cfg=$3
packages=$4
flatpak=$5
tokenfile=${6:-}
home=${7:-}
token=""

err="$out/stderr"
rc=0

# Worst case 10 (update) + 2 * 10 (system) + 2 * 10 (Home Manager) + 3 * 3
# (Flatpak) = 59 minutes, plus 30 seconds per call for timeout -k to kill what
# ignores the TERM: 63 minutes; the service waits longer before it gives a run
# up.
. "$(dirname "$0")/lib.sh"

# Reads the optional GitHub token, refusing anything that could leak it or
# smuggle in settings: it must be the user's own file, readable by nobody else,
# outside the flake (Nix copies flake directories to the world-readable store),
# and a single token of plain characters (it ends up in a Nix config, where a
# line break would start a new setting). A refusal is reported by a code only.
load_token() {
	[ -n "$tokenfile" ] || return 0
	if [ ! -f "$tokenfile" ]; then
		echo "fail token missing"
		return 0
	fi
	if [ -n "$dir" ]; then
		case "$(readlink -f "$tokenfile")" in
		"$(readlink -f "$dir")"/*)
			echo "fail token in-flake"
			return 0
			;;
		esac
	fi
	if [ "$(stat -L -c %u "$tokenfile")" != "$(id -u)" ]; then
		echo "fail token owner"
		return 0
	fi
	case "$(stat -L -c %a "$tokenfile")" in
	400 | 600) ;;
	*)
		echo "fail token mode"
		return 0
		;;
	esac
	value=$(head -n 1 "$tokenfile" | tr -d '\r')
	case "$value" in
	"" | *[!A-Za-z0-9_]*)
		echo "fail token format"
		return 0
		;;
	esac
	if [ "${#value}" -gt 255 ]; then
		echo "fail token format"
		return 0
	fi
	token=$value
}

# nix flake update, with the token if there is one. The token goes through the
# environment of this one process, never onto a command line (where every user
# could read it with ps), and in a subshell, so the evaluations below, which run
# code of revisions not accepted yet, never get it.
update_lock() {
	(
		if [ -n "$token" ]; then
			NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}extra-access-tokens = github.com=$token"
			export NIX_CONFIG
		fi
		run_nix 10 flake update --flake "$dir" --output-lock-file "$out/new.lock" >/dev/null 2>"$err"
	)
	rc=$?
	return "$rc"
}

# Nix keeps going when it cannot ask an input for its latest revision: it warns,
# uses what it knew before and exits with 0. Then the new lock proves nothing,
# so this counts as a failure. By code, as the raw message contains the IP.
stale_lock() {
	grep -q 'unable to download' "$err" || return 1
	if grep -q 'rate limit' "$err"; then
		echo "fail lock rate-limit"
	elif grep -q 'HTTP error 401' "$err"; then
		echo "fail lock bad-token"
	else
		echo "fail lock stale"
	fi
	return 0
}

# Name, version, changelog and homepage of each package; entries that fail to
# evaluate (broken, unfree without permission) are skipped instead of failing
# the whole list, a missing changelog or homepage just stays "". Shared by the
# NixOS and the standalone Home Manager expression below.
pkgexpr='text = x: let r = builtins.tryEval (if builtins.isString x then x else if builtins.isList x && x != [ ] && builtins.isString (builtins.head x) then builtins.head x else ""); in if r.success then r.value else "";
  pkg = p: let
    info = (if p ? pname then { n = p.pname; v = p.version or ""; }
      else let d = builtins.parseDrvName (p.name or ""); in { n = d.name; v = d.version; })
      // { c = text (p.meta.changelog or ""); h = text (p.meta.homepage or ""); };
    r = builtins.tryEval (builtins.deepSeq info info);
  in if r.success then [ r.value ] else [ ];
  list = x: let r = builtins.tryEval x; in if r.success && builtins.isList r.value then r.value else [ ];'

# NixOS: environment.systemPackages, the kernel, and home.packages of every
# user when Home Manager runs as a NixOS module (it adds the packages of enabled
# programs there too).
apply="c: let
  $pkgexpr
  kernel = builtins.tryEval c.boot.kernelPackages.kernel;
  homeUsers = builtins.tryEval (builtins.attrValues (c.home-manager.users or { }));
  home = if homeUsers.success then builtins.concatMap (u: list (u.home.packages or [ ])) homeUsers.value else [ ];
in builtins.concatMap pkg (list c.environment.systemPackages ++ (if kernel.success then [ kernel.value ] else [ ]) ++ home)"

# Standalone Home Manager (homeConfigurations.<name>).
applyHome="c: let
  $pkgexpr
in builtins.concatMap pkg (list (c.home.packages or [ ]))"

# Evaluates a package list for one lock file into $2: the NixOS configuration,
# or with $3 = home the standalone Home Manager one. Always both sides with the
# configuration as it is now, so that an edit of the configuration never looks
# like an update; Nix's own caches keep this cheap when nothing changed.
evaluate() {
	lock=$1
	result=$2
	if [ "${3:-}" = home ]; then
		attr="homeConfigurations.\"$home\".config"
		expr=$applyHome
	else
		attr="nixosConfigurations.\"$cfg\".config"
		expr=$apply
	fi
	if run_nix 10 eval --json --no-write-lock-file --reference-lock-file "$lock" \
		"$dir#$attr" --apply "$expr" >"$result.tmp" 2>"$err"; then
		mv "$result.tmp" "$result"
		return 0
	fi
	rm -f "$result.tmp" "$result"
	return 1
}

if [ -n "$dir" ]; then
	echo "step lock"
	load_token
	rm -f "$out/new.lock" "$out/packages-old.json" "$out/packages-new.json" \
		"$out/home-old.json" "$out/home-new.json"
	if [ ! -f "$dir/flake.lock" ]; then
		echo "fail lock no-lock"
	elif ! update_lock; then
		fail lock
	elif stale_lock; then
		:
	elif [ "$packages" = 1 ]; then
		[ -n "$cfg" ] || cfg=$(cat /proc/sys/kernel/hostname)
		echo "step eval-old"
		if ! evaluate "$dir/flake.lock" "$out/packages-old.json"; then
			fail eval-old
		elif cmp -s "$dir/flake.lock" "$out/new.lock"; then
			# Nothing to update: same lock, same packages.
			cp "$out/packages-old.json" "$out/packages-new.json"
		else
			echo "step eval-new"
			evaluate "$out/new.lock" "$out/packages-new.json" || fail eval-new
		fi
		if [ -n "$home" ]; then
			echo "step home"
			if ! evaluate "$dir/flake.lock" "$out/home-old.json" home; then
				fail home
			elif cmp -s "$dir/flake.lock" "$out/new.lock"; then
				cp "$out/home-old.json" "$out/home-new.json"
			elif ! evaluate "$out/new.lock" "$out/home-new.json" home; then
				fail home
			fi
		fi
	fi
fi

if [ "$flatpak" = 1 ] && command -v flatpak >/dev/null 2>&1; then
	echo "step flatpak"
	limit 3 flatpak list --columns=installation,application,branch,version,name,origin >"$out/flatpak-installed.tsv" 2>"$err" || fail flatpak
	: >"$out/flatpak-updates.tsv"
	for inst in system user; do
		if limit 3 flatpak remote-ls "--$inst" --updates --columns=application,branch,version >"$out/flatpak-$inst.tsv" 2>"$err"; then
			sed "s/^/$inst\t/" "$out/flatpak-$inst.tsv" >>"$out/flatpak-updates.tsv"
		else
			fail flatpak
		fi
		rm -f "$out/flatpak-$inst.tsv"
	done
fi

rm -f "$err"
echo "done"
