#!/usr/bin/env python3
"""Generate seamless native SVG loops from Thinking Orbs' MIT orbit language."""

# State vocabulary and geometry derived from Jakub Antalik's Thinking Orbs
# (MIT, 2026): https://github.com/Jakubantalik/thinking-orbs

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path

OUT = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "agentik/orbs"
FPS = 30
LOOP_SECONDS = 2
FRAMES = FPS * LOOP_SECONDS
STATES = ("working", "searching", "solving", "listening", "connecting", "weaving", "composing", "breathing", "shaping", "done")
ATTENTION_STATES = ("waiting", "blocked")
PROGRESS_STEPS = 8
PROGRESS_FRAME_SUBSTEPS = 30
PROGRESS_FRAMES = PROGRESS_STEPS * PROGRESS_FRAME_SUBSTEPS
TAU = math.tau

Dot = tuple[float, float, float, float, float, float]

def write_asset(path: Path, content: str) -> None:
    """Atomically update a frame without leaving the live renderer assetless."""
    if path.is_file() and path.read_text(encoding="utf-8") == content:
        return
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)
Line = tuple[float, float, float, float, float, float, float]


def clamp(value: float, low: float = 0, high: float = 1) -> float:
    return max(low, min(high, value))


def frac(value: float) -> float:
    return value - math.floor(value)


def hash_d(a: float, b: float) -> float:
    value = math.sin(a * 12.9898 + b * 78.233) * 43758.5453
    return frac(value)


def svg_number(value: float, precision: int) -> str:
    """Serialize the same rounded SVG number without redundant zeroes."""
    result = f"{value:.{precision}f}".rstrip("0").rstrip(".")
    if result in {"-0", ""}:
        return "0"
    if result.startswith("0."):
        return result[1:]
    if result.startswith("-0."):
        return "-" + result[2:]
    return result


def gray_color(white: float) -> str:
    """Return the shortest exact hexadecimal form of a grayscale color."""
    component = round((1 - clamp(white)) * 255)
    pair = f"{component:02x}"
    return f"#{pair[0] * 3}" if pair[0] == pair[1] else f"#{pair * 3}"


def fib_dir(index: int, total: int) -> tuple[float, float, float]:
    golden = math.pi * (3 - math.sqrt(5))
    y = 1 - (2 * (index + 0.5)) / total
    radial = math.sqrt(max(0, 1 - y * y))
    angle = index * golden
    return radial * math.cos(angle), y, radial * math.sin(angle)


def noise(x: float, y: float) -> float:
    xi, yi = math.floor(x), math.floor(y)
    fx, fy = x - xi, y - yi
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b, c, d = hash_d(xi, yi), hash_d(xi + 1, yi), hash_d(xi, yi + 1), hash_d(xi + 1, yi + 1)
    return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy


def projector(yaw: float, tilt: float, cx: float, cy: float, scale: float):
    sin_tilt, cos_tilt = math.sin(tilt), math.cos(tilt)
    sin_yaw, cos_yaw = math.sin(yaw), math.cos(yaw)

    def project(x: float, y: float, z: float) -> tuple[float, float, float]:
        x1 = x * cos_yaw + z * sin_yaw
        z1 = -x * sin_yaw + z * cos_yaw
        y1 = y * cos_tilt - z1 * sin_tilt
        return cx + x1 * scale, cy - y1 * scale, y * sin_tilt + z1 * cos_tilt

    return project


