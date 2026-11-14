"""Noctalia pixel-stream producer. Capture/decoding stays outside the shell."""

import array
import fcntl
import mmap
import os
from pathlib import Path
import queue
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time


class Child:
    def __init__(self, argv, *, pixels=False):
        self.log = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(
                argv, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE if pixels else self.log, stderr=self.log,
            )
        except Exception:
            self.log.close()
            raise

    def error(self):
        size = os.fstat(self.log.fileno()).st_size
        return os.pread(self.log.fileno(), 4096, max(0, size - 4096)).decode("utf-8", "replace").strip()

    def stop(self, sig=signal.SIGTERM):
        if self.process.poll() is None:
            self.process.send_signal(sig)
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.process.stdout is not None:
            self.process.stdout.close()
        self.log.close()


class FrameServer:
    def __init__(self, path, command, width, height, events):
        if not (0 < width <= 4096 and 0 < height <= 4096 and width * height <= 4194304):
            raise ValueError("Invalid frame size")
        self.path = Path(path)
        self.command = command
        self.width, self.height = width, height
        self.events = events
        self.stopped = threading.Event()
        self.condition = threading.Condition()
        self.latest = None
        self.version = 0
        self.child = None
        self.client = None
        self.last_client = time.monotonic()
        self.ever_connected = False
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        try:
            self.server.bind(str(self.path))
            os.chmod(self.path, 0o600)
            self.identity = self.path.lstat()
            self.server.listen(1)
            self.server.settimeout(0.25)
        except Exception:
            self.server.close()
            raise
        self.capture_thread = threading.Thread(target=self.capture, daemon=True)
        self.server_thread = threading.Thread(target=self.serve, daemon=True)
        self.capture_thread.start()
        self.server_thread.start()

    def emit(self, kind, detail=""):
        # Only lifecycle events, never pixels or a per-frame event queue.
        try:
            self.events.put_nowait((kind, detail, self))
        except queue.Full:
            pass

    def capture(self):
        deadline = time.monotonic() + 8
        size = self.width * self.height * 4
        while not self.stopped.is_set():
            child = None
            try:
                child = Child(self.command, pixels=True)
                self.child = child
                while not self.stopped.is_set():
                    pixels = child.process.stdout.read(size)
                    if len(pixels) != size:
                        break
                    with self.condition:
                        first = self.latest is None
                        self.latest = pixels
                        self.version += 1
                        self.condition.notify_all()
                    if first:
                        self.emit("ready")
                detail = child.error()
                child.stop()
                self.child = None
                if self.stopped.is_set():
                    return
                if self.latest is not None or time.monotonic() >= deadline:
                    self.emit("error", detail or "Video capture stopped")
                    return
                # scrcpy may need a moment to publish the loopback format.
                self.stopped.wait(0.25)
            except (OSError, ValueError) as error:
                if child is not None:
                    child.stop()
                    self.child = None
                if not self.stopped.is_set():
                    self.emit("error", str(error))
                return

    def receive(self, client, *, deadline=None):
        while not self.stopped.is_set():
            if deadline is not None and time.monotonic() >= deadline:
                return None
            try:
                data, ancillary, flags, _ = client.recvmsg(8, socket.CMSG_SPACE(16), socket.MSG_CMSG_CLOEXEC)
            except socket.timeout:
                continue  # A hidden control may legitimately stop requesting frames.
            # The shell never sends descriptors. Close unexpected ones before rejecting.
            for level, kind, value in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    descriptors = array.array("i")
                    descriptors.frombytes(value[:len(value) // descriptors.itemsize * descriptors.itemsize])
                    for descriptor in descriptors:
                        os.close(descriptor)
            if len(data) != 8 or ancillary or flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC):
                return None
            return struct.unpack("<II", data)
        return None

    def stream(self, client):
        if self.receive(client, deadline=time.monotonic() + 2) != (1, 1):  # HELLO v1
            return
        size = self.width * self.height * 4
        descriptor = os.memfd_create("androidconnect-pixels", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
        try:
            os.ftruncate(descriptor, size)
            fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SEAL)
            with mmap.mmap(descriptor, size, access=mmap.ACCESS_WRITE) as buffer:
                sent, attached = -1, False
                while self.receive(client) == (2, 0):  # REQUEST releases the previous buffer.
                    with self.condition:
                        self.condition.wait_for(
                            lambda: self.stopped.is_set() or (self.latest is not None and sent != self.version)
                        )
                        if self.stopped.is_set():
                            return
                        pixels, sent = self.latest, self.version
                    # Capture keeps only its latest bytes, independently of this mapping.
                    # Never modify the shared buffer again until the next REQUEST.
                    buffer[:] = pixels
                    if not attached:
                        message = struct.pack("<IIII", 1, 0, self.width, self.height)  # BUFFER 0
                        rights = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [descriptor]))]
                        if client.sendmsg([message], rights) != len(message):
                            return
                        attached = True
                    if client.send(struct.pack("<II", 2, 0)) != 8:  # FRAME 0
                        return
        finally:
            os.close(descriptor)

    def serve(self):
        while not self.stopped.is_set():
            try:
                client, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with client:
                credentials = client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
                if struct.unpack("3i", credentials)[1] != os.geteuid():
                    continue
                self.client = client
                self.ever_connected = True
                client.settimeout(0.25)
                try:
                    self.stream(client)
                except (OSError, ValueError):
                    pass
                finally:
                    self.client = None
                    self.last_client = time.monotonic()

    def stop(self):
        self.stopped.set()
        with self.condition:
            self.condition.notify_all()
        client = self.client
        if client is not None:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.server.close()
        # Terminating FFmpeg unblocks a V4L2 read before joining its reader.
        child = self.child
        if child is not None and child.process.poll() is None:
            child.process.terminate()
        self.capture_thread.join(timeout=3)
        self.server_thread.join(timeout=2)
        try:
            current = self.path.lstat()
            if (current.st_dev, current.st_ino) == (self.identity.st_dev, self.identity.st_ino):
                self.path.unlink()
        except FileNotFoundError:
            pass


