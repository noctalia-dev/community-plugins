import math
from PIL import Image, ImageDraw, ImageFont

# ----------------- Параметры отрисовки -----------------
WIDTH, HEIGHT = 216, 216

BLUE_ACCENT = (120, 180, 255)
ORANGE_ACCENT = (255, 185, 120)
TRACK_COLOR = (42, 45, 60, 255)
TEXT_MAIN = (235, 240, 250)
TEXT_MUTED = (140, 150, 170)

SKINS = {
    "dark": {
        "track": (42, 45, 60, 255),
        "text": (235, 240, 250),
        "label": (120, 180, 255),
        "subtext": (140, 150, 170),
        "ring": (120, 180, 255),
    },
    "light": {
        "track": (49, 49, 49, 255),
        "text": (31, 31, 31),
        "label": (120, 180, 255),
        "subtext": (60, 60, 60),
        "ring": (53, 132, 228),
    }
}

SCALE = 3
w_hi, h_hi = WIDTH * SCALE, HEIGHT * SCALE


def get_font(size):
    font_names = ["segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"]
    for name in font_names:
        try:
            return ImageFont.truetype(name, int(size * SCALE))
        except OSError:
            continue
    return ImageFont.load_default()

font_value = get_font(34)
font_label = get_font(28)
font_sub = get_font(24)


def draw_capsule_arc(draw, center, radius, thickness, start_angle, end_angle, fill):
    cx, cy = center
    mid_r = radius - thickness / 2.0
    cap_r = thickness / 2.0

    bbox = [cx - radius, cy - radius, cx + radius, cy + radius]
    draw.arc(bbox, start=start_angle, end=end_angle, fill=fill, width=int(thickness))

    for angle in (start_angle, end_angle):
        rad = math.radians(angle)
        cap_x = cx + mid_r * math.cos(rad)
        cap_y = cy + mid_r * math.sin(rad)
        draw.ellipse(
            [cap_x - cap_r, cap_y - cap_r, cap_x + cap_r, cap_y + cap_r],
            fill=fill
        )


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
        width=int(thickness)
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

    draw.text((cx, cy - 28 * SCALE), val_text, font=font_value, fill=skin["text"], anchor="mm")
    draw.text((cx, cy + 12 * SCALE), label_text, font=font_label, fill=skin["label"], anchor="mm")
    draw.text((cx, cy + 48 * SCALE), sub_text, font=font_sub, fill=skin["subtext"], anchor="mm")

    return base_img


def draw_graph(percent, val_text, label_text, sub_text, skin, filename):
    img = Image.new("RGBA", (w_hi, h_hi), (0, 0, 0, 0))

    if skin not in SKINS:
        skin = "dark"

    # Левый график (CPU)
    img = draw_gauge(
        img,
        center=(WIDTH // 2 * SCALE, HEIGHT // 2 * SCALE),
        percent=percent,
        val_text=val_text,
        label_text=label_text,
        sub_text=sub_text,
        skin=SKINS[skin]
    )

    final_img = img.resize((110, 110), Image.Resampling.LANCZOS)
    try:
        final_img.save(filename, "PNG")
    except FileNotFoundError as e:
        return False
    return True
