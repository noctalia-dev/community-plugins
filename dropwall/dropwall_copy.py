#!/usr/bin/env python3
"""Atomically copy one dropped image without replacing an existing file."""

import argparse
import ctypes
import os
import select
import signal
import stat
import sys
import tempfile
import time
import urllib.parse


TEMP_PREFIX = ".dropwall-copy-"
TEMP_SUFFIX = ".tmp"
STALE_SECONDS = 24 * 60 * 60
ACTIVE_TEMP = None
COPY_CHUNK = 1024 * 1024


# Exit immediately if Noctalia closes the process pipe.
signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def arm_parent_death_signal():
    """Ask Linux to terminate this copy if Noctalia disappears."""
    parent = os.getppid()
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:  # PR_SET_PDEATHSIG
            return
        if os.getppid() != parent:
            os.kill(os.getpid(), signal.SIGTERM)
    except (AttributeError, OSError):
        return


def encode_path(path):
    return urllib.parse.quote_from_bytes(os.fsencode(path), safe="")


def remove_active_temp():
    global ACTIVE_TEMP
    if ACTIVE_TEMP:
        try:
            os.unlink(ACTIVE_TEMP)
        except OSError:
            pass
        ACTIVE_TEMP = None


def terminate(signum, _frame):
    remove_active_temp()
    os._exit(128 + signum)


class WorkerLease:
    """A pidfd tied to the GTK worker that accepted this drop."""

    def __init__(self, pid):
        if not hasattr(os, "pidfd_open"):
            raise OSError("this Linux/Python build does not support pidfd_open")
        self.fd = os.pidfd_open(pid, 0)
        self.poller = select.poll()
        self.poller.register(self.fd, select.POLLIN | select.POLLHUP | select.POLLERR)
        self.check()

    def check(self):
        if self.poller.poll(0):
            raise BrokenPipeError("DropWall worker stopped during the copy")

    def close(self):
        os.close(self.fd)


def cleanup_stale_temps(directory):
    """Remove only old, owned temporary files left by interrupted copies."""
    cutoff = time.time() - STALE_SECONDS
    try:
        names = os.listdir(directory)
    except OSError:
        return

    for name in names:
        if not (name.startswith(TEMP_PREFIX) and name.endswith(TEMP_SUFFIX)):
            continue
        path = os.path.join(directory, name)
        try:
            info = os.lstat(path)
            if info.st_uid == os.getuid() and stat.S_ISREG(info.st_mode) and info.st_mtime < cutoff:
                os.unlink(path)
        except OSError:
            continue


def is_inside(path, directory):
    try:
        return os.path.commonpath((path, directory)) == directory
    except ValueError:
        return False


def publish_unique(temp_path, source, directory, lease):
    filename = os.path.basename(source)
    stem, suffix = os.path.splitext(filename)
    stem = stem or "wallpaper"

    for counter in range(10000):
        candidate_name = filename if counter == 0 else "%s-%d%s" % (stem, counter, suffix)
        candidate = os.path.join(directory, candidate_name)
        try:
            lease.check()
            # The hard link exposes the already-complete inode atomically and
            # fails if candidate exists. It can never replace user data.
            os.link(temp_path, candidate, follow_symlinks=False)
            return candidate
        except FileExistsError:
            continue

    raise FileExistsError("could not allocate a unique destination filename")


def copy_atomic(source, directory, lease):
    global ACTIVE_TEMP

    real_directory = os.path.realpath(directory)
    if not os.path.isdir(real_directory):
        raise NotADirectoryError("wallpaper directory does not exist")

    source_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    source_fd = os.open(source, source_flags)
    with os.fdopen(source_fd, "rb") as source_file:
        source_info = os.fstat(source_file.fileno())
        if not stat.S_ISREG(source_info.st_mode):
            raise OSError("the dropped path is not a regular file")

        # Resolve the descriptor we actually validated, not a pathname that
        # could have been swapped after open().
        real_source = os.path.realpath("/proc/self/fd/%d" % source_file.fileno())
        if is_inside(real_source, real_directory):
            return real_source

        cleanup_stale_temps(real_directory)
        temp_fd, temp_path = tempfile.mkstemp(
            prefix=TEMP_PREFIX,
            suffix=TEMP_SUFFIX,
            dir=real_directory,
        )
        ACTIVE_TEMP = temp_path
        try:
            with os.fdopen(temp_fd, "wb") as temp_file:
                while True:
                    lease.check()
                    chunk = source_file.read(COPY_CHUNK)
                    if not chunk:
                        break
                    temp_file.write(chunk)
                temp_file.flush()
                os.fsync(temp_file.fileno())
            # Keep copies private even if the source was more permissive.
            os.chmod(temp_path, 0o600)
            return publish_unique(temp_path, source, real_directory, lease)
        finally:
            remove_active_temp()


def main():
    arm_parent_death_signal()
    parser = argparse.ArgumentParser(description="Safely copy one DropWall image")
    parser.add_argument("--lease-pid", type=int, required=True)
    parser.add_argument("source")
    parser.add_argument("directory")
    args = parser.parse_args()

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, terminate)

    lease = None
    try:
        lease = WorkerLease(args.lease_pid)
        destination = copy_atomic(args.source, args.directory, lease)
    except Exception as error:
        print(str(error).replace("\n", " "), file=sys.stderr, flush=True)
        return 1
    finally:
        if lease is not None:
            lease.close()

    print("COPIED\t%s" % encode_path(destination), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
