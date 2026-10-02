-- lib/tracker.luau — core session logic.
--
-- The tracker is pure Luau: it consumes events and mutates a session list.
-- It never touches the host, so the test suite can drive it deterministically.
--
-- Principles (spec §10, §14–§17):
--   * Same app continuously -> ONE session (samples merge into the open
--     session; a 2 s poll builds hour-long sessions, not 1800 rows).
--   * App switch Firefox→Kitty→Firefox -> three separate sessions.
--   * Idle / lock / suspend / clock jump close the session and nothing in the
--     unobserved gap is credited to anyone: undercount, never fabricate.
--   * After any close, the next observed sample starts a NEW session.
--
-- Session shape:
--   { id, dateKey, appId, appName, title?, startedAtMs, endedAtMs?,
--     durationSeconds?, open? }
--
-- Excluded applications (the Noctalia shell itself — see lib/exclusion.luau)
-- are rejected at beginSession(), i.e. BEFORE any session is created and
-- before duration can ever accumulate. An excluded sample behaves exactly
-- like "no trackable application": the open user-app session is closed at
-- its last real observation and the excluded interval is an untracked gap.

local M = {}

local exclusion = require("./exclusion.luau")

local function safeStr(v)
  if type(v) == "string" and v ~= "" then
    return v
  end
  return nil
end

-- makeId(nowMs) -> unique, chronologically sortable session id.
function M.makeId(nowMs)
  local seq = (M._seq or 0) + 1
  M._seq = seq
  local datePart = os.date("!%Y%m%d%H%M%S", math.floor(nowMs / 1000))
  return string.format("s-%s-%03d-%03d", datePart, nowMs % 1000, seq % 1000)
end

