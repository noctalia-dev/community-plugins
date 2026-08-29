#!/usr/bin/env python3
"""conf2lua.py — Convierte presets .conf/.frag a llamadas hl.* para Hyprland Lua

Uso: conf2lua.py <archivo> [--color KEY=VALUE ...]

Las variables $color se expanden con los valores proporcionados.
Ej: conf2lua.py border.conf --color primary=rgb(67e4d4) --color surface=rgb(0d2f30)
"""

import sys, re, os


def gradient_to_lua(value, colors):
    """Convierte '$primary $surface 90deg' → string o tabla según nº colores"""
    tokens = value.strip().split()
    if not tokens:
        return '""'
    
    angle = None
    color_tokens = tokens[:]
    if tokens[-1].endswith('deg'):
        angle = tokens[-1].replace('deg', '')
        color_tokens = tokens[:-1]
    
    if not color_tokens:
        return '""'
    
    # Expandir $var → valor real
    resolved = []
    for t in color_tokens:
        if t.startswith('$'):
            varname = t[1:]
            resolved.append('"' + colors.get(varname, t) + '"')
        else:
            resolved.append('"' + t + '"')
    
    if len(resolved) == 1 and not angle:
        # Color sólido → string simple
        return resolved[0]
    
    # Gradiente → formato tabla
    parts = ["{\n                colors = { " + ", ".join(resolved) + " }"]
    if angle:
        parts.append("angle = " + angle)
    parts.append("            }")
    return ",\n                ".join(parts)


def parse_animation(text, lines, colors):
    for line in text.split('\n'):
        stripped = line.strip()
        if not stripped or stripped.startswith('# @') or stripped.startswith('// @'):
            continue
        
        if stripped.startswith('animations') or stripped.startswith('general') or stripped.startswith('decoration'):
            continue
        if stripped == '}' or stripped == '};':
            continue
        
        if stripped.startswith('#') or stripped.startswith('//'):
            lines.append(f"-- {stripped.lstrip('#/ ')}")
            continue
        
        m = re.match(r'bezier\s*=\s*(\S+),\s*(\S+),\s*(\S+),\s*(\S+),\s*(\S+)', stripped)
        if m:
            name, x1, y1, x2, y2 = m.groups()
            lines.append(f'hl.curve("{name}", {{ type = "bezier", points = {{ {{{x1}, {y1}}}, {{{x2}, {y2}}} }} }})')
            continue
        
        m = re.match(r'animation\s*=\s*(.+?),?\s*(\d+)\s*,?\s*([^,]+)\s*,?\s*([^,]+)\s*,?\s*(.*)', stripped)
        if m:
            leaf, en, speed, curve, style = m.groups()
            leaf = leaf.strip()
            curve = curve.strip().rstrip(',')
            style = style.strip().rstrip(',')
            if en == '0':
                lines.append(f'hl.animation({{ leaf = "{leaf}", enabled = false }})')
            else:
                parts = [f'leaf = "{leaf}"', f'enabled = true', f'speed = {speed}', f'bezier = "{curve}"']
                if style:
                    parts.append(f'style = "{style}"')
                lines.append(f'hl.animation({{ {", ".join(parts)} }})')
            continue
        
        m = re.match(r'enabled\s*=\s*(.+)', stripped)
        if m:
            continue


