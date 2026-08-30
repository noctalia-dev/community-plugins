local util = require("./util.luau")

local M = {}

M.TRANSPORT = {
  UNKNOWN = "UNKNOWN",
  ABSENT = "ABSENT",
  CTL = "CTL",
  LEGACY = "LEGACY",
  READONLY = "READONLY",
}

M.transport = M.TRANSPORT.UNKNOWN
M.configType = "unknown"
M.hasIsPaused = false
M.hasGetRound = false

local STATES = {
  STOPPED = true, WORKING = true, RESTING = true,
  FINISHED = true, WAITING_FOR_REST = true, WAITING_FOR_WORK = true,
}
M.STATES = STATES

local function run(cmd, cb, timeoutMs)
  return noctalia.runAsync(cmd, cb, timeoutMs or 4000)
end

local function evalFailed(out)
  local t = util.trim(out)
  return not (t == "ok" or t:match("^ok%f[%W]") ~= nil)
end

local function ctlOk(res, validate)
  if res.exitCode ~= 0 then return false end
  local out = util.trim(res.stdout or "")
  if out == "" then return false end
  local lower = out:lower()
  if lower:find("invalid", 1, true) or lower:find("unknown request", 1, true) then return false end
  if validate ~= nil then return validate(out) end
  return true
end

function M.canControl()
  return M.transport == M.TRANSPORT.CTL or M.transport == M.TRANSPORT.LEGACY
end

function M.usesLuaConfig()
  return M.configType == "lua"
end

function M.probe(onDone)
  local function finish(t)
    M.transport = t
    if onDone then onDone(t) end
  end

  run("hyprctl hyprmodoro:getState", function(res)
    if not ctlOk(res, function(out) return STATES[out] == true end) then
      M.hasIsPaused = false
      M.hasGetRound = false
      finish(M.TRANSPORT.ABSENT)
      return
    end

    run('hyprctl eval "return true"', function(e)
      local eo = util.trim(e.stdout or "")
      M.configType = eo:find("only supported with the lua config", 1, true) and "legacy" or "lua"

      run("hyprctl hyprmodoro:isPaused", function(p)
        M.hasIsPaused = ctlOk(p, function(out)
          local v = out:lower()
          return v == "0" or v == "1" or v == "true" or v == "false"
        end)

        run("hyprctl hyprmodoro:getRound", function(r)
          M.hasGetRound = ctlOk(r, function(out) return tonumber(out) ~= nil end)

          run("hyprctl hyprmodoro:version", function(v)
            if ctlOk(v) then
              finish(M.TRANSPORT.CTL)
            elseif M.configType == "legacy" then
              finish(M.TRANSPORT.LEGACY)
            else
              finish(M.TRANSPORT.READONLY)
            end
          end)
        end)
      end)
    end)
  end)
end

local ACTIONS = { start = true, stop = true, pause = true, skip = true, set = true, setRest = true }

local CTL_NAME = { set = "setWork" }

function M.action(name, arg, onDone)
  local function done(ok, message)
    if onDone then onDone(ok, message) end
  end

  if not ACTIONS[name] then
    done(false, "unknown action " .. tostring(name))
    return
  end

  local cmd
  if M.transport == M.TRANSPORT.CTL then
    cmd = "hyprctl hyprmodoro:" .. (CTL_NAME[name] or name)
  elseif M.transport == M.TRANSPORT.LEGACY then
    cmd = "hyprctl dispatch hyprmodoro:" .. name
  else
    done(false, M.transport == M.TRANSPORT.ABSENT and "absent" or "readonly")
    return
  end

  if arg ~= nil then cmd = cmd .. " " .. tostring(arg) end

  run(cmd, function(res)
    local out = util.trim(res.stdout or "")
    local lower = out:lower()
    local ok = res.exitCode == 0
      and not lower:find("failed", 1, true)
      and not lower:find("invalid", 1, true)
      and not lower:find("unknown request", 1, true)
    done(ok, ok and "" or (out ~= "" and out or util.trim(res.stderr or "")))
  end)
end

function M.sequence(steps, onDone)
  local index = 0
  local function step()
    index = index + 1
    local current = steps[index]
    if current == nil then
      if onDone then onDone(true, "") end
      return
    end
    M.action(current[1], current[2], function(ok, message)
      if not ok then
        if onDone then onDone(false, message) end
        return
      end
      step()
    end)
  end
  step()
end

local READ_CMD =
  "hyprctl hyprmodoro:getState; echo; hyprctl hyprmodoro:getTime; echo; hyprctl hyprmodoro:getProgress"
local READ_CMD_PAUSED = READ_CMD .. "; echo; hyprctl hyprmodoro:isPaused"

function M.read(onResult)
  if M.transport == M.TRANSPORT.ABSENT or M.transport == M.TRANSPORT.UNKNOWN then
    onResult(nil)
    return
  end

  run(M.hasIsPaused and READ_CMD_PAUSED or READ_CMD, function(res)
    if res.exitCode ~= 0 then
      onResult(nil)
      return
    end

    local lines = util.splitLines(res.stdout or "")
    local state = lines[1]
    if state == nil or not STATES[state] then
      onResult(nil)
      return
    end

    local paused = nil
    if M.hasIsPaused and lines[4] ~= nil then
      local value = lines[4]:lower()
      paused = value == "1" or value == "true"
    end

    onResult({
      state = state,
      time = lines[2] or "00:00",
      progress = tonumber(lines[3]) or 0,
      paused = paused,
    })
  end)
end

function M.readRound(onResult)
  if not M.hasGetRound then
    onResult(nil)
    return
  end
  run("hyprctl hyprmodoro:getRound", function(res)
    onResult(res.exitCode == 0 and tonumber(util.trim(res.stdout or "")) or nil)
  end)
end

function M.setConfigLua(compactBody, onDone)
  local code = "hl.config({ plugin = { hyprmodoro = { " .. compactBody .. " } } })"
  run("hyprctl eval " .. util.shq(code), function(res)
    local out = util.trim(res.stdout or "")
    local ok = res.exitCode == 0 and not evalFailed(out)
    if onDone then onDone(ok, ok and "" or out) end
  end, 6000)
end

function M.setConfigLegacy(pairsList, onDone)
  local parts = {}
  for _, kv in ipairs(pairsList) do
    table.insert(parts, "hyprctl keyword " .. util.shq("plugin:hyprmodoro:" .. kv[1] .. " " .. kv[2]))
  end
  if #parts == 0 then
    if onDone then onDone(true, "") end
    return
  end
  run(table.concat(parts, "; "), function(res)
    if onDone then onDone(res.exitCode == 0, util.trim(res.stderr or "")) end
  end, 8000)
end

function M.reload(onDone)
  run("hyprctl reload", function(res)
    if onDone then onDone(res.exitCode == 0) end
  end, 8000)
end

return M
