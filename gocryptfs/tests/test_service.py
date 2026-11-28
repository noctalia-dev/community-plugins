"""Regression tests for the gocryptfs service, run under the real Luau interpreter.

Noctalia runs plugins as Luau. Luau has no `io` library and no `os.getenv`; a plugin reads
environment variables through `noctalia.getenv(name)`. Calling `os.getenv` raises
"attempt to call a nil value", and because the service primes its private temp directory
while it loads, the whole service dies at startup. The panel then talks to nothing, so
Save and Remember do nothing and show no error.

These tests load the unmodified `service.luau` behind a stub of the `noctalia` API and an
`os` table without `getenv`, exactly like the plugin sandbox.

Run from the repository root:

    python3 -m unittest discover -s gocryptfs/tests -p 'test_*.py'

They need the `luau` binary (https://github.com/luau-lang/luau) on PATH, or set
LUAU=/path/to/luau. Without it the Luau tests are skipped.
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parent.parent
SERVICE = PLUGIN_DIR / "service.luau"
LUAU = os.environ.get("LUAU") or shutil.which("luau")

# Stub of the parts of the Noctalia plugin API the service touches while it loads.
# Anything it does not name resolves to a function that returns nil. Commands handed to
# runAsync are recorded, and only the chmod that primes the temp dir gets its callback run,
# so the test does not drive the whole mount state machine.
PRELUDE = """\
local os = { time = os.time, clock = os.clock, date = os.date } -- sandbox: no os.getenv
local __log = {}
local function __nothing() return nil end
local function __lenient(t)
  return setmetatable(t, { __index = function() return __nothing end })
end
local __user = %(user)s
local noctalia = __lenient({
  getenv = function(name)
    if name == "USER" then return __user end
    return nil
  end,
  expandPath = function(path) return path end,
  pluginDataDir = function() return "/plugin-data" end,
  fileExists = function(path) return path == "/dev/shm" end,
  mkdirAll = function(path)
    table.insert(__log, "MKDIR " .. path)
    return true
  end,
  runAsync = function(command, callback)
    table.insert(__log, "RUN " .. tostring(command))
    if callback and string.sub(tostring(command), 1, 5) == "chmod" then
      callback({ exitCode = 0, timedOut = false, stdout = "", stderr = "" })
    end
  end,
  tr = function(key) return key end,
  getConfig = function() return nil end,
  commandExists = function() return false end,
  readFile = function() return nil, "missing" end,
  state = __lenient({}),
  json = __lenient({}),
  string = __lenient({}),
})
"""

POSTLUDE = """
print("LOADED")
for _, line in ipairs(__log) do print(line) end
"""


def run_service(user):
    """Load service.luau behind the stub; return the CompletedProcess."""
    lua_user = "nil" if user is None else '"%s"' % user
    source = PRELUDE % {"user": lua_user} + SERVICE.read_text() + POSTLUDE
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / "service_under_test.luau"
        script.write_text(source)
        return subprocess.run(
            [LUAU, str(script)], capture_output=True, text=True, timeout=30, cwd=tmp
        )


@unittest.skipUnless(LUAU, "luau binary not found; set LUAU or put it on PATH")
class ServiceLoadTest(unittest.TestCase):
    def test_service_loads_in_the_plugin_sandbox(self):
        result = run_service("testuser")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LOADED", result.stdout)

    def test_private_temp_dir_is_named_after_the_user(self):
        result = run_service("testuser")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MKDIR /dev/shm/noctalia-gocryptfs.testuser", result.stdout)

    def test_private_temp_dir_is_locked_down_to_mode_700(self):
        result = run_service("testuser")
        self.assertEqual(result.returncode, 0, result.stderr)
        chmods = [l for l in result.stdout.splitlines() if l.startswith("RUN") and "chmod" in l]
        self.assertTrue(
            any("700" in l and "noctalia-gocryptfs.testuser" in l for l in chmods),
            result.stdout,
        )

    def test_temp_dir_falls_back_when_user_is_unset(self):
        result = run_service(None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MKDIR /dev/shm/noctalia-gocryptfs.user", result.stdout)


class SandboxApiTest(unittest.TestCase):
    """Cheap guard that needs no interpreter: APIs the plugin sandbox does not provide."""

    # Luau has no io library, and its os library has no getenv or execute.
    FORBIDDEN = re.compile(r"\b(os\.(getenv|execute|exit|remove|rename|tmpname)|io\.[a-z]+)\s*\(")

    def test_entry_scripts_avoid_apis_missing_from_the_sandbox(self):
        for path in sorted(PLUGIN_DIR.glob("*.luau")):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                code = line.split("--", 1)[0]
                match = self.FORBIDDEN.search(code)
                self.assertIsNone(
                    match,
                    "%s:%d uses %s, which does not exist in the plugin sandbox"
                    % (path.name, number, match and match.group(0)),
                )


if __name__ == "__main__":
    unittest.main()
