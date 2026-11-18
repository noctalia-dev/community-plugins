#!/usr/bin/env bash
set -eu

CONFIG="${JB_CONFIG_DIR:-$HOME/.config/JetBrains}"
TOOLBOX="${JB_TOOLBOX_DIR:-$HOME/.local/share/JetBrains/Toolbox/apps}"
MAX_RESULTS="${JB_MAX_RESULTS:-20}"
IGNORED=("$@")

PRODUCT_PREFIXES=(
	IdeaIC:IntelliJIdea
	IntelliJIdea:IntelliJIdea
	AndroidStudio:AndroidStudio
	WebStorm:WebStorm
	CLion:CLion
	GoLand:GoLand
	RustRover:RustRover
	PyCharm:PyCharm
	PhpStorm:PhpStorm
	RubyMine:RubyMine
	DataGrip:DataGrip
	Rider:Rider
)

declare -A PRODUCT_CMD=(
	[IntelliJIdea]=idea
	[AndroidStudio]=studio
	[WebStorm]=webstorm
	[CLion]=clion
	[GoLand]=goland
	[RustRover]=rustrover
	[PyCharm]=pycharm
	[PhpStorm]=phpstorm
	[RubyMine]=rubymine
	[DataGrip]=datagrip
	[Rider]=rider
)

declare -A PRODUCT_SLUG=(
	[IntelliJIdea]=intellij-idea
	[AndroidStudio]=android-studio
	[WebStorm]=webstorm
	[CLion]=clion
	[GoLand]=goland
	[RustRover]=rustrover
	[PyCharm]=pycharm
	[PhpStorm]=phpstorm
	[RubyMine]=rubymine
	[DataGrip]=datagrip
	[Rider]=rider
)

declare -A PRODUCT_ICON=(
	[IntelliJIdea]=jetbrains-intellij-idea
	[AndroidStudio]=com.google.AndroidStudio
	[WebStorm]=com.jetbrains.WebStorm
	[CLion]=com.jetbrains.CLion
	[GoLand]=com.jetbrains.GoLand
	[RustRover]=com.jetbrains.RustRover
	[PyCharm]=com.jetbrains.PyCharm
	[PhpStorm]=com.jetbrains.PhpStorm
	[RubyMine]=com.jetbrains.RubyMine
	[DataGrip]=com.jetbrains.DataGrip
	[Rider]=com.jetbrains.Rider
)

declare -A seen_icons=()

product_name() {
	local dir="$1" entry prefix canonical
	for entry in "${PRODUCT_PREFIXES[@]}"; do
		prefix="${entry%%:*}"
		canonical="${entry#*:}"
		if [[ "$dir" == "$prefix"* ]]; then
			printf '%s\n' "$canonical"
			return 0
		fi
	done
	return 1
}

is_ignored() {
	local dir="$1"
	local lower="${dir,,}"
	local ig lower_ig
	for ig in "${IGNORED[@]}"; do
		lower_ig="${ig,,}"
		if [[ "$lower" == "$lower_ig"* ]]; then
			return 0
		fi
	done
	return 1
}

find_icon() {
	local product="$1"
	local cmd="${PRODUCT_CMD[$product]:-}"
	local slug="${PRODUCT_SLUG[$product]:-}"
	local icon_name="${PRODUCT_ICON[$product]:-}"
	local base name path root ext

	[[ -n "$cmd" && -n "$slug" ]] || return 1

	base="${TOOLBOX}/${slug}/bin"
	for name in "${cmd}.svg" "${cmd}.png" "idea.svg"; do
		path="${base}/${name}"
		if [[ -f "$path" ]]; then
			printf '%s\n' "$path"
			return 0
		fi
	done

	[[ -n "$icon_name" ]] || return 1
	for root in \
		"${HOME}/.local/share/icons" \
		"/usr/share/icons/hicolor/scalable/apps" \
		"/usr/share/icons/WhiteSur/apps/scalable" \
		"/usr/share/pixmaps"; do
		for ext in .svg .png; do
			path="${root}/${icon_name}${ext}"
			if [[ -f "$path" ]]; then
				printf '%s\n' "$path"
				return 0
			fi
		done
	done

	return 1
}

parse_xml() {
	local xml="$1"
	local product="$2"
	awk -v product="$product" -v home="$HOME" '
		function decode_xml(text) {
			gsub("&quot;", "\"", text)
			gsub("&apos;", "\047", text)
			gsub("&lt;", "<", text)
			gsub("&gt;", ">", text)
			gsub("&amp;", "\\&", text)
			return text
		}

		function expand_path(path,    pos, needle) {
			needle = "$USER_HOME$"
			while ((pos = index(path, needle)) > 0) {
				path = substr(path, 1, pos - 1) home substr(path, pos + length(needle))
			}
			needle = "$APPLICATION_HOME_DIR$"
			while ((pos = index(path, needle)) > 0) {
				path = substr(path, 1, pos - 1) substr(path, pos + length(needle))
			}
			return path
		}

		BEGIN { RS = "</entry>" }
		/<entry key="/ {
			key = ""
			if (match($0, /key="[^"]+"/)) {
				key = decode_xml(expand_path(substr($0, RSTART + 5, RLENGTH - 6)))
			}
			if (key == "" || key ~ /^\$/) next

			ts = 0
			if (match($0, /activationTimestamp" value="[0-9]+"/)) {
				part = substr($0, RSTART, RLENGTH)
				sub(/^activationTimestamp" value="/, "", part)
				sub(/"$/, "", part)
				ts = part + 0
			} else if (match($0, /projectOpenTimestamp" value="[0-9]+"/)) {
				part = substr($0, RSTART, RLENGTH)
				sub(/^projectOpenTimestamp" value="/, "", part)
				sub(/"$/, "", part)
				ts = part + 0
			}

			print ts "\t" product "\t" key
		}
	' "$xml"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
projects_file="${tmpdir}/projects.tsv"
: >"$projects_file"

for xml in "$CONFIG"/*/options/recentProjects.xml; do
	[[ -f "$xml" ]] || continue
	dir="$(basename "$(dirname "$(dirname "$xml")")")"
	[[ "$dir" == *-backup ]] && continue
	is_ignored "$dir" && continue
	product="$(product_name "$dir" || true)"
	[[ -n "$product" ]] || continue

	if [[ -z "${seen_icons[$product]:-}" ]]; then
		seen_icons[$product]=1
		if icon="$(find_icon "$product" || true)" && [[ -n "$icon" ]]; then
			printf 'ICON\t%s\t%s\n' "$product" "$icon"
		fi
	fi

	parse_xml "$xml" "$product" >>"$projects_file"
done

awk -F '\t' -v limit="$MAX_RESULTS" '
	{
		path = $3
		if (!(path in best_ts) || $1 > best_ts[path]) {
			best_ts[path] = $1
			best_line[path] = $0
		}
	}
	END {
		count = 0
		for (path in best_line) {
			split(best_line[path], fields, "\t")
			count++
			ts[count] = fields[1] + 0
			out[count] = best_line[path]
		}
		for (i = 1; i <= count; i++) {
			for (j = i + 1; j <= count; j++) {
				if (ts[j] > ts[i]) {
					tmp = ts[i]; ts[i] = ts[j]; ts[j] = tmp
					tmp = out[i]; out[i] = out[j]; out[j] = tmp
				}
			}
		}
		if (limit < 1) {
			limit = 20
		}
		max = count < limit ? count : limit
		for (i = 1; i <= max; i++) {
			print out[i]
		}
	}
' "$projects_file"
