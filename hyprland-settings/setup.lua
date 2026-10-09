-- One-time setup, only when the user presses "Set up" in the panel: creates
-- the settings file and adds require("<module>") to the end of hyprland.lua,
-- with a backup. Plain Lua like txn.lua, run under the same lock:
--
--   flock -w 10 <data>/lock lua setup.lua <hyprland.lua> <settings file> <module> <backup dir>
--
-- Prints "present" (line already there) or "added". Exit codes: 1 usage,
-- 3 no Lua config (hyprland.conf only), 4 syntax error after the change,
-- 6 I/O. Nothing is changed unless everything before the rename worked.

local conf, settings, module, backups = arg[1], arg[2], arg[3], arg[4]

local function fail(code, message)
  io.stderr:write(message, "\n")
  os.exit(code)
end

if not (conf and settings and module and backups and module:match("^[%w_%-]+$")) then
  fail(1, "usage: setup.lua <hyprland.lua> <settings file> <module> <backup dir>")
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function resolve(path)
  local p = io.popen("readlink -f -- " .. shellQuote(path))
  local real = p and p:read("l")
  if p then p:close() end
  if real == nil or real == "" then fail(6, "cannot resolve " .. path) end
  return real
end

-- nil only when the file does not exist.
local function read(path)
  local f, err, errno = io.open(path, "rb")
  if f == nil then
    if errno == 2 then return nil end
    fail(6, "cannot open " .. path .. ": " .. tostring(err))
  end
  local text, rerr = f:read("a")
  f:close()
  if text == nil then fail(6, "cannot read " .. path .. ": " .. tostring(rerr)) end
  return text
end

local function write(path, text)
  local f, err = io.open(path, "wb")
  if f == nil then fail(6, "cannot write " .. path .. ": " .. tostring(err)) end
  local ok, werr = f:write(text)
  local cok = f:close()
  if not ok or not cok then fail(6, "cannot write " .. path .. ": " .. tostring(werr)) end
end

local realConf = resolve(conf)
local text = read(realConf)
if text == nil then
  local dir = conf:match("^(.*)/[^/]*$") or "."
  if read(dir .. "/hyprland.conf") ~= nil then fail(3, "hyprland.conf found: this plugin needs Hyprland's Lua config") end
  fail(3, "no hyprland.lua at " .. conf)
end

-- The settings file must exist before the require, or Hyprland fails to
-- load it and never watches it.
local realSettings = resolve(settings)
if read(realSettings) == nil then write(realSettings, "") end

local escaped = module:gsub("%-", "%%-")
if text:find("require%s*%(?%s*[\"']" .. escaped .. "[\"']") then
  print("present")
  os.exit(0)
end

os.execute("mkdir -p " .. shellQuote(backups))
write(backups .. "/hyprland.lua.before-setup-" .. os.date("%Y%m%d-%H%M%S"), text)

local added = (text == "" or text:sub(-1) == "\n") and text or (text .. "\n")
added = added .. "\n-- Added by Hyprland Settings (Noctalia plugin): loads the file its panel writes.\n"
  .. "-- Move it up if a later block here must win over the panel.\n"
  .. 'require("' .. module .. '")\n'

local tmp = realConf .. ".hs-tmp"
write(tmp, added)
if not os.execute("luac -p " .. shellQuote(tmp) .. " >&2") then
  os.remove(tmp)
  fail(4, "syntax error after adding the line, nothing changed")
end
local ok, err = os.rename(tmp, realConf)
if not ok then
  os.remove(tmp)
  fail(6, "cannot replace " .. realConf .. ": " .. tostring(err))
end
print("added")
