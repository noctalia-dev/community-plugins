-- tests/writer_apply_hyprland_validation_failure_test.lua
-- Covers Fix 8: the rewritten hyprland.lua (with the require() line appended)
-- must itself be validated with `Hyprland --verify-config` before being
-- committed. If that validation fails (e.g. the user's hyprland.lua ends in a
-- top-level `return`, making an appended require() a syntax error), the real
-- hyprland.lua must be left completely untouched, even though the managed
-- file's own validation succeeded and it was already committed.
local stateValues = {}
local watchers = {}
local writtenFiles = {}
local ranCommands = {}
local hyprlandConfigPath = "/tmp/hdc-test-hypr-fail/hyprland.lua"
local managedFilePath = "/tmp/hdc-test-hypr-fail/hypr-display-config.lua"

noctalia = {
  getConfig = function(key)
    if key == "hyprland_config" then return hyprlandConfigPath end
    return nil
  end,
  expandPath = function(path) return path end,
  readFile = function(path)
    if path == hyprlandConfigPath then return 'return {}\n' end
    return nil
  end,
  writeFile = function(path, content)
    writtenFiles[path] = content
    return true
  end,
  fileExists = function(path) return writtenFiles[path] ~= nil or path == hyprlandConfigPath end,
  commandExists = function(name) return name == "hyprctl" or name == "Hyprland" end,
  runAsync = function(command, callback)
    ranCommands[#ranCommands + 1] = command
    if command:find("Hyprland %-%-verify%-config") then
      if command:find("hyprland.tmp.lua", 1, true) ~= nil then
        -- The rewritten hyprland.lua (with require() appended after a
        -- trailing `return {}`) is invalid Lua.
        callback({ exitCode = 1, stdout = "", stderr = "unexpected symbol near 'require'" })
      else
        -- The managed file's own validation still succeeds.
        callback({ exitCode = 0, stdout = "" })
      end
    else
      callback({ exitCode = 0, stdout = "" })
    end
    return true
  end,
  state = {
    set = function(key, value)
      stateValues[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    get = function(key) return stateValues[key] end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  notifyError = function() end,
}

assert(loadfile("writer_service.luau"))()

noctalia.state.set("hypr-display-config.apply_request", {
  request_id = "req-hypr-fail",
  monitors = {
    { name = "eDP-1", width = 1920, mode = "preferred", scale = 1, transform = 0,
      disabled = false, workspaces = { 1 } },
  },
})

local result = stateValues["hypr-display-config.apply_result"]
assert(type(result) == "table", "no result published")
assert(result.status == "error", "expected error status when hyprland.lua validation fails, got " .. tostring(result.status))
assert(type(result.message) == "string" and #result.message > 0, "error result should carry a message")

-- The real hyprland.lua must never be overwritten with the bad content.
assert(writtenFiles[hyprlandConfigPath] == nil,
  "hyprland.lua must not be rewritten when its post-edit validation fails")

-- The managed file's own validation succeeded independently, so it's fine
-- (and expected) for it to have already been committed.
assert(writtenFiles[managedFilePath] ~= nil, "managed file should still be committed")

-- Sanity: we actually exercised the hyprland.lua temp-validation path.
local sawHyprlandTmpVerify = false
for _, command in ipairs(ranCommands) do
  if command:find("Hyprland %-%-verify%-config") and command:find("hyprland.tmp.lua", 1, true) ~= nil then
    sawHyprlandTmpVerify = true
  end
end
assert(sawHyprlandTmpVerify, "expected a Hyprland --verify-config call against the hyprland.lua temp file")

-- Regression check for the Critical temp-path-extension bug: Hyprland 0.56.2
-- selects its config parser purely by file extension, so every
-- `Hyprland --verify-config` target MUST still end in `.lua` (a naively
-- appended `.tmp` produces `hyprland.lua.tmp`, which silently falls back to
-- the legacy conf-file parser and can neither validate real Lua nor reject
-- malformed Lua). This assertion is what would have caught it: the stubbed
-- runAsync above can't tell a `.lua` path from a `.lua.tmp` one by itself, so
-- the shape of the command string is the only thing standing in for real
-- Hyprland's extension-based dispatch.
for _, command in ipairs(ranCommands) do
  if command:match("^Hyprland %-%-verify%-config") then
    assert(command:match("%.lua'?$") ~= nil,
      "verify-config path must end in .lua, got: " .. command)
  end
end

print("writer_apply_hyprland_validation_failure_test: ok")
