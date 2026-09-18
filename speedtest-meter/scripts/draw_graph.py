# Circular speedometer dial drawing.
#
# The arc/capsule ring-rendering core is adapted from the official Noctalia
# "processes" plugin (noctalia-dev/community-plugins, scripts/draw_graph.py)
# so the gauge looks and behaves exactly like the CPU/Memory circles there.
# On top of that core this module adds a tachometer-style dial: a top
# semicircle arc, tick marks, a colored progress arc and a rotating needle.

import math
import os

from PIL import Image, ImageDraw, ImageFont

# ---------------- Canvas ----------------------------------------------------
WIDTH, HEIGHT = 216, 320
SCALE = 3
w_hi, h_hi = WIDTH * SCALE, HEIGHT * SCALE

# Default accents (as used by the processes plugin).
BLUE_ACCENT = (120, 180, 255)
ORANGE_ACCENT = (255, 185, 120)

SKINS = {
    "dark": {
        "track": (42, 45, 60, 255),
        "text": (235, 240, 250),
        "muted": (140, 150, 170),
        "needle": (235, 240, 250),
        "label": (120, 180, 255),
        "subtext": (140, 150, 170),
        "ring": (120, 180, 255),
    },
    "light": {
        "track": (49, 49, 49, 255),
        "text": (31, 31, 31),
        "muted": (90, 90, 90),
        "needle": (31, 31, 31),
        "label": (120, 180, 255),
        "subtext": (60, 60, 60),
        "ring": (53, 132, 228),
    },
}

try:
    RESAMPLING = Image.Resampling.LANCZOS
except AttributeError:  # Pillow < 9.1
    RESAMPLING = Image.LANCZOS


def get_font(size):
    font_names = ["segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"]
    for name in font_names:
        try:
            return ImageFont.truetype(name, int(size * SCALE))
        except OSError:
            continue
    return ImageFont.load_default()


font_value = get_font(30)
font_unit = get_font(19)
font_label = get_font(15)
font_sub = get_font(24)


def draw_capsule_arc(draw, center, radius, thickness, start_angle, end_angle, fill):
    """Draw an arc with rounded (capsule) ends — same technique as processes.
    Handles arcs that wrap past 360° by splitting into two draw calls."""
    cx, cy = center
    mid_r = radius - thickness / 2.0
    cap_r = thickness / 2.0

    def _single_arc(sa, ea):
        bbox = [cx - radius, cy - radius, cx + radius, cy + radius]
        draw.arc(bbox, start=sa, end=ea, fill=fill, width=int(thickness))
        for angle in (sa, ea):
            rad = math.radians(angle)
            cap_x = cx + mid_r * math.cos(rad)
            cap_y = cy + mid_r * math.sin(rad)
            draw.ellipse(
                [cap_x - cap_r, cap_y - cap_r, cap_x + cap_r, cap_y + cap_r],
                fill=fill,
            )

    if end_angle > 360.0:
        _single_arc(start_angle, 360.0)
        _single_arc(0.0, end_angle - 360.0)
    else:
        _single_arc(start_angle, end_angle)


