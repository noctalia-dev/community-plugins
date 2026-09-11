-- tests/prelude.lua — load the real plugin modules in plain Lua 5.4.
--
-- The plugin modules are Luau but written in the Lua 5.4 subset, so they run
-- unchanged under `lua tests/run_tests.lua`. This prelude provides a minimal
-- `noctalia` stub and a loader that executes a module file with a sandboxed
-- environment whose `require` resolves "./x.luau" and "../y.luau" lexically,
-- mirroring Noctalia's entry-local require semantics.

local M = {}

local function noctalia_stub()
  return {
    log = function() end,
    tr = function(key, subst)
      local known = {
        ["format.duration_hours_minutes"] = "{h}h {m}m",
        ["format.duration_hours"] = "{h}h",
        ["format.duration_minutes"] = "{m}m",
        ["format.duration_seconds"] = "{s}s",
        ["format.duration_minutes_seconds"] = "{m}m {s}s",
      }
      if type(key) == "string" and known[key] then
        local out = known[key]
        if type(subst) == "table" then
          for k, v in pairs(subst) do
            out = out:gsub("{" .. k .. "}", tostring(v))
          end
        end
        return out
      end
      return key
    end,
    nowMs = function()
      return os.time() * 1000
    end,
    -- Test hook: provider tests set _G.WDID_TEST_ASYNC(args, cb) to fake
    -- runAsync results; without it runAsync behaves as "not accepted".
    runAsync = function(args, cb, _timeout)
      if type(_G.WDID_TEST_ASYNC) == "function" then
        return _G.WDID_TEST_ASYNC(args, cb)
      end
      return false
    end,
    commandExists = function(_cmd)
      return _G.WDID_TEST_COMMAND_EXISTS == true
    end,
    pluginDataDir = function()
      return nil
    end,
  }
end

local function splitDir(path)
  return path:match("^(.*)/[^/]+$") or "."
end

local function normalize(parts)
  local out = {}
  for _, p in ipairs(parts) do
    if p == ".." then
      table.remove(out)
    elseif p ~= "." then
      out[#out + 1] = p
    end
  end
  return out
end

-- Load a module file relative to dir. Returns the module value.
-- Relative requires inside the module resolve against the module's own
-- directory, mirroring Noctalia's entry-local require semantics.
function M.loadModule(dir, relPath)
  local path = dir .. "/" .. relPath
  -- directory containing the module file, e.g. dir .. "/lib" for lib/x.luau
  local moduleDir = dir
  local sub = relPath:match("^(.*)/")
  if sub and sub ~= "" then
    moduleDir = dir .. "/" .. sub
  end
  -- Tests can replace the whole noctalia stub (e.g. the panel render test
  -- needs a state store + panel.render capture) via WDID_TEST_NOCTALIA,
  -- mirroring the WDID_TEST_ASYNC hook.
  local noct = type(_G.WDID_TEST_NOCTALIA) == "function" and _G.WDID_TEST_NOCTALIA() or noctalia_stub()
  local env = setmetatable({ noctalia = noct }, { __index = _G })
  env.require = function(spec)
    if type(spec) ~= "string" or (spec:sub(1, 2) ~= "./" and spec:sub(1, 3) ~= "../") then
      error("test loader only supports relative requires, got: " .. tostring(spec))
    end
    local baseParts = {}
    for p in string.gmatch(moduleDir, "[^/]+") do
      table.insert(baseParts, p)
    end
    for p in string.gmatch(spec, "[^/]+") do
      table.insert(baseParts, p)
    end
    local parts = normalize(baseParts)
    if #parts == 0 then
      error("require resolved to empty path: " .. tostring(spec))
    end
    return M.loadModule(table.concat(parts, "/", 1, #parts - 1), parts[#parts])
  end
  local chunk, err = loadfile(path, "t", env)
  if not chunk then
    error("cannot load " .. path .. ": " .. tostring(err))
  end
  local ok, result = pcall(chunk)
  if not ok then
    error("error running " .. path .. ": " .. tostring(result))
  end
  return result, env
end

-- Convenience: load a plugin file (service/widget paths use these).
function M.loadPluginFile(pluginDir, fileName)
  return M.loadModule(pluginDir, fileName)
end

return M
