"""Check gtk-launch's exit without attaching the GUI's output to a captured job."""

import re
import subprocess
import sys


def main(argv):
    if len(argv) != 1 or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.+\-]*\.desktop", argv[0]):
        return 2
    try:
        # gtk-launch exits after delegating to the desktop entry. Its GUI child
        # must inherit /dev/null, not Noctalia's temporary capture pipes, and
        # must not share the captured helper's timeout/cancellation process group.
        result = subprocess.run(["gtk-launch", argv[0]], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True, timeout=15, check=False)
        return result.returncode
    except (OSError, subprocess.TimeoutExpired):
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
