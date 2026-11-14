-- Regression tests for service.luau, runnable with Lua 5.4.
--
-- The service is an entry point: Noctalia loads it once and then calls
-- `update()` every tick. Here the host is simulated (noctalia.state,
-- noctalia.runAsync, noctalia.getConfig...) so the entry point runs the same
-- way it does inside the shell, and the commands it spawns are answered by
-- hand. Then the published state is inspected.
--
-- Usage: lua5.4 bin/test-service.lua service.luau lib/lyrics.luau

local servicePath = arg[1] or "service.luau"
local modelPath = arg[2] or "lib/lyrics.luau"

local checks = 0
local failures = 0

local function check(condition, message)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
  end
end

local function eq(current, expected, message)
  check(
    current == expected,
    string.format("%s (got %s, expected %s)", message, tostring(current), tostring(expected))
  )
end

-- Host simulation -------------------------------------------------------

local store = {}
local pending = {}
local interval = nil
local clock = 1000
local logs = {}

local noctalia = {
  setUpdateInterval = function(ms)
    interval = ms
  end,
  state = {
    set = function(key, value)
      store[key] = value
    end,
    get = function(key)
      return store[key]
    end,
    watch = function()
    end,
  },
  runAsync = function(command, callback)
    pending[#pending + 1] = { command = command, callback = callback }
    return true
  end,
  pluginDir = function()
    return "/plugin"
  end,
  nowMs = function()
    return clock
  end,
  log = function(...)
    local parts = {}
    for index = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(index, ...)))
    end
    logs[#logs + 1] = table.concat(parts, " ")
  end,
  notifyError = function()
  end,
  json = {
    decode = function(text)
      return _G.decode_json(text)
    end,
    encode = function()
      return "{}"
    end,
  },
  getConfig = function()
    return nil
  end,
}

_G.noctalia = noctalia

-- The model module is loaded with dofile and handed to the service through a
-- fake `require`: inside Noctalia `require("./lib/lyrics.luau")` resolves
-- against the plugin root, which is not on Lua's package.path here.
local model = dofile(modelPath)
local realRequire = require
_G.require = function(name)
  if name == "./lib/lyrics.luau" or name == "lib/lyrics.luau" then
    return model
  end
  return realRequire(name)
end

dofile(servicePath)

-- Helpers ---------------------------------------------------------------

