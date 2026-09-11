#!/usr/bin/env python3
"""Build thumbnail.webp: 960x540, the fixed grid the Noctalia store uses.

    python3 tests/make-thumbnail.py

The community checklist asks for the official generator; that was not reachable
when this was made, so this draws the same thing by hand with Noctalia's own
icon font for the glyph. Overwrite it with the generator's output when you can
reach https://assets.noctalia.dev/plugins/thumbnail-generator.html.
"""

import json
import pathlib

from PIL import Image, ImageDraw, ImageFont

SIZE = (960, 540)
TABLER_JSON = pathlib.Path("/usr/share/noctalia/assets/fonts/tabler.json")
TABLER_TTF = pathlib.Path("/usr/share/noctalia/assets/fonts/noctalia-tabler.ttf")
TEXT_TTF = pathlib.Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf")
TEXT_REGULAR = pathlib.Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
OUT = pathlib.Path(__file__).resolve().parent.parent / "thumbnail.webp"

# Catppuccin Mocha, the palette the shell is themed with.
BASE = (30, 30, 46)
MANTLE = (24, 24, 37)
SURFACE = (49, 50, 68)
TEXT = (205, 214, 244)
SUBTEXT = (166, 173, 200)
BLUE = (137, 180, 250)
GREEN = (166, 227, 161)


def glyph(name):
    data = json.loads(TABLER_JSON.read_text())
    return chr(int(data[name]["codepoint"].removeprefix("U+"), 16))


def main():
    image = Image.new("RGB", SIZE, BASE)
    draw = ImageDraw.Draw(image)

    # a subtle two-tone backdrop: dark mantle band at the bottom third
    draw.rectangle([0, 360, SIZE[0], SIZE[1]], fill=MANTLE)

    tabler = ImageFont.truetype(str(TABLER_TTF), 150)
    wifi = ImageFont.truetype(str(TABLER_TTF), 44)
    title = ImageFont.truetype(str(TEXT_TTF), 68)
    body = ImageFont.truetype(str(TEXT_REGULAR), 27)
    small = ImageFont.truetype(str(TEXT_REGULAR), 22)

    # icon on the left, centred in its own column
    draw.text((70, 150), glyph("network"), font=tabler, fill=BLUE)
    draw.text((206, 236), glyph("wifi-3"), font=wifi, fill=GREEN)

    draw.text((300, 168), "Network Control", font=title, fill=TEXT)
    # keep the subtitle inside the frame: measure rather than hope
    subtitle = "NetworkManager addressing, in the bar"
    limit = SIZE[0] - 303 - 40
    while draw.textlength(subtitle, font=body) > limit and len(subtitle) > 8:
        subtitle = subtitle[:-2]
    draw.text((303, 258), subtitle, font=body, fill=SUBTEXT)
    print("subtitle %r width %.0f/%.0f" % (subtitle, draw.textlength(subtitle, font=body), limit))

    rows = [
        ("wifi-3", "Join networks, DHCP or static"),
        ("route", "Address, gateway, DNS, IPv4 + IPv6"),
        ("arrow-back-up", "Unconfirmed changes roll back"),
    ]
    y = 322
    for icon, text in rows:
        draw.text((303, y), glyph(icon), font=wifi, fill=BLUE)
        draw.text((360, y + 9), text, font=small, fill=SUBTEXT)
        y += 52

    draw.text((303, 480), "muhammadessam/network-control", font=small, fill=(110, 114, 137))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    image.save(OUT, "WEBP", quality=88, method=6)
    print("wrote", OUT, image.size, OUT.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