function M.newTracker(opts)
  opts = opts or {}
  local newId = opts.makeId or M.makeId
  local maxGapMs = opts.maxGapMs or 120000
  local dateKeyFn = opts.dateKeyFn
  if not dateKeyFn then
    dateKeyFn = function(ms)
      local t = os.date("*t", math.floor(ms / 1000))
      return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
    end
  end

  local self = {
    sessions = {},      -- closed sessions (append-only) + at most one open
    open = nil,         -- currently open session or nil
    lastSampleMs = nil, -- last observed "active" moment
    lastAppId = nil,
    lastTitle = nil,
    _idSeq = 0,
  }

  local function beginSession(app, atMs)
    -- Hard gate: the shell (and any other excluded id) can never become a
    -- session, on any code path that reaches here.
    if exclusion.isExcludedApplication(app) then
      return nil
    end
    self._idSeq = self._idSeq + 1
    local session = {
      id = newId(atMs),
      dateKey = dateKeyFn(atMs),
      appId = safeStr(app.appId) or "unknown",
      appName = safeStr(app.appName) or app.appId or "Unknown",
      startedAtMs = atMs,
    }
    if app.title then
      session.title = app.title
    end
    session.open = true
    self.open = session
    return session
  end

  -- Close the open session at endMs. Returns the closed session or nil.
  local function closeAt(endMs)
    local s = self.open
    if not s then
      return nil
    end
    s.open = nil
    s.endedAtMs = endMs
    s.durationSeconds = math.max(0, math.floor((endMs - s.startedAtMs) / 1000))
    self.open = nil
    table.insert(self.sessions, s)
    return s
  end

  -- Close and drop the sampling anchor, so the next sample starts fresh.
  local function closeOpen(endMs)
    local closed = closeAt(endMs)
    self.lastSampleMs = nil
    self.lastAppId = nil
    self.lastTitle = nil
    return closed
  end

  -- consume(event, nowMs) -> table of closed sessions produced by this event.
  function self:consume(ev, nowMs)
    local produced = {}
    local kind = ev.type

    if kind == "start" then
      -- Service startup: previous state is unknowable, close defensively.
      local closed = closeOpen(nowMs)
      if closed then
        produced[#produced + 1] = closed
      end

    elseif kind == "sample" then
      local app = ev.app
      if not app or safeStr(app.appId) == nil then
        -- No readable active window: treat as unknown state.
        local closed = closeOpen(self.lastSampleMs or nowMs)
        if closed then
          produced[#produced + 1] = closed
        end
        return produced
      end

      if self.lastSampleMs == nil then
        local session = beginSession(app, nowMs)
        if session == nil then
          -- Excluded application (e.g. the Noctalia shell itself): no
          -- session, no sampling anchor; the interval stays untracked.
          closeOpen(self.lastSampleMs or nowMs)
          return produced
        end
        self.lastSampleMs = nowMs
        self.lastAppId = app.appId
        self.lastTitle = app.title
        return produced
      end

      local delta = nowMs - self.lastSampleMs
      if delta < 0 or delta > maxGapMs then
        -- Clock jumped backwards, or a long unobserved gap (suspend, VM
        -- pause, SIGSTOP). End the old session at its last real observation;
        -- the gap itself is credited to nobody.
        local closed = closeOpen(self.lastSampleMs)
        if closed then
          produced[#produced + 1] = closed
        end
        local session = beginSession(app, nowMs)
        if session == nil then
          -- Excluded app after a gap: the gap stays untracked, nothing opens.
          return produced
        end
        self.lastSampleMs = nowMs
        self.lastAppId = app.appId
        self.lastTitle = app.title
        return produced
      end

      if app.appId ~= self.lastAppId then
        -- App switch happened somewhere inside (lastSampleMs, nowMs]; split
        -- the uncertainty at the midpoint so neither app is systematically
        -- favored. Boundaries stay clean: old ends where the new begins.
        local boundary = math.floor((self.lastSampleMs + nowMs) / 2)
        local closed = closeAt(boundary)
        if closed then
          produced[#produced + 1] = closed
        end
        local session = beginSession(app, boundary)
        if session == nil then
          -- Switching to an excluded app (e.g. Noctalia) closes the user-app
          -- session here; the anchors are dropped so the excluded interval is
          -- an untracked gap, and the next user app opens a fresh session.
          self.lastSampleMs = nil
          self.lastAppId = nil
          self.lastTitle = nil
          return produced
        end
        self.lastSampleMs = nowMs
        self.lastAppId = app.appId
        self.lastTitle = app.title
        return produced
      end

      -- Same app continues: just extend the observation window.
      self.lastSampleMs = nowMs
      if ev.trackTitle and app.title ~= nil and app.title ~= self.lastTitle then
        self.lastTitle = app.title
        if self.open then
          self.open.title = app.title
        end
      end

    elseif kind == "idle" or kind == "close" or kind == "suspend" or kind == "pause" then
      local closed = closeOpen(self.lastSampleMs or nowMs)
      if closed then
        produced[#produced + 1] = closed
      end

    elseif kind == "resume" then
      -- Defensive: ensure nothing carries across a resume boundary.
      local closed = closeOpen(nowMs)
      if closed then
        produced[#produced + 1] = closed
      end
    end

    return produced
  end

  -- The appId of the open session, or nil.
  function self:activeAppId()
    if self.open then
      return self.open.appId
    end
    return nil
  end

  return self
end

-- pruneSessions(sessions, todayKey, retentionDays) -> kept, removedCount
-- Drops closed sessions older than the retention window and any zero- or
-- negative-length sessions (pathological rows). Invalid dateKeys are dropped
-- as garbage. The open session (if passed) is always kept.
function M.pruneSessions(sessions, todayKey, retentionDays)
  local kept, removed = {}, 0
  -- cutoff = today - (retentionDays - 1); keep dateKey >= cutoff.
  local cutoff = todayKey
  for _ = 1, math.max(0, (retentionDays or 30) - 1) do
    cutoff = M.prevDay(cutoff)
  end
  for _, s in ipairs(sessions or {}) do
    if type(s) ~= "table" then
      removed = removed + 1
    elseif s.open then
      kept[#kept + 1] = s
    elseif type(s.dateKey) ~= "string" or #s.dateKey ~= 10 or s.dateKey < cutoff then
      removed = removed + 1
    elseif (s.durationSeconds or 0) <= 0 then
      removed = removed + 1
    else
      kept[#kept + 1] = s
    end
  end
  return kept, removed
end

-- prevDay(dateKey) -> the day before (pure string arithmetic, ISO ordering).
function M.prevDay(dateKey)
  if type(dateKey) ~= "string" then
    return dateKey
  end
  local y, m, d = dateKey:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return dateKey
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  d = d - 1
  if d == 0 then
    m = m - 1
    if m == 0 then
      y, m = y - 1, 12
    end
    local daysInMonth = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    local len = daysInMonth[m]
    if m == 2 and ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) then
      len = 29
    end
    d = len
  end
  return string.format("%04d-%02d-%02d", y, m, d)
end

return M
