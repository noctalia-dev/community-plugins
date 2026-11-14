local mp = require("mp")
local options = { enabled = false, action = "", record_dir = "", queue_events = "", queue_path = "", clear_id = "" }
require("mp.options").read_options(options, "youtube-resume")
if not options.enabled then return end
local utils = require("mp.utils")
local function env(name)
  local value = os.getenv(name)
  return value and value ~= "" and value or nil
end
local state = env("NOCTALIA_STATE_HOME") or env("XDG_STATE_HOME")
  or ((env("HOME") or "") .. "/.local/state")
local data = state .. "/noctalia/plugins/data/nullflake/youtube-explorer"
local dir = options.record_dir ~= "" and options.record_dir or (data .. "/resume")
local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a"); f:close(); return body
end
local function validId(id)
  return type(id) == "string" and #id == 11 and id:match("^[A-Za-z0-9_-]+$") ~= nil
end
local writeSerial = 0
local writerId = tostring(utils.getpid())
local function write(path, body)
  writeSerial = writeSerial + 1
  local temporary = path .. ".part." .. writerId .. "." .. writeSerial
  local f = io.open(temporary, "w")
  if not f then return false end
  local ok = f:write(body)
  local closed = f:close()
  if ok and closed and os.rename(temporary, path) then return true end
  os.remove(temporary); return false
end
local made = mp.command_native({name = "subprocess", args = {
  "mkdir", "-p", "-m", "700", "--", dir}, playback_only = false})
if not made or made.status ~= 0 then
  mp.msg.error("Cannot create resume storage")
  if options.action ~= "" then mp.commandv("quit", 1) end
  return
end
local function url(id) return "https://www.youtube.com/watch?v=" .. id end
local function removeResume(id, original)
  if not mp.commandv("delete-watch-later-config", url(id)) then return false end
  if original and original ~= url(id) and not mp.commandv("delete-watch-later-config", original) then return false end
  local path = dir .. "/" .. id .. ".json"
  if utils.file_info(path) and not os.remove(path) then return false end
  return true
end
if options.action ~= "" then
  if options.action ~= "clear" then mp.commandv("quit", 1); return end
  local target = options.clear_id
  if target ~= "" and not validId(target) then mp.commandv("quit", 1); return end
  local names = utils.readdir(dir, "files")
  if not names then mp.msg.error("Cannot read resume storage"); mp.commandv("quit", 1); return end
  local marker = target ~= "" and (".reset-" .. target) or ".reset"
  local ok = write(dir .. "/" .. marker, tostring(os.time()) .. ":" .. writerId .. ":" .. tostring(mp.get_time()))
  if ok then
    for _, name in ipairs(names) do
      local candidate = name:match("^([A-Za-z0-9_-]+)%.json$")
      if validId(candidate) and (target == "" or candidate == target) then
        local entry = utils.parse_json(read(dir .. "/" .. name) or "")
        -- Only use original URLs written by this script, never local paths.
        local original = type(entry) == "table" and type(entry.url) == "string"
          and entry.url:match("^https?://") and entry.url or nil
        if not removeResume(candidate, original) then ok = false end
      end
    end
  end
  mp.commandv("quit", ok and 0 or 1); return
end

local id, original, position, length, title, reset, itemReset
local completed, suppressed = false, false
local function saveProgress()
  if not id then return end
  if read(dir .. "/.reset") ~= reset or read(dir .. "/.reset-" .. id) ~= itemReset then
    suppressed = true
    mp.set_property_bool("save-position-on-quit", false)
    removeResume(id, original)
  end
  if completed or suppressed or not position or not length or length <= 0
    or position <= 0 or position >= length then return end
  mp.commandv("write-watch-later-config")
  if not write(dir .. "/" .. id .. ".json", utils.format_json({id = id, url = original,
    title = title, position = position, length = length, updatedAt = os.time()})) then
    mp.msg.error("Could not save playback progress")
  end
end
mp.register_event("file-loaded", function()
  original = mp.get_property("path", "")
  local host, path = original:match("^https?://([^/]+)/(.+)$")
  local candidate
  if host == "youtu.be" then candidate = path:match("^([^?&#/]+)")
  elseif host == "youtube.com" or host == "www.youtube.com" or host == "m.youtube.com"
    or host == "music.youtube.com" then
    candidate = path:match("^watch%?v=([^&#]+)") or path:match("^watch%?.-&v=([^&#]+)")
      or path:match("^shorts/([^?&#/]+)") or path:match("^live/([^?&#/]+)") or path:match("^embed/([^?&#/]+)")
  end
  id = validId(candidate) and candidate or nil
  position, length, title = nil, mp.get_property_number("duration"), mp.get_property("media-title", id or "")
  completed, suppressed, reset = false, false, read(dir .. "/.reset")
  itemReset = id and read(dir .. "/.reset-" .. id) or nil
  mp.set_property_bool("save-position-on-quit", true)
  if id and options.queue_events ~= "" then
    local madeEvents = mp.command_native({name = "subprocess", args = {
      "mkdir", "-p", "-m", "700", "--", options.queue_events}, playback_only = false})
    if madeEvents and madeEvents.status == 0 then
      local name = string.format("%010d.%s.%010d.json", os.time(), writerId, writeSerial + 1)
      local event = {id = id}
      local queue = utils.parse_json(read(options.queue_path) or "")
      if type(queue) == "table" and type(queue.items) == "table" then
        for _, item in ipairs(queue.items) do
          if item.id == id then event = item; break end
        end
      end
      if not write(options.queue_events .. "/" .. name, utils.format_json(event)) then
        mp.msg.error("Could not record queued playback")
      end
    else mp.msg.error("Cannot create queue event storage") end
  end
end)
mp.observe_property("time-pos", "number", function(_, value) if value then position = value end end)
mp.observe_property("duration", "number", function(_, value) if value then length = value end end)
mp.observe_property("pause", "bool", function(_, paused) if paused then saveProgress() end end)
mp.add_periodic_timer(5, saveProgress)
mp.register_event("end-file", function(event)
  -- Automatic playlist transitions may clear eof-reached before its observer runs.
  if event.reason == "eof" and id then
    completed = true
    removeResume(id, original)
  else saveProgress() end
  id, position, length = nil, nil, nil
end)
mp.register_event("shutdown", saveProgress)

-- keep-open leaves the player at EOF; completed videos should start over.
mp.observe_property("eof-reached", "bool", function(_, eof)
  completed = eof == true
  mp.set_property_bool("save-position-on-quit", not eof and not suppressed)
  if eof then
    mp.commandv("delete-watch-later-config")
    if id then removeResume(id, original) end
  end
end)
