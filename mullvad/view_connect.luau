--!nonstrict
-- Connect tab: how to connect (mode), where (country and city), and the
-- connect / disconnect buttons. Pure: it builds a ui tree from the snapshot and
-- the panel's local ui_state and never changes either.
--
--   view_connect.build(snapshot, ui_state, send, setUi, showFlags) -> UiNode
--     send(request)   a mullvad.request for the service
--     setUi(patch)    optional: the panel merges patch into ui_state and re-renders
--     showFlags       true prefixes each country name with its flag emoji
--   view_connect.connectRequest(snapshot, ui_state) -> request | nil
--
-- ui_state fields read here (codes, not indices, so a re-read relay list in a
-- different order never moves the selection):
--   mode         "country" | "my_country" | "random" (default "country")
--   countryCode  picked country; nil, false or not in the list = default
--   cityCode     picked city of that country; false / unknown = any city;
--                nil (never picked) = the default's city
--
-- The default is the daemon's relay location (settings.relay.location) when it
-- is a listed country or city: Connect then sends that same location, never
-- another country. Any other setting (any, a custom list, a hostname, something
-- unlisted, or not read yet) shows as a leading "Current setting" option in the
-- country select, and Connect sends mode "current": a plain `mullvad connect`
-- that keeps the setting as it is.
--
-- Below the buttons: the lockdown, multihop and auto-connect toggles, each shown
-- once the service has read that setting (snapshot.settings) and checked as the
-- daemon reports it. A toggle sends the opposite of what the daemon reports.
-- With multihop on, the entry selects follow. They show only the daemon's entry
-- (settings.relay.entry, by code), never a local pick: a pick sends set_entry at
-- once and the selects move when the re-read shows it.

local model = require("./model.luau")

local view_connect = {}

local function tr(key, subst)
  if noctalia and noctalia.tr then
    return noctalia.tr(key, subst)
  end
  return key
end

local MODES = { "country", "my_country", "random" }

-- Tunnel states where the button row offers Disconnect (and Reconnect / Switch).
local TUNNEL_UP = { connected = true, connecting = true, error = true }
-- Tunnel states on the way up or down: no new Connect / Switch until it settles.
local TUNNEL_MOVING = { connecting = true, disconnecting = true }

local function relayList(snapshot)
  if type(snapshot.relays) == "table" then
    return snapshot.relays
  end
  return {}
end

local function modeOf(ui_state)
  local mode = ui_state.mode
  if mode == "my_country" or mode == "random" then
    return mode
  end
  return "country"
end

local function findCountry(list, code)
  if type(code) ~= "string" then
    return nil, nil
  end
  for i, c in ipairs(list) do
    if c.code == code then
      return c, i
    end
  end
  return nil, nil
end

local function findCity(country, code)
  if country == nil or type(code) ~= "string" then
    return nil, 0
  end
  for i, ci in ipairs(country.cities or {}) do
    if ci.code == code then
      return ci, i
    end
  end
  return nil, 0
end

-- The relay location constraint the daemon reports (settings.relay.location),
-- or nil before the service has read it.
local function relayLocation(snapshot)
  local settings = snapshot.settings
  if type(settings) == "table" and type(settings.relay) == "table" and type(settings.relay.location) == "table" then
    return settings.relay.location
  end
  return nil
end

-- The daemon's relay location as a listed country (its 1-based index) and city
-- (nil = any city), or nil when the setting is anything the selects cannot show.
local function settingSelection(snapshot)
  local constraint = relayLocation(snapshot)
  if constraint == nil or (constraint.kind ~= "country" and constraint.kind ~= "city") then
    return nil, nil, nil
  end
  local country, index = findCountry(relayList(snapshot), constraint.country)
  if country == nil then
    return nil, nil, nil
  end
  if constraint.kind == "country" then
    return country, index, nil
  end
  local city = findCity(country, constraint.city)
  if city == nil then
    return nil, nil, nil
  end
  return country, index, city
end