def add_orbits(dots: list[Dot], size: int, phase: float, density: float, radius_mul: float) -> None:
    cx = cy = size / 2
    orbit_radius = size * 0.41
    scale = (size / 300) ** 0.6
    orbit_count = max(2, round(12 * density))
    ghost_count = max(6, round(40 * density))
    project = projector(phase, 0.3, cx, cy, 1)
    for orbit in range(orbit_count):
        h1, h2, h3 = hash_d(orbit, 1.7), hash_d(orbit, 5.2), hash_d(orbit, 8.9)
        radius = orbit_radius * (0.45 + 0.52 * h1)
        theta, phi = h1 * TAU, math.acos(2 * h2 - 1)
        nx, ny, nz = math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta)
        ux, uy = -ny, nx
        length = max(1e-6, math.hypot(ux, uy))
        ux, uy = ux / length, uy / length
        vx, vy, vz = -nz * uy, nz * ux, nx * uy - ny * ux
        for point in range(ghost_count):
            angle = point / ghost_count * TAU
            x, y, z = project((ux * math.cos(angle) + vx * math.sin(angle)) * radius, (uy * math.cos(angle) + vy * math.sin(angle)) * radius, vz * math.sin(angle) * radius)
            depth = (z / radius + 1) / 2
            dots.append((x, y, z, max(0.3, 0.9 * radius_mul * scale), 0.72, 0.5 * (0.4 + 0.6 * depth)))
        for particle in range(3):
            angle = phase * (1 + orbit % 3) + particle / 3 * TAU + h2 * 6
            x, y, z = project((ux * math.cos(angle) + vx * math.sin(angle)) * radius, (uy * math.cos(angle) + vy * math.sin(angle)) * radius, vz * math.sin(angle) * radius)
            depth = (z / radius + 1) / 2
            dots.append((x, y, z, max(0.3, (1.2 + 1.6 * depth) * radius_mul * scale), 0.3 - 0.22 * depth, 1))


def add_lattice(dots: list[Dot], size: int, phase: float, state: str, density: float, radius_mul: float) -> None:
    cx = cy = size / 2
    sphere_radius = size * (0.41 if state != "listening" else 0.437)
    scale = (size / 300) ** 0.6
    rings = max(4, round((17 if state == "searching" else 15) * math.sqrt(density)))
    longitude_density = max(8, round((44 if state == "searching" else 40) * math.sqrt(density)))
    project = projector(phase, 0.38 + 0.06 * math.sin(phase), cx, cy, sphere_radius)
    for ring in range(rings + 1):
        latitude = -math.pi / 2 + ring / rings * math.pi
        cos_lat, sin_lat = math.cos(latitude), math.sin(latitude)
        longitude_count = max(1, round(abs(cos_lat) * longitude_density))
        wave = 0.62 * math.sin(phase * 3 - ring * 0.52) + 0.38 * math.sin(phase * 2 + ring * 0.83)
        for longitude_index in range(longitude_count):
            longitude = longitude_index / longitude_count * TAU
            x, y, z = cos_lat * math.cos(longitude), sin_lat, cos_lat * math.sin(longitude)
            active = 0
            if state == "solving":
                band = math.sin(phase * 2 + ring * 0.8)
                angle = band * math.pi / 4
                x, z = x * math.cos(angle) - z * math.sin(angle), x * math.sin(angle) + z * math.cos(angle)
                active = abs(band)
            if state == "listening":
                wobble = 1 + 0.105 * wave
                x, y, z = x * wobble, y * wobble, z * wobble
            px, py, depth_z = project(x, y, z)
            depth = (depth_z / sphere_radius + 1) / 2
            if state == "searching":
                delta = math.atan2(math.sin(longitude - phase * 3), math.cos(longitude - phase * 3))
                scan = math.exp(-(delta * delta) / 0.18) * max(0, depth_z / sphere_radius)
                dots.append((px, py, depth_z, max(0.3, (0.6 + 1.7 * depth + scan) * radius_mul * scale), 0.62 - 0.54 * depth, 0.45 + 0.55 * scan))
            else:
                crest = max(0, wave) if state == "listening" else 0
                dots.append((px, py, depth_z, max(0.3, (0.6 + 1.7 * depth + 0.3 * active) * (1 + 0.4 * crest) * radius_mul * scale), 0.66 - 0.56 * depth - 0.1 * crest - 0.14 * active, 1))


