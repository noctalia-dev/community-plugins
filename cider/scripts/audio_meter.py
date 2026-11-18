#!/usr/bin/env python3
"""Lightweight system-audio energy meter via Pulse/PipeWire monitor.

Uses `parec` on `@DEFAULT_MONITOR@` (stdlib only). Not vocal isolation — quiet
intros/interludes register as silent; soft instrumentals may too.
"""

from __future__ import annotations

import math
import shutil
import struct
import subprocess
import threading
import time
from typing import Any


RATE = 8000
CHANNELS = 1
SAMPLE_BYTES = 2  # s16le
CHUNK_SAMPLES = 400  # 50ms at 8kHz
CHUNK_BYTES = CHUNK_SAMPLES * CHANNELS * SAMPLE_BYTES
# How long level must stay on one side of the threshold before flipping.
SILENT_HOLD_MS = 280
ACTIVE_HOLD_MS = 90


def rms_s16le(chunk: bytes) -> float:
    """Peak-normalized RMS in 0..1 from little-endian int16 PCM."""
    if len(chunk) < SAMPLE_BYTES:
        return 0.0
    n = len(chunk) // SAMPLE_BYTES
    samples = struct.unpack("<" + ("h" * n), chunk[: n * SAMPLE_BYTES])
    if not samples:
        return 0.0
    mean_sq = sum(s * s for s in samples) / float(n)
    return min(1.0, math.sqrt(mean_sq) / 32768.0)


def level_from_rms(rms: float) -> float:
    """Map RMS to a 0..100 display/threshold scale (boosted for music monitors)."""
    return min(100.0, max(0.0, float(rms) * 400.0))


class AudioMeter:
    """Background `parec` reader. Fail-open: if capture dies, reports active."""

    def __init__(self) -> None:
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._proc: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()
        self._level = 0.0
        self._capture_ok = False
        self._want_active = True
        self._active = True
        self._pending_since = 0.0
        self._threshold = 8.0

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def set_threshold(self, threshold: float) -> None:
        self._threshold = max(1.0, min(40.0, float(threshold)))

    def start(self) -> None:
        if self.running:
            return
        if not shutil.which("parec"):
            with self._lock:
                self._capture_ok = False
                self._active = True
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._run, name="cider-audio-meter", daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        proc = self._proc
        if proc is not None:
            try:
                proc.terminate()
            except OSError:
                pass
        thread = self._thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=1.0)
        self._thread = None
        self._proc = None
        with self._lock:
            self._level = 0.0
            self._capture_ok = False

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "level": round(self._level, 2),
                "active": self._active if self._capture_ok else True,
                "capture_ok": self._capture_ok,
                "threshold": self._threshold,
            }

    def _set_level(self, level: float) -> None:
        now = time.time()
        want = level >= self._threshold
        with self._lock:
            self._level = level
            self._capture_ok = True
            if want == self._want_active:
                hold_ms = ACTIVE_HOLD_MS if want else SILENT_HOLD_MS
                if self._pending_since <= 0:
                    self._pending_since = now
                elif (now - self._pending_since) * 1000.0 >= hold_ms:
                    self._active = want
            else:
                self._want_active = want
                self._pending_since = now

    def _run(self) -> None:
        cmd = [
            "parec",
            "--raw",
            "--record",
            "--device=@DEFAULT_MONITOR@",
            f"--rate={RATE}",
            f"--channels={CHANNELS}",
            "--format=s16le",
            "--latency-msec=50",
            "--client-name=noctalia-cider-meter",
            "--stream-name=lyrics-silence-gate",
        ]
        try:
            self._proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
            )
        except OSError:
            with self._lock:
                self._capture_ok = False
                self._active = True
            return

        assert self._proc.stdout is not None
        buf = b""
        try:
            while not self._stop.is_set():
                chunk = self._proc.stdout.read(CHUNK_BYTES)
                if not chunk:
                    break
                buf += chunk
                while len(buf) >= CHUNK_BYTES:
                    piece = buf[:CHUNK_BYTES]
                    buf = buf[CHUNK_BYTES:]
                    self._set_level(level_from_rms(rms_s16le(piece)))
        finally:
            try:
                if self._proc.poll() is None:
                    self._proc.terminate()
            except OSError:
                pass
            with self._lock:
                # Capture ended — fail open so scroll keeps moving.
                self._capture_ok = False
                self._active = True
