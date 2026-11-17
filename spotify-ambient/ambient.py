#!/usr/bin/env python3
"""Render a contrast-safe ambient wallpaper from an MPRIS artwork URI."""

from __future__ import annotations

import argparse
import colorsys
import fcntl
import ipaddress
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path
from urllib.parse import unquote, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps, ImageStat, __version__ as PILLOW_VERSION

MAX_DOWNLOAD = 12 * 1024 * 1024
MAX_SOURCE_PIXELS = 50_000_000
BLUR_FRACTION = 0.045  # reveal broad cover-art forms without exposing fine text/details
MIN_BLUR_RADIUS = 18


def _validate_artwork_http_url(url: str) -> None:
    """Reject non-public destinations, including redirect targets."""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("Artwork URL must use HTTP(S) and include a hostname")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("Artwork URL must not contain embedded credentials")
    try:
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        try:
            addresses = [ipaddress.ip_address(parsed.hostname)]
        except ValueError:
            resolved = socket.getaddrinfo(parsed.hostname, port, type=socket.SOCK_STREAM)
            addresses = [ipaddress.ip_address(item[4][0]) for item in resolved]
    except (OSError, ValueError) as exc:
        raise ValueError("Artwork URL hostname could not be safely resolved") from exc
    if not addresses or any(not address.is_global for address in addresses):
        raise ValueError("Artwork URL must resolve only to public IP addresses")


class _SafeArtworkRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        _validate_artwork_http_url(new_url)
        return super().redirect_request(request, file_pointer, code, message, headers, new_url)


def _decode_artwork(image: Image.Image) -> Image.Image:
    """Validate image dimensions before decoding pixel data."""
    if image.width <= 0 or image.height <= 0 or image.width * image.height > MAX_SOURCE_PIXELS:
        raise ValueError("Artwork dimensions exceed the pixel safety limit")
    image.load()
    return ImageOps.exif_transpose(image).convert("RGB")


def load_artwork(uri: str) -> Image.Image:
    parsed = urlparse(uri)
    if parsed.scheme == "file":
        if parsed.netloc not in ("", "localhost"):
            raise ValueError("Artwork file URI must refer to the local machine")
        source = Path(unquote(parsed.path))
        if not source.is_file():
            raise ValueError("MPRIS artwork file does not exist")
        if source.stat().st_size > MAX_DOWNLOAD:
            raise ValueError("Artwork exceeds the 12 MiB safety limit")
        with Image.open(source) as image:
            return _decode_artwork(image)
    elif parsed.scheme in ("http", "https"):
        _validate_artwork_http_url(uri)
        request = Request(uri, headers={"User-Agent": "Spotify-Ambient/0.4.2"})
        opener = build_opener(_SafeArtworkRedirectHandler)
        with opener.open(request, timeout=15) as response:
            data = response.read(MAX_DOWNLOAD + 1)
        if len(data) > MAX_DOWNLOAD:
            raise ValueError("Artwork exceeds the 12 MiB safety limit")
        import io
        with Image.open(io.BytesIO(data)) as image:
            return _decode_artwork(image)
    else:
        raise ValueError("Unsupported artwork URI scheme; expected https:// or file://")


def _mean_saturation(image: Image.Image) -> float:
    """Return average HSV saturation (0-255) from a small source thumbnail."""
    sample = image.copy()
    sample.thumbnail((160, 160), Image.Resampling.LANCZOS)
    return ImageStat.Stat(sample.convert("HSV")).mean[1]