-- Small JSON decoder, only for the shapes lyrics-fetch.py prints: a flat
-- object whose values are numbers, booleans, strings, null or an array of flat
-- objects. That is enough to exercise the service.
local function decode_json(text)
  local position = 1

  local function skip()
    while position <= #text and text:sub(position, position):match("%s") do
      position = position + 1
    end
  end

  local parseValue

  local function parseString()
    position = position + 1
    local out = {}
    while position <= #text do
      local char = text:sub(position, position)
      if char == '"' then
        position = position + 1
        return table.concat(out)
      elseif char == "\\" then
        position = position + 1
        local escape = text:sub(position, position)
        if escape == "n" then
          out[#out + 1] = "\n"
        elseif escape == "t" then
          out[#out + 1] = "\t"
        elseif escape == "u" then
          out[#out + 1] = "?"
          position = position + 4
        else
          out[#out + 1] = escape
        end
        position = position + 1
      else
        out[#out + 1] = char
        position = position + 1
      end
    end
    return table.concat(out)
  end

  local function parseNumber()
    local start = position
    while position <= #text and text:sub(position, position):match("[-%d%.eE+]") do
      position = position + 1
    end
    return tonumber(text:sub(start, position - 1))
  end

  local function parseArray()
    local list = {}
    position = position + 1
    skip()
    if text:sub(position, position) == "]" then
      position = position + 1
      return list
    end
    while true do
      list[#list + 1] = parseValue()
      skip()
      local char = text:sub(position, position)
      position = position + 1
      if char == "]" then
        return list
      end
    end
  end

  local function parseObject()
    local object = {}
    position = position + 1
    skip()
    if text:sub(position, position) == "}" then
      position = position + 1
      return object
    end
    while true do
      skip()
      local key = parseString()
      skip()
      position = position + 1 -- ':'
      object[key] = parseValue()
      skip()
      local char = text:sub(position, position)
      position = position + 1
      if char == "}" then
        return object
      end
    end
  end

  parseValue = function()
    skip()
    local char = text:sub(position, position)
    if char == "{" then
      return parseObject()
    elseif char == "[" then
      return parseArray()
    elseif char == '"' then
      return parseString()
    elseif text:sub(position, position + 3) == "true" then
      position = position + 4
      return true
    elseif text:sub(position, position + 4) == "false" then
      position = position + 5
      return false
    elseif text:sub(position, position + 3) == "null" then
      position = position + 4
      return nil
    end
    return parseNumber()
  end

  return parseValue()
end

_G.decode_json = decode_json

-- Runs the next spawned command and answers it. Returns the command.
local function pump(exitCode, stdout, stderr)
  local entry = table.remove(pending, 1)
  if entry == nil then
    return nil
  end
  if entry.callback ~= nil then
    entry.callback({
      exitCode = exitCode or 0,
      stdout = stdout or "",
      stderr = stderr or "",
    })
  end
  return entry.command
end

local function pumpAll()
  local seen = {}
  while #pending > 0 do
    seen[#seen + 1] = pump(0, "")
  end
  return seen
end

local function joins(command)
  if type(command) == "table" then
    return table.concat(command, " ")
  end
  return tostring(command)
end

local function takePending(predicate)
  for index = 1, #pending do
    if predicate(joins(pending[index].command)) then
      return table.remove(pending, index)
    end
  end
  return nil
end

local function answer(entry, exitCode, stdout)
  if entry == nil or entry.callback == nil then
    return
  end
  entry.callback({ exitCode = exitCode, stdout = stdout, stderr = "" })
end

local playerLine = function(status, position, length, title, artist)
  return table.concat({
    status,
    tostring(position),
    tostring(length),
    title,
    artist,
  }, "\t")
end

local function poll(line)
  pending = {}
  update()
  local entry = takePending(function(command)
    return command:match("^playerctl")
  end)
  if entry == nil then
    return false
  end
  answer(entry, line and 0 or 1, line or "")
  return true
end

local function fetchAnswer(json)
  local entry = takePending(function(command)
    return command:match("lyrics%-fetch%.py")
  end)
  answer(entry, 0, json)
  return entry ~= nil
end

-- The JSON the adapter prints for one synced track.
local function payload(title, artist)
  return string.format(
    '{"ok":true,"source":"lrclib","synced":true,"cached":false,"lines":['
      .. '{"start":0,"end":2.5,"text":"first line"},'
      .. '{"start":2.5,"end":5,"text":"second line"}]}'
  )
end

-- 1. The tick rate and the initial state --------------------------------

eq(interval, 500, "the service ticks twice a second")
eq(store.loading, false, "it starts without a pending search")
eq(store.track, nil, "it starts without a track")
eq(store.lyrics, nil, "it starts without lyrics")

-- 2. No player -----------------------------------------------------------

poll(nil)
eq(store.track, nil, "without a player there is no track")
eq(store.lyrics, nil, "without a player there are no lyrics")
eq(store.error, nil, "without a player there is no error")
eq(store.loading, false, "without a player nothing is loading")

-- 3. A playing track -----------------------------------------------------

clock = 5000
poll(playerLine("Playing", 1500000, 200000000, "Song", "Artist"))

local track = store.track
check(type(track) == "table", "a playing track is published")
if type(track) == "table" then
  eq(track.title, "Song", "the track carries the title")
  eq(track.artist, "Artist", "the track carries the artist")
  eq(track.duration, 200, "the microsecond length becomes seconds")
  eq(track.playing, true, "the track knows it is playing")
  eq(track.positionMs, 1500, "the position is published in milliseconds")
  eq(track.positionAtMs, 5000, "the position carries the moment it was read")
  eq(track.key, model.trackKey("Song", "Artist", 200), "the track key identifies it")
end
eq(store.loading, true, "the lyrics are marked as loading")
eq(store.lyrics, nil, "the previous lyrics are dropped")

-- 4. The adapter answer --------------------------------------------------

check(fetchAnswer(payload("Song", "Artist")), "the service asks the adapter for lyrics")
check(type(store.lyrics) == "table", "the lyrics are published")
if type(store.lyrics) == "table" then
  eq(#store.lyrics.lines, 2, "the lyrics keep their lines")
  eq(store.lyrics.synced, true, "the lyrics know they are synced")
end
eq(store.loading, false, "it stops loading when the answer arrives")
eq(store.error, nil, "a good answer leaves no error")

-- 5. The same track is not fetched again --------------------------------

clock = 6000
poll(playerLine("Playing", 2500000, 200000000, "Song", "Artist"))
local refetch = takePending(function(command)
  return command:match("lyrics%-fetch%.py")
end)
check(refetch == nil, "the same track is not fetched twice")
check(type(store.lyrics) == "table", "the lyrics survive the next poll")

-- 6. Pausing keeps the track and does not refetch -----------------------

clock = 7000
poll(playerLine("Paused", 2500000, 200000000, "Song", "Artist"))
local pausedTrack = store.track
check(type(pausedTrack) == "table", "a paused track is still a track")
if type(pausedTrack) == "table" then
  eq(pausedTrack.playing, false, "the track knows it is paused")
  eq(pausedTrack.positionMs, 2500, "the paused position is kept")
end
check(
  takePending(function(command)
    return command:match("lyrics%-fetch%.py")
  end) == nil,
  "pausing does not fetch lyrics again"
)

-- 7. A stale answer is discarded (focus 4) ------------------------------

clock = 8000
poll(playerLine("Playing", 1000, 100000000, "Other", "Someone"))
local staleEntry = takePending(function(command)
  return command:match("lyrics%-fetch%.py")
end)
check(staleEntry ~= nil, "the new track is fetched")

clock = 8500
poll(playerLine("Playing", 2000, 100000000, "Third", "Nobody"))
local currentEntry = takePending(function(command)
  return command:match("lyrics%-fetch%.py")
end)
check(currentEntry ~= nil, "the third track is fetched too")

-- The answer for "Other" arrives late: it must not overwrite "Third".
answer(staleEntry, 0, payload("Other", "Someone"))
eq(store.loading, true, "a stale answer does not clear the loading flag")
eq(
  store.track.key,
  model.trackKey("Third", "Nobody", 100),
  "a stale answer does not change the track"
)
check(store.lyrics == nil, "a stale answer does not publish its lyrics")

answer(currentEntry, 0, payload("Third", "Nobody"))
check(store.lyrics ~= nil, "the answer of the current track is published")

-- 8. An empty answer is an error, not a crash ---------------------------

clock = 9000
poll(playerLine("Playing", 1000, 100000000, "Unknown", "Nobody"))
fetchAnswer('{"ok":false,"error":"not_found"}')
eq(store.lyrics, nil, "a failed search leaves no lyrics")
eq(store.error, "not_found", "a failed search publishes the reason")
eq(store.loading, false, "a failed search stops loading")

-- 9. Broken output does not crash ---------------------------------------

clock = 10000
poll(playerLine("Playing", 1000, 100000000, "Broken", "Nobody"))
fetchAnswer("not json at all")
eq(store.lyrics, nil, "unparsable output leaves no lyrics")
eq(store.loading, false, "unparsable output stops loading")
check(type(store.error) == "string", "unparsable output is reported")

-- 10. IPC refresh asks for the same track again -------------------------

clock = 11000
poll(playerLine("Playing", 1000, 100000000, "Broken", "Nobody"))
onIpc("refresh", nil)
local forced = takePending(function(command)
  return command:match("lyrics%-fetch%.py")
end)
check(forced ~= nil, "refresh asks the adapter again")
if forced ~= nil then
  check(joins(forced.command):match("%-%-force") ~= nil, "refresh forces the search")
  answer(forced, 0, payload("Broken", "Nobody"))
end
check(store.lyrics ~= nil, "refresh publishes what it finds")

-- 11. A new track clears the previous error -----------------------------

clock = 12000
poll(playerLine("Playing", 1000, 100000000, "Fresh", "Nobody"))
eq(store.error, nil, "a new track clears the previous error")
eq(store.loading, true, "a new track starts loading")

-- 12. The per-track break ------------------------------------------------

eq(store.brain, true, "a new track gets the karaoke fill back")
onIpc("brain", nil)
eq(store.brain, false, "the brain IPC turns the fill off")

clock = 13000
poll(playerLine("Playing", 2000, 100000000, "Fresh", "Nobody"))
eq(store.brain, false, "the same track keeps the fill off")

clock = 14000
poll(playerLine("Playing", 1000, 100000000, "Another", "Nobody"))
eq(store.brain, true, "a new track turns the fill back on")

-- Result ------------------------------------------------------------------

if failures > 0 then
  io.stderr:write(string.format("%d of %d checks failed\n", failures, checks))
  os.exit(1)
end
print(string.format("%d checks passed", checks))
