#!/bin/bash
# assemble.sh — HVE v5 (Lua edition)
# Genera ~/.cache/noctalia/HVE/overlay.lua

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PLUGIN_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
FRAGMENTS_DIR="$PLUGIN_DIR/assets/fragments"
HVE_SAFE_DIR="$HOME/.cache/noctalia/HVE"
FINAL_FILE="$HVE_SAFE_DIR/overlay.lua"

mkdir -p "$HVE_SAFE_DIR"

# 1. Header
# Sin reset de animaciones: el overlay se carga tras lua/visual.lua al hacer
# reload, así que los fragments ya pisan la base. Resetear apagaba las 16
# animaciones cuando no había fragment de animación activo.
cat > "$FINAL_FILE" << 'HEADER'
-- HVE Overlay — generado automáticamente
-- Cargar desde hyprland.lua:
--   pcall(function() dofile(os.getenv("HOME") .. "/.cache/noctalia/HVE/overlay.lua") end)

HEADER

# 2. Animations
if [ -f "$FRAGMENTS_DIR/animation.lua" ]; then
    echo "" >> "$FINAL_FILE"
    echo "-- [MODULE: ANIMATIONS]" >> "$FINAL_FILE"
    cat "$FRAGMENTS_DIR/animation.lua" >> "$FINAL_FILE"
fi

# 3. Borders
if [ -f "$FRAGMENTS_DIR/border.lua" ]; then
    echo "" >> "$FINAL_FILE"
    echo "-- [MODULE: BORDERS]" >> "$FINAL_FILE"
    cat "$FRAGMENTS_DIR/border.lua" >> "$FINAL_FILE"
fi

# 4. Shaders
if [ -f "$FRAGMENTS_DIR/shader.lua" ]; then
    echo "" >> "$FINAL_FILE"
    echo "-- [MODULE: SHADERS]" >> "$FINAL_FILE"
    cat "$FRAGMENTS_DIR/shader.lua" >> "$FINAL_FILE"
fi

# 5. Geometry
if [ -f "$FRAGMENTS_DIR/geometry.lua" ]; then
    echo "" >> "$FINAL_FILE"
    echo "-- [MODULE: GEOMETRY]" >> "$FINAL_FILE"
    cat "$FRAGMENTS_DIR/geometry.lua" >> "$FINAL_FILE"
fi
