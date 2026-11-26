"""Pointer layer for the sleep timer dial.

Noctalia only reports press / drag / release / wheel to a plugin through ui.pixelStream,
and a pixel stream needs a companion process that serves frames over a Unix socket.
This companion serves a single fully transparent 1x1 frame, so the dial image under
the stream stays visible and the panel script gets the pointer events.

Usage: python3 companion.py <socket path>
Exits a few seconds after Noctalia stops connecting (the panel was closed).
Protocol: docs/user/plugins/development/declarative-ui.mdx, "Companion protocol".
"""

import fcntl
import os
import socket
import struct
import sys
import time

IDLE_EXIT_SECONDS = 5


def transparent_buffer():
    fd = os.memfd_create("sleep-timer-dial", os.MFD_ALLOW_SEALING)
    os.write(fd, b"\0\0\0\0")  # one RGBA pixel, alpha 0
    fcntl.fcntl(fd, fcntl.F_ADD_SEALS, fcntl.F_SEAL_SHRINK)
    return fd


def take_lock(path):
    """Returns the lock file held for the companion's lifetime, or None if another copy has it.

    Only the copy holding the lock binds the socket, so a second copy can never unlink a
    running copy's socket. When the panel reopens just as the previous copy is about to
    exit on idle, the new copy waits for the lock and takes over; it gives up once the
    other copy has clearly stayed (it got a connection, so it is serving the panel).
    """
    lock = open(path + ".lock", "a")
    deadline = time.monotonic() + IDLE_EXIT_SECONDS + 1
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock
        except OSError:
            if time.monotonic() >= deadline:
                lock.close()
                return None
            time.sleep(0.2)


def serve(conn, buffer_fd):
    sent = False
    while True:
        msg = conn.recv(64)
        if len(msg) < 8:
            return  # connection closed
        kind, value = struct.unpack_from("<II", msg)
        if kind == 1 and value != 1:
            return  # HELLO with a protocol version we do not speak
        # The frame never changes, so only the first REQUEST of a connection gets one
        if kind == 2 and not sent:
            socket.send_fds(conn, [struct.pack("<IIII", 1, 0, 1, 1)], [buffer_fd])
            conn.send(struct.pack("<II", 2, 0))
            sent = True


def main():
    path = sys.argv[1]
    lock = take_lock(path)
    if lock is None:
        return  # another copy is serving this socket
    # A socket file left by a copy that was killed is stale: the lock was free
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    # Owner-only from the moment the socket file exists
    old_umask = os.umask(0o177)
    try:
        server.bind(path)
    finally:
        os.umask(old_umask)
    server.listen(2)
    server.settimeout(IDLE_EXIT_SECONDS)
    buffer_fd = transparent_buffer()
    try:
        while True:
            try:
                conn, _ = server.accept()
            except socket.timeout:
                return
            with conn:
                conn.settimeout(None)
                try:
                    serve(conn, buffer_fd)
                except OSError:
                    pass
    finally:
        server.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        lock.close()


if __name__ == "__main__":
    main()