-- The leading country-select option when the daemon's setting is not a listed
-- country or city, else nil.
local function currentSettingLabel(snapshot)
  if settingSelection(snapshot) ~= nil then
    return nil
  end
  local constraint = relayLocation(snapshot)
  local name = nil
  if constraint == nil then
    name = nil
  elseif constraint.kind == "any" then
    name = tr("connect.entry_any_option")
  elseif constraint.kind == "custom_list" then
    name = constraint.list
  elseif constraint.kind == "hostname" then
    name = constraint.hostname
  elseif constraint.kind == "unknown" then
    name = constraint.raw
  elseif constraint.city ~= nil then
    name = tostring(constraint.city) .. ", " .. tostring(constraint.country)
  else
    name = constraint.country
  end
  if type(name) ~= "string" or name == "" then
    return tr("connect.current_setting")
  end
  return tr("connect.current_setting_named", { name = name })
end

-- The selected country and its 1-based position in snapshot.relays: the picked
-- one, else the daemon's relay setting when it is a listed country or city, else
-- nil ("Current setting").
function view_connect.selectedCountry(snapshot, ui_state)
  local country, index = findCountry(relayList(snapshot), ui_state.countryCode)
  if country ~= nil then
    return country, index
  end
  country, index = settingSelection(snapshot)
  return country, index
end

-- The selected city of `country` and its 1-based position (0 = any city): the
-- picked one, else, while no city was ever picked, the setting's city when the
-- setting names that country.
local function selectedCity(snapshot, ui_state, country)
  if country == nil then
    return nil, 0
  end
  if ui_state.cityCode == nil then
    local settingCountry, _, settingCity = settingSelection(snapshot)
    if settingCity ~= nil and settingCountry == country then
      return findCity(country, settingCity.code)
    end
    return nil, 0
  end
  return findCity(country, ui_state.cityCode)
end

-- The connect request the current selection stands for, or nil when there is
-- nothing to connect to yet.
function view_connect.connectRequest(snapshot, ui_state)
  local list = relayList(snapshot)
  if #list == 0 then
    return nil
  end
  local mode = modeOf(ui_state)
  if mode == "my_country" then
    if snapshot.realLocation == nil then
      return nil
    end
    return { action = "connect", mode = "my_country" }
  end
  if mode == "random" then
    return { action = "connect", mode = "random" }
  end
  local country = view_connect.selectedCountry(snapshot, ui_state)
  if country == nil then
    return { action = "connect", mode = "current" }
  end
  local city = selectedCity(snapshot, ui_state, country)
  return { action = "connect", mode = "country", country = country.code, city = city and city.code or nil }
end

-- True when connecting with the selection would land where the tunnel already
-- is, so the button should be a plain `mullvad reconnect`. Compared against the
-- relay constraint when known (a pick of the constraint's own country, or city,
-- is current; a hostname or custom-list constraint never matches a pick), else
-- against the tunnel.
function view_connect.selectionIsCurrent(snapshot, ui_state)
  local tunnel = snapshot.tunnel or {}
  local constraint = relayLocation(snapshot)
  local mode = modeOf(ui_state)
  if mode == "random" then
    return false
  end
  if mode == "my_country" then
    if snapshot.realLocation == nil then
      return false
    end
    if constraint ~= nil then
      local country = findCountry(relayList(snapshot), constraint.country)
      return constraint.kind == "country" and country ~= nil and country.name == snapshot.realLocation.country
    end
    return tunnel.country ~= nil and snapshot.realLocation.country == tunnel.country
  end
  if not ui_state.countryCode and not ui_state.cityCode then
    return true
  end
  local country = view_connect.selectedCountry(snapshot, ui_state)
  if country == nil then
    return false
  end
  local city = selectedCity(snapshot, ui_state, country)
  if constraint ~= nil then
    if constraint.country ~= country.code then
      return false
    end
    if city == nil then
      return constraint.kind == "country"
    end
    return constraint.kind == "city" and constraint.city == city.code
  end
  if country.code ~= tunnel.countryCode then
    return false
  end
  return city == nil or city.name == tunnel.city
