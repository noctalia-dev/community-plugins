"""Bound search time and stop obsolete yt-dlp process groups."""
import os
import signal
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path


def current(path: Path, token: str) -> bool:
    try:
        return path.read_text() == token
    except (OSError, UnicodeError):
        return False


def stop(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        _ = process.communicate(timeout=.3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _ = process.communicate()


def run(path: Path, token: str, command: Sequence[str], *, timeout: float = 8) -> int:
    if not current(path, token):
        return 130
    process = subprocess.Popen(
        command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, start_new_session=True,
    )
    deadline = time.monotonic() + timeout
    try:
        while True:
            if not current(path, token):
                stop(process)
                return 130
            if time.monotonic() >= deadline:
                stop(process)
                return 124
            try:
                stdout, stderr = process.communicate(timeout=.1)
                _ = sys.stdout.buffer.write(stdout)
                _ = sys.stderr.buffer.write(stderr)
                assert process.returncode is not None
                return process.returncode
            except subprocess.TimeoutExpired:
                pass
    finally:
        if process.poll() is None:
            stop(process)


if __name__ == '__main__':
    try:
        filename, ticket, *argv = sys.argv[1:]
        if not argv or argv[0] != 'yt-dlp':
            raise ValueError('Expected a yt-dlp search command')
        sys.exit(run(Path(filename), ticket, argv))
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
