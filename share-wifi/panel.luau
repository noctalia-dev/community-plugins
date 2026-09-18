-- panel.luau
-- Popup configuration panel for Share WiFi

local helperPath = noctalia.pluginDir() .. "/helper.sh"
local configPath = noctalia.pluginDataDir() .. "/config.json"

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function shEscape(str)
  -- POSIX single-quote escaping: wrap in ' and replace each ' with '\''
  return "'" .. string.gsub(tostring(str), "'", "'\\''") .. "'"
end

local state = {
  ssid = "MyHotspot",
  password = "password123",
  band = "5Ghz",          -- "Auto", "5Ghz", "2.4Ghz"
  channel = "40",         -- e.g. "40"
  useChannel = true,      -- checkbox like in screenshot
  maxClients = 2,         -- default 2, strictly 1-8 (no unlimited)
  active = false,
  starting = false,
  stopping = false,
  clients = 0,
  detecting = false,
  statusMessage = "",
  autoDetectedInfo = ""
}

-- Load saved config if exists
local function loadSavedConfig()
  local raw = noctalia.readFile(configPath)
  if raw then
    local data = noctalia.json.decode(raw)
    if data then
      if data.ssid and data.ssid ~= "" then state.ssid = data.ssid end
      if data.password and data.password ~= "" then state.password = data.password end
      if data.band and data.band ~= "" then state.band = data.band end
      if data.channel and data.channel ~= "" then state.channel = data.channel end
      if data.useChannel ~= nil then state.useChannel = data.useChannel end
      if data.maxClients ~= nil then
        local mc = tonumber(data.maxClients) or 2
        if mc < 1 then mc = 2 end
        if mc > 8 then mc = 8 end
        state.maxClients = mc
      else
        state.maxClients = 2
      end
    end
  else
    -- Pre-populate from /etc/create_ap.conf if available
    local apConf = noctalia.readFile("/etc/create_ap.conf")
    if apConf then
      local ssid = apConf:match("SSID=([^\n]+)")
      local pass = apConf:match("PASSPHRASE=([^\n]+)")
      local chan = apConf:match("CHANNEL=([^\n]+)")
      local band = apConf:match("FREQ_BAND=([^\n]+)")
      if ssid and ssid ~= "" then state.ssid = ssid end
      if pass and pass ~= "" then state.password = pass end
      if chan and chan ~= "" and chan ~= "0" then state.channel = chan end
      if band == "5" then state.band = "5Ghz" elseif band == "2.4" then state.band = "2.4Ghz" end
    end
  end
end

local function saveConfig()
  noctalia.writeFile(configPath, noctalia.json.encode({
    ssid = state.ssid,
    password = state.password,
    band = state.band,
    channel = state.channel,
    useChannel = state.useChannel,
    maxClients = state.maxClients
  }))
end

-- Auto-detect Wi-Fi band & channel from current connection
local function autoDetect(callback)
  state.detecting = true
  render()

  noctalia.runAsync(shEscape(helperPath) .. " detect", function(res)
    state.detecting = false
    if res.exitCode == 0 and res.stdout ~= "" then
      local data = noctalia.json.decode(res.stdout)
      if data then
        if data.connected then
          state.band = data.band or "5Ghz"
          state.channel = data.channel or "40"
          state.autoDetectedInfo = tr("panel.detected_wifi", { band = state.band, channel = state.channel })
          state.statusMessage = tr("panel.synced_status")
        else
          state.autoDetectedInfo = tr("panel.no_wifi")
          state.band = "2.4Ghz"
          state.channel = "6"
        end
        saveConfig()
      end
    end
    render()
    if callback then callback() end
  end)
end

-- Refresh running status
local function checkStatus(callback)
  if state.starting or state.stopping then
    if callback then callback() end
    return
  end

  noctalia.runAsync(shEscape(helperPath) .. " status", function(res)
    if state.starting or state.stopping then
      if callback then callback() end
      return
    end
    if res.exitCode == 0 and res.stdout ~= "" then
      local data = noctalia.json.decode(res.stdout)
      if data then
        state.active = (data.active == true)
        state.clients = tonumber(data.clients) or 0
        noctalia.state.set("share_wifi_status", {
          active = state.active,
          starting = false,
          stopping = false,
          clients = state.clients,
          maxClients = state.maxClients
        })
      end
    end
    render()
    if callback then callback() end
  end)