def _monochrome_ambient(width: int, height: int) -> Image.Image:
    """Build a restrained midnight indigo/teal/violet colour field."""
    # Work small and upscale: the result is a smooth gradient, not visible blobs.
    small_w = max(96, width // 8)
    small_h = max(96, height // 8)
    field = Image.new("RGB", (small_w, small_h), (16, 19, 31))
    blur = max(12, round(min(small_w, small_h) * 0.20))

    blobs = [
        (0.16, 0.22, 0.48, 0.62, (112, 82, 169), 178),  # upper-left indigo
        (0.84, 0.28, 0.46, 0.58, (52, 126, 163), 166),  # upper-right teal
        (0.76, 0.82, 0.52, 0.46, (150, 82, 157), 152),    # lower-right violet
        (0.18, 0.82, 0.46, 0.44, (43, 106, 137), 136),    # lower-left blue-teal
    ]
    for cx, cy, rx, ry, colour, opacity in blobs:
        mask = Image.new("L", (small_w, small_h), 0)
        draw = ImageDraw.Draw(mask)
        box = (
            round((cx - rx / 2) * small_w),
            round((cy - ry / 2) * small_h),
            round((cx + rx / 2) * small_w),
            round((cy + ry / 2) * small_h),
        )
        draw.ellipse(box, fill=opacity)
        mask = mask.filter(ImageFilter.GaussianBlur(blur))
        layer = Image.new("RGB", (small_w, small_h), colour)
        field = Image.composite(layer, field, mask)

    return field.resize((width, height), Image.Resampling.BICUBIC)


def _tone_map_for_readability(image: Image.Image) -> Image.Image:
    """Lift crushed shadows and cap bright regions to keep wallpaper subdued.

    HSV value is constrained to roughly 12..96/255. This cannot guarantee
    terminal contrast by itself (terminal opacity/theme also matter), but it
    prevents the wallpaper from containing near-white hotspots or pure black.
    """
    hsv = image.convert("HSV")
    hue, saturation, value = hsv.split()
    low, high = 12, 96
    # Gentle power curve: preserve broad midtone differences while compressing
    # highlights much more than a single global brightness multiplier would.
    lut = [round(low + (high - low) * ((v / 255) ** 0.76)) for v in range(256)]
    value = value.point(lut)
    return Image.merge("HSV", (hue, saturation, value)).convert("RGB")


def render(uri: str, width: int, height: int, destination: Path) -> None:
    if not (320 <= width <= 16384 and 320 <= height <= 16384):
        raise ValueError("Output dimensions are outside the supported range")

    source = load_artwork(uri)
    background = ImageOps.fit(
        source, (width, height), method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )
    # The earlier 6.5% radius hid too much of the subject. 4.5% keeps the
    # ambient look while allowing silhouettes, faces and broad artwork shapes
    # to read more clearly; small text and fine details remain softened.
    radius = max(MIN_BLUR_RADIUS, round(min(width, height) * BLUR_FRACTION))
    background = background.filter(ImageFilter.GaussianBlur(radius=radius))

    saturation = _mean_saturation(source)
    if saturation < 24:
        # Monochrome covers need an intentional colour field; retain a little
        # of their luminance structure so the wallpaper still feels album-led.
        ambient = _monochrome_ambient(width, height)
        background = Image.blend(ambient, background, 0.30)
    else:
        # Preserve an album's own palette when the source is already colourful.
        background = ImageEnhance.Color(background).enhance(1.16)

    background = _tone_map_for_readability(background)

    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=".ambient-", suffix=".jpg", dir=destination.parent)
    os.close(fd)
    try:
        background.save(temp_name, "JPEG", quality=94, optimize=True, progressive=True)
        os.replace(temp_name, destination)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def _run_diagnostic_command(argv: list[str], timeout: float = 5.0) -> tuple[bool, str]:
    """Run a read-only diagnostic command without exposing artwork URLs."""
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError:
        return False, f"command not found: {argv[0]}"
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout:g}s: {' '.join(argv)}"
    detail = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part and part.strip())
    if result.returncode != 0:
        return False, detail or f"exit status {result.returncode}"
    return True, detail


