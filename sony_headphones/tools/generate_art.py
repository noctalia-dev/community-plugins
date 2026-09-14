#!/usr/bin/env python3
"""Generate the plugin's original headphone artwork (SVG sources).

The generated SVG files live in assets/ and are rasterised to WebP with
`rsvg-convert` + `magick` by the author when the artwork changes. They are
original, stylised illustrations created for this plugin and licensed MIT;
no third-party product imagery is used.

Usage:  python3 tools/generate_art.py
"""

import os

OUT = os.path.join(os.path.dirname(__file__), "..", "assets")

STYLES = {
    "black": {"shell": "#17171b", "pad": "#303038", "outline": None},
    "white": {"shell": "#f2f2f6", "pad": "#d8d8e0", "outline": "#c3c3cd"},
    "silver": {"shell": "#d3d6dd", "pad": "#b4b8c2", "outline": "#a4a8b3"},
    "lavender": {"shell": "#bca9dd", "pad": "#9f8ac5", "outline": "#8f7ab3"},
}


def stroke(style):
    if style["outline"]:
        return ' stroke="%s" stroke-width="3"' % style["outline"]
    return ""


def over_ear(name):
    s = STYLES[name]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="400" height="350" viewBox="0 0 400 350">
  <!-- headband -->
  <path d="M 92 196 C 92 66 308 66 308 196" fill="none" stroke="{s['shell']}" stroke-width="34" stroke-linecap="round"/>
  <path d="M 110 190 C 110 86 290 86 290 190" fill="none" stroke="{s['pad']}" stroke-width="14" stroke-linecap="round"/>
  <!-- ear cups -->
  <ellipse cx="84" cy="204" rx="56" ry="66" fill="{s['shell']}"{stroke(s)}/>
  <ellipse cx="316" cy="204" rx="56" ry="66" fill="{s['shell']}"{stroke(s)}/>
  <ellipse cx="84" cy="208" rx="36" ry="46" fill="{s['pad']}"/>
  <ellipse cx="316" cy="208" rx="36" ry="46" fill="{s['pad']}"/>
  <!-- highlights -->
  <ellipse cx="66" cy="176" rx="10" ry="18" fill="#ffffff" opacity="0.14"/>
  <ellipse cx="298" cy="176" rx="10" ry="18" fill="#ffffff" opacity="0.14"/>
</svg>
'''


def in_ear(name):
    s = STYLES[name]
    outline = stroke(s)

    def bud(cx):
        return f'''  <g transform="translate({cx},168)">
    <rect x="-17" y="36" width="34" height="86" rx="17" fill="{s['shell']}"/>
    <ellipse cx="0" cy="0" rx="58" ry="62" fill="{s['shell']}"{outline}/>
    <ellipse cx="0" cy="-2" rx="34" ry="37" fill="{s['pad']}"/>
    <ellipse cx="-16" cy="-24" rx="10" ry="14" fill="#ffffff" opacity="0.14"/>
  </g>
'''

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="400" height="350" viewBox="0 0 400 350">
{bud(128)}
{bud(272)}
</svg>
'''


def main():
    files = []
    for name in STYLES:
        files.append((f"over_ear_{name}.svg", over_ear(name)))
    for name in ("black", "white"):
        files.append((f"in_ear_{name}.svg", in_ear(name)))

    for filename, content in files:
        path = os.path.join(OUT, filename)
        with open(path, "w") as f:
            f.write(content)
        print("wrote", os.path.normpath(path))


if __name__ == "__main__":
    main()