end

function render()
  local isBusy = state.active or state.starting or state.stopping

  panel.render(ui.column({ gap = 10, padding = 16 }, {
    -- Header
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({
          name = "access-point",
          size = 20,
          color = (state.active or state.starting) and "primary" or "on_surface"
        }),
        ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold" })
      }),
      ui.row({
        fill = (state.active or state.starting) and "primary/0.2" or "surface_variant/0.5",
        radius = 6,
        paddingH = 8,
        paddingV = 4,
        align = "center"
      }, {
        ui.label({
          text = if state.starting then
            tr("panel.status_starting")
          elseif state.stopping then
            tr("panel.status_stopping")
          elseif state.active then
            tr("panel.status_active", {
              clients = tostring(state.clients),
              max = tostring(state.maxClients)
            })
          else
            tr("panel.status_off"),
          fontSize = 11,
          fontWeight = "bold",
          color = (state.active or state.starting) and "primary" or "on_surface/0.5"
        })
      })
    }),

    ui.separator({ spacing = 2 }),

    -- SSID Input
    ui.column({ gap = 4 }, {
      ui.label({ text = tr("panel.ssid_label"), fontSize = 12, color = "on_surface/0.7" }),
      ui.input({
        key = "field_ssid",
        value = state.ssid,
        placeholder = tr("panel.ssid_placeholder"),
        enabled = not isBusy,
        onChange = function(val)
          state.ssid = val
        end
      })
    }),

    -- Password Input
    ui.column({ gap = 4 }, {
      ui.label({ text = tr("panel.password_label"), fontSize = 12, color = "on_surface/0.7" }),
      ui.input({
        key = "field_password",
        value = state.password,
        placeholder = tr("panel.password_placeholder"),
        enabled = not isBusy,
        onChange = function(val)
          state.password = val
        end
      })
    }),

    ui.separator({ spacing = 2 }),

    -- Frequency band
    ui.column({ gap = 6 }, {
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = tr("panel.band_label"), fontSize = 12, fontWeight = "medium" }),
        ui.row({ gap = 4 }, {
          ui.button({
            key = "band_auto",
            text = tr("panel.band_auto"),
            controlSize = "sm",
            variant = state.band == "Auto" and "primary" or "ghost",
            enabled = not isBusy,
            onClick = function()
              state.band = "Auto"
              saveConfig()
              render()
            end
          }),
          ui.button({
            key = "band_5g",
            text = tr("panel.band_5g"),
            controlSize = "sm",
            variant = state.band == "5Ghz" and "primary" or "ghost",
            enabled = not isBusy,
            onClick = function()
              state.band = "5Ghz"
              saveConfig()
              render()
            end
          }),
          ui.button({
            key = "band_24g",
            text = tr("panel.band_24g"),
            controlSize = "sm",
            variant = state.band == "2.4Ghz" and "primary" or "ghost",
            enabled = not isBusy,
            onClick = function()
              state.band = "2.4Ghz"
              saveConfig()
              render()
            end
          })
        })
      })
    }),

    -- Channel
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr("panel.channel_label"), fontSize = 12, fontWeight = "medium" }),
      ui.input({
        key = "field_channel",
        value = tostring(state.channel),
        placeholder = tr("panel.channel_placeholder"),
        width = 65,
        controlSize = "sm",
        enabled = not isBusy,
        onChange = function(val)
          state.channel = val
        end
      })
    }),

    -- Max clients (1 - 8)
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr("panel.max_clients_label"), fontSize = 12, fontWeight = "medium" }),
      ui.input({
        key = "field_max_clients",
        value = tostring(state.maxClients),
        placeholder = "2",
        width = 65,
        controlSize = "sm",
        enabled = not isBusy,
        onChange = function(val)
          local num = tonumber(val)
          if num then
            if num > 8 then
              num = 8
              noctalia.notify(tr("panel.title"), tr("notify.max_clients_capped"))
            elseif num < 1 then
              num = 1
            end
            state.maxClients = num
          elseif val == "" then
            state.maxClients = 2
          end
        end
      })
    }),

    -- Auto-detect note & refresh
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({
        text = if state.autoDetectedInfo ~= "" then
          state.autoDetectedInfo
        elseif state.statusMessage ~= "" then
          state.statusMessage
        else
          tr("panel.status_ready"),
        fontSize = 11,
        color = "on_surface/0.5"
      }),
      ui.button({
        key = "btn_rescan",
        glyph = "refresh",
        glyphSize = 13,
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.rescan_tooltip"),
        enabled = not isBusy,
        onClick = function()
          autoDetect(function()
            noctalia.notify(tr("panel.title"), tr("notify.synced"))
          end)
        end
      })
    }),

    ui.spacer({ size = 4 }),

    -- Toggle Hotspot Button
    ui.button({
      key = "btn_toggle",
      text = if state.starting then
        tr("panel.btn_starting")
      elseif state.stopping then
        tr("panel.btn_stopping")
      elseif state.active then
        tr("panel.btn_stop")
      else
        tr("panel.btn_start"),
      variant = if (state.starting or state.stopping) then
        "ghost"
      elseif state.active then
        "destructive"
      else
        "primary",
      enabled = not (state.starting or state.stopping),
      onClick = function()
        toggleHotspot()
      end
    })
  }))
