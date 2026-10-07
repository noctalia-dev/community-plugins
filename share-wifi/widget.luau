-- widget.luau
-- Icon & status indicator on Noctalia Bar

local helperPath = noctalia.pluginDir() .. "/helper.sh"

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function shEscape(str)
  return "'" .. string.gsub(tostring(str), "'", "'\\''") .. "'"
end

local function getRefreshIntervalMs()
  local val = tonumber(noctalia.getConfig("refresh_interval")) or 3
  if val < 1 then val = 1 end
  if val > 3600 then val = 3600 end
  return val * 1000
end

noctalia.setUpdateInterval(getRefreshIntervalMs())

local status = {
  active = false,
  starting = false,
  stopping = false,
  clients = 0,
  maxClients = 2,
}

-- Try loading saved maxClients from config
local configPath = noctalia.pluginDataDir() .. "/config.json"
local function loadMaxClients()
  local raw = noctalia.readFile(configPath)
  if raw then
    local data = noctalia.json.decode(raw)
    if data and data.maxClients then
      local mc = tonumber(data.maxClients) or 2
      if mc < 1 then mc = 2 end
      if mc > 8 then mc = 8 end
      status.maxClients = mc
    else
      status.maxClients = 2
    end
  else
    status.maxClients = 2
  end
end
loadMaxClients()

local function renderWidget()
  local isVertical = barWidget.isVertical()
  local container = if isVertical then ui.column else ui.row
  local children = {
    ui.glyph({
      name = "access-point",
      size = 17,
      color = if (status.active or status.starting or status.stopping) then "primary" else "on_surface",
    })
  }

  if status.active then
    local maxLimit = (status.maxClients and status.maxClients > 0) and status.maxClients or 2
    local badgeText = string.format("%d/%d", status.clients, maxLimit)
    table.insert(children, ui.label({
      text = badgeText,
      fontSize = 11,
      fontWeight = "bold",
      color = "primary",
    }))
  elseif status.starting or status.stopping then
    table.insert(children, ui.label({
      text = "...",
      fontSize = 11,
      fontWeight = "bold",
      color = "primary",
    }))
  end

  barWidget.render(container({ gap = 4, align = "center", justify = "center" }, children))

  if status.active then
    local maxLimit = (status.maxClients and status.maxClients > 0) and status.maxClients or 2
    barWidget.setTooltip(tr("widget.tooltip_active", {
      clients = tostring(status.clients),
      max = tostring(maxLimit)
    }))
  elseif status.starting then
    barWidget.setTooltip(tr("widget.tooltip_starting"))
  elseif status.stopping then
    barWidget.setTooltip(tr("widget.tooltip_stopping"))
  else
    barWidget.setTooltip(tr("widget.tooltip_off"))
  end
end

function update()
  -- Keep interval in sync with user's configured setting
  noctalia.setUpdateInterval(getRefreshIntervalMs())

  -- If starting or stopping in progress, don't overwrite with background status!
  if status.starting or status.stopping then
    return
  end

  noctalia.runAsync(shEscape(helperPath) .. " status", function(res)
    if status.starting or status.stopping then
      return
    end
    if res.exitCode == 0 and res.stdout ~= "" then
      local data = noctalia.json.decode(res.stdout)
      if data then
        status.active = (data.active == true)
        status.clients = tonumber(data.clients) or 0
        noctalia.state.set("share_wifi_status", {
          active = status.active,
          starting = false,
          stopping = false,
          clients = status.clients,
          maxClients = status.maxClients
        })
        renderWidget()
      end
    end
  end)
end

function onClick()
  noctalia.togglePanel("conqazht/share-wifi:panel")
end

function onRightClick()
  if status.starting or status.stopping then
    return
  end

  if status.active then
    status.stopping = true
    status.active = false
    status.clients = 0
    noctalia.state.set("share_wifi_status", {
      active = false,
      starting = false,
      stopping = true,
      clients = 0,
      maxClients = status.maxClients
    })
    renderWidget()
    noctalia.notify(tr("panel.title"), tr("notify.stopped"))

    noctalia.runAsync(shEscape(helperPath) .. " stop", function(res)
      status.stopping = false
      status.active = false
      noctalia.state.set("share_wifi_status", {
        active = false,
        starting = false,
        stopping = false,
        clients = 0,
        maxClients = status.maxClients
      })
      renderWidget()
      update()
    end)
  else
    noctalia.togglePanel("conqazht/share-wifi:panel")
  end
end

-- Watch state updates from panel
noctalia.state.watch("share_wifi_status", function(newStatus)
  if newStatus then
    status.active = (newStatus.active == true)
    status.starting = (newStatus.starting == true)
    status.stopping = (newStatus.stopping == true)
    status.clients = tonumber(newStatus.clients) or 0
    if newStatus.maxClients ~= nil then
      status.maxClients = tonumber(newStatus.maxClients) or 0
    end
    renderWidget()
  end
end)

renderWidget()
update()