def draw_speedometer(percent, value_text, unit_text, label_text, max_label,
                     accent, skin_name, filename, export_size=160):
    skin = SKINS.get(skin_name, SKINS["dark"])
    img = Image.new("RGBA", (w_hi, h_hi), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cx = (WIDTH // 2) * SCALE
    cy = 164 * SCALE
    radius = 78 * SCALE
    thickness = 14 * SCALE

    # 270° arc — open at the bottom like speedtest.net.
    # The arc sweeps from bottom-left (135°) clockwise to bottom-right (45°),
    # covering 270° of the circle.
    start_deg = 135.0
    arc_span = 270.0
    end_deg = start_deg + arc_span
    pct = max(0.0, min(1.0, float(percent) / 100.0))
    progress_deg = start_deg + arc_span * pct

    # Helper: draw an arc that may wrap past 360° by splitting into two calls.
    def _draw_arc(draw_obj, bbox, sa, ea, fill, width):
        if ea > 360.0:
            draw_obj.arc(bbox, start=sa, end=360.0, fill=fill, width=width)
            draw_obj.arc(bbox, start=0.0, end=ea - 360.0, fill=fill, width=width)
        else:
            draw_obj.arc(bbox, start=sa, end=ea, fill=fill, width=width)

    # Track ring (the full 270° arc).
    bbox = [cx - radius, cy - radius, cx + radius, cy + radius]
    _draw_arc(draw, bbox, start_deg, end_deg, skin["track"], int(thickness))

    # Colored progress arc with a soft halo.
    if pct > 0:
        span = max(arc_span * pct, 18)
        halo_layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        halo_draw = ImageDraw.Draw(halo_layer)
        halo_thickness = thickness + 8 * SCALE
        halo_radius = radius + 4 * SCALE
        halo_color = accent + (70,)
        draw_capsule_arc(halo_draw, (cx, cy), halo_radius, halo_thickness,
                         start_deg, start_deg + span, halo_color)
        img = Image.alpha_composite(img, halo_layer)
        draw = ImageDraw.Draw(img)
        draw_capsule_arc(draw, (cx, cy), radius, thickness,
                         start_deg, start_deg + span, accent + (255,))

    # Ticks along the outer edge of the dial.
    r_tick = radius + thickness / 2.0
    for i in range(0, 11):
        t = i / 10.0
        a = math.radians(start_deg + arc_span * t)
        if i % 5 == 0:
            length, width = 11 * SCALE, int(3 * SCALE)
        else:
            length, width = 7 * SCALE, max(1, int(2 * SCALE))
        x1 = cx + r_tick * math.cos(a)
        y1 = cy + r_tick * math.sin(a)
        x2 = cx + (r_tick + length) * math.cos(a)
        y2 = cy + (r_tick + length) * math.sin(a)
        if pct > 0 and t <= pct:
            fade = 1.0 - 0.6 * (t / pct)
            color = tuple(int(max(0, min(255, c * fade))) for c in accent) + (255,)
        else:
            color = skin["muted"]
        draw.line([x1, y1, x2, y2], fill=color, width=width)

    # Scale end numerals ("0" .. <max>) at the bottom openings of the arc.
    left_angle = math.radians(start_deg)
    right_angle = math.radians(end_deg)
    num_r = r_tick + 18 * SCALE
    draw.text((cx + num_r * math.cos(left_angle),
               cy + num_r * math.sin(left_angle)), "0",
              font=font_label, fill=skin["muted"], anchor="mm")
    if max_label:
        draw.text((cx + num_r * math.cos(right_angle),
                   cy + num_r * math.sin(right_angle)), max_label,
                  font=font_label, fill=skin["muted"], anchor="mm")

    # Needle + center hub.
    a = math.radians(progress_deg)
    needle_len = 0.66 * radius
    nx = cx + needle_len * math.cos(a)
    ny = cy + needle_len * math.sin(a)
    draw.line([cx, cy, nx, ny], fill=skin["needle"], width=int(4 * SCALE))
    draw.ellipse(
        [cx - 9 * SCALE, cy - 9 * SCALE, cx + 9 * SCALE, cy + 9 * SCALE],
        fill=accent + (255,),
    )
    draw.ellipse(
        [cx - 4 * SCALE, cy - 4 * SCALE, cx + 4 * SCALE, cy + 4 * SCALE],
        fill=skin["text"],
    )

    # Center text block (value / unit / label) drawn below the needle hub.
    draw.text((cx, cy + 34 * SCALE), value_text, font=font_value,
              fill=skin["text"], anchor="mm")
    if unit_text:
        draw.text((cx, cy + 56 * SCALE), unit_text, font=font_unit,
                  fill=skin["muted"], anchor="mm")
    if label_text:
        draw.text((cx, cy + 78 * SCALE), label_text, font=font_label,
                  fill=accent + (255,), anchor="mm")

    # Crop to show the full gauge including the circular arc.
    crop_bottom = 280
    final_w = export_size
    final_h = int(export_size * (crop_bottom / WIDTH))
    final_img = img.crop((0, 0, WIDTH * SCALE, crop_bottom * SCALE)) \
        .resize((final_w, final_h), RESAMPLING)
    try:
        with open(filename, "wb") as f:
            final_img.save(f, "PNG")
    except OSError as e:
        raise RuntimeError("cannot write gauge: %s" % e)
    return True


# Kept from the original module so the ring-drawing core ("the circle logic")
# is still available standalone for other uses.
def nofollow_opener(path, flags):
    return os.open(path, flags | os.O_NOFOLLOW)


def draw_graph(percent, val_text, label_text, sub_text, skin, filename):
    img = Image.new("RGBA", (w_hi, h_hi), (0, 0, 0, 0))
    if skin not in SKINS:
        skin = "dark"
    img = draw_gauge(
        img,
        center=(WIDTH // 2 * SCALE, HEIGHT // 2 * SCALE),
        percent=percent,
        val_text=val_text,
        label_text=label_text,
        sub_text=sub_text,
        skin=SKINS[skin],
    )
    final_img = img.resize((110, 110), RESAMPLING)
    try:
        with open(filename, "wb", opener=nofollow_opener) as f:
            final_img.save(f, "PNG")
    except FileNotFoundError:
        return False
    return True


def draw_gauge(base_img, center, percent, val_text, label_text, sub_text, skin):
    radius = 100 * SCALE
    thickness = 16 * SCALE
    cx, cy = center

    halo_layer = Image.new("RGBA", base_img.size, (0, 0, 0, 0))
    halo_draw = ImageDraw.Draw(halo_layer)

    draw = ImageDraw.Draw(base_img)
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        outline=skin["track"],
        width=int(thickness),
    )

    if percent > 0:
        start_deg = -90
        span = max(360 * min(percent, 100) / 100, 14)
        end_deg = start_deg + span

        halo_thickness = thickness + (14 * SCALE)
        halo_radius = radius + (7 * SCALE)
        halo_color = skin["ring"] + (70,)

        draw_capsule_arc(
            halo_draw, center, halo_radius, halo_thickness,
            start_deg, end_deg, halo_color
        )

        base_img = Image.alpha_composite(base_img, halo_layer)
        draw = ImageDraw.Draw(base_img)

        draw_capsule_arc(
            draw, center, radius, thickness,
            start_deg, end_deg, skin["ring"] + (255,)
        )

    draw.text((cx, cy - 28 * SCALE), val_text, font=font_value,
              fill=skin["text"], anchor="mm")
    draw.text((cx, cy + 12 * SCALE), label_text, font=font_label,
              fill=skin["label"], anchor="mm")
    draw.text((cx, cy + 48 * SCALE), sub_text, font=font_sub,
              fill=skin["subtext"], anchor="mm")

    return base_img