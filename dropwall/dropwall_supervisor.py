#!/usr/bin/env python3
"""Keep one DropWall GTK target attached to a single Noctalia stream."""

import argparse
import ctypes
import os
import signal
import subprocess
import sys
import time


# Exit immediately when Noctalia closes runStream's stdout pipe.
signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def arm_parent_death_signal():
    """Ask Linux to terminate us if Noctalia disappears."""
    parent = os.getppid()
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:  # PR_SET_PDEATHSIG
            return
        if os.getppid() != parent:
            os.kill(os.getpid(), signal.SIGTERM)
    except (AttributeError, OSError):
        return


def emit(line):
    print(line, flush=True)


def worker_command(args):
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dropwall_helper.py")
    return [sys.executable, "-B", helper, "--layer", args.layer]


def run_worker(command):
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    assert process.stdout is not None
    for line in process.stdout:
        emit(line.rstrip("\n"))
    return process.wait()


def main():
    parser = argparse.ArgumentParser(description="DropWall helper supervisor")
    parser.add_argument("--layer", choices=("background", "bottom"), default="background")
    args = parser.parse_args()

    arm_parent_death_signal()
    command = worker_command(args)
    lock_retry_seconds = 2

    while True:
        try:
            exit_code = run_worker(command)
        except OSError as error:
            emit("ERR\tcould not start the GTK helper: %s" % str(error).replace("\n", " "))
            exit_code = 127

        emit("RESTART\t%d" % exit_code)
        if exit_code == 3:
            # A collision normally means the previous runtime is still
            # shutting down. Back off if it is a genuinely persistent owner.
            time.sleep(lock_retry_seconds)
            lock_retry_seconds = min(lock_retry_seconds * 2, 60)
        else:
            lock_retry_seconds = 2
            time.sleep(30)


if __name__ == "__main__":
    sys.exit(main())
