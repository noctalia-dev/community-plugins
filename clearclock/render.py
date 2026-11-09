#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render position-aware gradients, frosted glyphs, and wallpaper-backed glass."""
import argparse
import json
import math
from pathlib import Path
import subprocess

from PIL import Image, ImageChops, ImageColor, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps, ImageStat


def luminance(color):
    channels = [v / 255 for v in color[:3]]
    linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in channels]
    return sum(v * w for v, w in zip(linear, (.2126, .7152, .0722)))


def mix(a, b, amount):
    return tuple(round(x * (1 - amount) + y * amount) for x, y in zip(a[:3], b[:3]))


def readable(color, backgrounds, target=3):
    """Choose a coherent light or dark tint with useful local contrast."""
    def score(candidate):
        light = luminance(candidate)
        ratios = [(max(light, luminance(bg)) + .05) / (min(light, luminance(bg)) + .05)
                  for bg in backgrounds]
        return sorted(ratios)[max(0, len(ratios) // 5)]
    choices = [mix(color, pole, amount / 10) for pole in ((255, 255, 255), (12, 16, 24))
               for amount in range(3, 11)]
    passing = [c for c in choices if score(c) >= target]
    return min(passing, key=lambda c: sum((x - y) ** 2 for x, y in zip(c, color))) if passing else max(choices, key=score)


def font(settings, kind, directory, scale):
    family = settings.get(kind + "FontFamily", "ccdefault")
    bold = settings.get(kind + "BoldText", False)
    name = "Smooch-Regular.ttf" if kind == "day" else ("Outfit-Bold.ttf" if bold else "Outfit-Regular.ttf")
    path = Path(directory) / name
    if family not in ("", "ccdefault"):
        try:
            found = subprocess.run(["fc-match", "-f", "%{file}", family + (":style=Bold" if bold else "")],
                                   check=True, capture_output=True, text=True, timeout=3).stdout
            if found: path = Path(found)
        except (OSError, subprocess.SubprocessError):
            pass
    return ImageFont.truetype(str(path), max(1, round(settings[kind + "FontSize"] * scale)))


def projected_wallpaper(image, output, fill):
    size = (max(1, round(output["width"])), max(1, round(output["height"])))
    if fill == "stretch": return image.resize(size, Image.Resampling.LANCZOS)
    if fill == "crop": return ImageOps.fit(image, size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", size, (0, 0, 0))
    if fill == "fit": image = ImageOps.contain(image, size, Image.Resampling.LANCZOS)
    if fill == "repeat":
        for y in range(0, size[1], image.height):
            for x in range(0, size[0], image.width): canvas.paste(image, (x, y))
    else:
        canvas.paste(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
    return canvas


def render(request, destination):
    settings = request["settings"]
    scale = 2
    fonts = {kind: font(settings, kind, request["fontDir"], scale) for kind in ("clock", "day", "date")}
    text = {kind: request.get(kind, "") for kind in fonts}
    spacing = settings.get("dateLetterSpacing", 2) * scale
    widths = {kind: math.ceil(fonts[kind].getlength(value)) for kind, value in text.items()}
    if text["date"] and spacing:
        widths["date"] = math.ceil(sum(fonts["date"].getlength(c) for c in text["date"]) + spacing * (len(text["date"]) - 1))
    pad = (24 if request.get("glass") else 8) * scale
    layer = math.ceil(max(settings["clockFontSize"], settings["dayFontSize"] if text["day"] else 0) * 1.3 * scale)
    date_height = math.ceil(settings["dateFontSize"] * 1.3 * scale) if text["date"] else 0
    gap = settings.get("dateGap", -20) * scale if text["date"] else 0
    width = max(1, max(widths.values()) + 2 * pad)
    height = max(1, layer + gap + date_height + 2 * pad)
    if width > 8192 or height > 4096: raise ValueError("Clock exceeds renderer size limit")
    widget, output = request["widget"], request["output"]
    fit = min(widget["box_width"] / (width / scale), widget["box_height"] / (height / scale)) if widget.get("box_width", 0) > 0 and widget.get("box_height", 0) > 0 else 1
    region_w, region_h = width / scale * fit, height / scale * fit
    with Image.open(request["wallpaper"]) as source:
        source = ImageOps.exif_transpose(source).convert("RGB")
        fill = request.get("fill", "crop")
        if fill == "span":
            outputs = request.get("outputs", [output])
            left = min(o.get("x", 0) for o in outputs)
            top = min(o.get("y", 0) for o in outputs)
            right = max(o.get("x", 0) + o["width"] for o in outputs)
            bottom = max(o.get("y", 0) + o["height"] for o in outputs)
            virtual = ImageOps.fit(source, (round(right-left), round(bottom-top)), Image.Resampling.LANCZOS)
            x, y = output.get("x", 0)-left, output.get("y", 0)-top
            projected = virtual.crop((x, y, x+output["width"], y+output["height"]))
        else:
            projected = projected_wallpaper(source, output, fill)
        cx, cy = widget.get("cx", output["width"]/2), widget.get("cy", output["height"]/2)
        angle = widget.get("rotation", 0)
        # Sample in the clock's own orientation so moving/rotating it stays aligned.
        cosine, sine = math.cos(angle), math.sin(angle)
        sx, sy = region_w / width, region_h / height
        backdrop = projected.transform((width, height), Image.Transform.AFFINE,
            (cosine*sx, -sine*sy, cx-cosine*region_w/2+sine*region_h/2,
             sine*sx, cosine*sy, cy-sine*region_w/2-cosine*region_h/2), Image.Resampling.BICUBIC)

    original_backdrop = backdrop.copy()
    canvas = Image.new("RGBA", (width, height))
    if request.get("glass"):
        strength = max(0, min(1, request.get("glassStrength", .5)))
        glass = ImageEnhance.Color(backdrop.filter(ImageFilter.GaussianBlur((8 + strength*22)*scale))).enhance(.75).convert("RGBA")
        tint = (255, 255, 255, round(18+strength*45)) if luminance(ImageStat.Stat(backdrop).mean) > .35 else (12, 18, 28, round(25+strength*65))
        glass = Image.alpha_composite(glass, Image.new("RGBA", glass.size, tint))
        mask = Image.new("L", glass.size)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, width-1, height-1), radius=26*scale, fill=255)
        canvas.paste(glass, (0, 0), mask)
        ImageDraw.Draw(canvas).rounded_rectangle((1, 1, width-2, height-2), radius=26*scale, outline=(255,255,255,80), width=scale)
        backdrop = glass.convert("RGB")

    small = backdrop.resize((9, 5))
    samples = [small.getpixel((x,y)) for y in range(5) for x in range(9)]
    primary = ImageColor.getrgb(request.get("primary", "#a8c7fa"))[:3]
    stops = []
    for index in range(3):
        region = backdrop.crop((width*index//3, 0, width*(index+1)//3, height))
        local = tuple(round(v) for v in ImageStat.Stat(region).mean[:3])
        stops.append(readable(mix(local, primary, .22), samples))
    strip = Image.new("RGB", (width, 1))
    pixels = []
    for x in range(width):
        progress = x / max(1,width-1) * 2
        segment = min(1, int(progress))
        pixels.append(mix(stops[segment], stops[segment+1], progress-segment))
    strip.putdata(pixels)
    gradient = strip.resize((width, height)).convert("RGBA")
    def solid(value, fallback):
        try: return ImageColor.getrgb(value)
        except ValueError: return fallback
    for kind in ("clock", "day", "date"):
        value = text[kind]
        if not value: continue
        mask = Image.new("L", (width,height))
        draw = ImageDraw.Draw(mask)
        box = fonts[kind].getbbox(value)
        center_y = pad+layer/2 if kind != "date" else pad+layer+gap+date_height/2
        y = center_y - (box[1]+box[3])/2
        if kind == "date" and spacing:
            x = (width-widths[kind])/2
            for character in value:
                draw.text((x,y),character,font=fonts[kind],fill=255)
                x += fonts[kind].getlength(character)+spacing
        else:
            draw.text(((width-widths[kind])/2-box[0],y),value,font=fonts[kind],fill=255)
        if kind == "clock" and request.get("gradient"):
            ink = gradient
        else:
            if kind == "day" and request.get("fontGlass"):
                color = readable(primary, samples, 3)
            elif kind == "day" and request.get("gradient"):
                color = readable(stops[1], stops, 4.5)
            elif kind == "date" and request.get("gradient"):
                color = readable(primary, samples, 4.5)
            else:
                color = solid(request["colors"].get(kind,"#ffffff"),(255,255,255))
            ink = Image.new("RGBA", canvas.size, color)
        if kind == "clock" and request.get("fontGlass"):
            strength = max(0, min(1, request.get("fontGlassStrength", .55)))
            frost = original_backdrop.filter(ImageFilter.GaussianBlur((3+strength*12)*scale))
            frost = ImageEnhance.Color(frost).enhance(.65).convert("RGBA")
            # Keep the local wallpaper visible inside the letters, softened and
            # tinted by the same adaptive ink as the opaque gradient mode.
            frost = Image.blend(frost, ink.convert("RGBA"), .55+strength*.25)
            sheen = Image.new("RGBA", (1,height))
            sheen.putdata([(255,255,255,round(65*(1-y/max(1,height-1))**2)) for y in range(height)])
            frost = Image.alpha_composite(frost, sheen.resize((width,height)))
            frost.putalpha(round(205+strength*35))
            shadow = ImageChops.offset(mask.filter(ImageFilter.GaussianBlur(3*scale)), scale, 2*scale)
            shadow = shadow.point(lambda value: round(value*.22))
            canvas = Image.alpha_composite(canvas, Image.composite(
                Image.new("RGBA",canvas.size,(0,0,0,100)), Image.new("RGBA",canvas.size), shadow))
            canvas = Image.alpha_composite(canvas, Image.composite(frost, Image.new("RGBA",canvas.size), mask))
            # Directional bevel: a fine bright upper edge and a soft lower edge.
            highlight = ImageChops.subtract(mask, ImageChops.offset(mask,scale,scale))
            lowlight = ImageChops.subtract(mask, ImageChops.offset(mask,-scale,-scale))
            canvas = Image.alpha_composite(canvas, Image.composite(
                Image.new("RGBA",canvas.size,(255,255,255,200)), Image.new("RGBA",canvas.size),highlight))
            canvas = Image.alpha_composite(canvas, Image.composite(
                Image.new("RGBA",canvas.size,(15,24,35,100)), Image.new("RGBA",canvas.size),lowlight))
        else:
            if kind == "day" and request.get("fontGlass"):
                # The script crosses both glass digits and open wallpaper.
                # A fine opposite-tone edge keeps it readable over both.
                edge = ImageChops.subtract(mask.filter(ImageFilter.MaxFilter(2*scale+1)), mask)
                rim = (10,16,24,150) if luminance(color) > .45 else (255,255,255,150)
                canvas = Image.alpha_composite(canvas, Image.composite(
                    Image.new("RGBA",canvas.size,rim),Image.new("RGBA",canvas.size),edge))
            canvas = Image.composite(ink, canvas, mask)
    destination = Path(destination)
    temporary = destination.with_suffix(".tmp")
    canvas.save(temporary, format="PNG")
    temporary.replace(destination)
    return {"width": width/scale, "height": height/scale, "stops": stops}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    print(json.dumps(render(json.loads(args.request), args.output)))