end

function toggleHotspot()
  if state.starting or state.stopping then
    return
  end

  if state.active then
    state.stopping = true
    state.statusMessage = tr("panel.status_stopping")
    noctalia.state.set("share_wifi_status", {
      active = false,
      starting = false,
      stopping = true,
      clients = 0,
      maxClients = state.maxClients
    })
    render()

    noctalia.runAsync(shEscape(helperPath) .. " stop", function(res)
      state.stopping = false
      state.active = false
      state.clients = 0
      state.statusMessage = tr("panel.status_stopped")
      noctalia.state.set("share_wifi_status", {
        active = false,
        starting = false,
        stopping = false,
        clients = 0,
        maxClients = state.maxClients
      })
      noctalia.notify(tr("panel.title"), tr("notify.stopped"))
      render()
      checkStatus()
    end)
  else
    saveConfig()
    state.starting = true
    state.statusMessage = tr("panel.status_starting")
    noctalia.state.set("share_wifi_status", {
      active = false,
      starting = true,
      stopping = false,
      clients = 0,
      maxClients = state.maxClients
    })
    render()

    local bandArg = state.band
    local chanArg = (state.channel and state.channel ~= "") and state.channel or "Auto"
    local maxClientsArg = tostring(state.maxClients or 0)
    local startCmd = string.format("%s start %s %s %s %s %s",
      shEscape(helperPath), shEscape(state.ssid), shEscape(state.password),
      shEscape(bandArg), shEscape(chanArg), shEscape(maxClientsArg)
    )

    noctalia.runAsync(startCmd, function(res)
      state.starting = false
      if res.exitCode == 0 then
        state.active = true
        state.statusMessage = tr("panel.status_active_fmt", { band = state.band, channel = state.channel })
        noctalia.state.set("share_wifi_status", {
          active = true,
          starting = false,
          stopping = false,
          clients = 0,
          maxClients = state.maxClients
        })
        noctalia.notify(tr("panel.title"), tr("notify.started"))
      else
        state.active = false
        noctalia.state.set("share_wifi_status", {
          active = false,
          starting = false,
          stopping = false,
          clients = 0,
          maxClients = state.maxClients
        })
        local errMsg = tr("notify.error_start_failed")
        if res.stderr and res.stderr ~= "" then
          local ok, parsed = pcall(function() return noctalia.json.decode(res.stderr) end)
          if ok and parsed and parsed.error then
            errMsg = parsed.error
          else
            errMsg = res.stderr
          end
        end
        state.statusMessage = errMsg
        noctalia.notifyError(tr("notify.error_title"), errMsg)
      end
      render()
      checkStatus()
    end)
  end
end

function onOpen()
  loadSavedConfig()
  checkStatus(function()
    if not state.active then
      autoDetect()
    else
      render()
    end
  end)
end

-- Sync if hotspot is toggled externally (e.g. from bar widget right-click or shortcut)
noctalia.state.watch("share_wifi_status", function(newStatus)
  if newStatus and not state.starting and not state.stopping then
    local changed = false
    if newStatus.active ~= nil and state.active ~= newStatus.active then
      state.active = newStatus.active
      changed = true
    end
    if newStatus.clients ~= nil and state.clients ~= tonumber(newStatus.clients) then
      state.clients = tonumber(newStatus.clients) or 0
      changed = true
    end
    if changed then
      render()
    end
  end
end)

-- Initial load
loadSavedConfig()
checkStatus()