def add_web(dots: list[Dot], lines: list[Line], size: int, phase: float, density: float, radius_mul: float) -> None:
    cx = cy = size / 2
    sphere_radius = size * 0.4
    scale = (size / 300) ** 0.6
    count = max(8, round(30 * density))
    threshold = 0.72
    project = projector(phase, 0.32, cx, cy, sphere_radius)
    nodes = []
    for index in range(count):
        x, y, z = fib_dir(index, count)
        x += 0.3 * math.sin(phase + index * 0.31)
        y += 0.3 * math.sin(phase * 2 + index * 0.53)
        z += 0.3 * math.sin(phase * 3 + index * 0.77)
        length = math.sqrt(x * x + y * y + z * z)
        nodes.append((x / length, y / length, z / length))
    for first in range(count):
        for second in range(first + 1, count):
            dx, dy, dz = nodes[first][0] - nodes[second][0], nodes[first][1] - nodes[second][1], nodes[first][2] - nodes[second][2]
            distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            if distance >= threshold:
                continue
            x1, y1, z1 = project(*nodes[first])
            x2, y2, z2 = project(*nodes[second])
            depth = ((z1 + z2) / sphere_radius + 1) / 2
            lines.append((x1, y1, x2, y2, max(0.4, 0.8 * scale), 0.42, (1 - distance / threshold) * (0.3 + 0.55 * depth)))
    for index, node in enumerate(nodes):
        x, y, z = project(*node)
        depth = (z / sphere_radius + 1) / 2
        pulse = 1 + 0.25 * math.sin(phase * 2 + index * 2.7)
        dots.append((x, y, z, max(0.3, (1.4 + 1.8 * depth) * pulse * radius_mul * scale), 0.55 - 0.45 * depth, 1))
    for signal in range(max(2, round(5 * density))):
        first, second = signal % count, (signal * 7 + 3) % count
        progress = frac(phase / TAU * (1 + signal % 3) + signal / 5)
        x = nodes[first][0] + (nodes[second][0] - nodes[first][0]) * progress
        y = nodes[first][1] + (nodes[second][1] - nodes[first][1]) * progress
        z = nodes[first][2] + (nodes[second][2] - nodes[first][2]) * progress
        length = math.sqrt(x * x + y * y + z * z)
        px, py, depth_z = project(x / length, y / length, z / length)
        depth = (depth_z / sphere_radius + 1) / 2
        dots.append((px, py, depth_z, max(0.3, (2.1 + 1.8 * depth) * radius_mul * scale), 0.05, 0.5 + 0.5 * depth))


def add_braid(dots: list[Dot], size: int, phase: float, density: float, radius_mul: float) -> None:
    cx = cy = size / 2
    sphere_radius = size * 0.38
    scale = (size / 300) ** 0.6
    project = projector(phase, 0.3, cx, cy, 1)
    for index in range(max(12, round(150 * density))):
        x, y, z = fib_dir(index, max(12, round(150 * density)))
        px, py, depth_z = project(x * sphere_radius, y * sphere_radius, z * sphere_radius)
        depth = (depth_z / sphere_radius + 1) / 2
        dots.append((px, py, depth_z, max(0.3, 0.8 * scale), 0.78, 0.1 + 0.22 * depth))
    strand_count = max(10, round(52 * density))
    for strand in range(3):
        offset = strand / 3 * TAU
        for index in range(strand_count):
            u = ((index / strand_count + phase / TAU) % 1 * 2 - 1) * 0.96
            surface = math.sqrt(max(0, 1 - u * u))
            angle = u * math.pi * 3 + offset
            weave = 1 + 0.075 * math.sin(u * math.pi * 6 + offset * 2 + phase * 2)
            px, py, depth_z = project(math.cos(angle) * surface * sphere_radius * weave, u * sphere_radius * weave, math.sin(angle) * surface * sphere_radius * weave)
            depth = (depth_z / sphere_radius + 1) / 2
            end_fade = min(1, (1 - abs(u)) / 0.1)
            dots.append((px, py, depth_z, max(0.3, (1.2 + 1.8 * depth) * radius_mul * scale), 0.55 - 0.45 * depth, end_fade * (0.45 + 0.55 * depth)))


