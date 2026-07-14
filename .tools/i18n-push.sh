#!/usr/bin/env -S bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
API_BASE="${I18N_API_BASE:-https://i18n.noctalia.dev}"
PROJECT_SLUG="community-plugins"
OVERWRITE=false
SINGLE_LANG=""

usage() {
    echo "Usage: COMMUNITY_PLUGINS_PUSH_SECRET=... $0 [--overwrite] [--lang <locale>]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --overwrite)
            OVERWRITE=true
            shift
            ;;
        --lang)
            if [[ $# -lt 2 ]]; then
                echo "Error: --lang requires a locale" >&2
                usage >&2
                exit 1
            fi
            SINGLE_LANG="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

for command in curl jq; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: $command is required" >&2
        exit 1
    fi
done

if [[ -z "${COMMUNITY_PLUGINS_PUSH_SECRET:-}" ]]; then
    echo "Error: COMMUNITY_PLUGINS_PUSH_SECRET is required" >&2
    exit 1
fi

if [[ -n "$SINGLE_LANG" && ! "$SINGLE_LANG" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo "Error: Invalid locale: $SINGLE_LANG" >&2
    exit 1
fi

shopt -s nullglob
MANIFESTS=("$REPO_ROOT"/*/plugin.toml)
if [[ ${#MANIFESTS[@]} -eq 0 ]]; then
    echo "Error: No plugin manifests found in $REPO_ROOT" >&2
    exit 1
fi

validate_translation_file() {
    local file="$1"
    if ! jq -e '
        def valid_translation:
            if type == "object" then all(.[]; valid_translation)
            else type == "string"
            end;
        type == "object" and valid_translation
    ' "$file" >/dev/null; then
        echo "Error: Translation must be a JSON object containing only objects and strings: $file" >&2
        exit 1
    fi
}

COMBINED_JSON='{}'
FILE_COUNT=0

for manifest in "${MANIFESTS[@]}"; do
    plugin_dir="$(dirname -- "$manifest")"
    plugin="$(basename -- "$plugin_dir")"
    if [[ ! "$plugin" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
        echo "Error: Invalid plugin directory name: $plugin" >&2
        exit 1
    fi

    if [[ -n "$SINGLE_LANG" ]]; then
        translation_files=("$plugin_dir/translations/$SINGLE_LANG.json")
    else
        english_file="$plugin_dir/translations/en.json"
        if [[ ! -f "$english_file" ]]; then
            echo "Error: Missing English translation: $english_file" >&2
            exit 1
        fi
        translation_files=("$plugin_dir"/translations/*.json)
    fi

    for file in "${translation_files[@]}"; do
        [[ -f "$file" ]] || continue
        locale="$(basename -- "$file" .json)"
        if [[ ! "$locale" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
            echo "Error: Invalid locale filename: $file" >&2
            exit 1
        fi
        validate_translation_file "$file"
        COMBINED_JSON="$(jq \
            --arg locale "$locale" \
            --arg plugin "$plugin" \
            --slurpfile content "$file" \
            '. + {($locale): ((.[$locale] // {}) + {($plugin): $content[0]})}' \
            <<<"$COMBINED_JSON")"
        echo "Loaded: $plugin/translations/$locale.json"
        FILE_COUNT=$((FILE_COUNT + 1))
    done
done

if [[ $FILE_COUNT -eq 0 ]]; then
    if [[ -n "$SINGLE_LANG" ]]; then
        echo "Error: No plugin provides locale: $SINGLE_LANG" >&2
    else
        echo "Error: No translation files found" >&2
    fi
    exit 1
fi

LOCALE_COUNT="$(jq 'keys | length' <<<"$COMBINED_JSON")"
echo "Project: $PROJECT_SLUG"
echo "Found $FILE_COUNT file(s) across $LOCALE_COUNT locale(s)"
read -r -p "Push these translations to $API_BASE? [y/N] " reply
if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

PUSH_URL="$API_BASE/api/projects/$PROJECT_SLUG/push"
if [[ "$OVERWRITE" == true ]]; then
    PUSH_URL="$PUSH_URL?overwrite=true"
    echo "Overwrite mode enabled"
fi

RESPONSE_FILE="$(mktemp)"
trap 'rm -f "$RESPONSE_FILE"' EXIT
HTTP_CODE="$(curl --silent --show-error \
    --output "$RESPONSE_FILE" \
    --write-out '%{http_code}' \
    --request POST \
    --header "Authorization: Bearer $COMMUNITY_PLUGINS_PUSH_SECRET" \
    --header "Content-Type: application/json" \
    --data-binary @- \
    "$PUSH_URL" <<<"$COMBINED_JSON")"

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: HTTP $HTTP_CODE" >&2
    jq . "$RESPONSE_FILE" 2>/dev/null || cat "$RESPONSE_FILE"
    exit 1
fi

echo "Translations pushed successfully."
jq . "$RESPONSE_FILE" 2>/dev/null || cat "$RESPONSE_FILE"
