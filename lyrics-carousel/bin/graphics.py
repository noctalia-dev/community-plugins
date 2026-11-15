"""Image renderer for the lyrics carousel (kitty graphics protocol).

Advantages over text mode:
  * The active line can be drawn with a different font size (active_scale).
  * Scrolling happens at the pixel level, not at the terminal row level.
  * Any TTF/OTF is accepted, including the ones kitty rejects because
    they are not monospaced.

The pixel size of the terminal comes from TIOCGWINSZ (ws_xpixel/ws_ypixel),
which kitty fills in, so the image fits 1:1 in the cell grid.
"""

from __future__ import annotations

import base64
import fcntl
import os
import struct
import sys
import termios
import zlib

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover
    Image = None


def terminal_cells(fd=None):
    """(cols, rows, xpix, ypix) of the terminal.

    kitty fills in ws_xpixel/ws_ypixel, so the drawing area is known
    exactly and the image fits 1:1 in the cell grid.
    """
    fd = fd if fd is not None else sys.stdout.fileno()
    try:
        raw = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
    except OSError:
        return 0, 0, 0, 0
    rows, cols, xpix, ypix = struct.unpack("HHHH", raw)
    return cols, rows, xpix, ypix


def is_kitty() -> bool:
    return os.environ.get("KITTY_WINDOW_ID") is not None


class GraphicsRenderer:
    """Draws the carousel on a canvas and sends it to kitty."""

    IMAGE_ID = 77

    def __init__(self, out=None):
        self.out = out or sys.stdout
        self.image_id = self.IMAGE_ID
        self.placement_id = 78
        self.last_size = (0, 0)
        self.supported = is_kitty()
        self.broken = False
        self.write_errors = 0

    # -- canvas ---------------------------------------------------------

    def new_canvas(self, width, height):
        if Image is None:
            return None
        return Image.new("RGBA", (max(1, width), max(1, height)), (0, 0, 0, 0))

    # -- sending --------------------------------------------------------

    def _send(self, payload: bytes, cols: int, rows: int, width: int, height: int):
        """Transmits the image data (without placing it).

        Only the first chunk carries the control data; the rest only carry
        the m flag (kitty graphics protocol).
        """
        if self.broken:
            return False
        encoded = base64.b64encode(payload).decode("ascii")
        chunk = 4096
        parts = [encoded[i : i + chunk] for i in range(0, len(encoded), chunk)] or [""]
        try:
            for index, part in enumerate(parts):
                more = 1 if index < len(parts) - 1 else 0
                if index == 0:
                    # Without the "a" key the image is only transmitted; the
                    # placement is done afterwards with a=p.
                    control = (
                        f"f=32,s={width},v={height},o=z,i={self.image_id},q=2,m={more}"
                    )
                else:
                    control = f"m={more}"
                self.out.write(f"\x1b_G{control};{part}\x1b\\")
            self.out.flush()
        except OSError:
            # The terminal was resized or closed: this is not a fatal error.
            self.write_errors += 1
            if self.write_errors > 30:
                self.broken = True
            return False
        return True

    def present(self, image, cols: int, rows: int):
        """Sends the image and leaves it placed in the window.

        The raw RGBA format (f=32) compressed with zlib is used: it is
        about three times faster to encode than PNG and weighs the same.

        To update in place the previous image is deleted, the new data is
        transmitted and the image is placed again with the same placement
        id (C=1 prevents the cursor from moving). Everything goes inside a
        synchronized update so it does not flicker.
        """
        if image is None or cols <= 0 or rows <= 0:
            return False
        width, height = image.size
        try:
            payload = zlib.compress(image.tobytes(), 1)
        except Exception:  # noqa: BLE001
            return False
        try:
            self.out.write("\x1b[?2026h")
            # The previous image (and its placements) is deleted.
            self.out.write(f"\x1b_Ga=d,d=I,i={self.image_id},q=2\x1b\\")
            ok = self._send(payload, cols, rows, width, height)
            # The new image is placed in the corner with the same id.
            # The cursor marks the spot: it goes to the top-left corner.
            self.out.write("\x1b[1;1H")
            self.out.write(
                f"\x1b_Ga=p,i={self.image_id},p={self.placement_id},"
                f"c={cols},r={rows},C=1,q=2\x1b\\"
            )
            self.out.write("\x1b[?2026l")
            self.out.flush()
        except OSError:
            self.write_errors += 1
            if self.write_errors > 30:
                self.broken = True
            return False
        self.last_size = (cols, rows)
        return ok

    def clear(self):
        """Removes the image from the screen."""
        self.out.write(f"\x1b_Ga=d,d=I,i={self.image_id},q=2\x1b\\")
        self.out.flush()


def load_font(path: str, size: float):
    if Image is None or not path:
        return None
    try:
        # The size can be fractional: this way the growing text does not
        # step by one pixel.
        return ImageFont.truetype(path, max(1.0, float(size)))
    except (OSError, TypeError, ValueError):
        # An old version of Pillow may not accept a fractional size: fall
        # back to the integer instead of bringing the render down.
        try:
            return ImageFont.truetype(path, max(1, int(round(float(size)))))
        except (OSError, TypeError, ValueError):
            return None


def text_width(draw, text, font) -> float:
    if not text:
        return 0.0
    try:
        return draw.textlength(text, font=font)
    except AttributeError:
        return font.getsize(text)[0]
