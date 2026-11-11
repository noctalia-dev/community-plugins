"""Synthesize the bundled notification sounds (soft, short, no clipping).

Run: python tools/make_sounds.py   -> writes resources/sounds/*.wav
"""
import math
import struct
import wave
from pathlib import Path

RATE = 44100
OUT = Path(__file__).resolve().parent.parent / "resources" / "sounds"


def note(freq, start, length, amp, decay, partials=((1, 1.0),), attack=0.012):
    """A decaying tone: (start sample, samples) with a soft attack."""
    n = int(length * RATE)
    data = []
    for i in range(n):
        t = i / RATE
        env = (min(1.0, t / attack)) * math.exp(-t * decay)
        v = sum(w * math.sin(2 * math.pi * freq * m * t) for m, w in partials)
        data.append(amp * env * v)
    return int(start * RATE), data


def render(name, notes, total):
    buf = [0.0] * int(total * RATE)
    for start, data in notes:
        for i, v in enumerate(data):
            if start + i < len(buf):
                buf[start + i] += v
    peak = max(abs(v) for v in buf) or 1.0
    scale = 0.6 / peak  # leave headroom; volume is applied at playback
    fade = int(0.05 * RATE)
    for i in range(fade):
        buf[-1 - i] *= i / fade
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(v * scale * 32767)) for v in buf))


BELL = ((1, 1.0), (2.0, 0.25), (3.01, 0.08))       # warm, few overtones
MARIMBA = ((1, 1.0), (4.0, 0.15))                   # woody: strong 4th partial, fast decay

OUT.mkdir(parents=True, exist_ok=True)
# Soft chime: a single mellow tone with a quiet fifth above.
render("soft-chime", [note(659.25, 0, 2.2, 1.0, 2.2, BELL), note(987.77, 0.0, 2.2, 0.35, 2.6, BELL)], 2.3)
# Gentle bell: rising major third, unhurried.
render("gentle-bell", [note(587.33, 0, 1.6, 1.0, 2.4, BELL), note(739.99, 0.32, 1.9, 0.9, 2.2, BELL)], 2.3)
# Wood: two short marimba taps, falling — reads as "time to switch".
render("wood", [note(783.99, 0, 0.6, 1.0, 9.0, MARIMBA, 0.004), note(587.33, 0.18, 0.8, 0.9, 7.0, MARIMBA, 0.004)], 1.0)
print("wrote", sorted(p.name for p in OUT.glob("*.wav")))