def collect_diagnostics() -> dict:
    """Collect a redacted, read-only report suitable for a GitHub issue."""
    checks: list[dict[str, str]] = []

    def add(name: str, ok: bool, detail: str, level: str | None = None) -> None:
        checks.append({
            "name": name,
            "status": level or ("ok" if ok else "error"),
            "detail": detail or ("available" if ok else "not available"),
        })

    add("python", True, platform.python_version())
    add("platform", True, f"{platform.system()} {platform.release()} ({platform.machine()})")
    add("pillow", True, PILLOW_VERSION)

    playerctl = shutil.which("playerctl")
    add("playerctl", bool(playerctl), playerctl or "Install playerctl and retry")
    if playerctl:
        ok, players = _run_diagnostic_command([playerctl, "-l"])
        spotify_present = ok and "spotify" in {line.strip() for line in players.splitlines()}
        add("spotify_mpris", spotify_present, "registered" if spotify_present else "Spotify MPRIS player is not registered", "ok" if spotify_present else "warning")
        if spotify_present:
            status_ok, status = _run_diagnostic_command([playerctl, "-p", "spotify", "status"])
            add("spotify_status", status_ok, status or ("status returned no text" if status_ok else "Could not query Spotify"), "ok" if status_ok else "warning")

    noctalia = shutil.which("noctalia")
    add("noctalia_cli", bool(noctalia), noctalia or "Noctalia CLI not found on PATH")
    if noctalia:
        ok, scheme = _run_diagnostic_command([noctalia, "msg", "color-scheme-get"])
        add("noctalia_ipc", ok, scheme or ("IPC responded" if ok else "Noctalia IPC did not respond"))
        theme_ok, theme_help = _run_diagnostic_command([noctalia, "theme", "--help"])
        theme_support = theme_ok and "--terminal-colors" in theme_help
        add("noctalia_image_theme_cli", theme_support, "image theme CLI supports --terminal-colors" if theme_support else "Noctalia theme CLI help did not advertise --terminal-colors", "ok" if theme_support else "error")

    return {
        "report_version": 1,
        "plugin_version": "0.4.2",
        "checks": checks,
        "notes": [
            "This report does not include Spotify track titles, artwork URLs, credentials, or file contents.",
            "A warning for spotify_mpris is normal when Spotify is closed.",
        ],
    }


def print_diagnostics(as_json: bool = False) -> int:
    report = collect_diagnostics()
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("Spotify Ambient diagnostic report")
        print(f"Plugin: {report['plugin_version']} | Python: {platform.python_version()}")
        print("-" * 64)
        for check in report["checks"]:
            print(f"[{check['status'].upper():7}] {check['name']}: {check['detail']}")
        print("\nPrivacy: no track title, artwork URL, credentials, or file contents are included.")
        print("Attach this output when reporting a problem; redact usernames from paths if you add them manually.")
    return 1 if any(item["status"] == "error" for item in report["checks"]) else 0


