--!nonstrict
-- Warm only the first screen of a few read-only sections for the selected phone.
local M = {}
local kinds = { "messages", "photos", "apps" }

function M.new(pages, snapshot, visibility, online, geometry)
  local records, epoch, stableDevice, stableSince = {}, nil, nil, nil

  local function record(device)
    if epoch ~= snapshot.cacheEpoch then
      records, epoch = {}, snapshot.cacheEpoch
      stableDevice, stableSince = nil, nil
    end
    if not records[device] then records[device] = {} end
    return records[device]
  end

  local function update()
    if not snapshot.pageCacheV2 or snapshot.state ~= "ready" then
      stableDevice, stableSince = nil, nil
      return
    end
    local device, appWindowsAllowed
    for _, phone in ipairs(snapshot.devices) do
      if phone.id == visibility.device then
        device, appWindowsAllowed = phone.id, phone.appWindowsAllowed
        break
      end
      if not device and phone.online then device, appWindowsAllowed = phone.id, phone.appWindowsAllowed end
    end
    if not device or not online(device) then
      stableDevice, stableSince = nil, nil
      return
    end
    local state, now = record(device), pages.time()
    if stableDevice ~= device then stableDevice, stableSince = device, now end
    if visibility.open or pages.hasJob() or now - stableSince < 10000 then return end

    for _, kind in ipairs(kinds) do
      local denied = snapshot.deniedPages and snapshot.deniedPages[kind .. ":" .. device]
      if not state[kind] and not denied and (kind ~= "apps" or appWindowsAllowed ~= false)
        and (kind ~= "messages" or (snapshot.privateMessages and not snapshot.messagesDenied)) then
        local limit = kind == "apps" and geometry.appsLayout().limit
          or (kind == "messages" and geometry.page.limits.messages or nil)
        local cmd = { device = device, value = { page = kind, limit = limit, key = "warm:" .. kind } }
        -- A visit can already have filled this slot. An expired or evicted
        -- entry (or a failed attempt) is not a reason to start another queue.
        state[kind] = true
        if not pages.hasCachedPage(cmd) then
          pages.read(cmd, true, false, "warm")
          return
        end
      end
    end
  end

  return {
    update = update,
    forget = function(device) records[device] = nil end,
    rearm = function(kind, device)
      for id, state in pairs(records) do
        if not device or id == device then state[kind] = nil end
      end
    end,
  }
end

return M
