"""ImageRenderer class: draws the carousel as an image and sends it to kitty."""

from __future__ import annotations

import math
import os
import subprocess
import sys

# realpath: the module may be reached through a symbolic link and its
# siblings (graphics) live in the real directory.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from graphics import GraphicsRenderer, load_font, terminal_cells, text_width  # noqa: E402

try:
    from PIL import Image, ImageChops, ImageDraw
except ImportError:  # pragma: no cover
    Image = None

FALLBACK_FONT = "/usr/share/fonts/TTF/DejaVuSansMono.ttf"

# Frames per second of the image. At rest (karaoke and animated background)
# 30 are enough; while the carousel scrolls it goes up to 60, which is when
# the eye notices the stutter. The frame signature avoids resending it.
IMAGE_FPS = 30
MOTION_FPS = 60


def mmss(seconds):
    """Seconds -> mm:ss."""
    seconds = max(0, int(seconds or 0))
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


class ImageRenderer:
    """Renders the carousel with Pillow and displays it with the kitty protocol.

    Advantages over text mode:
      * the active line is drawn at a different size (active_scale),
      * scrolling happens at the pixel level,
      * any typeface is supported, not just monospaced ones.
    """

    # How strongly the accent shows in the tone of what has not been sung
    # yet (the karaoke): 45% of the accent over the background.
    KARAOKE_PENDING = 0.45

    def __init__(self, app):
        self.app = app
        self.gfx = GraphicsRenderer()
        self.fonts = {}
        self.font_files = {}
        self.last_signature = None
        self._measure_draw = None
        self._signature = None
        self.frames = 0
        self.sends = 0

    # -- typefaces ------------------------------------------------------

    def font_file(self, family: str) -> str:
        if family in self.font_files:
            return self.font_files[family]
        path = ""
        try:
            result = subprocess.run(
                ["fc-match", "-f", "%{file}", family],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            )
            if result.returncode == 0:
                path = (result.stdout or "").strip().splitlines()[0:1]
                path = path[0] if path else ""
        except (OSError, subprocess.SubprocessError, IndexError):
            path = ""
        if not path or not os.path.isfile(path):
            path = FALLBACK_FONT
        self.font_files[family] = path
        return path

    def font(self, family: str, size: float):
        # The size is stored in quarter-pixels: the text grows continuously
        # (without 1 px steps) and the cache does not grow without bound,
        # because the range of possible sizes is small.
        key = (family, int(round(size * 4)))
        font = self.fonts.get(key)
        if font is None:
            font = load_font(self.font_file(family), key[1] / 4.0)
            self.fonts[key] = font
        return font

    def invalidate_fonts(self):
        """Clears the font cache (after a font_family/font_size change)."""
        self.fonts.clear()
        self.font_files.clear()

    # -- drawing utilities ---------------------------------------------

    @staticmethod
    def _mix(color, background, factor):
        return (
            int(background[0] + (color[0] - background[0]) * factor),
            int(background[1] + (color[1] - background[1]) * factor),
            int(background[2] + (color[2] - background[2]) * factor),
        )

    @staticmethod
    def _lerp(first, second, factor):
        """Interpolates from `first` (factor 0) to `second` (factor 1).

        `_mix` blends a color over the background and the factor says how
        strong the color is; here the factor is the progress of a
        transition, so the order of the colors is the order in which they
        are seen on screen.
        """
        factor = max(0.0, min(1.0, factor))
        return (
            int(first[0] + (second[0] - first[0]) * factor),
            int(first[1] + (second[1] - first[1]) * factor),
            int(first[2] + (second[2] - first[2]) * factor),
        )

    def _karaoke_pending(self, accent, background):
        """The dimmed tone of what has not been sung yet (the karaoke).

        This is the color used to draw the part of the main line that has
        not been sung yet. The line that is about to become the main one
        has to arrive at this tone, otherwise it darkens abruptly once it
        becomes the main line.
        """
        return self._mix(accent, background, self.KARAOKE_PENDING)

    def fit_text(self, text, max_width, size, family):
        """Trims the text so it fits in the available width."""
        font = self.font(family, size)
        if font is None:
            return text
        if text_width(self._measure_draw, text, font) <= max_width:
            return text
        cut = len(text)
        while cut > 1:
            cut -= 1
            candidate = text[:cut] + "…"
            if text_width(self._measure_draw, candidate, font) <= max_width:
                return candidate
        return "…"

    def _draw_centered(self, draw, text, center_y, size, color, family):
        font = self.font(family, size)
        if font is None:
            return 0.0
        width = text_width(draw, text, font)
        x = (draw.im.size[0] - width) / 2
        draw.text((x, center_y), text, font=font, fill=color, anchor="lm")
        return width

    @staticmethod
    def _image_from(draw):
        """The full image that `draw` is drawing on.

        ImageDraw does not keep the image: `draw.im` is the internal core
        (it is useful to know the size, but not to compose layers). The
        whole image is needed to crop and paste the sung portion, so the
        real one is looked up first.
        """
        for atributo in ("_image", "image", "im"):
            candidate_image = getattr(draw, atributo, None)
            if candidate_image is not None and hasattr(candidate_image, "crop"):
                return candidate_image
        return None

    def _draw_karaoke(
        self, draw, text, center_y, size, sung, unsung, amount, family, alpha=255
    ):
        """Fills the sung part of the line from left to right, pixel by pixel.

        `amount` is the number of sung characters, with decimals. The
        progress is interpolated inside the current glyph, so the fill
        does not jump from letter to letter but follows the real rhythm of
        the lyrics: a long syllable takes longer to fill, which is what
        made it look like it recognized the song speed.

        The brightness is the text's own: the sung part is filled with the
        accent color and what is missing goes in a dimmed tone. There is no
        blurred halo around it (it was a shadow that also cost 3.2 ms per
        frame and made the carousel drop below 60 fps).

        The edge of the fill fades out with an alpha ramp: the sung text
        blends into the missing one instead of cutting sharply, and the
        eye follows the light as it advances.

        `alpha` is the opacity of the line (derived from its distance to
        the center): without it, the outgoing line arrived opaque at the
        handover and turned translucent all at once when the drawing path
        changed.
        """
        font = self.font(family, size)
        if font is None:
            return
        base = self._image_from(draw)
        if base is None:
            return
        total = text_width(draw, text, font)
        x = (base.size[0] - total) / 2
        length = len(text)
        fill_color = unsung if alpha >= 255 else unsung + (max(0, int(alpha)),)
        draw.text((x, center_y), text, font=font, fill=fill_color, anchor="lm")
        if length <= 0:
            return
        amount = max(0.0, min(float(length), amount))
        if amount <= 0.0:
            return
        if amount >= length:
            sung_px = total
        else:
            steps = max(1, int(amount))
            sung_px = 0.0
            for index in range(steps):
                sung_px += text_width(draw, text[index], font)
            if steps < length:
                sung_px += (amount - steps) * text_width(draw, text[steps], font)
        if sung_px <= 0.0:
            return

        # The line's box: without a blurred halo the large margin is not
        # needed, just a few pixels so the glyph antialiasing is not cut
        # off.
        left, top, right, bottom = draw.textbbox(
            (x, center_y), text, font=font, anchor="lm"
        )
        pad = 4
        box = (
            max(0, int(left) - pad),
            max(0, int(top) - pad),
            min(base.size[0], int(math.ceil(right)) + pad),
            min(base.size[1], int(math.ceil(bottom)) + pad),
        )
        width = box[2] - box[0]
        height = box[3] - box[1]
        if width <= 0 or height <= 0:
            return

        # Sung edge, in pixels inside the line's box.
        limit = max(1, min(width, int(math.ceil(sung_px + x - box[0]))))

        def paint_layer(color):
            """The whole phrase on a layer cropped to the line."""
            layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
            ImageDraw.Draw(layer).text(
                (x - box[0], center_y - box[1]),
                text,
                font=font,
                fill=color,
                anchor="lm",
            )
            if alpha < 255:
                # The layer inherits the opacity of the line: otherwise the
                # outgoing line would arrive opaque at the handover and
                # turn translucent all at once when the drawing path
                # changed.
                factor = max(0.0, min(1.0, alpha / 255.0))
                layer.putalpha(
                    layer.getchannel("A").point(lambda value: int(value * factor))
                )
            return layer

        # The sung portion is cropped with crop (one extra pixel changes
        # nothing): this way the edge of the fill falls inside the current
        # glyph and the progress is continuous instead of jumping from word
        # to word.
        clip_box = (0, 0, limit, height)
        full_image = paint_layer(sung)
        sharp_image = full_image.crop(clip_box)

        # The brightness of the text: only the sung part, in its color,
        # without a blurred shadow around it. The halo was a shadow that
        # also cost 3.2 ms per frame (two GaussianBlur calls) and made it
        # drop below 60 fps.
        ramp = max(2, int(size * 0.5))

        # The edge of the fill is smoothed: an alpha ramp over the last
        # columns blends the sung text with the part that has not been
        # sung yet, instead of cutting the color sharply (a vertical
        # slice of light). The ramp falls off towards the limit: the sung
        # color fades as it reaches the edge. With the ramp reversed the
        # red lit up exactly at the end and cut off abruptly.
        if limit > 0:
            soft_mask = Image.new("L", (limit, height), 255)
            ramp_span = min(ramp, limit)
            ramp_values = [
                int(255 * (ramp_span - indice) / float(ramp_span)) for indice in range(ramp_span)
            ]
            ramp_column = Image.new("L", (ramp_span, 1))
            ramp_column.putdata(ramp_values)
            ramp_column = ramp_column.resize((ramp_span, height), Image.Resampling.NEAREST)
            soft_mask.paste(ramp_column, (limit - ramp_span, 0))
            sharp_image.putalpha(ImageChops.multiply(sharp_image.getchannel("A"), soft_mask))

        base.alpha_composite(sharp_image, (box[0], box[1]))

    def _draw_left(self, draw, text, x, y, size, color, family, anchor="lm"):
        font = self.font(family, size)
        if font is None:
            return
        draw.text((x, y), text, font=font, fill=color, anchor=anchor)

    def _draw_right(self, draw, text, right_x, y, size, color, family):
        font = self.font(family, size)
        if font is None:
            return
        width = text_width(draw, text, font)
        draw.text((right_x - width, y), text, font=font, fill=color, anchor="lm")

    # -- layout ---------------------------------------------------------

    def _layout(self, focus, center_y, size, scale):
        """Returns the positions (vertical center) of the lines around focus.

        In the "down" direction the upcoming lines enter from the top (as
        in text mode) and the past ones leave through the bottom; in "up"
        it is the other way around.
        """
        app = self.app
        above = app.cfg["visible_above"]
        below = app.cfg["visible_below"]
        down = app.cfg["direction"] == "down"
        small_h = size * 1.32
        big_h = size * scale * 1.32
        gap = size * 0.30 * max(1, app.cfg["spacing"])
        positions = {}
        positions[focus] = center_y

        if down:
            # Upcoming lines go above, lines already passed go below.
            cursor = center_y - big_h / 2 - gap - small_h / 2
            for index in range(focus + 1, focus + 1 + above):
                positions[index] = cursor
                cursor -= small_h + gap
            cursor = center_y + big_h / 2 + gap + small_h / 2
            for index in range(focus - 1, focus - 1 - below, -1):
                positions[index] = cursor
                cursor += small_h + gap
        else:
            cursor = center_y - big_h / 2 - gap - small_h / 2
            for index in range(focus - 1, focus - 1 - above, -1):
                positions[index] = cursor
                cursor -= small_h + gap
            cursor = center_y + big_h / 2 + gap + small_h / 2
            for index in range(focus + 1, focus + 1 + below):
                positions[index] = cursor
                cursor += small_h + gap
        return positions

    # -- main render ----------------------------------------------------

    def render(self):
        app = self.app
        if Image is None or not self.gfx.supported:
            return False
        cols, rows, xpix, ypix = terminal_cells()
        if xpix <= 0 or ypix <= 0 or cols <= 0 or rows <= 0:
            return False

        cfg = app.cfg
        theme = app.theme
        accent = theme.accent_color(cfg)
        family = cfg["font_family"]
        size = float(cfg["font_size"])
        scale = float(cfg["active_scale"])
        position = app.position()
        duration = app.track.duration if app.track else 0.0

        self.frames += 1
        signature = self._frame_signature(accent) + (cols, rows, xpix, ypix)
        if signature == self.last_signature:
            return True
        self.last_signature = signature

        # NATIVE RENDER (full resolution): maximum quality.
        # Without the visualizer the draw is fast (~20ms). No downscale = perfect sharpness.
        image = Image.new("RGBA", (xpix, ypix), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        self._measure_draw = draw
        background = theme.background

        # -- header
        top = size * 1.9
        bottom = ypix - size * 1.9
        if cfg["header"]:
            title = app.track.title or app.tr("nothing_playing")
            artist = app.track.artist or ""
            self._draw_left(draw, title, size * 1.6, top, size * 0.95, theme.bright, family)
            if artist:
                self._draw_left(
                    draw, "— " + artist, size * 1.6, top + size * 1.2,
                    size * 0.8, theme.faint, family,
                )
            rule_y = top + size * 2.0
            ImageDraw.Draw(image).rectangle(
                [size * 1.6, rule_y, xpix - size * 1.6, rule_y + max(1, size * 0.05)],
                fill=self._mix(theme.faint, background, 0.35),
            )
            top = rule_y + size * 0.9

        # -- lyrics
        center_y = (top + bottom) / 2
        if app.state == "lyrics" and app.lines:
            self._draw_lyrics(draw, center_y, size, scale, family, accent, position, top, bottom)
        else:
            self._draw_state(draw, center_y, size, family)

        # -- footer
        if cfg["footer"]:
            self._draw_footer(draw, xpix, ypix, size, family, accent, position, duration)
        if cfg["hints"]:
            self._draw_hints(draw, size, family)

        self.sends += 1
        return self.gfx.present(image, cols, rows)

    def _frame_signature(self, accent):
        """Frame signature: if it does not change, the image is not sent again."""
        app = self.app
        cfg = app.cfg
        position = app.position()
        index, focus, progress = app.scroll_state(position)
        parts = [
            index, focus, round(progress * MOTION_FPS), app.state, app.track.title,
            app.track.artist, int(position) if cfg["footer"] else 0,
            accent, cfg["font_family"], cfg["font_size"], cfg["active_scale"],
            cfg["visible_above"], cfg["visible_below"], cfg["direction"],
            cfg["karaoke"], cfg["marker"], cfg["header"], cfg["footer"],
            cfg["hints"], cfg["spacing"], cfg["ghost"],
            round(position * MOTION_FPS),
        ]
        # The background moves even when the lyrics do not change: its
        # signature is part of the frame signature, otherwise the image
        # would stay frozen between lines.
        visualizer = getattr(app, "visualizer", None)
        if visualizer is not None:
            parts.append(visualizer.signature())
        return tuple(parts)

    def _draw_lyrics(self, draw, center_y, size, scale, family, accent, position, area_top, area_bottom):
        app = self.app
        theme = app.theme
        background = theme.background
        index, focus, progress = app.scroll_state(position)
        lines = app.lines

        pos_a = self._layout(index, center_y, size, scale)
        pos_b = self._layout(focus, center_y, size, scale)

        visible = set(pos_a) | set(pos_b)
        # Lines leaving (present in pos_a but not in pos_b)
        leaving = set(pos_a.keys()) - set(pos_b.keys())
        # Lines entering (present in pos_b but not in pos_a)
        entering = set(pos_b.keys()) - set(pos_a.keys())
        # Extra margin to avoid cutting text in the middle of painting: the
        # maximum line height (with scale) plus the gap.
        max_line_h = size * scale * 1.32
        gap = size * 0.30 * max(1, app.cfg["spacing"])
        margin = max_line_h + gap
        # Off-screen positions for smooth entering/leaving
        off_top = area_top - max_line_h - gap
        off_bottom = area_bottom + max_line_h + gap
        down = app.cfg["direction"] == "down"
        # Interpolated scale: the leaving line shrinks, the entering one grows.
        for line_index in sorted(visible):
            if line_index < 0 or line_index >= len(lines):
                continue
            line = lines[line_index]
            y_a = pos_a.get(line_index)
            y_b = pos_b.get(line_index)
            if y_a is None:
                # Line ENTERING: comes from off-screen
                if down:
                    y_a = off_top  # In "down", they come from ABOVE
                else:
                    y_a = off_bottom  # In "up", they come from BELOW
                y = y_a + (pos_b[line_index] - y_a) * progress
            elif y_b is None:
                # Line LEAVING: moves towards off-screen
                if down:
                    y_b = off_bottom  # In "down", they go BELOW
                else:
                    y_b = off_top  # In "up", they go ABOVE
                y = pos_a[line_index] + (y_b - pos_a[line_index]) * progress
            else:
                # Line in both: normal interpolation
                y = y_a + (y_b - y_a) * progress
            # Clip to the visible area: do not paint lines that fall outside.
            if y + margin < area_top or y - margin > area_bottom:
                continue

            if line_index == index:
                factor = 1.0 + (scale - 1.0) * (1.0 - progress)
                # The one that stops being the main line: it shrinks back to its normal size.
            elif line_index == focus:
                factor = 1.0 + (scale - 1.0) * progress
                # The one that is about to become the main line: it grows to the main size.
            else:
                factor = 1.0
            line_size = size * factor

            distance = abs(y - center_y)
            span = max(1.0, (area_bottom - area_top) * 0.5)
            fade = max(0.22, 1.0 - (distance / span) ** 1.0)
            # The lines at the edges (the ones entering and leaving the
            # frame) fade out. The two handover lines do not: if they lost
            # their alpha they would vanish abruptly at the start or end
            # of the transition.
            if line_index in entering and line_index != focus:
                fade *= progress
            elif line_index in leaving and line_index != index:
                fade *= 1.0 - progress
            # The alpha of the rest depends only on the distance to the
            # center: the entering line keeps the previous one and the
            # leaving line stays in place until it fills the slot of the
            # already sung ones.
            is_sung = line_index == index
            is_focus = line_index == focus
            if is_sung:
                # The main line that stops being it: from the main color to
                # the color of the already sung lines.
                target = self._mix(theme.past, background, fade)
                color = self._lerp(accent, target, progress)
            elif is_focus:
                # The one about to become the main line: from the white it
                # already had to the main color.
                base_color = self._mix(theme.foreground, background, fade)
                color = self._lerp(base_color, accent, progress)
                if app.karaoke and app.cfg["karaoke"]:
                    # With karaoke the main line is drawn in two tones: the
                    # sung part in the accent color and the missing part
                    # dimmed. The entering line has to arrive already at
                    # that dimmed tone: if it arrives at the accent, it
                    # darkens abruptly once it becomes the main line. That
                    # is why, on top of the color transition, there is
                    # another one for darkness: from the level the following
                    # lines have (without darkening) to the pending tone.
                    color = self._lerp(
                        color, self._karaoke_pending(accent, background), progress
                    )
            else:
                base = theme.foreground if line_index > index else theme.past
                color = self._mix(base, background, fade)
            # Apply the transition alpha to the color (RGBA)
            color = color + (int(fade * 255),)

            text = self.fit_text(
                line.text, draw.im.size[0] - size * 6, size * factor, family
            )
            marker = ""
            if app.cfg["marker"] and is_sung:
                marker = "> "
            if marker:
                self._draw_marker(draw, text, y, line_size, marker, family, accent)
            if is_sung and app.karaoke and app.cfg["karaoke"]:
                end = line.start + (line.duration or 4.0)
                next_start = app.next_timed_start(line_index)
                if next_start is not None and next_start > line.start:
                    end = next_start if not line.duration else min(end, next_start)
                # The same calculation as text mode: if the adapter gives
                # per-character timings the fill respects them, and if not
                # it spreads the line duration across the characters.
                amount = app.karaoke_amount(line, text, position, end)
                sung_text = accent
                pending_text = self._karaoke_pending(accent, background)
                if progress > 0.0:
                    # The line that stops being the main one fades towards
                    # the color of the already sung ones: when it ends it
                    # looks the same as its neighbours, with no color jump.
                    target = self._mix(theme.past, background, fade)
                    sung_text = self._lerp(accent, target, progress)
                    pending_text = self._lerp(pending_text, target, progress)
                self._draw_karaoke(
                    draw,
                    text,
                    y,
                    line_size,
                    sung_text,
                    pending_text,
                    amount,
                    family,
                    int(fade * 255),
                )
            else:
                self._draw_centered(draw, text, y, line_size, color, family)

    def _draw_marker(self, draw, text, center_y, size, marker, family, color):
        """The ">" marker glued to the left of the active line."""
        font = self.font(family, size)
        if font is None:
            return
        width = text_width(draw, text, font)
        marker_width = text_width(draw, marker, font)
        x = (draw.im.size[0] - width) / 2 - marker_width - size * 0.35
        draw.text((x, center_y), marker, font=font, fill=color, anchor="lm")

    def _draw_state(self, draw, center_y, size, family):
        app = self.app
        theme = app.theme
        if app.state == "loading":
            message = app.tr("searching_lyrics")
            detail = (app.track.title + " — " + app.track.artist).strip(" —")
        elif app.state == "empty":
            message = app.tr("no_lyrics_title")
            detail = app.tr("try_another_source")
        else:
            message = app.tr("nothing_playing")
            detail = app.tr("open_player")
        self._draw_centered(draw, message, center_y, size, theme.faint, family)
        self._draw_centered(draw, detail, center_y + size * 1.6, size * 0.9, theme.bright, family)

    def _draw_footer(self, draw, xpix, ypix, size, family, accent, position, duration):
        app = self.app
        theme = app.theme
        y = ypix - size * 1.6
        left = mmss(position)
        right = mmss(duration) if duration > 0 else "--:--"
        ratio = max(0.0, min(1.0, position / duration)) if duration > 0 else 0.0
        margin = size * 1.6
        bar_x0 = margin + size * 3.2
        bar_x1 = xpix - margin - size * 3.2
        bar_width = max(10, bar_x1 - bar_x0)
        self._draw_left(draw, left, margin, y, size * 0.9, theme.faint, family)
        self._draw_right(draw, right, xpix - margin, y, size * 0.9, theme.faint, family)
        filled = int(bar_width * ratio)
        color = self._mix(theme.past, theme.background, 0.6)
        draw.rectangle([bar_x0, y - size * 0.18, bar_x1, y + size * 0.18], fill=color)
        if filled > 0:
            draw.rectangle(
                [bar_x0, y - size * 0.18, bar_x0 + filled, y + size * 0.18], fill=accent
            )

    def _draw_hints(self, draw, size, family):
        app = self.app
        theme = app.theme
        xpix, ypix = app.terminal_pixels()
        y = ypix - size * 0.6
        candidates = app.texts.get("hints") or [""]
        self._measure_draw = draw
        limit = max(1.0, xpix - size * 3.2)
        text = candidates[0]
        font = self.font(family, size * 0.8)
        if font is not None:
            for candidate in candidates:
                if text_width(draw, candidate, font) <= limit:
                    text = candidate
                    break
            else:
                text = self.fit_text(candidates[0], limit, size * 0.8, family)
        # The whole row is centered in the window: it used to start on the
        # left and the leftover piled up on the right.
        self._draw_centered(
            draw, text, y, size * 0.8,
            self._mix(theme.faint, theme.background, 0.7), family,
        )

