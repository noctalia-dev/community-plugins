#!/usr/bin/env python3
"""Adjust wallpaper brightness and keep only the single active wallpaper file on disk."""

import os
import sys


def adjust_with_pil(src_path: str, dst_path: str, factor: float) -> None:
    from PIL import Image, ImageEnhance, ImageOps

    with Image.open(src_path) as img:
        img = ImageOps.exif_transpose(img)
        if img.mode not in ("RGB", "RGBA"):
            img = img.convert("RGBA" if "A" in img.mode else "RGB")

        if img.mode == "RGBA":
            r, g, b, a = img.split()
            rgb = Image.merge("RGB", (r, g, b))
            enhanced_rgb = ImageEnhance.Brightness(rgb).enhance(factor)
            er, eg, eb = enhanced_rgb.split()
            result = Image.merge("RGBA", (er, eg, eb, a))
        else:
            result = ImageEnhance.Brightness(img).enhance(factor)

        parent = os.path.dirname(dst_path)
        os.makedirs(parent, exist_ok=True)
        base, ext = os.path.splitext(dst_path)
        tmp_path = f"{base}.tmp{ext or '.jpg'}"

        if (ext or "").lower() in (".jpg", ".jpeg"):
            if result.mode == "RGBA":
                result = result.convert("RGB")
            result.save(tmp_path, format="JPEG", quality=93, optimize=True)
        elif (ext or "").lower() == ".webp":
            result.save(tmp_path, format="WEBP", quality=92)
        else:
            result.save(tmp_path, format="PNG")

        os.replace(tmp_path, dst_path)


def cleanup_previous_files(cache_dir: str, prefix: str, keep_filename: str) -> None:
    """Keep strictly one active wallpaper file per monitor and remove obsolete versions."""
    if not os.path.isdir(cache_dir) or not prefix:
        return
    try:
        for name in os.listdir(cache_dir):
            if name.startswith(prefix) and name != keep_filename and not name.endswith(".json"):
                try:
                    os.remove(os.path.join(cache_dir, name))
                except OSError:
                    pass
    except OSError:
        pass


def main() -> int:
    if len(sys.argv) < 4:
        sys.stderr.write("usage: adjust_wallpaper.py <src> <dst> <brightness_percent> [prefix]\n")
        return 2

    src_path = sys.argv[1]
    dst_path = sys.argv[2]
    try:
        brightness = float(sys.argv[3])
    except ValueError:
        sys.stderr.write("invalid brightness value\n")
        return 2

    prefix = sys.argv[4] if len(sys.argv) >= 5 else ""
    if not os.path.isfile(src_path):
        sys.stderr.write(f"source file not found: {src_path}\n")
        return 1

    factor = max(0.05, min(3.0, brightness / 100.0))
    try:
        adjust_with_pil(src_path, dst_path, factor)
    except Exception as exc:
        sys.stderr.write(f"failed to process wallpaper: {exc}\n")
        return 1

    cleanup_previous_files(os.path.dirname(dst_path), prefix, os.path.basename(dst_path))
    sys.stdout.write(dst_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
