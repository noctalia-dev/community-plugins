#!/usr/bin/env python3
"""Capturas de las ventanas flotantes para el panel de Noctalia.

El plugin escribe un JSON con las ventanas que quiere capturar.

MÉTODOS DE CAPTURA:
1. SOLO VENTANA REAL (primario): grim -T <stableId>
   Hyprland expone un identificador estable del toplevel (`stableId`). grim
   puede capturar ese toplevel directamente, sin importar qué ventana, panel,
   barra o notificación esté por encima. No toca el z-order ni mueve nada.

2. Fallback antiguo: alterzorder top -> grim -g -> alterzorder bottom
   Solo si el cliente no tiene stableId. Puede incluir capas por encima
   (paneles layer-shell), por eso ya no es el método preferido.

3. Último recurso: geometría exacta (grim -g "x,y WxH")
   Puede incluir cualquier cosa que esté por encima de la ventana.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time


def _save_resized(raw: str, target_w: int, target_h: int, out: str) -> None:
    """Convierte la captura temporal al tamaño de miniatura del panel."""
    from PIL import Image

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with Image.open(raw) as image:
        image = image.convert("RGB")
        if image.size != (target_w, target_h):
            image = image.resize((target_w, target_h), Image.LANCZOS)
        image.save(out)


def capture_toplevel(stable_id: str, target_w: int, target_h: int, out: str) -> bool:
    """Captura SOLO esa ventana con `grim -T <stableId>`.

    Es una captura del buffer del toplevel: no importa si hay otras ventanas,
    el panel de Noctalia, una barra o una notificación por encima. Tampoco
    cambia el orden de las ventanas.
    """
    handle, raw = tempfile.mkstemp(prefix="fterm-", suffix=".png")
    os.close(handle)
    try:
        # La ventana puede tardar un instante en estar mapeada tras abrirse:
        # se reintenta un par de veces antes de darla por perdida.
        for attempt in range(3):
            try:
                subprocess.run(
                    ["grim", "-T", str(stable_id), raw],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                )
                _save_resized(raw, target_w, target_h, out)
                return True
            except Exception:
                if attempt == 2:
                    return False
                time.sleep(0.08)
        return False
    finally:
        try:
            os.unlink(raw)
        except OSError:
            pass


def run_hyprctl(args: list[str], timeout: float = 3.0) -> subprocess.CompletedProcess:
    """Ejecuta hyprctl con args y retorna CompletedProcess."""
    return subprocess.run(
        ["hyprctl"] + args,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def raise_window(address: str) -> bool:
    """Sube la ventana al tope del stack (layer top). Retorna True si ok."""
    try:
        result = run_hyprctl(["dispatch", "alterzorder", f"top,address:{address}"])
        return result.returncode == 0
    except Exception:
        return False


def lower_window(address: str) -> bool:
    """Baja la ventana al bottom del stack. Retorna True si ok."""
    try:
        result = run_hyprctl(["dispatch", "alterzorder", f"bottom,address:{address}"])
        return result.returncode == 0
    except Exception:
        return False


def capture_window_only(address: str, x: int, y: int, w: int, h: int,
                         target_w: int, target_h: int, out: str) -> bool:
    """Captura SOLO la ventana: la sube al tope, captura geometría, la baja.

    Esto evita que se capturen ventanas/capas que estén por encima.
    """
    # 1. Subir ventana
    if not raise_window(address):
        return False

    # Pequeña pausa para que el compositor procese el z-order change
    time.sleep(0.05)

    try:
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        handle, raw = tempfile.mkstemp(prefix="fterm-", suffix=".png")
        os.close(handle)

        command = ["grim", "-g", f"{x},{y} {w}x{h}", raw]

        subprocess.run(
            command,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=5.0,
        )
        _save_resized(raw, target_w, target_h, out)
        return True
    except Exception:
        return False
    finally:
        # 2. Restaurar z-order (bajar ventana)
        time.sleep(0.02)
        lower_window(address)
        try:
            os.unlink(raw)
        except Exception:
            pass


def capture_output_geometry(item: dict, scales: dict[str, float]) -> bool:
    """Captura por geometría exacta de la ventana (grim -g).

    Captura el rectángulo exacto de la ventana en coordenadas de pantalla.
    Nota: puede incluir cosas que estén por encima (otras ventanas, capas).
    El panel evita capturar cuando isCovered() detecta solapamiento.
    """
    out = str(item["out"])
    x = int(item["x"])
    y = int(item["y"])
    w = int(item["w"])
    h = int(item["h"])
    target_w = max(16, int(item.get("width", 320)))
    target_h = max(16, int(item.get("height", 190)))

    if w <= 0 or h <= 0:
        raise ValueError("ventana sin tamaño")

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    handle, raw = tempfile.mkstemp(prefix="fterm-", suffix=".png")
    os.close(handle)

    # Captura la geometría EXACTA de la ventana (sin output, solo geometría)
    command = ["grim", "-g", f"{x},{y} {w}x{h}", raw]

    try:
        subprocess.run(
            command,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        _save_resized(raw, target_w, target_h, out)
    finally:
        try:
            os.unlink(raw)
        except OSError:
            pass
    return True


def output_scale(output: str, cache: dict[str, float]) -> float:
    """Factor de escala de la salida (Hyprland), 1.0 si no se puede saber."""
    if output in cache:
        return cache[output]
    try:
        result = subprocess.run(
            ["hyprctl", "monitors", "-j"],
            capture_output=True,
            text=True,
            timeout=4.0,
        )
        monitors = json.loads(result.stdout)
    except Exception:  # noqa: BLE001 - sin hyprctl se asume escala 1
        cache[output] = 1.0
        return 1.0
    if not isinstance(monitors, list):
        cache[output] = 1.0
        return 1.0
    for monitor in monitors:
        if isinstance(monitor, dict) and monitor.get("name") == output:
            try:
                scale = float(monitor.get("scale") or 1.0)
            except (TypeError, ValueError):
                scale = 1.0
            cache[output] = scale
            return scale
    cache[output] = 1.0
    return 1.0


def capture(item: dict, scales: dict[str, float]) -> None:
    """Captura una ventana.

    Prioridad:
      1. `stable_id` -> grim -T (solo el contenido de esa ventana).
      2. `address`   -> subir/capturar/bajar (fallback antiguo).
      3. geometría   -> grim -g (último recurso).

    Si item tiene "current_out", también guarda una copia allí para el preview principal.
    """
    out = str(item["out"])
    x = int(item["x"])
    y = int(item["y"])
    w = int(item["w"])
    h = int(item["h"])
    target_w = max(16, int(item.get("width", 320)))
    target_h = max(16, int(item.get("height", 190)))
    current_out = item.get("current_out")
    address = item.get("address")
    stable_id = item.get("stable_id") or item.get("stableId")

    if w <= 0 or h <= 0:
        raise ValueError("ventana sin tamaño")

    def copy_current() -> None:
        if current_out:
            try:
                shutil.copy2(out, current_out)
            except Exception:
                pass

    # MODO 1: captura directa del toplevel (solo la ventana, sin capas encima).
    if stable_id:
        if capture_toplevel(str(stable_id), target_w, target_h, out):
            copy_current()
            return
        # Si el toplevel aún no está listo, se omite esta ronda. Capturar por
        # geometría guardaría el escritorio o lo que haya encima, que es
        # justo lo que queremos evitar.
        return

    # MODO 2: captura SOLO VENTANA por z-order (clientes sin stableId).
    if address:
        ok = capture_window_only(address, x, y, w, h, target_w, target_h, out)
        if ok:
            copy_current()
            return
        # Si falla, cae al método fallback

    # MODO 3: Fallback - geometría exacta (puede incluir cosas por encima)
    capture_output_geometry(item, scales)

    copy_current()


def main() -> int:
    if len(sys.argv) != 2:
        print("uso: snapshot.py <lote.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        items = json.load(handle)

    failures = 0
    scales: dict[str, float] = {}
    for item in items:
        try:
            capture(item, scales)
        except Exception as exc:  # noqa: BLE001 - un fallo no debe parar el lote
            failures += 1
            print(f"snapshot: {item.get('out')}: {exc}", file=sys.stderr)

    return 1 if failures and failures == len(items) else 0


if __name__ == "__main__":
    sys.exit(main())
