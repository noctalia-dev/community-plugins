"""Run the REST client tests with Noctalia-compatible module paths."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PLUGIN = Path(__file__).resolve().parents[1]
LUAU = os.environ.get("LUAU_BIN") or shutil.which("luau")


class RestClientTests(unittest.TestCase):
    def test_rest_client(self):
        self.run_suite("rest-test.luau", "REST client tests passed")

    def test_rest_state(self):
        self.run_suite("rest-state-test.luau", "REST state tests passed")

    def run_suite(self, filename, success_message):
        if LUAU is None:
            self.skipTest("luau is not installed")

        sources = {
            "rest": (PLUGIN / "rest.luau").read_text(),
            "rest_state": (PLUGIN / "rest_state.luau").read_text(),
            "test": (PLUGIN / "tests" / filename).read_text(),
        }

        with tempfile.TemporaryDirectory(prefix="sp-rest-client-") as directory:
            root = Path(directory)
            bundled = "\n".join(
                f'["{name}"] = [====[{source}]====],'
                for name, source in sources.items()
            )
            (root / "rest-client-sources.luau").write_text(
                "return {\n" + bundled + "\n}\n"
            )
            (root / "rest-client-test.luau").write_text(
                """local sources = require("./rest-client-sources")
local cache = {}
local function load_source(name)
  local env = setmetatable({}, { __index = getfenv() })
  env.require = function(path)
    local module = path:gsub("^%.%./", ""):gsub("^%./", ""):gsub("%.luau$", "")
    if cache[module] == nil then cache[module] = load_source(module) end
    return cache[module]
  end
  local chunk = assert(loadstring(sources[name], "@" .. name .. ".luau"))
  setfenv(chunk, env)
  return chunk()
end
load_source("test")
"""
            )
            result = subprocess.run(
                [LUAU, "rest-client-test.luau"],
                cwd=root,
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(success_message, result.stdout)


if __name__ == "__main__":
    unittest.main()
