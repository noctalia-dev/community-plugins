"""Keep the generated image cache bounded without touching library records."""
import json
import os
import re
import stat
import sys
import time
from pathlib import Path

MAX_BYTES = 128 * 1024 * 1024
MAX_AGE = 30 * 24 * 60 * 60
IMAGE_NAME = re.compile(r"(?:video-[A-Za-z0-9_-]{11}|channel-UC[A-Za-z0-9_-]{22})\.jpg")


def clean_cache(directory, protected, *, now=None, max_bytes=MAX_BYTES, max_age=MAX_AGE):
    now = time.time() if now is None else now
    entries = []
    removed = 0
    with os.scandir(directory) as scan:
        for entry in scan:
            if not IMAGE_NAME.fullmatch(entry.name):
                continue
            try:
                info = entry.stat(follow_symlinks=False)
                if not stat.S_ISREG(info.st_mode):
                    continue
                if entry.name in protected:
                    os.utime(entry.path, (now, now), follow_symlinks=False)
                entries.append((now if entry.name in protected else info.st_mtime,
                                entry.name, info.st_size))
            except OSError:
                continue
    total = sum(size for _, _, size in entries)
    for modified, name, size in sorted(entries):
        if name in protected or (now - modified <= max_age and total <= max_bytes):
            continue
        try:
            (Path(directory) / name).unlink()
        except OSError:
            continue
        total -= size
        removed += 1
    return removed


def main():
    if len(sys.argv) != 3:
        raise ValueError("Expected cache directory and protected image names")
    protected = json.loads(sys.argv[2])
    if not isinstance(protected, list):
        raise TypeError("Protected image names must be a list")
    if not all(isinstance(name, str) and IMAGE_NAME.fullmatch(name) for name in protected):
        raise ValueError("Invalid protected image name")
    print(clean_cache(sys.argv[1], set(protected)))


if __name__ == "__main__":
    try:
        main()
    except (OSError, TypeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
