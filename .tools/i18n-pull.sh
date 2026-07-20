#!/usr/bin/env -S bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
API_BASE="${I18N_API_BASE:-https://i18n.noctalia.dev}"
PROJECT_SLUG="community-plugins"

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 1
fi

for command in curl jq; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: $command is required" >&2
        exit 1
    fi
done

echo "Project: $PROJECT_SLUG"
echo "Output repository: $REPO_ROOT"
read -r -p "Pull translations and overwrite returned local files? [y/N] " reply
if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

RESPONSE_FILE="$(mktemp)"
STAGING_DIR="$(mktemp -d)"
trap 'rm -f "$RESPONSE_FILE"; rm -rf "$STAGING_DIR"' EXIT

HTTP_CODE="$(curl --silent --show-error \
    --output "$RESPONSE_FILE" \
    --write-out '%{http_code}' \
    "$API_BASE/api/projects/$PROJECT_SLUG/pull")"
if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: HTTP $HTTP_CODE" >&2
    jq . "$RESPONSE_FILE" 2>/dev/null || cat "$RESPONSE_FILE"
    exit 1
fi

if ! jq -e 'type == "object" and length > 0' "$RESPONSE_FILE" >/dev/null; then
    echo "Error: API response must be a non-empty locale object" >&2
    exit 1
fi

mapfile -t LOCALES < <(jq -r 'keys[]' "$RESPONSE_FILE")
FILE_COUNT=0
for locale in "${LOCALES[@]}"; do
    if [[ ! "$locale" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
        echo "Error: API returned an invalid locale: $locale" >&2
        exit 1
    fi
    if ! jq -e --arg locale "$locale" '.[$locale] | type == "object" and length > 0' "$RESPONSE_FILE" >/dev/null; then
        echo "Error: Locale payload must be a non-empty object: $locale" >&2
        exit 1
    fi

    mapfile -t PLUGINS < <(jq -r --arg locale "$locale" '.[$locale] | keys[]' "$RESPONSE_FILE")
    for plugin in "${PLUGINS[@]}"; do
        if [[ ! "$plugin" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
            echo "Error: API returned an invalid plugin name: $plugin" >&2
            exit 1
        fi
        if [[ ! -f "$REPO_ROOT/$plugin/plugin.toml" ]]; then
            echo "Error: API returned unknown plugin: $plugin" >&2
            exit 1
        fi
        if ! jq -e --arg locale "$locale" --arg plugin "$plugin" '
            def valid_translation:
                if type == "object" then all(.[]; valid_translation)
                else type == "string"
                end;
            .[$locale][$plugin] | type == "object" and valid_translation
        ' "$RESPONSE_FILE" >/dev/null; then
            echo "Error: Invalid translation payload for $plugin/$locale" >&2
            exit 1
        fi

        mkdir -p "$STAGING_DIR/$plugin/translations"
        jq --arg locale "$locale" --arg plugin "$plugin" \
            '.[$locale][$plugin]' "$RESPONSE_FILE" \
            >"$STAGING_DIR/$plugin/translations/$locale.json"
        FILE_COUNT=$((FILE_COUNT + 1))
    done
done

shopt -s nullglob
MANIFESTS=("$REPO_ROOT"/*/plugin.toml)
for manifest in "${MANIFESTS[@]}"; do
    plugin_dir="$(dirname -- "$manifest")"
    plugin="$(basename -- "$plugin_dir")"
    if jq -e --arg plugin "$plugin" '.en[$plugin] | type == "object"' "$RESPONSE_FILE" >/dev/null; then
        continue
    fi

    english_file="$plugin_dir/translations/en.json"
    if [[ -f "$english_file" ]] && jq -e 'type == "object" and length == 0' "$english_file" >/dev/null; then
        continue
    fi

    echo "Error: English payload is missing plugin: $plugin" >&2
    exit 1
done

while IFS= read -r -d '' staged_file; do
    relative_path="${staged_file#"$STAGING_DIR/"}"
    output_file="$REPO_ROOT/$relative_path"
    output_dir="$(dirname -- "$output_file")"
    mkdir -p "$output_dir"
    temporary_file="$(mktemp "$output_dir/.i18n-pull.XXXXXX")"
    cp -- "$staged_file" "$temporary_file"
    mv -- "$temporary_file" "$output_file"
    echo "Saved: $relative_path"
done < <(find "$STAGING_DIR" -type f -name '*.json' -print0 | sort -z)

echo "Successfully pulled $FILE_COUNT translation file(s)."
