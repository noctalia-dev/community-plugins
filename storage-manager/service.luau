--!nonstrict
-- Storage Manager service. Looks at the mounted filesystems every ten minutes,
-- publishes them as state "volumes" for the bar widget and the panel, warns
-- when the system or home filesystem runs low, and (if the setting asks for
-- it) deletes trash older than a set number of days every six hours.

local common = require("./lib/common.luau")

local VOLUME_EVERY_MS = 10 * 60 * 1000
local PURGE_EVERY_MS = 6 * 60 * 60 * 1000
local FIRST_LOOK_MS = 45 * 1000

local started = noctalia.nowMs()
local lastVolumes = 0
local lastPurge = 0
local looking = false
local purging = false
-- mount -> true once warned, until it recovers a little
local warned = {}

local function checkLow(vols)
  if noctalia.getConfig("low_space_warning") ~= true then
    return
  end
  local limit = tonumber(noctalia.getConfig("low_space_percent")) or 10
  for _, v in ipairs(vols) do
    if (v.root or v.home) and not v.readonly then
      local pct = common.freePercent(v)
      if pct < limit then
        if not warned[v.mount] then
          warned[v.mount] = true
          local body = noctalia.tr("notify.low_body", {
            free = common.size(v.avail),
            name = v.name,
            percent = math.floor(pct + 0.5),
          })
          local opts = { actions = { { id = "open", label = noctalia.tr("notify.open") } }, onAction = "onLowAction" }
          if pct < 3 then
            noctalia.notifyError(noctalia.tr("notify.low_title"), body, opts)
          else
            noctalia.notify(noctalia.tr("notify.low_title"), body, opts)
          end
        end
      elseif pct > limit + 2 then
        warned[v.mount] = nil
      end
    end
  end
end

function onLowAction(id)
  if id == "open" then
    noctalia.togglePanel(common.PANEL)
  end
end

local function refreshVolumes()
  if looking then
    return
  end
  looking = true
  lastVolumes = noctalia.nowMs()
  common.ask({ "volumes" }, function(data)
    looking = false
    if data and data.volumes then
      noctalia.state.set("volumes", data)
      checkLow(data.volumes)
    end
  end)
end

local function purgeTrash()
  local days = tonumber(noctalia.getConfig("empty_trash_after"))
  if days == nil or days <= 0 or purging then
    return
  end
  purging = true
  lastPurge = noctalia.nowMs()
  common.job({ "trash-old", tostring(days) }, nil, function(data)
    purging = false
    if data and (tonumber(data.removed) or 0) > 0 then
      noctalia.log("emptied " .. tostring(data.removed) .. " old trash items, " .. common.size(data.freed))
      refreshVolumes()
    end
  end)
end

noctalia.setUpdateInterval(15000)

function update()
  local now = noctalia.nowMs()
  if now - lastVolumes >= VOLUME_EVERY_MS then
    refreshVolumes()
  end
  -- trash is left alone for the first moments of a session
  if now - started >= FIRST_LOOK_MS and now - lastPurge >= PURGE_EVERY_MS then
    purgeTrash()
  end
end

refreshVolumes()

-- the panel asks for a fresh look after it changes something
noctalia.state.watch("refresh_request", function()
  refreshVolumes()
end)

function onConfigChanged()
  warned = {}
  lastPurge = 0
  refreshVolumes()
end

function onResume()
  refreshVolumes()
end

function onIpc(event)
  if event == "refresh" then
    refreshVolumes()
  elseif event == "purge-trash" then
    lastPurge = 0
    purgeTrash()
  end
end
