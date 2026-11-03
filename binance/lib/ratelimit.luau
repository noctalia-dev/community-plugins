--!nonstrict
-- Rate-limit pauses shared with the helper through files, so a reload cannot
-- bypass them. The service writes ratelimit-public.json, the helper
-- ratelimit-signed.json; both sides wait until the later deadline. 429 pauses
-- at least 60 s, 418 at least 10 min, doubling while bans repeat. An
-- unreadable file counts as a 60 s pause.

local fs = require("./fs.luau")

local M = {}

M.PUBLIC = "ratelimit-public.json"
M.SIGNED = "ratelimit-signed.json"
local MAX_BACKOFF_S = 6 * 3600

export type Pause = { untilMs: number, status: number }

-- Next pause length after a `status` response, given the previous step.
function M.nextBackoff(status: number, previousS: number?): number
  local floor = if status == 418 then 600 else 60
  return math.min(math.max(floor, (previousS or 0) * 2), MAX_BACKOFF_S)
end

-- Parses one pause file's contents (nil when the file is missing).
function M.parse(raw: string?, decode, now: number): Pause?
  if raw == nil then
    return nil
  end
  local data = decode(raw)
  if type(data) ~= "table" or type(data.until_ms) ~= "number" then
    return { untilMs = now + 60000, status = 429 }
  end
  return { untilMs = data.until_ms, status = if data.status == 418 then 418 else 429 }
end

-- The pause in force now across both files, or nil.
function M.active(dir: string, now: number): Pause?
  local untilMs, status = 0, 0
  for _, name in { M.PUBLIC, M.SIGNED } do
    local path = `{dir}/{name}`
    local raw = if noctalia.fileExists(path) then noctalia.readFile(path) else nil
    local pause = M.parse(raw, noctalia.json.decode, now)
    if pause ~= nil and pause.untilMs > now then
      untilMs = math.max(untilMs, pause.untilMs)
      status = math.max(status, pause.status)
    end
  end
  return if untilMs > 0 then { untilMs = untilMs, status = status } else nil
end

-- Records a public 418/429 and returns the new pause.
function M.recordPublic(dir: string, status: number, now: number): Pause
  local path = `{dir}/{M.PUBLIC}`
  local previous = nil
  if noctalia.fileExists(path) then
    local data = noctalia.json.decode(noctalia.readFile(path) or "")
    if type(data) == "table" and type(data.backoff_s) == "number" then
      previous = data.backoff_s
    end
  end
  local backoff = M.nextBackoff(status, previous)
  local pause = { untilMs = now + backoff * 1000, status = status }
  fs.writeAtomic(path, noctalia.json.encode({ until_ms = pause.untilMs, status = status, backoff_s = backoff }))
  return pause
end

-- After a successful public fetch: an expired pause file resets the doubling.
function M.clearPublic(dir: string, now: number)
  local path = `{dir}/{M.PUBLIC}`
  if noctalia.fileExists(path) then
    local pause = M.parse(noctalia.readFile(path), noctalia.json.decode, now)
    if pause == nil or pause.untilMs <= now then
      noctalia.removeFile(path)
    end
  end
end

return M