end

local function hint(text, color)
  return ui.label({ text = text, fontSize = 11, color = color or "on_surface_variant", maxLines = 3 })
end

local function fieldLabel(key)
  return ui.label({ text = tr(key), fontSize = 10, color = "on_surface_variant" })
end

-- Segmented choice without fill: every option is a ghost button; the active one
-- sits in a primary-bordered box (buttons have no border prop of their own).
local function modeRow(snapshot, mode, patch)
  local boxes = {}
  for _, id in ipairs(MODES) do
    local enabled = true
    if id == "my_country" and snapshot.realLocation == nil then
      enabled = false
    end
    local active = id == mode
    boxes[#boxes + 1] = ui.row({
      key = "mode.box." .. id,
      flexGrow = 1,
      radius = 8,
      border = active and "primary" or nil,
      borderWidth = 1,
    }, {
      ui.button({
        key = "mode." .. id,
        text = tr("connect.mode." .. id),
        variant = "ghost",
        controlSize = "sm",
        flexGrow = 1,
        enabled = enabled,
        onClick = function()
          patch({ mode = id })
        end,
      }),
    })
  end
  return ui.column({ gap = 4 }, {
    ui.label({ key = "mode.label", text = tr("connect.mode_label"), fontSize = 10, color = "on_surface_variant" }),
    ui.row({ gap = 6 }, boxes),
  })
end

local function locationPickers(snapshot, ui_state, patch, showFlags)
  local list = relayList(snapshot)
  local country, index = view_connect.selectedCountry(snapshot, ui_state)
  local _, cityIndex = selectedCity(snapshot, ui_state, country)

  -- "Current setting" first when the daemon's setting is not a listed country.
  local lead = currentSettingLabel(snapshot)
  local offset = lead ~= nil and 1 or 0
  local countryNames = {}
  if lead ~= nil then
    countryNames[1] = lead
  end
  for i, c in ipairs(list) do
    countryNames[i + offset] = model.withFlag(c.name, c.code, showFlags)
  end
  local cityNames = { tr("connect.any_city") }
  if country ~= nil then
    for i, ci in ipairs(country.cities) do
      cityNames[i + 1] = ci.name
    end
  end

  return ui.row({ gap = 8 }, {
    ui.column({ gap = 2, flexGrow = 1 }, {
      fieldLabel("connect.country"),
      ui.select({
        key = "country.select",
        options = countryNames,
        selectedIndex = index and (index - 1 + offset) or 0,
        enabled = #list > 0,
        controlSize = "sm",
        onChange = function(value)
          local position = tonumber(value)
          if position == nil then
            return
          end
          if lead ~= nil and position == 0 then
            patch({ countryCode = false, cityCode = false })
            return
          end
          local picked = list[position + 1 - offset]
          if picked ~= nil then
            patch({ countryCode = picked.code, cityCode = false })
          end
        end,
      }),
    }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      fieldLabel("connect.city"),
      ui.select({
        key = "city.select",
        options = cityNames,
        selectedIndex = cityIndex,
        enabled = country ~= nil,
        controlSize = "sm",
        onChange = function(value)
          local picked = tonumber(value)
          if picked == nil or country == nil then
            return
          end
          -- Pin the country too, so the city cannot re-point when the default
          -- country (the daemon's setting) changes underneath it.
          local city = country.cities[picked]
          patch({ countryCode = country.code, cityCode = city and city.code or false })
        end,
      }),
    }),
  })
end