def _exception_report(context: str, exc: BaseException) -> None:
    print(f"spotify-ambient: {context}: {type(exc).__name__}: {exc}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("render")
    command.add_argument("art_uri")
    command.add_argument("width", type=int)
    command.add_argument("height", type=int)
    command.add_argument("destination", type=Path)
    palette_command = sub.add_parser("palette")
    palette_command.add_argument("art_uri")
    palette_command.add_argument("destination", type=Path)
    palette_command.add_argument("--preview", type=Path, help="write a visual PNG preview of the dark variant")
    palette_command.add_argument("--preview-light", type=Path, help="also write a visual PNG preview of the light variant")
    palette_command.add_argument("--scheme", default="m3-content", choices=("m3-content", "m3-tonal-spot", "m3-fruit-salad", "m3-rainbow", "m3-monochrome"), help="Noctalia image palette generator")
    apply_command = sub.add_parser("palette-apply", help="generate and apply a palette under the shutdown lock")
    apply_command.add_argument("art_uri")
    apply_command.add_argument("destination", type=Path)
    apply_command.add_argument("palette_name")
    apply_command.add_argument("lock_path", type=Path)
    doctor_command = sub.add_parser("doctor", help="check dependencies and Noctalia/Spotify integration")
    doctor_command.add_argument("--json", action="store_true", help="print machine-readable JSON")
    args = parser.parse_args()

    if args.command == "doctor":
        return print_diagnostics(as_json=args.json)

    try:
        if args.command == "render":
            render(args.art_uri, args.width, args.height, args.destination)
        elif args.command == "palette-apply":
            generate_and_apply_palette(args.art_uri, args.destination, args.palette_name, args.lock_path)
        else:
            palette = generate_palette(args.art_uri, args.destination, scheme=args.scheme)
            if args.preview:
                save_palette_preview(palette, args.preview, mode="dark")
            if args.preview_light:
                save_palette_preview(palette, args.preview_light, mode="light")
    except Exception as exc:
        _exception_report(f"{args.command} failed", exc)
        return 1
    return 0


# ---- Noctalia image-theme palette generation (palette format 2) ----


def _relative_luminance(hex_colour: str) -> float:
    values = [int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in values]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def _contrast_ratio(foreground: str, background: str) -> float:
    a, b = sorted((_relative_luminance(foreground), _relative_luminance(background)), reverse=True)
    return (a + 0.05) / (b + 0.05)


def _rgb_hex(rgb: tuple[int, int, int]) -> str:
    return "#" + "".join(f"{max(0, min(255, int(channel))):02x}" for channel in rgb)


def _hls_hex(hue: float, lightness: float, saturation: float) -> str:
    rgb = colorsys.hls_to_rgb(hue % 1.0, max(0.0, min(1.0, lightness)), max(0.0, min(1.0, saturation)))
    return _rgb_hex(tuple(round(channel * 255) for channel in rgb))


def _best_text_colour(background: str) -> str:
    light = "#e9edf5"
    dark = "#171922"
    return light if _contrast_ratio(light, background) >= _contrast_ratio(dark, background) else dark


def _readable_accent(
    hue: float,
    saturation: float,
    preferred_lightness: float = 0.42,
    *,
    foreground: str = "#e9edf5",
) -> str:
    """Create a muted accent that supports light text at >= 4.5:1 contrast.

    Accent brightness is deliberately capped. Cover art contributes hue and
    some saturation, but cannot produce pale/white UI controls or force dark
    text onto bright accent surfaces.
    """
    candidates = []
    saturation = max(0.34, min(0.62, saturation * 0.90))
    for step in range(24, 51):
        lightness = step / 100
        colour = _hls_hex(hue, lightness, saturation)
        ratio = _contrast_ratio(foreground, colour)
        if ratio >= 4.5:
            candidates.append((abs(lightness - preferred_lightness), -ratio, colour))
    if candidates:
        return min(candidates)[2]

    # A dark fallback remains readable even for unusually bright hues.
    for step in range(23, 11, -1):
        colour = _hls_hex(hue, step / 100, saturation)
        if _contrast_ratio(foreground, colour) >= 4.5:
            return colour
    return _hls_hex(hue, 0.18, min(0.55, saturation))


def _terminal_colour(
    hue: float,
    saturation: float,
    background: str,
    preferred_lightness: float,
    minimum_contrast: float = 4.5,
) -> str:
    """Choose a restrained ANSI foreground visible on the terminal base."""
    saturation = max(0.36, min(0.64, saturation * 0.90))
    candidates = []
    for step in range(28, 67):
        lightness = step / 100
        colour = _hls_hex(hue, lightness, saturation)
        ratio = _contrast_ratio(colour, background)
        if ratio >= minimum_contrast:
            candidates.append((abs(lightness - preferred_lightness), -ratio, colour))
    if candidates:
        return min(candidates)[2]
    return _hls_hex(hue, 0.66, saturation)


def _extract_palette_colours(image: Image.Image) -> list[tuple[float, float, float, float]]:
    """Return candidate (score, hue, saturation, lightness) tuples from artwork."""
    sample = image.copy()
    sample.thumbnail((144, 144), Image.Resampling.LANCZOS)
    quantized = sample.quantize(colors=32, method=Image.Quantize.MEDIANCUT)
    palette = quantized.getpalette() or []
    counts = quantized.getcolors(maxcolors=144 * 144) or []
    total = max(1, sample.width * sample.height)
    candidates: list[tuple[float, float, float, float]] = []

    for count, index in counts:
        offset = index * 3
        if offset + 2 >= len(palette):
            continue
        rgb = tuple(palette[offset:offset + 3])
        hue, lightness, saturation = colorsys.rgb_to_hls(*(channel / 255 for channel in rgb))
        coverage = count / total
        # Ignore near-black/near-white neutrals; they should never make an
        # accent or force the interface into a light palette.
        if saturation < 0.20 or lightness < 0.10 or lightness > 0.88 or coverage < 0.002:
            continue
        score = (saturation ** 0.75) * (0.55 + min(coverage * 5.0, 0.45))
        candidates.append((score, hue, saturation, lightness))

    return sorted(candidates, reverse=True)


def _select_accent_hues(image: Image.Image) -> list[tuple[float, float]]:
    candidates = _extract_palette_colours(image)
    selected: list[tuple[float, float]] = []
    for _, hue, saturation, _ in candidates:
        if all(min((hue - other) % 1.0, (other - hue) % 1.0) >= 0.075 for other, _ in selected):
            selected.append((hue, saturation))
        if len(selected) == 3:
            break

    # White, black, and grayscale covers still receive colour accents, but
    # the palette remains dark. Do not derive surface brightness from cover.
    fallback = [(0.69, 0.52), (0.53, 0.48), (0.80, 0.48)]  # indigo, teal, violet
    for hue, saturation in fallback:
        if len(selected) == 3:
            break
        if all(min((hue - other) % 1.0, (other - hue) % 1.0) >= 0.075 for other, _ in selected):
            selected.append((hue, saturation))
    return selected[:3]


def _select_terminal_hues(
    image: Image.Image,
    accents: list[tuple[float, float]],
) -> list[tuple[float, float]]:
    """Select six album-led ANSI hues, falling back to nearby accent variants.

    The old Spotify integration mapped ANSI slots to the album's extracted
    swatches instead of fixed semantic red/green/yellow hues. Keep that
    behaviour, but let the terminal colour builder clamp lightness and enforce
    contrast so a saturated cover cannot produce eye-searing text colours.
    """
    selected: list[tuple[float, float]] = []
    for _, hue, saturation, _ in _extract_palette_colours(image):
        if all(min((hue - other) % 1.0, (other - hue) % 1.0) >= 0.025 for other, _ in selected):
            selected.append((hue, saturation))
        if len(selected) == 6:
            break

    # A monochrome or single-hue cover may not contain six distinct swatches.
    # Extend the extracted accent set with modest hue offsets rather than
    # injecting fixed neon green/red/yellow into every album's ANSI palette.
    seeds = accents or [(0.69, 0.52), (0.53, 0.48), (0.80, 0.48)]
    offsets = (0.055, -0.055, 0.105, -0.105, 0.16, -0.16)
    offset_index = 0
    while len(selected) < 6:
        seed_hue, seed_saturation = seeds[(len(selected)) % len(seeds)]
        hue = (seed_hue + offsets[offset_index % len(offsets)]) % 1.0
        offset_index += 1
        if all(min((hue - other) % 1.0, (other - hue) % 1.0) >= 0.025 for other, _ in selected):
            selected.append((hue, max(0.36, seed_saturation * 0.88)))
    return selected[:6]


def build_noctalia_palette(image: Image.Image) -> dict:
    """Build a legacy-format dark-first palette from album artwork.

    This helper is retained as a tested palette utility; the active runtime
    generation path uses Noctalia's native image-theme CLI.

    The source art influences accent hues only. Surface luminance is fixed in
    a dark range, so white album art cannot turn the shell or terminal light.
    """
    accents = _select_accent_hues(image)
    primary, secondary, tertiary = [
        _readable_accent(hue, saturation) for hue, saturation in accents
    ]
    error = _readable_accent(0.01, 0.62, 0.41)

    # A softly tinted charcoal, never sampled from artwork's lightness.
    base_hue = accents[0][0]
    surface = _hls_hex(base_hue, 0.075, 0.16)
    surface_variant = _hls_hex(base_hue, 0.125, 0.19)
    outline = _hls_hex(base_hue, 0.29, 0.12)
    hover = _hls_hex(accents[0][0], 0.205, 0.42)

    on_surface = "#e2e6ef"
    on_surface_variant = "#b8c0d0"
    # Accent surfaces are kept dark enough to consistently use a light
    # foreground, regardless of the brightness of the source cover.
    on_primary = "#e9edf5"
    on_secondary = "#e9edf5"
    on_tertiary = "#e9edf5"
    on_error = "#e9edf5"

    terminal_hues = _select_terminal_hues(image, accents)
    terminal_names = ("red", "green", "yellow", "blue", "magenta", "cyan")
    normal_levels = (0.52, 0.50, 0.49, 0.54, 0.52, 0.50)
    bright_levels = (0.57, 0.55, 0.54, 0.59, 0.57, 0.55)

    # Match the previous working integration: ANSI accents follow album-art
    # swatches. Their lightness is independently constrained for readability.
    terminal_normal = {"black": surface, "white": on_surface}
    terminal_bright = {"black": outline, "white": "#e9edf5"}
    for name, (hue, saturation), normal_lightness, bright_lightness in zip(
        terminal_names, terminal_hues, normal_levels, bright_levels
    ):
        terminal_normal[name] = _terminal_colour(
            hue, saturation, surface, normal_lightness, 4.5
        )
        terminal_bright[name] = _terminal_colour(
            hue, saturation, surface, bright_lightness, 4.5
        )

    dark = {
        "mPrimary": primary,
        "mOnPrimary": on_primary,
        "mSecondary": secondary,
        "mOnSecondary": on_secondary,
        "mTertiary": tertiary,
        "mOnTertiary": on_tertiary,
        "mError": error,
        "mOnError": on_error,
        "mSurface": surface,
        "mOnSurface": on_surface,
        "mSurfaceVariant": surface_variant,
        "mOnSurfaceVariant": on_surface_variant,
        "mOutline": outline,
        "mShadow": "#080910",
        "mHover": hover,
        "mOnHover": "#edf0f6",
        "terminal": {
            "background": surface,
            "foreground": on_surface,
            "cursor": primary,
            "cursorText": on_primary,
            "selectionBg": primary,
            "selectionFg": on_primary,
            "normal": terminal_normal,
            "bright": terminal_bright,
        },
    }
    return {"dark": dark}


def _darken_hex_lightness(colour: str, amount: float = 0.055) -> str:
    """Slightly lower HSL lightness while retaining the source hue/chroma."""
    rgb = tuple(int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
    hue, lightness, saturation = colorsys.rgb_to_hls(*rgb)
    return _hls_hex(hue, max(0.12, lightness - amount), saturation)


def _best_contrast_text(background: str) -> str:
    """Choose the darker or lighter neutral with the stronger contrast."""
    light, dark = "#f3f1ee", "#171411"
    return light if _contrast_ratio(light, background) >= _contrast_ratio(dark, background) else dark


def palette_from_noctalia_tokens(tokens: dict, *, mode: str = "dark") -> dict:
    """Convert one Noctalia CLI token map into a palette format 2 mode object."""
    if mode not in ("dark", "light"):
        raise ValueError("mode must be 'dark' or 'light'")
    role_keys = (
        "primary", "on_primary", "secondary", "on_secondary",
        "tertiary", "on_tertiary", "error", "on_error",
        "surface", "on_surface", "surface_container", "on_surface_variant",
        "outline_variant", "shadow", "hover", "on_hover",
    )
    terminal_direct = {
        "background": "terminal_background",
        "foreground": "terminal_foreground",
        "cursor": "terminal_cursor",
        "cursor_text": "terminal_cursor_text",
        "selection_fg": "terminal_selection_fg",
        "selection_bg": "terminal_selection_bg",
    }
    ansi_names = ("black", "red", "green", "yellow", "blue", "magenta", "cyan", "white")
    required = list(role_keys) + list(terminal_direct.values())
    required += [f"terminal_{group}_{name}" for group in ("normal", "bright") for name in ansi_names]
    if not isinstance(tokens, dict):
        raise ValueError("Noctalia theme output must be a JSON object")

    def is_hex_colour(value: object) -> bool:
        return (
            isinstance(value, str)
            and len(value) == 7
            and value[0] == "#"
            and all(character in "0123456789abcdefABCDEF" for character in value[1:])
        )

    missing = [key for key in required if not is_hex_colour(tokens.get(key))]
    if missing:
        raise ValueError("Noctalia theme output is missing required colour tokens: " + ", ".join(missing))

    palette = {key: tokens[key] for key in role_keys}
    if mode == "dark":
        # Keep surfaces exactly as Noctalia generated them. Only tone down the
        # accent/highlight fills slightly, then recalculate their foregrounds
        # so text remains readable on the adjusted colours.
        for role in ("primary", "secondary", "tertiary", "hover"):
            palette[role] = _darken_hex_lightness(palette[role])
            on_role = "on_" + role
            palette[on_role] = _best_contrast_text(palette[role])

    terminal = {key: tokens[token] for key, token in terminal_direct.items()}
    for group in ("normal", "bright"):
        terminal[group] = {name: tokens[f"terminal_{group}_{name}"] for name in ansi_names}
    palette["terminal"] = terminal
    return palette

def generate_palette(uri: str, destination: Path, *, scheme: str = "m3-content") -> dict:
    """Generate dark and light variants from the ORIGINAL cover using Noctalia.

    Noctalia remains the palette engine. The dark variant receives a small
    accent-lightness reduction; its surfaces and the entire light variant are
    left as generated by Noctalia.
    """
    artwork = load_artwork(uri)
    destination.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="spotify-ambient-theme-") as temp_dir:
        temp_root = Path(temp_dir)
        cover_path = temp_root / "source-cover.png"
        artwork.save(cover_path, "PNG", optimize=True)
        variants = {}
        for mode, flag in (("dark", "--dark"), ("light", "--light")):
            token_path = temp_root / f"noctalia-tokens-{mode}.json"
            command = [
                "noctalia", "theme", str(cover_path),
                "--scheme", scheme, flag,
                "--terminal-colors", "palette",
                "-o", str(token_path),
            ]
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=45, check=False)
            except FileNotFoundError as exc:
                raise RuntimeError("Noctalia CLI was not found; cannot use the native Noctalia palette generator") from exc
            except subprocess.TimeoutExpired as exc:
                raise RuntimeError(f"Noctalia {mode} palette generation timed out after 45 seconds") from exc
            if result.returncode != 0:
                detail = (result.stderr or result.stdout or "Noctalia theme command returned no diagnostic output").strip()
                raise RuntimeError(f"Noctalia {mode} palette generation failed (exit {result.returncode}): {detail}")
            if not token_path.is_file():
                raise RuntimeError(f"Noctalia {mode} theme command succeeded but did not create its token JSON")
            try:
                tokens = json.loads(token_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise RuntimeError(f"Could not read Noctalia {mode} theme tokens: {exc}") from exc
            variants[mode] = palette_from_noctalia_tokens(tokens, mode=mode)

    palette = {"version": 2, **variants}
    fd, temp_name = tempfile.mkstemp(prefix=".palette-", suffix=".json", dir=destination.parent)
    os.close(fd)
    try:
        with open(temp_name, "w", encoding="utf-8") as handle:
            json.dump(palette, handle, indent=2)
            handle.write("\n")
        os.replace(temp_name, destination)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
    return palette

def generate_and_apply_palette(
    uri: str,
    destination: Path,
    palette_name: str,
    lock_path: Path,
) -> None:
    """Generate and apply one palette while holding the shared shutdown lock.

    The lock is also acquired by detached service-exit cleanup. Keeping it for
    both generation and the Noctalia IPC apply prevents cleanup from restoring
    the previous theme between those two operations.
    """
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        generate_palette(uri, destination)
        try:
            result = subprocess.run(
                ["noctalia", "msg", "color-scheme-set", "custom", palette_name],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
        except FileNotFoundError as exc:
            raise RuntimeError("Noctalia CLI was not found; could not apply generated palette") from exc
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError("Noctalia color-scheme-set timed out after 15 seconds") from exc
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "Noctalia returned no diagnostic output").strip()
            raise RuntimeError(f"Noctalia color-scheme-set failed (exit {result.returncode}): {detail}")


def save_palette_preview(palette_data: dict, destination: Path, *, mode: str = "dark") -> None:
    """Render a compact swatch sheet for either generated palette variant."""
    from PIL import ImageFont

    palette = palette_data[mode]
    def role(current: str, legacy: str) -> str:
        return palette[current] if current in palette else palette[legacy]

    surface = role("surface", "mSurface")
    on_surface = role("on_surface", "mOnSurface")
    on_surface_variant = role("on_surface_variant", "mOnSurfaceVariant")
    width, height = 1280, 760
    canvas = Image.new("RGB", (width, height), surface)
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    small_font = ImageFont.load_default()

    draw.text((44, 28), f"SPOTIFY AMBIENT  /  NOCTALIA {mode.upper()} PALETTE", fill=on_surface, font=font)
    draw.text((44, 58), "Original album cover -> Noctalia M3 Content; ambient wallpaper is separate", fill=on_surface_variant, font=small_font)

    cards = [
        ("Surface", surface, on_surface),
        ("Surface container", role("surface_container", "mSurfaceVariant"), on_surface_variant),
        ("Primary", role("primary", "mPrimary"), role("on_primary", "mOnPrimary")),
        ("Secondary", role("secondary", "mSecondary"), role("on_secondary", "mOnSecondary")),
        ("Tertiary", role("tertiary", "mTertiary"), role("on_tertiary", "mOnTertiary")),
        ("Error", role("error", "mError"), role("on_error", "mOnError")),
        ("Hover", role("hover", "mHover"), role("on_hover", "mOnHover")),
        ("Outline", role("outline_variant", "mOutline"), on_surface),
    ]
    margin, gap = 44, 18
    card_w = (width - margin * 2 - gap * 3) // 4
    card_h = 190
    for index, (label, background, foreground) in enumerate(cards):
        row, column = divmod(index, 4)
        x = margin + column * (card_w + gap)
        y = 105 + row * (card_h + gap)
        draw.rounded_rectangle((x, y, x + card_w, y + card_h), radius=16, fill=background)
        draw.text((x + 18, y + 18), label, fill=foreground, font=font)
        draw.text((x + 18, y + 76), "Aa 0123", fill=foreground, font=font)
        draw.text((x + 18, y + 145), background.upper(), fill=foreground, font=small_font)

    strip_y = 530
    draw.text((margin, strip_y), "TERMINAL ANSI COLOURS", fill=on_surface, font=font)
    terminal = palette["terminal"]
    ansi = list(terminal["normal"].values()) + list(terminal["bright"].values())
    chip_gap = 7
    chip_w = (width - margin * 2 - chip_gap * 15) // 16
    for index, colour in enumerate(ansi):
        x = margin + index * (chip_w + chip_gap)
        draw.rounded_rectangle((x, strip_y + 38, x + chip_w, strip_y + 92), radius=7, fill=colour)

    draw.rounded_rectangle((margin, 680, width - margin, 724), radius=10, fill=terminal["background"])
    draw.text((margin + 18, 694), "Terminal preview: $ spotify-ambient  —  Noctalia-generated ANSI colours", fill=terminal["foreground"], font=font)

    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination, "PNG", optimize=True)


if __name__ == "__main__":
    raise SystemExit(main())
