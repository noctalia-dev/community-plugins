--!nonstrict
local format = require("./format.luau")
local settings = require("./settings.luau")
local store = require("./store.luau")
local types = require("./types.luau")

local M = {}

local FILE = "reminded.json"

local reminded: { [string]: boolean } = {}

function M.load()
  local data = store.read(FILE)
  if type(data) == "table" then
    reminded = data
  end
end

local function shq(s: string): string
  return "'" .. (string.gsub(s, "'", "'\\''")) .. "'"
end

function M.notify(c: types.Contest, text: string)
  local title = `{c.src} · {c.name}`
  if not noctalia.commandExists("notify-send") then
    noctalia.notify(title, text)
    return
  end
  local cmd = "notify-send -a Contests -t 120000 -w -A "
    .. shq("default=" .. noctalia.tr("reminders.open")) .. " " .. shq(title) .. " " .. shq(text)
  local accepted = noctalia.runStream(cmd, function(line: string)
    if line == "default" then
      noctalia.runAsync({ "xdg-open", c.url })
    end
  end)
  if not accepted then
    noctalia.notify(title, text)
  end
end

function M.check(upcoming: { types.Contest }, favorites: { [string]: boolean })
  if not settings.remindersEnabled() then
    return
  end
  local now = os.time()
  local lead = settings.remindLeadSeconds()
  local atStart = settings.remindAtStart()
  local dirty = false
  local present: { [string]: boolean } = {}

  for _, c in ipairs(upcoming) do
    local leadKey = c.url .. "|lead"
    local startKey = c.url .. "|start"
    present[leadKey] = true
    present[startKey] = true
    if favorites[c.url] then
      if lead > 0 and now >= c.start - lead and now < c.start and not reminded[leadKey] then
        reminded[leadKey] = true
        dirty = true
        M.notify(c, noctalia.tr("reminders.starts_in", { time = format.fmtDur(c.start - now) }))
      end
      if atStart and now >= c.start and now < c.start + 120 and not reminded[startKey] then
        reminded[startKey] = true
        dirty = true
        M.notify(c, noctalia.tr("reminders.starting_now"))
      end
    end
  end

  if next(present) ~= nil then
    for key in pairs(reminded) do
      if not present[key] then
        reminded[key] = nil
        dirty = true
      end
    end
  end
  if dirty then
    store.write(FILE, reminded)
  end
end

return M