-- Connected and the selection is where the tunnel already is: Reconnect
-- (`mullvad reconnect`, a new server under the same constraints). A different
-- selection: Switch, which sends the connect request for it.
local function secondButton(snapshot, ui_state, send, busy, request, moving)
  if view_connect.selectionIsCurrent(snapshot, ui_state) then
    return ui.button({
      key = "reconnect.button",
      text = tr("connect.reconnect"),
      glyph = "shield-check",
      tooltip = tr("connect.reconnect_tooltip"),
      variant = "primary",
      controlSize = "lg",
      flexGrow = 1,
      enabled = not busy,
      onClick = function()
        send({ action = "reconnect" })
      end,
    })
  end
  return ui.button({
    key = "switch.button",
    text = tr("connect.switch"),
    glyph = "shield-check",
    tooltip = tr("connect.switch_tooltip"),
    variant = "primary",
    controlSize = "lg",
    flexGrow = 1,
    enabled = not busy and not moving and request ~= nil,
    onClick = function()
      if request ~= nil then
        send(request)
      end
    end,
  })
end

local function buttonRow(snapshot, ui_state, send)
  local busy = snapshot.busy == true
  local request = view_connect.connectRequest(snapshot, ui_state)
  local state = snapshot.tunnel and snapshot.tunnel.state
  local moving = TUNNEL_MOVING[state] == true
  if TUNNEL_UP[state] then
    return ui.row({ gap = 8 }, {
      ui.button({
        key = "disconnect.button",
        text = tr("connect.disconnect"),
        glyph = "plug-connected-x",
        variant = "destructive",
        controlSize = "lg",
        flexGrow = 1,
        enabled = not busy,
        onClick = function()
          send({ action = "disconnect" })
        end,
      }),
      secondButton(snapshot, ui_state, send, busy, request, moving),
    })
  end
  return ui.row({ gap = 8 }, {
    ui.button({
      key = "connect.button",
      text = tr("connect.connect"),
      glyph = "shield-check",
      variant = "primary",
      controlSize = "lg",
      flexGrow = 1,
      enabled = not busy and not moving and request ~= nil,
      onClick = function()
        if request ~= nil then
          send(request)
        end
      end,
    }),
  })
end

local function toggleRow(key, labelKey, hintKey, checked, enabled, onToggle)
  return ui.row({ gap = 8, align = "center" }, {
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = tr(labelKey), fontSize = 12 }),
      hint(tr(hintKey)),
    }),
    ui.toggle({
      key = key,
      checked = checked,
      enabled = enabled,
      onChange = function()
        onToggle(not checked)
      end,
    }),
  })
end

-- The entry country select: a leading option, then the relay countries. The
-- leading option means "any country" and is selected whenever the daemon's entry
-- names no listed country; its label then says what the entry really is (any, a
-- custom list, or something this panel cannot show). Choosing it sends
-- set_entry any. Returns the label, the selected listed country (or nil) and its
-- 1-based index in the list.
local function entryLead(list, entry)
  local country, index = nil, nil
  if entry.kind == "country" or entry.kind == "city" or entry.kind == "hostname" then
    country, index = findCountry(list, entry.country)
  end
  if country ~= nil or entry.kind == "any" then
    return tr("connect.entry_any_option"), country, index
  end
  if entry.kind == "custom_list" then
    return tr("connect.entry_list_option", { name = entry.list or "" }), nil, nil
  end
  return tr("connect.entry_unknown_option"), nil, nil
end

