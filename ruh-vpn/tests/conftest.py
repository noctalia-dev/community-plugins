"""Point the backend at a throwaway data dir BEFORE any backend import.

backend.paths reads RUH_VPN_* at import time, so this must run first —
pytest imports conftest before collecting test modules, which guarantees it.
"""

import os
import sys
import tempfile
from pathlib import Path

_tmp = tempfile.mkdtemp(prefix="ruh-vpn-test-")
os.environ["RUH_VPN_DATA_DIR"] = _tmp
os.environ["RUH_VPN_RUNTIME_DIR"] = os.path.join(_tmp, "runtime")
os.environ["RUH_VPN_GEOIP"] = "0"

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
