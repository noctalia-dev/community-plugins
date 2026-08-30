#!/bin/bash
# border.sh — HVE v5: aplica preset de borde
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PLUGIN_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
PRESETS_DIR="$PLUGIN_DIR/assets/borders"
FRAGMENTS_DIR="$PLUGIN_DIR/assets/fragments"
SCRIPTS_DIR="$PLUGIN_DIR/assets/scripts"
CONVERTER="$SCRIPTS_DIR/conf2lua.py"
COLORS_FILE="$HOME/.config/hypr/noctalia/noctalia-colors.lua"

mkdir -p "$FRAGMENTS_DIR"
PRESET_NAME=$1

if [ "$PRESET_NAME" == "none" ] || [ -z "$PRESET_NAME" ]; then
    rm -f "$FRAGMENTS_DIR/border.lua"
else
    TARGET_FILE="$PRESETS_DIR/$PRESET_NAME"
    if [ -f "$TARGET_FILE" ]; then
        # Extraer colores de noctalia-colors.lua para expandir $variables
        COLOR_ARGS=""
        if [ -f "$COLORS_FILE" ]; then
            while IFS= read -r line; do
                name=$(echo "$line" | grep -oP 'local\s+\K\w+')
                val=$(echo "$line" | grep -oP '"\K[^"]*')
                if [ -n "$name" ] && [ -n "$val" ]; then
                    COLOR_ARGS="$COLOR_ARGS --color $name=$val"
                fi
            done < <(grep -oP 'local\s+\w+\s*=\s*"[^"]*"' "$COLORS_FILE")
        fi
        
        python3 "$CONVERTER" "$TARGET_FILE" $COLOR_ARGS > "$FRAGMENTS_DIR/border.lua"
    else
        rm -f "$FRAGMENTS_DIR/border.lua"
    fi
fi
bash "$SCRIPTS_DIR/assemble.sh"