def add_ribbon(dots: list[Dot], size: int, phase: float, state: str, density: float, radius_mul: float) -> None:
    cx = cy = size / 2
    sphere_radius = size * 0.39
    scale = (size / 300) ** 0.6
    face_on = state == "breathing"
    lanes = max(2, round(5 * density * (4.2 if face_on else 4)))
    segments = max(12, round(88 * math.sqrt(density)))
    project = projector(0 if face_on else phase, 0 if face_on else 0.3, cx, cy, 1)
    for lane in range(lanes):
        lane_offset = (lane - (lanes - 1) / 2) * 0.03
        edge = abs(lane - (lanes - 1) / 2) / max(1, (lanes - 1) / 2)
        for segment in range(segments):
            angle = segment / segments * TAU
            wobble = (0.16 * math.sin(angle * 3 - phase * 3 + lane * 0.22) + 0.07 * math.sin(angle * 5 + phase * 2)) * (0.58 if face_on else 1)
            radius = sphere_radius * (1 + wobble) if face_on else sphere_radius
            x, y, z = math.cos(angle), math.sin(angle), lane_offset + (0 if face_on else wobble)
            length = math.sqrt(x * x + y * y + z * z)
            px, py, depth_z = project(x / length * radius, y / length * radius, z / length * radius)
            depth = (depth_z / sphere_radius + 1) / 2
            dots.append((px, py, depth_z, max(0.3, (1.1 + 1.7 * depth) * (1 - 0.25 * edge) * radius_mul * scale), 0.52 - 0.44 * depth + 0.18 * edge, 0.4 + 0.6 * depth))


def add_done(dots: list[Dot], size: int, phase: float, density: float, radius_mul: float) -> None:
    """Render a rotating sparkling completion orb."""
    cx = cy = size / 2
    sphere_radius = size * 0.38
    scale = (size / 300) ** 0.6
    pulse = 1
    project = projector(phase, 0.34, cx, cy, sphere_radius)
    count = max(10, round(96 * density))
    for index in range(count):
        x, y, z = fib_dir(index, count)
        px, py, depth_z = project(x, y, z)
        depth = (z + 1) / 2
        dots.append((
            px,
            py,
            depth_z,
            max(0.3, (0.9 + 1.25 * depth) * radius_mul * scale * pulse),
            0.62 - 0.42 * depth,
            0.38 + 0.5 * depth,
        ))

def polygon(vertices: list[tuple[float, float]], fraction: float) -> tuple[float, float]:
    lengths = [math.dist(vertices[index], vertices[(index + 1) % len(vertices)]) for index in range(len(vertices))]
    target = fraction * sum(lengths)
    for index, length in enumerate(lengths):
        if target <= length:
            a, b = vertices[index], vertices[(index + 1) % len(vertices)]
            ratio = target / length if length else 0
            return a[0] + (b[0] - a[0]) * ratio, a[1] + (b[1] - a[1]) * ratio
        target -= length
    return vertices[-1]


def add_morph(dots: list[Dot], size: int, phase: float, density: float, radius_mul: float) -> None:
    shapes = (
        lambda fraction: (math.cos(-math.pi / 2 + fraction * TAU) * 0.24, math.sin(-math.pi / 2 + fraction * TAU) * 0.24),
        lambda fraction: polygon([(0, -0.26), (0.24, 0.16), (-0.24, 0.16)], fraction),
        lambda fraction: polygon([(0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)], fraction),
    )
    slot = phase / TAU * len(shapes)
    first = int(slot) % len(shapes)
    blend = slot - math.floor(slot)
    blend = blend * blend * (3 - 2 * blend)
    count = max(6, round(34 * density))
    pulse = 1 + 0.02 * math.sin(phase * 3)
    for index in range(count):
        fraction = index / count
        a, b = shapes[first](fraction), shapes[(first + 1) % len(shapes)](fraction)
        x, y = (a[0] + (b[0] - a[0]) * blend) * size * 1.45 * pulse, (a[1] + (b[1] - a[1]) * blend) * size * 1.45 * pulse
        dots.append((size / 2 + x, size / 2 + y, 0, max(0.35, 0.021 * 1.35 * size * radius_mul), 0.1, 1))

