#!/usr/bin/env python3
"""Extrae los fotogramas de un GIF a PNG para poder animarlo en el panel.

`ui.image` de Noctalia pinta solo el primer fotograma de un GIF animado, así
que el plugin extrae cada fotograma a un PNG y los intercambia con un tick de
frames. Este script deja los PNG y un `manifest.json` con las duraciones en el
directorio que le pasa el plugin.

Uso:
    gif-frames.py <archivo.gif> <directorio_salida>
"""
from __future__ import annotations

import json
import os
import sys

try:
    from PIL import Image, ImageSequence
except Exception as exc:  # pragma: no cover - depende del sistema
    print(f"Pillow no disponible: {exc}", file=sys.stderr)
    raise SystemExit(2)

# Los GIF muy largos se recortan para no llenar el disco ni el presupuesto de
# CPU del panel; con 120 fotogramas hay de sobra para una miniatura.
MAX_FRAMES = 120
MAX_WIDTH = 320


def main() -> int:
    if len(sys.argv) != 3:
        print("uso: gif-frames.py <archivo.gif> <directorio_salida>", file=sys.stderr)
        return 1

    source, outdir = sys.argv[1], sys.argv[2]
    if not os.path.isfile(source):
        print(f"no existe: {source}", file=sys.stderr)
        return 1

    os.makedirs(outdir, exist_ok=True)

    # Limpiar fotogramas de una extracción anterior para no mezclar versiones.
    for name in os.listdir(outdir):
        if name.startswith("frame-") and name.endswith(".png"):
            try:
                os.remove(os.path.join(outdir, name))
            except OSError:
                pass

    frames: list[str] = []
    durations: list[int] = []

    with Image.open(source) as image:
        for index, frame in enumerate(ImageSequence.Iterator(image)):
            if index >= MAX_FRAMES:
                break
            rgba = frame.convert("RGBA")
            width, height = rgba.size
            if width > MAX_WIDTH:
                new_height = max(1, round(height * MAX_WIDTH / width))
                rgba = rgba.resize((MAX_WIDTH, new_height), Image.BILINEAR)
            name = f"frame-{index:03d}.png"
            rgba.save(os.path.join(outdir, name), "PNG", optimize=True)
            frames.append(name)
            # Pillow expone la duración en milisegundos; algunos GIF usan 0
            # para "lo antes posible", que interpretamos como 100 ms.
            duration = int(frame.info.get("duration", 100) or 100)
            durations.append(max(20, duration))

    if not frames:
        print("el GIF no produjo fotogramas", file=sys.stderr)
        return 1

    manifest = {
        "frames": frames,
        "durations": durations,
        "mtime": int(os.path.getmtime(source)),
    }
    with open(os.path.join(outdir, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