def parse_border(text, lines, colors):
    for line in text.split('\n'):
        stripped = line.strip()
        if not stripped or stripped.startswith('# @') or stripped.startswith('// @'):
            continue
        
        if stripped == '}' or stripped == '};':
            continue
        
        if stripped.startswith('#') or stripped.startswith('//'):
            lines.append(f"-- {stripped.lstrip('#/ ')}")
            continue
        
        if stripped.startswith('general') or stripped.startswith('animations') or stripped.startswith('decoration'):
            continue
        
        m = re.match(r'col\.active_border\s*=\s*(.+)', stripped)
        if m:
            val = m.group(1).strip()
            lines.append(f'hl.config({{ general = {{ col = {{ active_border = {gradient_to_lua(val, colors)} }} }} }})')
            continue
        
        # col.inactive_border = VALUE
        m = re.match(r'col\.inactive_border\s*=\s*(.+)', stripped)
        if m:
            val = m.group(1).strip()
            lines.append(f'hl.config({{ general = {{ col = {{ inactive_border = {gradient_to_lua(val, colors)} }} }} }})')
            continue
        
        # bezier = name, x1, y1, x2, y2 (BORDER)
        m = re.match(r'bezier\s*=\s*(\S+),\s*(\S+),\s*(\S+),\s*(\S+),\s*(\S+)', stripped)
        if m:
            name, x1, y1, x2, y2 = m.groups()
            lines.append(f'hl.curve("{name}", {{ type = "bezier", points = {{ {{{x1}, {y1}}}, {{{x2}, {y2}}} }} }})')
            continue
        
        # animation = borderangle, enabled, speed, curve, style (BORDER)
        m = re.match(r'animation\s*=\s*(.+?),?\s*(\d+)\s*,?\s*([^,]+)\s*,?\s*([^,]+)\s*,?\s*(.*)', stripped)
        if m:
            leaf, en, speed, curve, style = m.groups()
            leaf = leaf.strip()
            curve = curve.strip().rstrip(',')
            style = style.strip().rstrip(',')
            if en == '0':
                lines.append(f'hl.animation({{ leaf = "{leaf}", enabled = false }})')
            else:
                parts = [f'leaf = "{leaf}"', f'enabled = true', f'speed = {speed}', f'bezier = "{curve}"']
                if style:
                    parts.append(f'style = "{style}"')
                lines.append(f'hl.animation({{ {", ".join(parts)} }})')
            continue
        
        m = re.match(r'enabled\s*=\s*(.+)', stripped)
        if m:
            continue


def parse_shader(filepath, lines):
    expanded = os.path.expanduser(filepath) if filepath.startswith('~') else filepath
    lines.append(f'hl.config({{ decoration = {{ screen_shader = "{expanded}" }} }})')


def detect_type(text, filepath):
    if filepath.endswith('.frag'):
        return 'shader'
    if 'col.active_border' in text or 'col.inactive_border' in text:
        return 'border'
    return 'animation'


def parse_args():
    """Parsea argumentos: archivo + --color KEY=VALUE ..."""
    args = sys.argv[1:]
    filepath = None
    colors = {}
    
    i = 0
    while i < len(args):
        if args[i] == '--color' and i + 1 < len(args):
            kv = args[i + 1]
            if '=' in kv:
                k, v = kv.split('=', 1)
                colors[k] = v
            i += 2
        elif not filepath and not args[i].startswith('--'):
            filepath = args[i]
            i += 1
        else:
            i += 1
    
    return filepath, colors


def parse(text, filepath='', colors=None):
    if colors is None:
        colors = {}
    lines = [
        "-- HVE Overlay — generado automáticamente",
        "-- Cargar desde hyprland.lua con: dofile(os.getenv('HOME') .. '/.cache/noctalia/HVE/overlay.lua')",
        "",
    ]
    
    preset_type = detect_type(text, filepath)
    
    if preset_type == 'animation':
        lines.append(f"-- [ANIMATION: {os.path.basename(filepath)}]")
        parse_animation(text, lines, colors)
    elif preset_type == 'border':
        lines.append(f"-- [BORDER: {os.path.basename(filepath)}]")
        parse_border(text, lines, colors)
    elif preset_type == 'shader':
        lines.append(f"-- [SHADER: {os.path.basename(filepath)}]")
        parse_shader(filepath, lines)
    
    return '\n'.join(lines)


if __name__ == '__main__':
    filepath, colors = parse_args()
    if not filepath:
        print("Uso: conf2lua.py <archivo> [--color KEY=VALUE ...]", file=sys.stderr)
        sys.exit(1)
    
    with open(filepath) as f:
        content = f.read()
    
    print(parse(content, filepath, colors))