def attention_ring(size: int, phase: float, attention: str) -> str:
    """Render a restrained urgency ring behind a state orb."""
    cx = cy = size / 2
    pulse = 0.5 + 0.5 * math.sin(phase * 2)
    color = "#ffb74d" if attention == "waiting" else "#ef5350"
    radius = size * (0.425 + 0.025 * pulse)
    opacity = 0.38 + 0.32 * pulse
    width = max(0.7, size * 0.045)
    return (
        f'<circle cx="{svg_number(cx, 2)}" cy="{svg_number(cy, 2)}" '
        f'r="{svg_number(radius, 2)}" fill="none" stroke="{color}" '
        f'stroke-opacity="{svg_number(opacity, 3)}" stroke-width="{svg_number(width, 2)}"/>'
    )


def render_progress(progress: float) -> str:
    """Render an orb-sized determinate counterclockwise progress ring."""
    size = 20
    cx = cy = size / 2
    radius = 7.5
    circumference = TAU * radius
    fraction = max(0.0, min(float(PROGRESS_STEPS), progress)) / PROGRESS_STEPS
    dash = circumference * fraction
    gap = circumference - dash
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}">'
        f'<circle cx="{cx}" cy="{cy}" r="{radius}" fill="none" stroke="rgb(120,120,120)" '
        f'stroke-opacity="0.45" stroke-width="2.5"/>'
        f'<circle cx="{cx}" cy="{cy}" r="{radius}" fill="none" stroke="rgb(235,235,235)" '
        f'stroke-width="2.5" stroke-linecap="round" stroke-dasharray="{dash:.3f} {gap:.3f}" '
        f'transform="matrix(-1 0 0 1 {size} 0) rotate(-90 {cx} {cy})"/>'
        '</svg>'
    )


def render_phase(state: str, size: int, phase: float, attention: str | None = None) -> str:
    phase = phase % TAU
    density, radius_mul = (0.25, 2.2)
    if size not in (20, 64):
        raise ValueError(f"unsupported orb size: {size}")
    dots: list[Dot] = []
    lines: list[Line] = []
    if state == "working":
        add_orbits(dots, size, phase, density, radius_mul)
    elif state in {"searching", "solving", "listening"}:
        add_lattice(dots, size, phase, state, density, radius_mul)
    elif state == "connecting":
        add_web(dots, lines, size, phase, density, radius_mul)
    elif state == "weaving":
        add_braid(dots, size, phase, density, radius_mul)
    elif state in {"composing", "breathing"}:
        add_ribbon(dots, size, phase, state, density, radius_mul)
    elif state == "done":
        add_done(dots, size, phase, density, radius_mul)
    else:
        add_morph(dots, size, phase, density, radius_mul)
    circles = [
        f'<circle cx="{svg_number(x, 2)}" cy="{svg_number(y, 2)}" '
        f'r="{svg_number(radius, 2)}" fill="{gray_color(white)}"'
        + ("" if alpha == 1 else f' fill-opacity="{svg_number(alpha, 3)}"') + "/>"
        for x, y, z, radius, white, alpha in sorted(dots, key=lambda dot: dot[2])
        if alpha >= 0.02
    ]
    strokes = [
        f'<line x1="{svg_number(x1, 2)}" y1="{svg_number(y1, 2)}" '
        f'x2="{svg_number(x2, 2)}" y2="{svg_number(y2, 2)}" '
        f'stroke="{gray_color(white)}" stroke-opacity="{svg_number(alpha, 3)}" '
        f'stroke-width="{svg_number(width, 2)}"/>'
        for x1, y1, x2, y2, width, white, alpha in lines
        if alpha >= 0.02
    ]
    ring = attention_ring(size, phase, attention) if attention in ATTENTION_STATES else ""
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}">{ring}{"".join(strokes)}{"".join(circles)}</svg>'

