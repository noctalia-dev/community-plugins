#!/bin/bash
# border.sh — HVE v5: applies a border preset
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PLUGIN_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
PRESETS_DIR="$PLUGIN_DIR/assets/borders"
FRAGMENTS_DIR="$PLUGIN_DIR/assets/fragments"
SCRIPTS_DIR="$PLUGIN_DIR/assets/scripts"
CONVERTER="$SCRIPTS_DIR/conf2lua.py"

mkdir -p "$FRAGMENTS_DIR"
PRESET_NAME=$1

if [ "$PRESET_NAME" == "none" ] || [ -z "$PRESET_NAME" ]; then
    rm -f "$FRAGMENTS_DIR/border.lua"
else
    TARGET_FILE="$PRESETS_DIR/$PRESET_NAME"
    if [ -f "$TARGET_FILE" ]; then
        # $colours are emitted as c("name") and resolved by the overlay at
        # runtime against the live palette: no colour file needs to be read.
        python3 "$CONVERTER" "$TARGET_FILE" > "$FRAGMENTS_DIR/border.lua"
        if grep -q '"\$[a-z]' "$FRAGMENTS_DIR/border.lua"; then
            echo "border.sh: unresolved colour variable in border.lua" >&2
        fi
    else
        rm -f "$FRAGMENTS_DIR/border.lua"
    fi
fi
bash "$SCRIPTS_DIR/assemble.sh"
