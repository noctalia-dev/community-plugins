#!/usr/bin/env python3
"""Build a tintable icon font from the bundled Mihomo logo.

Development dependencies: OpenCV and fontTools. The generated TTF has one
private-use glyph at U+E001. It is loaded by the widget at runtime; users do
not need either dependency.
"""

from __future__ import annotations

from pathlib import Path

import cv2
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / "icon.png"
SVG_OUTPUT = ROOT / "mihomo-glyph.svg"
FONT_OUTPUT = ROOT / "mihomo-glyph.ttf"
UNITS_PER_EM = 1000
GLYPH_CODEPOINT = 0xE001


def signed_area(points: list[tuple[int, int]]) -> float:
    return sum(
        x1 * y2 - x2 * y1
        for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1])
    ) / 2


def load_contours() -> list[tuple[list[tuple[int, int]], bool]]:
    image = cv2.imread(str(SOURCE), cv2.IMREAD_UNCHANGED)
    if image is None or image.shape[2] != 4:
        raise SystemExit(f"Could not read RGBA source image: {SOURCE}")

    blue, green, red, alpha = cv2.split(image)
    white = (red > 220) & (green > 220) & (blue > 220)
    mask = ((alpha > 16) & ~white).astype("uint8") * 255
    contours, hierarchy = cv2.findContours(mask, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    if hierarchy is None:
        raise SystemExit("No contours found in Mihomo source image")

    x, y, width, height = cv2.boundingRect(mask)
    scale = min(840 / width, 840 / height)
    x_offset = (UNITS_PER_EM - width * scale) / 2
    y_offset = 80

    result: list[tuple[list[tuple[int, int]], bool]] = []
    for index, contour in enumerate(contours):
        if abs(cv2.contourArea(contour)) < 2:
            continue
        simplified = cv2.approxPolyDP(contour, 0.75, True)
        points = [
            (
                round((int(point[0][0]) - x) * scale + x_offset),
                round((y + height - int(point[0][1])) * scale + y_offset),
            )
            for point in simplified
        ]
        if len(points) < 3:
            continue

        is_hole = hierarchy[0][index][3] != -1
        area = signed_area(points)
        should_be_clockwise = not is_hole
        if (should_be_clockwise and area > 0) or (is_hole and area < 0):
            points.reverse()
        result.append((points, is_hole))

    if not result:
        raise SystemExit("No usable contours found in Mihomo source image")
    return result


def build_glyph(contours: list[tuple[list[tuple[int, int]], bool]]):
    pen = TTGlyphPen(None)
    for points, _is_hole in contours:
        pen.moveTo(points[0])
        for point in points[1:]:
            pen.lineTo(point)
        pen.closePath()
    return pen.glyph()


def write_svg(contours: list[tuple[list[tuple[int, int]], bool]]) -> None:
    paths = []
    for points, _is_hole in contours:
        commands = [f"M {points[0][0]} {UNITS_PER_EM - points[0][1]}"]
        commands.extend(f"L {x} {UNITS_PER_EM - y}" for x, y in points[1:])
        commands.append("Z")
        paths.append(" ".join(commands))
    SVG_OUTPUT.write_text(
        "\n".join(
            [
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000">',
                f'  <path d="{" ".join(paths)}" fill="#000" fill-rule="nonzero"/>',
                "</svg>",
                "",
            ]
        ),
        encoding="utf-8",
    )


def write_font(contours: list[tuple[list[tuple[int, int]], bool]]) -> None:
    empty_pen = TTGlyphPen(None)
    glyphs = {
        ".notdef": empty_pen.glyph(),
        "space": TTGlyphPen(None).glyph(),
        "mihomo": build_glyph(contours),
    }

    builder = FontBuilder(UNITS_PER_EM, isTTF=True)
    builder.setupGlyphOrder([".notdef", "space", "mihomo"])
    builder.setupCharacterMap({32: "space", GLYPH_CODEPOINT: "mihomo"})
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({
        ".notdef": (UNITS_PER_EM, 0),
        "space": (500, 0),
        "mihomo": (UNITS_PER_EM, 0),
    })
    builder.setupHorizontalHeader(ascent=1000, descent=-200)
    builder.setupNameTable({
        "familyName": "Mihomo Glyph",
        "styleName": "Regular",
        "uniqueFontIdentifier": "Mihomo Glyph Regular 1.0",
        "fullName": "Mihomo Glyph Regular",
        "psName": "MihomoGlyph-Regular",
        "version": "Version 1.0",
    })
    builder.setupOS2(
        sTypoAscender=1000,
        sTypoDescender=-200,
        usWinAscent=1000,
        usWinDescent=200,
    )
    builder.setupPost()
    builder.setupMaxp()
    builder.font["head"].created = 2082844800
    builder.font["head"].modified = 2082844800
    builder.font.recalcTimestamp = False
    builder.save(FONT_OUTPUT)


def main() -> None:
    contours = load_contours()
    write_svg(contours)
    write_font(contours)
    print(FONT_OUTPUT)


if __name__ == "__main__":
    main()