def render(
    state: str,
    size: int,
    index: int,
    attention: str | None = None,
    *,
    frames: int = FRAMES,
) -> str:
    return render_phase(state, size, TAU * (index % frames) / frames, attention)


def manifest_data(fps: int) -> dict[str, int | str]:
    return {
        "schema_version": 1,
        "fps": fps,
        "frame_count": fps * LOOP_SECONDS,
        "loop_seconds": LOOP_SECONDS,
        "source": "https://github.com/Jakubantalik/thinking-orbs",
        "license": "MIT",
        "copyright": "Copyright (c) 2026 Jakub Antalik",
    }


def manifest(fps: int) -> str:
    return json.dumps(manifest_data(fps), indent=2, sort_keys=True) + "\n"


def current_pack(output: Path) -> dict[str, int | str] | None:
    try:
        current = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(current, dict) or current.get("fps") not in (30, 60):
        return None
    expected = manifest_data(int(current["fps"]))
    return expected if current == expected else None


def generate(output: Path, fps: int) -> dict[str, int | str]:
    if fps not in (30, 60):
        raise ValueError("orb FPS must be 30 or 60")
    frames = fps * LOOP_SECONDS
    output.mkdir(parents=True, exist_ok=True)
    manifest_path = output / "manifest.json"
    manifest_path.unlink(missing_ok=True)
    expected = {
        f"{state}-{size}-{index}.svg"
        for state in STATES
        for size in (20, 64)
        for index in range(frames)
    }
    expected.update({
        f"{state}-{attention}-20-{index}.svg"
        for state in STATES if state != "done"
        for attention in ATTENTION_STATES
        for index in range(frames)
    })
    expected.update(f"progress-{step}.svg" for step in range(PROGRESS_STEPS + 1))
    expected.update(f"progress-transition-{frame}.svg" for frame in range(PROGRESS_FRAMES + 1))
    for state in STATES:
        for size in (20, 64):
            for index in range(frames):
                write_asset(output / f"{state}-{size}-{index}.svg", render(state, size, index, frames=frames))
        if state != "done":
            for attention in ATTENTION_STATES:
                for index in range(frames):
                    write_asset(
                        output / f"{state}-{attention}-20-{index}.svg",
                        render(state, 20, index, attention, frames=frames),
                    )
    for step in range(PROGRESS_STEPS + 1):
        write_asset(output / f"progress-{step}.svg", render_progress(step))
    for frame in range(PROGRESS_FRAMES + 1):
        write_asset(
            output / f"progress-transition-{frame}.svg",
            render_progress(frame / PROGRESS_FRAME_SUBSTEPS),
        )
    for path in output.glob("*.svg"):
        if path.name not in expected:
            path.unlink()
    write_asset(manifest_path, manifest(fps))
    return manifest_data(fps)


def payload(output: Path, data: dict[str, int | str]) -> dict[str, int | str | bool]:
    return {"ready": True, "directory": str(output), **data}


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate attributed Agentik orb frames")
    parser.add_argument("--fps", type=int, choices=(30, 60))
    parser.add_argument("--output", type=Path, default=OUT)
    parser.add_argument(
        "--ensure",
        action="store_true",
        help="reuse a complete supported pack, generating the 30 FPS default only when absent",
    )
    args = parser.parse_args()
    data = current_pack(args.output) if args.ensure and args.fps is None else None
    if data is None:
        data = generate(args.output, args.fps or FPS)
    print(json.dumps(payload(args.output, data), sort_keys=True))


if __name__ == "__main__":
    main()
