#!/bin/sh
if command -v hyprctl >/dev/null 2>&1; then
    if command -v jq >/dev/null 2>&1; then
        hyprctl clients -j 2>/dev/null | jq -r '.[] | select(.mapped == true and .hidden == false) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"'
    elif command -v python3 >/dev/null 2>&1; then
        hyprctl clients -j 2>/dev/null | python3 -c 'import sys, json; [print(f"{c[\"at\"][0]},{c[\"at\"][1]} {c[\"size\"][0]}x{c[\"size\"][1]}") for c in json.load(sys.stdin) if c.get("mapped") and not c.get("hidden")]'
    fi
elif command -v swaymsg >/dev/null 2>&1; then
    if command -v jq >/dev/null 2>&1; then
        swaymsg -t get_tree 2>/dev/null | jq -r '.. | select(.pid? and .visible? and .rect?) | "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)"'
    elif command -v python3 >/dev/null 2>&1; then
        swaymsg -t get_tree 2>/dev/null | python3 -c 'import sys, json; fn=lambda n: [print(f"{n[\"rect\"][\"x\"]},{n[\"rect\"][\"y\"]} {n[\"rect\"][\"width\"]}x{n[\"rect\"][\"height\"]}") if isinstance(n, dict) and n.get("pid") and n.get("visible") and "rect" in n else None, [fn(v) for v in (n.values() if isinstance(n, dict) else n if isinstance(n, list) else [])]]; fn(json.load(sys.stdin))'
    fi
fi
