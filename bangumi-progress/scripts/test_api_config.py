"""Exercise service endpoint changes with a mocked Noctalia host."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which("luau"), "Luau CLI is required")
class ApiConfigTests(unittest.TestCase):
    def test_live_endpoint_change_and_token_validation(self):
        source = (pathlib.Path(__file__).resolve().parents[1] / "service.luau").read_text()
        # Supply host mocks and invoke configuration callbacks instead of startup.
        source = source.replace("\ninit()\n", "\n")
        harness = r'''
local config = "https://api.bgm.tv"
local requests = {}
noctalia = {
  string = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
  getConfig = function() return config end,
  pluginDir = function() return nil end,
  pluginDataDir = function() return nil end,
  state = { watch = function() end, get = function() return false end, set = function() end },
  nowMs = function() return 100 end,
  setUpdateInterval = function() end,
  http = function(request, callback)
    table.insert(requests, { request = request, callback = callback })
    return true
  end,
}
'''
        assertions = r'''
authReady = true
accessToken = "fixture-token"
snapshot.authMode = "token"
snapshot.authSource = "pat"
meCache = { result = { id = 1 }, fetchedAt = os.time() }
config = "  https://mirror.example/api///  "
onConfigChanged()
assert(API_BASE == "https://mirror.example/api")
assert(#requests == 1)
assert(requests[1].request.url == "https://mirror.example/api/v0/me")
assert(table.find(requests[1].request.headers, "Authorization: Bearer fixture-token"))
local oldGeneration = sessionGeneration
onConfigChanged()
assert(sessionGeneration == oldGeneration, "unchanged URL must not restart requests")
snapshot.busy = true
config = "https://second.example"
onConfigChanged()
assert(API_BASE == "https://mirror.example/api", "defer while writing progress")
snapshot.busy = false
applyApiConfig()
assert(API_BASE == config)
assert(sessionGeneration > oldGeneration)
requests[1].callback({ ok = true, status = 200, body = "old response" })
assert(meCache.result == nil, "obsolete identity callback must be ignored")
snapshot.oauthBusy = true
config = " "
onConfigChanged()
assert(API_BASE == "https://second.example", "defer while signing in")
snapshot.oauthBusy = false
applyApiConfig()
assert(API_BASE == "https://api.bgm.tv")
assert(requests[#requests].request.url == "https://api.bgm.tv/v0/me")
local originalPaths, originalRead = oauthPaths, readJson
oauthPaths = function() return { client = "fixture" } end
readJson = function() return { api_base_url = " https://profile.example/api/ " } end
config = "https://gui.example"
assert(configuredApiBase() == "https://profile.example/api", "profile overrides GUI")
readJson = function() return { api_base_url = " " } end
assert(configuredApiBase() == config, "empty profile uses GUI")
oauthPaths, readJson = originalPaths, originalRead
print("API configuration checks passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / "service_test.luau"
            script.write_text(harness + source + assertions)
            result = subprocess.run(["luau", str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
