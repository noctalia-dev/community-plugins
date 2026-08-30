#!/bin/bash

# --- PATHS ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ASSETS_DIR="$SCRIPT_DIR/.."
TARGET_FOLDER="$1"
SEARCH_DIR="$ASSETS_DIR/$TARGET_FOLDER"

if [ ! -d "$SEARCH_DIR" ]; then echo "[]"; exit 0; fi

echo "["
FIRST=true

while read -r filepath; do
    filename=$(basename "$filepath")

    # Skip system files
    if [[ "$filename" == *"store"* || "$filename" == "geometry.conf" ]]; then continue; fi

    ID_NAME="${filename%.*}"

    # 1. Translation keys
    KEY_T="${TARGET_FOLDER}.presets.${ID_NAME}.title"
    KEY_D="${TARGET_FOLDER}.presets.${ID_NAME}.desc"

    # 2. ACTUAL FILE READING (Metadata extraction)
    function get_meta() {
        # 2>/dev/null prevents errors on weird files
        grep -m1 -E "^[ \t]*(#|//) @$1:" "$filepath" 2>/dev/null | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//;s/"/\\"/g' | tr -d '\r'
    }

    RAW_T=$(get_meta "Title")
    RAW_D=$(get_meta "Desc")
    ICON=$(get_meta "Icon")
    COLOR=$(get_meta "Color")
    TAG=$(get_meta "Tag")

    # Safe default values
    [ -z "$RAW_T" ] && RAW_T="$ID_NAME"
    [ -z "$ICON" ] && ICON="help"
    [ -z "$COLOR" ] && COLOR="#888888"
    [ -z "$TAG" ] && TAG="USER"

    if [ "$FIRST" = true ]; then FIRST=false; else echo ","; fi

    # 3. JSON Output with EVERYTHING (Keys + Raw Text)
    cat <<EOF
    {
        "file": "$filename",
        "title": "$KEY_T",
        "desc": "$KEY_D",
        "rawTitle": "$RAW_T",
        "rawDesc": "$RAW_D",
        "icon": "$ICON",
        "color": "$COLOR",
        "tag": "$TAG"
    }
EOF

done < <(find "$SEARCH_DIR" -maxdepth 1 -type f \( -name "*.conf" -o -name "*.frag" \) | sort)

echo "]"