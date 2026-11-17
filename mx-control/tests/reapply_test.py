# Tests for mxctl.reapply_saved. Needs Solaar installed. Run from the plugin root:
#   python3 tests/reapply_test.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))
import mxctl  # noqa: E402
from logitech_receiver.hidpp20_constants import SupportedFeature  # noqa: E402


class Setting:
    def __init__(self, name, kind=0x04):
        self.name, self.kind, self.applied = name, kind, 0

    def apply(self):
        self.applied += 1


class Dev:
    def __init__(self, serial, cookie=b"\x00\x00", config_change=True, sensitive=None):
        self.serial, self.cookie, self.name = serial, cookie, "MX Master 3S"
        self.online: bool | None = True  # None: ping raises
        self.features = {SupportedFeature.CONFIG_CHANGE} if config_change else None
        self.persister = {"_sensitive": sensitive or {}}
        self.settings = [Setting("dpi"), Setting("smart-shift"), Setting("rgb", 0x200), None]

    def ping(self):
        if self.online is None:
            raise OSError("no such device")
        return self.online

    def feature_request(self, feature, function, *params):
        assert feature == SupportedFeature.CONFIG_CHANGE
        if function == 0x00:
            return self.cookie + bytes(14)
        self.cookie = bytes(params)

    def applied(self):
        return {s.name: s.applied for s in self.settings if s}


configured = set()

# A reset device gets its saved settings back, except kinds the plugin never writes.
mouse = Dev("A")
assert mxctl.reapply_saved([mouse], configured)
assert mouse.applied() == {"dpi": 1, "smart-shift": 1, "rgb": 0}
assert mouse.cookie == mxctl.RESET_COOKIE

# Cookie still set: no reset, nothing written.
assert not mxctl.reapply_saved([mouse], configured)
assert mouse.applied()["dpi"] == 1

# Reset clears the cookie: applied again.
mouse.cookie = b"\x00\x00"
assert mxctl.reapply_saved([mouse], configured)
assert mouse.applied()["dpi"] == 2

# Offline devices and devices that fail to answer are skipped.
mouse.cookie = b"\x00\x00"
mouse.online = False
assert not mxctl.reapply_saved([mouse], configured)
mouse.online = None
assert not mxctl.reapply_saved([mouse], configured)
assert mouse.applied()["dpi"] == 2

# Solaar's "ignore" sensitivity is honoured.
quiet = Dev("B", sensitive={"dpi": "ignore"})
mxctl.reapply_saved([quiet], configured)
assert quiet.applied() == {"dpi": 0, "smart-shift": 1, "rgb": 0}

# Without ConfigChange: applied once while online, again after being offline.
old = Dev("C", config_change=False)
assert mxctl.reapply_saved([old], configured)
assert not mxctl.reapply_saved([old], configured)
old.online = False
assert not mxctl.reapply_saved([old], configured)
old.online = True
assert mxctl.reapply_saved([old], configured)
assert old.applied()["dpi"] == 2

# Devices the plugin does not manage are left alone.
cam = Dev("D")
cam.name = "Brio webcam"
assert not mxctl.reapply_saved([cam], configured)
assert cam.cookie == b"\x00\x00"

print("ok")
