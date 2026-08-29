#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PLUGIN_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
PRESETS_DIR="$PLUGIN_DIR/assets/shaders"
FRAGMENTS_DIR="$PLUGIN_DIR/assets/fragments"
SCRIPTS_DIR="$PLUGIN_DIR/assets/scripts"
CONVERTER="$SCRIPTS_DIR/conf2lua.py"
mkdir -p "$FRAGMENTS_DIR"
PRESET_NAME=$1
if [ "$PRESET_NAME" == "none" ] || [ -z "$PRESET_NAME" ]; then
    rm -f "$FRAGMENTS_DIR/shader.lua"
else
    TARGET_FILE="$PRESETS_DIR/$PRESET_NAME"
    if [ -f "$TARGET_FILE" ]; then
        python3 "$CONVERTER" "$TARGET_FILE" > "$FRAGMENTS_DIR/shader.lua"
    else
        rm -f "$FRAGMENTS_DIR/shader.lua"
    fi
fi
bash "$SCRIPTS_DIR/assemble.sh"
