--!nonstrict
-- Resets the cursor when the plugin is removed from Noctalia's settings.
--
-- Noctalia deletes the plugin directory *before* it tears the runtime down
-- (PluginManager::remove), so by the time onExit runs bin/curmgr.py is gone.
-- The data dir survives, so every start keeps a copy of the engine there.
-- A plugin removed while already disabled gets no onExit at all: the panel's
-- Reset button stays for that case.

local shared = require("./shared.luau")

local function dataEngine()
  local data = noctalia.pluginDataDir()
  return type(data) == "string" and data ~= "" and data .. "/curmgr.py" or nil
end

local dir, copy = noctalia.pluginDir(), dataEngine()
if type(dir) == "string" and dir ~= "" and copy ~= nil then
  noctalia.runAsync(`cp -f {shared.shellQuote(dir .. "/bin/curmgr.py")} {shared.shellQuote(copy)}`)
end

function onExit(_signal, reason)
  -- Disabling is temporary and shutdown is every logout; only a removal resets.
  if reason ~= "uninstall" or copy == nil then
    return
  end
  local override = shared.configString("engine_path", "")
  local engine = override ~= "" and shared.shellQuote(noctalia.expandPath(override))
    or `python3 -B {shared.shellQuote(copy)}`
  -- No callback: the runtime is gone before this finishes. The result lands
  -- next to the copy for anyone who wants to know what happened.
  noctalia.runAsync(`{shared.pathEnv()}{engine} uninstall > {shared.shellQuote(copy .. ".uninstall.json")} 2>&1`)
end
