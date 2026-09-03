#!/bin/bash
# apply_animation.sh — HVE v5 (Lua edition)

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PLUGIN_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
PRESETS_DIR="$PLUGIN_DIR/assets/animations"
FRAGMENTS_DIR="$PLUGIN_DIR/assets/fragments"
SCRIPTS_DIR="$PLUGIN_DIR/assets/scripts"
CONVERTER="$SCRIPTS_DIR/conf2lua.py"

mkdir -p "$FRAGMENTS_DIR"
PRESET_NAME=$1

if [ "$PRESET_NAME" == "none" ] || [ -z "$PRESET_NAME" ]; then
    rm -f "$FRAGMENTS_DIR/animation.lua"
    echo "Animations disabled."
else
    TARGET_FILE="$PRESETS_DIR/$PRESET_NAME"
    if [ -f "$TARGET_FILE" ]; then
        python3 "$CONVERTER" "$TARGET_FILE" > "$FRAGMENTS_DIR/animation.lua"
        echo "Animation applied: $PRESET_NAME"
    else
        rm -f "$FRAGMENTS_DIR/animation.lua"
        echo "Error: Animation $PRESET_NAME not found."
    fi
fi

# Assemble (sin reload — el widget lo dispara)
bash "$SCRIPTS_DIR/assemble.sh"