local function entryPickers(snapshot, send, enabled, showFlags)
  local list = relayList(snapshot)
  local entry = snapshot.settings.relay.entry or {}
  local lead, country, index = entryLead(list, entry)

  local countryNames = { lead }
  for i, c in ipairs(list) do
    countryNames[i + 1] = model.withFlag(c.name, c.code, showFlags)
  end

  local nodes = {}
  if country == nil and entry.kind ~= "any" and entry.kind ~= "custom_list" then
    nodes[#nodes + 1] = hint(tr("connect.entry_unknown", { entry = entry.raw or entry.country or "" }))
  end
  local columns = {
    ui.column({ gap = 2, flexGrow = 1 }, {
      fieldLabel("connect.entry_country"),
      ui.select({
        key = "entry.country.select",
        options = countryNames,
        selectedIndex = index or 0,
        enabled = enabled,
        controlSize = "sm",
        onChange = function(value)
          local picked = tonumber(value)
          if picked == 0 then
            send({ action = "set_entry", country = "any" })
          elseif picked ~= nil and list[picked] ~= nil then
            send({ action = "set_entry", country = list[picked].code })
          end
        end,
      }),
    }),
  }
  -- A city only makes sense under a listed country.
  if country ~= nil then
    local cityCode = nil
    if entry.kind == "city" or entry.kind == "hostname" then
      cityCode = entry.city
    end
    local _, cityIndex = findCity(country, cityCode)
    local cityNames = { tr("connect.any_city") }
    for i, ci in ipairs(country.cities or {}) do
      cityNames[i + 1] = ci.name
    end
    columns[2] = ui.column({ gap = 2, flexGrow = 1 }, {
      fieldLabel("connect.entry_city"),
      ui.select({
        key = "entry.city.select",
        options = cityNames,
        selectedIndex = cityIndex,
        enabled = enabled,
        controlSize = "sm",
        onChange = function(value)
          local picked = tonumber(value)
          if picked == nil then
            return
          end
          local city = country.cities[picked]
          send({ action = "set_entry", country = country.code, city = city and city.code or nil })
        end,
      }),
    })
  end
  nodes[#nodes + 1] = ui.row({ gap = 8 }, columns)
  return ui.column({ gap = 6 }, nodes)
end

-- Lockdown, multihop (+ entry), auto-connect: each only once its setting is read.
local function toggles(snapshot, send, showFlags)
  local settings = snapshot.settings
  if type(settings) ~= "table" then
    return {}
  end
  local enabled = snapshot.busy ~= true
  local nodes = {}
  if type(settings.lockdown) == "boolean" then
    nodes[#nodes + 1] = toggleRow("toggle.lockdown", "connect.lockdown", "connect.lockdown_hint",
      settings.lockdown, enabled, function(on)
        send({ action = "set_lockdown", on = on })
      end)
  end
  local relay = settings.relay
  if type(relay) == "table" then
    nodes[#nodes + 1] = toggleRow("toggle.multihop", "connect.multihop", "connect.multihop_hint",
      relay.multihop == true, enabled, function(on)
        send({ action = "set_multihop", on = on })
      end)
    if relay.multihop == true and #relayList(snapshot) > 0 then
      nodes[#nodes + 1] = entryPickers(snapshot, send, enabled, showFlags)
    end
  end
  if type(settings.autoConnect) == "boolean" then
    nodes[#nodes + 1] = toggleRow("toggle.auto_connect", "connect.auto_connect", "connect.auto_connect_hint",
      settings.autoConnect, enabled, function(on)
        send({ action = "set_auto_connect", on = on })
      end)
  end
  return nodes
end

function view_connect.build(snapshot, ui_state, send, setUi, showFlags)
  snapshot = snapshot or {}
  ui_state = ui_state or {}
  local function patch(changes)
    if setUi ~= nil then
      setUi(changes)
    end
  end
  local mode = modeOf(ui_state)

  local children = { modeRow(snapshot, mode, patch) }
  if snapshot.realLocation == nil then
    children[#children + 1] = hint(tr("connect.my_country_unknown"))
  end
  if #relayList(snapshot) == 0 then
    children[#children + 1] = hint(tr("error.no_relays"), "error")
  elseif mode == "country" then
    children[#children + 1] = locationPickers(snapshot, ui_state, patch, showFlags)
  elseif mode == "my_country" and snapshot.realLocation ~= nil then
    children[#children + 1] = hint(tr("connect.my_country_hint", {
      country = model.withFlag(snapshot.realLocation.country or "", model.countryCodeByName(snapshot, snapshot.realLocation.country), showFlags),
    }))
  elseif mode == "random" then
    children[#children + 1] = hint(tr("connect.random_hint"))
  end
  children[#children + 1] = buttonRow(snapshot, ui_state, send)
  for _, node in ipairs(toggles(snapshot, send, showFlags)) do
    children[#children + 1] = node
  end

  return ui.column({ key = "connect.tab", gap = 10 }, children)
end

return view_connect
