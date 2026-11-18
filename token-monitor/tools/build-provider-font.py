#!/usr/bin/env python3
"""Build theme-colored brand glyphs and verify their reviewed presentation table.

Development only: requires fontTools. The plugin ships the resulting font and
does not run this script or download assets. Source/licence: assets/README.md.
"""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path

ASSETS = Path(__file__).resolve().parents[1] / "assets"
catalog = json.loads((ASSETS / "providers.json").read_text())
brands = {entry["brand"] for entry in catalog["providers"] if entry["brand"]}
brands.update(entry["brand"] for entry in catalog["thirdPartyAdapters"])
BRANDS = {"deepseek": 0xE001, "antigravity": 0xE002}
BRANDS.update({name: 0xE003 + index for index, name in enumerate(sorted(brands - set(BRANDS)))})
assert set(BRANDS) == brands
# Fontconfig retains previously loaded families across plugin reloads. A content
# suffix prevents an older two-glyph face from hiding new glyphs in the same app.
fingerprint = hashlib.sha256((ASSETS / "providers.json").read_bytes())
for name in BRANDS:
    fingerprint.update((ASSETS / f"{name}.svg").read_bytes())
family = "Token Monitor Brands " + fingerprint.hexdigest()[:8]
font_file = "provider-icons-" + fingerprint.hexdigest()[:8] + ".ttf"

builder = FontBuilder(1000, isTTF=True)
builder.setupGlyphOrder([".notdef", *BRANDS])
builder.setupCharacterMap({point: name for name, point in BRANDS.items()})
glyphs = {".notdef": TTGlyphPen(None).glyph()}
for name in BRANDS:
    svg = ET.parse(ASSETS / f"{name}.svg").getroot()
    x, y, width, height = map(float, svg.attrib["viewBox"].split())
    assert width > 0 and height > 0 and width == height
    pen = TTGlyphPen(None)
    curves = Cu2QuPen(pen, max_err=0.5, reverse_direction=True)
    scale = 1000 / width
    transform = TransformPen(curves, (scale, 0, 0, -scale, -x * scale, 1000 + y * scale))
    for element in svg:
        if element.tag.endswith("}path"):
            parse_path(element.attrib["d"], transform)
        else:
            assert element.tag.endswith("}title")
    glyphs[name] = pen.glyph()

builder.setupGlyf(glyphs)
builder.setupHorizontalMetrics({name: (1000, 0) for name in glyphs})
builder.setupHorizontalHeader(ascent=1000, descent=0)
builder.setupNameTable({
    "familyName": family, "styleName": "Regular",
    "uniqueFontIdentifier": family.replace(" ", ""),
    "fullName": family + " Regular", "psName": family.replace(" ", "") + "-Regular",
    "version": "Version 2.000",
    "copyright": "Copyright (c) 2023 LobeHub; (c) 2026 Javis. MIT; see included asset licenses.",
})
builder.setupOS2(sTypoAscender=1000, sTypoDescender=0, sTypoLineGap=0,
                usWinAscent=1000, usWinDescent=0)
builder.setupPost()
# Fixed timestamp: byte-identical output when source and fontTools are unchanged.
builder.font.recalcTimestamp = False
builder.font["head"].created = builder.font["head"].modified = 3850070400
builder.save(ASSETS / font_file)

# Data only: runtime code never parses source SVGs or builds a font.
lines = ["-- Reviewed presentation data; keep in sync with assets/providers.json.",
         "return {", f'    font = "assets/{font_file}",', "    entries = {"]
for entry in catalog["providers"]:
    point = BRANDS.get(entry["brand"])
    mark = f"codepoint = 0x{point:X}" if point else 'glyph = "plug-connected"'
    lines.append(f'        {entry["id"]} = {{ name = {json.dumps(entry["name"])}, initials = {json.dumps(entry["initials"])}, {mark} }},')
lines += ["    },", "    adapters = {"]
for entry in catalog["thirdPartyAdapters"]:
    lines.append(f'        [{json.dumps(entry["id"])}] = {{ name = {json.dumps(entry["name"])}, initials = {json.dumps(entry["initials"])}, codepoint = 0x{BRANDS[entry["brand"]]:X} }},')
lines += ["    },", "    aliases = {"]
for alias, provider in catalog["aliases"].items():
    assert provider in {entry["id"] for entry in catalog["providers"]}
    lines.append(f'        {alias} = "{provider}",')
lines += ["    },", "}", ""]
assert (ASSETS.parent / "lib/providers.luau").read_text() == "\n".join(lines), "Review and update lib/providers.luau to match the catalog before shipping"
print(f"Built {len(BRANDS)} glyphs and {len(catalog['providers'])} provider entries: {family}")
