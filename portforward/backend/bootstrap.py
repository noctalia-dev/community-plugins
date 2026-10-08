"""Set up the bundled backend using only the system Python installation."""

import json
import sys
from pathlib import Path

if sys.version_info < (3, 11):  # noqa: UP036 -- Noctalia may find an older system Python.
    print(
        "Python 3.11 or newer is required. Install it before enabling Port Forwarding.",
        file=sys.stderr,
    )
    sys.exit(1)
if sys.platform != "linux":
    print("Linux with systemd user services is required.", file=sys.stderr)
    sys.exit(1)

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from portforward_manager.installation import ensure  # noqa: E402

try:
    print(json.dumps(ensure(Path(__file__).resolve().parent)))
except (ValueError, OSError) as error:
    print(error, file=sys.stderr)
    sys.exit(1)
