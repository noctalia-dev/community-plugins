-- Headless service: rotates salawat / azkar reminders, with every Nth
-- reminder a random Quran verse fetched from api.alquran.cloud.
-- Azkar come from the online azkar.json pool with time-based category
-- (morning 04:00–18:00, evening otherwise); bundled reminders stay as
-- the offline fallback for every source.

local reminders = require("./lib/reminders.luau")
local quran = require("./lib/quran.luau")
local azkar = require("./lib/azkar.luau")

local TICK_MS = 30 * 1000
local AZKAR_REFRESH_MS = 6 * 60 * 60 * 1000
local cursor = 0
local fireCount = 0
local nextFireMs = nil
local lastAzkarFetchMs = nil

math.randomseed(noctalia.nowMs())
noctalia.setUpdateInterval(TICK_MS)

local function intervalMs()
  local mins = noctalia.getConfig("interval")
  if type(mins) ~= "number" or mins < 1 then
    mins = 30
  end
  return mins * 60 * 1000
end

local function cfgBool(key, default)
  local v = noctalia.getConfig(key)
  if v == nil then
    return default
  end
  return v
end

local function cfgCount(key, default)
  local n = noctalia.getConfig(key)
  if type(n) ~= "number" or n < 1 then
    return default
  end
  return math.min(n, 10)
end

local function isEnabled()
  return noctalia.state.get("zakker/enabled") ~= false
end

local function quranEvery()
  local n = noctalia.getConfig("quran_every")
  if type(n) ~= "number" or n < 1 then
    n = 3
  end
  return n
end

local function publish(item)
  noctalia.state.set("zakker/latest", item.text)
  noctalia.state.set("zakker/kind", item.kind)
  noctalia.notify(item.title, item.text)
end

local function fireBundled(salawat_on, azkar_on)
  local items = reminders.collect(salawat_on, azkar_on)
  if #items == 0 then
    return false
  end
  cursor = (cursor % #items) + 1
  publish(items[cursor])
  return true
end

---@return boolean true when this side published (a disabled side publishes nothing)
local function fireSalawatSide()
  if not cfgBool("salawat_enabled", true) then
    return false
  end
  if fireBundled(true, false) then
    return true
  end
  -- enabled but empty (not expected with the bundled pool): any bundled item
  return fireBundled(true, true)
end

---@return boolean true when this side published (a disabled side publishes nothing)
local function fireAzkarSide()
  if not cfgBool("azkar_enabled", true) then
    return false
  end
  if azkar.hasItems() then
    local key, label = azkar.category()
    local n = cfgCount(key == azkar.MORNING_KEY and "morning_count" or "evening_count", 3)
    local items = azkar.take(key, n)
    if #items > 0 then
      publish({ kind = "dhikr", title = "🤲 " .. label, text = azkar.format(items) })
      return true
    end
  end
  -- offline: bundled azkar, else anything bundled
  if fireBundled(false, true) then
    return true
  end
  return fireBundled(true, true)
end

-- Fallback chain honoring the enable flags: azkar side, then salawat side.
local function fireFallback()
  if not fireAzkarSide() then
    fireSalawatSide()
  end
end

local function fireQuran()
  local edition = noctalia.getConfig("edition")
  if type(edition) ~= "string" or edition == "" then
    edition = "ar.abdulbasitmurattal"
  end
  local n = math.random(1, quran.AYAHS_COUNT)
  local accepted = noctalia.http({ url = quran.ayahUrl(n, edition) }, function(res)
    if not res.ok or res.status ~= 200 then
      noctalia.log("zakker quran fetch failed: ok=" .. tostring(res.ok) .. " status=" .. tostring(res.status))
      fireFallback()
      return
    end
    local decoded, err = noctalia.json.decode(res.body)
    if decoded == nil or decoded.code ~= 200 or decoded.data == nil then
      noctalia.log("zakker quran decode failed: " .. tostring(err))
      fireFallback()
      return
    end
    local ayah = quran.normalize(decoded.data, edition)
    noctalia.log("zakker quran ok #" .. tostring(ayah.number))
    local body = ayah.text .. "\n\n— " .. quran.header(ayah)
    local trEdition = noctalia.getConfig("translation_edition")
    if type(trEdition) == "string" and trEdition ~= "" then
      noctalia.http({ url = quran.ayahUrl(ayah.number, trEdition) }, function(res2)
        if res2.ok and res2.status == 200 then
          local d2, _ = noctalia.json.decode(res2.body)
          if d2 ~= nil and d2.code == 200 and d2.data ~= nil then
            local t = d2.data.text
            if type(t) == "string" then
              if t:sub(1, 3) == "\239\187\191" then
                t = t:sub(4)
              end
              body = body .. "\n\n— " .. t
            end
          end
        end
        publish({ kind = "quran", title = "📖 آية من القرآن", text = body })
      end)
    else
      publish({ kind = "quran", title = "📖 آية من القرآن", text = body })
    end
  end)
  if not accepted then
    noctalia.log("zakker quran request not accepted")
    fireFallback()
  end
end

local function fire()
  fireCount = fireCount + 1
  local quranOn = cfgBool("quran_enabled", true)
  local every = quranEvery()
  if quranOn and (fireCount % every) == 0 then
    fireQuran()
    return
  end
  -- non-quran turns alternate salawat / azkar so both keep appearing;
  -- a disabled side yields its turns to the other enabled side
  if (fireCount % 2) == 0 then
    if not fireAzkarSide() then
      fireSalawatSide()
    end
  else
    if not fireSalawatSide() then
      fireAzkarSide()
    end
  end
end

-- Boot: fetch the online azkar pool, then fire the first reminder as
-- time-aware azkar (morning 04:00–18:00, else evening). Falls back to
-- bundled azkar offline; honors azkar_enabled/salawat_enabled inside.
lastAzkarFetchMs = noctalia.nowMs()
azkar.refresh(function()
  lastAzkarFetchMs = noctalia.nowMs()
  if cfgBool("notify_on_start", true) then
    fireFallback()
  end
end)

function update()
  local now = noctalia.nowMs()
  if lastAzkarFetchMs == nil or (now - lastAzkarFetchMs) >= AZKAR_REFRESH_MS then
    azkar.refresh()
    lastAzkarFetchMs = now
  end
  if not isEnabled() then
    return
  end
  if nextFireMs == nil then
    nextFireMs = now + intervalMs()
    return
  end
  if now >= nextFireMs then
    fire()
    nextFireMs = now + intervalMs()
  end
  local remainMin = math.floor((nextFireMs - now) / 60000)
  noctalia.state.set("zakker/next_in_min", remainMin)
end

function onIpc(event, _payload)
  if event == "now" then
    fire()
    nextFireMs = noctalia.nowMs() + intervalMs()
  elseif event == "refresh" then
    azkar.refresh()
    lastAzkarFetchMs = noctalia.nowMs()
  elseif event == "reset" then
    nextFireMs = nil
    cursor = 0
    fireCount = 0
  end
end

function onConfigChanged()
  nextFireMs = nil
end