def preview_size(width, height, maximum_height):
    scale = min(360 / width, maximum_height / height, 1)
    return max(2, int(width * scale) // 2 * 2), max(2, int(height * scale) // 2 * 2)


def phone_geometry(width, height):
    """Fit v4's cropped artwork (597x1241) around its 538x1190 screen."""
    left, right = round(width * 25 / 538), round(width * 34 / 538)
    top, bottom = round(height * 26 / 1190), round(height * 25 / 1190)
    return {"width": left + width + right, "height": top + height + bottom,
            "screen": {"x": left, "y": top, "width": width, "height": height,
                       "radius": min(width * 52 / 538, height * 52 / 1190)}}


def phone_filter(width, height):
    """One cached artwork/mask frame; only scale, alpha merge and overlay run live."""
    phone = phone_geometry(width, height)
    screen = phone["screen"]
    left, top, radius = screen["x"], screen["y"], screen["radius"]

    def coverage(x, y):
        # Antialiased rounded-rectangle coverage at pixel centers.
        dx = f"max(abs(X-{x + (width - 1) / 2})-{width / 2 - radius},0)"
        dy = f"max(abs(Y-{y + (height - 1) / 2})-{height / 2 - radius},0)"
        return f"clip({radius + 0.5}-hypot({dx},{dy}),0,1)"

    return (
        f"[1:v]scale={phone['width']}:{phone['height']},"
        "format=rgba,split=2[art][shape];"
        f"[art]geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':"
        f"a='alpha(X,Y)*(1-({coverage(left, top)}))'[rim];"
        f"[shape]scale={width}:{height},format=gray,geq=lum='255*({coverage(0, 0)})'[mask];"
        f"[0:v]setpts=PTS-STARTPTS,scale={width}:{height},format=rgb24[video];"
        "[video][mask]alphamerge[rounded];"
        f"[rounded]pad={phone['width']}:{phone['height']}:{left}:{top}:color=black@0[canvas];"
        "[canvas][rim]overlay=format=rgb:alpha=straight,format=rgba[phone]"
    )
