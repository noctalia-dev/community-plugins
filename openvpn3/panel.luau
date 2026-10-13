--!nonstrict
-- Profile list with one-click connect, live session details, profile import,
-- per-profile options and the credentials / challenge / web-login prompts.

local status = {
  state = "checking", available = false, busy = false, busyProfile = "", message = "",
  sessions = {}, profiles = {}, pending = nil, notice = nil,
}

local view = "list" -- "list" | "add" | "detail" | "log"
local selectedPath = ""
local addFile = ""
local addName = ""
local removeArmed = ""
local addMode = "file" -- "file" | "url"
local addUrl = ""
local drafts = {}
local draftName = ""
local logPath = ""
local logLines = {}
local edits = {} -- toggle / dropdown changes waiting for Apply
local authValues = {}
local authKey = 0
local formKey = 0
local lastNotice = nil

local render
local resetDrafts

-- Toggles report their new state as the strings "true" / "false".
local function isOn(value)
  return value == true or value == "true"
end

local function send(action, extra)
  local command = { action = action, nonce = noctalia.nowMs() }
  if extra ~= nil then
    for k, v in pairs(extra) do
      command[k] = v
    end
  end
  noctalia.state.set("openvpn3.command", command)
end

local function stateLabel(state)
  local known = {
    checking = true, connected = true, connecting = true, paused = true,
    attention = true, disconnected = true, unavailable = true, error = true, failed = true,
  }
  return noctalia.tr(if known[state] then `status.{state}` else "status.error")
end

local function formatBytes(value)
  local bytes = tonumber(value)
  if bytes == nil or bytes < 0 then
    return "—"
  end
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local index = 1
  while bytes >= 1024 and index < #units do
    bytes /= 1024
    index += 1
  end
  local decimals = if index == 1 or bytes >= 10 then 0 else 1
  return string.format(`%.{decimals}f %s`, bytes, units[index])
end

local function formatDuration(created)
  if created == nil or created <= 0 then
    return "—"
  end
  local seconds = math.max(0, os.time() - created)
  if seconds < 60 then
    return string.format("%ds", seconds)
  elseif seconds < 3600 then
    return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60)
  end
  return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

local function openLog(sessionPath)
  view = "log"
  logPath = sessionPath
  logLines = {}
  send("log", { path = sessionPath })
  render()
end

local function logButton(session)
  return ui.button({
    glyph = "file-text", variant = "ghost", tooltip = noctalia.tr("panel.view-log"),
    onClick = function() openLog(session.path) end,
  })
end

local function formatRate(value)
  local rate = tonumber(value)
  if rate == nil or rate < 0 then
    return nil
  end
  return formatBytes(rate) .. "/s"
end

local function sessionFor(profile)
  for _, s in ipairs(status.sessions) do
    if s.configPath == profile.path or s.config == profile.name then
      return s
    end
  end
  return nil
end

local TEXT_KEYS = { "server-override", "port-override", "proxy-host", "proxy-port", "proxy-username", "proxy-password" }

function resetDrafts(profile)
  drafts = {}
  for _, key in ipairs(TEXT_KEYS) do
    local value = if profile.overrides ~= nil then profile.overrides[key] else nil
    drafts[key] = if key == "proxy-password" or value == nil then "" else tostring(value)
  end
  draftName = profile.name
  edits = {}
  formKey += 1
end

local function selectedProfile()
  for _, p in ipairs(status.profiles) do
    if p.path == selectedPath then
      return p
    end
  end
  return nil
end

local function infoRow(label, value)
  return ui.row({ gap = 8, justify = "space_between", align = "center" }, {
    ui.label({ text = label, color = "on_surface_variant", fontSize = 12 }),
    ui.label({
      text = if value == nil or value == "" then "—" else value,
      color = "on_surface", fontSize = 12, fontWeight = "bold", textAlign = "end", maxWidth = 240,
    }),
  })
end

local function closeButton()
  return ui.button({ glyph = "x", variant = "ghost", onClick = function() panel.close() end })
end

local function headerRow(title, subtitle, leading, trailing)
  local items = {
    leading,
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 16, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = subtitle or "", color = "on_surface_variant", fontSize = 11, maxLines = 1 }),
    }),
  }
  for _, item in ipairs(trailing or {}) do
    table.insert(items, item)
  end
  table.insert(items, closeButton())
  return ui.row({ gap = 8, align = "center" }, items)
end

local function backButton()
  return ui.button({
    glyph = "arrow-left", variant = "ghost",
    onClick = function()
      view = "list"
      removeArmed = ""
      render()
    end,
  })
end

-- Column for a whole panel page; the error banner (if any) goes right under the
-- header. Nothing is inserted for an empty message: a spacer here would take a
-- share of the free space and push the content down.
local function page(items, bannerText)
  local message = bannerText or status.message
  local list = {}
  for index, item in ipairs(items) do
    table.insert(list, item)
    if index == 1 and message ~= nil and message ~= "" then
      table.insert(list, ui.label({ text = message, color = "error", fontSize = 11, maxLines = 3 }))
    end
  end
  return ui.column({ gap = 10, padding = 12, flexGrow = 1 }, list)
end

-- ---------------------------------------------------------------------------
-- Sign-in prompt (credentials, OTP, passphrase, web login)
-- ---------------------------------------------------------------------------

local function renderAuth()
  local pending = status.pending
  local rows = {}
  -- Untouched fields must still be sent as empty strings (no holes in the array).
  for index = 1, #pending.fields do
    authValues[index] = authValues[index] or ""
  end

  if pending.kind == "url" then
    table.insert(rows, ui.column({ gap = 8, padding = 12, fill = "surface_variant/0.5", radius = 10 }, {
      ui.glyph({ name = "world", size = 28, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.web-auth"), fontSize = 14, fontWeight = "bold" }),
      ui.label({ text = noctalia.tr("panel.web-auth-hint"), color = "on_surface_variant", fontSize = 12, maxLines = 4 }),
      ui.button({
        text = noctalia.tr("panel.open-browser"), glyph = "external-link", variant = "outline",
        onClick = function() noctalia.runAsync({ "xdg-open", pending.url }) end,
      }),
    }))
    table.insert(rows, ui.row({ gap = 8, justify = "end" }, {
      ui.button({ text = noctalia.tr("panel.cancel"), variant = "ghost", onClick = function() send("cancel-auth") end }),
    }))
  else
    for index, field in ipairs(pending.fields) do
      table.insert(rows, ui.label({ text = field.label, color = "on_surface_variant", fontSize = 12 }))
      table.insert(rows, ui.input({
        key = `auth-{authKey}-{index}`,
        value = authValues[index] or "",
        placeholder = field.label,
        password = field.hidden,
        focus = index == 1,
        onChange = function(text) authValues[index] = text or "" end,
        onSubmit = function(text)
          authValues[index] = text or ""
          if index == #pending.fields then
            send("submit-auth", { values = authValues })
          end
        end,
      }))
    end
    table.insert(rows, ui.label({ text = noctalia.tr("panel.auth-hint"), color = "on_surface_variant", fontSize = 11, maxLines = 2 }))
    table.insert(rows, ui.row({ gap = 8, justify = "end" }, {
      ui.button({ text = noctalia.tr("panel.cancel"), variant = "ghost", onClick = function() send("cancel-auth") end }),
      ui.button({
        text = noctalia.tr("panel.connect"), variant = "primary",
        onClick = function() send("submit-auth", { values = authValues }) end,
      }),
    }))
  end

  panel.render(page({
    headerRow(noctalia.tr("panel.auth-title"), pending.profile, ui.glyph({ name = "lock", size = 20, color = "primary" }), nil),
    ui.scroll({ flexGrow = 1, gap = 8 }, rows),
  }, pending.error or ""))
end

-- ---------------------------------------------------------------------------
-- Profile list
-- ---------------------------------------------------------------------------

local function profileCard(profile)
  local session = sessionFor(profile)
  local connecting = status.busy and status.busyProfile == profile.name
  local active = session ~= nil and (session.state == "connected" or session.state == "connecting" or session.state == "paused" or session.state == "attention")
  local connected = session ~= nil and session.state == "connected"

  local subtitle
  local subtitleColor = "on_surface_variant"
  if connected then
    subtitle = `{stateLabel("connected")} · {formatDuration(session.created)}`
    subtitleColor = "primary"
  elseif session ~= nil and session.state == "paused" then
    subtitle = stateLabel("paused")
  elseif connecting or (session ~= nil and session.state == "connecting") then
    subtitle = noctalia.tr("panel.connecting")
    subtitleColor = "secondary"
  elseif not profile.valid then
    subtitle = noctalia.tr("panel.invalid")
    subtitleColor = "error"
  elseif profile.lastUsed ~= "" then
    subtitle = `{noctalia.tr("panel.last-used")} {profile.lastUsed}`
  else
    subtitle = `{noctalia.tr("panel.last-used")} {noctalia.tr("panel.never")}`
  end

  local glyph = "shield-off"
  local glyphColor = "on_surface_variant"
  if connected then
    glyph = "shield-check"
    glyphColor = "primary"
  elseif active or connecting then
    glyph = "shield"
    glyphColor = "secondary"
  end

  local canToggle = (profile.valid or active) and status.available and not (status.busy and not connecting)
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = glyph, size = 20, color = glyphColor }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = profile.name, fontSize = 14, fontWeight = "bold", maxLines = 1 }),
        ui.label({ text = subtitle, color = subtitleColor, fontSize = 11, maxLines = 1 }),
      }),
      if connecting or (session ~= nil and session.state == "connecting") then
        ui.button({ text = noctalia.tr("panel.cancel"), variant = "ghost", onClick = function() send("cancel-auth") end })
      else
        ui.spacer({ width = 0, flexGrow = 0 }),
      ui.toggle({
        checked = active or connecting,
        enabled = canToggle and not connecting,
        onChange = function(value)
          if isOn(value) then
            send("connect", { profile = profile.name, path = profile.path })
          elseif session ~= nil then
            send("disconnect", { path = session.path })
          end
        end,
      }),
      if session ~= nil then logButton(session) else ui.spacer({ width = 0, flexGrow = 0 }),
      ui.button({
        glyph = "adjustments", variant = "ghost", tooltip = noctalia.tr("panel.options"),
        onClick = function()
          view = "detail"
          selectedPath = profile.path
          removeArmed = ""
          resetDrafts(profile)
          render()
        end,
      }),
    }),
  }

  if session ~= nil and (connected or session.state == "paused") then
    table.insert(rows, ui.separator({}))
    table.insert(rows, infoRow(noctalia.tr("panel.server"), session.remote))
    table.insert(rows, infoRow(noctalia.tr("panel.device"), session.device))
    table.insert(rows, infoRow(noctalia.tr("panel.received"), formatBytes(session.bytesIn) .. (if formatRate(session.rateIn) ~= nil then `  ({formatRate(session.rateIn)})` else "")))
    table.insert(rows, infoRow(noctalia.tr("panel.sent"), formatBytes(session.bytesOut) .. (if formatRate(session.rateOut) ~= nil then `  ({formatRate(session.rateOut)})` else "")))
    table.insert(rows, ui.row({ gap = 6, justify = "end" }, {
      ui.button({
        text = if session.state == "paused" then noctalia.tr("panel.resume") else noctalia.tr("panel.pause"),
        variant = "ghost", enabled = not status.busy,
        onClick = function() send(if session.state == "paused" then "resume" else "pause", { path = session.path }) end,
      }),
      ui.button({
        text = noctalia.tr("panel.restart"), variant = "ghost", enabled = not status.busy,
        onClick = function() send("restart", { path = session.path }) end,
      }),
    }))
  end

  return ui.column({ gap = 8, padding = 10, fill = "surface_variant/0.5", radius = 10 }, rows)
end

-- Sessions started outside the plugin (e.g. `openvpn3 session-start` from a terminal).
local function externalCard(session)
  local connected = session.state == "connected"
  return ui.column({ gap = 8, padding = 10, fill = "surface_variant/0.5", radius = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = if connected then "shield-check" else "shield", size = 20, color = if connected then "primary" else "secondary" }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = session.config, fontSize = 14, fontWeight = "bold", maxLines = 1 }),
        ui.label({
          text = `{stateLabel(session.state)} · {formatDuration(session.created)}`,
          color = if connected then "primary" else "secondary", fontSize = 11, maxLines = 1,
        }),
      }),
      logButton(session),
      ui.button({
        text = noctalia.tr("panel.disconnect"), variant = "ghost", enabled = not status.busy,
        onClick = function() send("disconnect", { path = session.path }) end,
      }),
    }),
    infoRow(noctalia.tr("panel.server"), session.remote),
    infoRow(noctalia.tr("panel.received"), formatBytes(session.bytesIn)),
    infoRow(noctalia.tr("panel.sent"), formatBytes(session.bytesOut)),
  })
end

local function renderList()
  local body = {}
  if #status.profiles == 0 and #status.sessions == 0 then
    table.insert(body, ui.column({ gap = 8, padding = 16, align = "center" }, {
      ui.glyph({ name = "shield-off", size = 36, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.no-profiles"), fontSize = 14, fontWeight = "bold" }),
      ui.label({ text = noctalia.tr("panel.no-profiles-hint"), color = "on_surface_variant", fontSize = 12 }),
      ui.button({
        text = noctalia.tr("panel.add"), glyph = "plus", variant = "primary",
        onClick = function()
          view = "add"
          render()
        end,
      }),
    }))
  else
    for _, profile in ipairs(status.profiles) do
      table.insert(body, profileCard(profile))
    end
    for _, session in ipairs(status.sessions) do
      local owned = false
      for _, profile in ipairs(status.profiles) do
        if session.configPath == profile.path then
          owned = true
        end
      end
      if not owned then
        table.insert(body, externalCard(session))
      end
    end
  end

  local stateColor = if status.state == "connected" then "primary"
    elseif status.state == "error" or status.state == "unavailable" then "error"
    else "on_surface_variant"

  panel.render(page({
    headerRow(noctalia.tr("title"), stateLabel(status.state), ui.glyph({ name = "shield-lock", size = 20, color = stateColor }), {
      ui.button({
        glyph = "plus", variant = "ghost", tooltip = noctalia.tr("panel.add"),
        onClick = function()
          view = "add"
          render()
        end,
      }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.refresh"), onClick = function() send("refresh") end }),
    }),
    ui.scroll({ flexGrow = 1, gap = 8 }, body),
  }, nil))
end

-- ---------------------------------------------------------------------------
-- Add profile
-- ---------------------------------------------------------------------------

local function modeButton(mode, label)
  return ui.button({
    text = label, variant = if addMode == mode then "primary" else "ghost", flexGrow = 1,
    onClick = function()
      addMode = mode
      render()
    end,
  })
end

local function renderAdd()
  local body = {
    ui.row({ gap = 6 }, { modeButton("file", noctalia.tr("panel.from-file")), modeButton("url", noctalia.tr("panel.from-url")) }),
  }
  if addMode == "url" then
    table.insert(body, ui.label({ text = noctalia.tr("panel.url"), color = "on_surface_variant", fontSize = 12 }))
    table.insert(body, ui.input({
      key = `add-url-{formKey}`, value = addUrl, placeholder = "https://", focus = true,
      onChange = function(text) addUrl = text or "" end,
    }))
  else
    table.insert(body, ui.label({ text = noctalia.tr("panel.file"), color = "on_surface_variant", fontSize = 12 }))
    table.insert(body, ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = `add-file-{formKey}`, value = addFile, placeholder = noctalia.tr("panel.file-placeholder"),
        flexGrow = 1, focus = true,
        onChange = function(text) addFile = text or "" end,
      }),
      ui.button({
        glyph = "folder-open", variant = "outline", tooltip = noctalia.tr("panel.browse"),
        onClick = function()
        -- The picker is a separate window; remember to come back to this page.
        noctalia.state.set("openvpn3.resume", { view = "add", nonce = noctalia.nowMs() })
        noctalia.togglePanel("vinioli/openvpn3:picker")
      end,
      }),
    }))
  end
  table.insert(body, ui.label({ text = noctalia.tr("panel.name"), color = "on_surface_variant", fontSize = 12 }))
  table.insert(body, ui.input({
    key = `add-name-{formKey}`, value = addName, placeholder = noctalia.tr("panel.name-placeholder"),
    onChange = function(text) addName = text or "" end,
  }))
  table.insert(body, ui.row({ gap = 8, justify = "end" }, {
    ui.button({
      text = noctalia.tr("panel.cancel"), variant = "ghost",
      onClick = function()
        view = "list"
        render()
      end,
    }),
    ui.button({
      text = noctalia.tr("panel.import"), glyph = "plus", variant = "primary", enabled = not status.busy,
      onClick = function()
        if addMode == "url" then
          send("import", { url = addUrl, name = addName })
        else
          send("import", { file = addFile, name = addName })
        end
      end,
    }),
  }))

  panel.render(page({
    headerRow(noctalia.tr("panel.add-title"), "", backButton(), nil),
    ui.scroll({ flexGrow = 1, gap = 8 }, body),
  }, nil))
end

-- ---------------------------------------------------------------------------
-- Profile options
-- ---------------------------------------------------------------------------

local function choice(value, label)
  return { value = value, label = label }
end

local DEFAULT = "panel.opt.default"
local SELECTS = {
  ["ipv6"] = { choice("", DEFAULT), choice("yes", "panel.opt.on"), choice("no", "panel.opt.off") },
  ["allow-compression"] = { choice("", DEFAULT), choice("no", "panel.opt.off"), choice("asym", "panel.opt.asym"), choice("yes", "panel.opt.on") },
  ["automatic-restart"] = { choice("", DEFAULT), choice("no", "panel.opt.never"), choice("on-failure", "panel.opt.on-failure") },
  ["tls-version-min"] = { choice("", DEFAULT), choice("tls_1_0", "TLS 1.0"), choice("tls_1_1", "TLS 1.1"), choice("tls_1_2", "TLS 1.2"), choice("tls_1_3", "TLS 1.3") },
  ["tls-cert-profile"] = { choice("", DEFAULT), choice("legacy", "legacy"), choice("preferred", "preferred"), choice("suiteb", "suiteb") },
  ["dns-scope"] = { choice("", DEFAULT), choice("global", "global"), choice("tunnel", "tunnel") },
  ["log-level"] = { choice("", DEFAULT), choice("1", "1"), choice("2", "2"), choice("3", "3"), choice("4", "4"), choice("5", "5"), choice("6", "6") },
}

local function choiceText(c)
  if string.sub(c.label, 1, 6) == "panel." then
    return noctalia.tr(c.label)
  end
  return c.label
end

local function originalValue(profile, key)
  if key == "dco" then
    return profile.dco == true
  elseif key == "autoconnect" then
    return profile.autoconnect == true
  end
  local value = if profile.overrides ~= nil then profile.overrides[key] else nil
  if SELECTS[key] ~= nil then
    return if value == nil then "" else tostring(value)
  end
  return value == true
end

local function effectiveValue(profile, key)
  if edits[key] ~= nil then
    return edits[key]
  end
  return originalValue(profile, key)
end

local function setEdit(profile, key, value)
  if value == originalValue(profile, key) then
    edits[key] = nil
  else
    edits[key] = value
  end
  render()
end

local function toggleRow(profile, key, title, hint)
  local labels = {
    ui.label({ text = title, fontSize = 13, fontWeight = "bold" }),
  }
  if hint ~= nil then
    table.insert(labels, ui.label({ text = hint, color = "on_surface_variant", fontSize = 11, maxLines = 2 }))
  end
  return ui.row({ gap = 10, align = "center" }, {
    ui.column({ gap = 2, flexGrow = 1 }, labels),
    ui.toggle({
      checked = effectiveValue(profile, key) == true, enabled = not status.busy,
      onChange = function(value) setEdit(profile, key, isOn(value)) end,
    }),
  })
end

local function selectRow(profile, key, title)
  local choices = SELECTS[key]
  local labels = {}
  local selected = 0
  local current = effectiveValue(profile, key)
  for index, c in ipairs(choices) do
    table.insert(labels, choiceText(c))
    if c.value == current then
      selected = index - 1
    end
  end
  return ui.row({ gap = 10, align = "center", justify = "space_between" }, {
    ui.label({ text = title, fontSize = 13, fontWeight = "bold", flexGrow = 1 }),
    ui.select({
      options = labels, selectedIndex = selected, width = 170, enabled = not status.busy,
      onChange = function(index)
        local picked = choices[(tonumber(index) or 0) + 1]
        if picked ~= nil then
          setEdit(profile, key, picked.value)
        end
      end,
    }),
  })
end

local function textRow(key, title, placeholder, hidden)
  return ui.column({ gap = 4 }, {
    ui.label({ text = title, fontSize = 13, fontWeight = "bold" }),
    ui.input({
      key = `opt-{formKey}-{key}`, value = drafts[key] or "", placeholder = placeholder or "",
      password = hidden == true,
      onChange = function(text) drafts[key] = text or "" end,
    }),
  })
end

local function section(title, rows)
  local children = { ui.label({ text = title, color = "primary", fontSize = 12, fontWeight = "bold" }) }
  for _, row in ipairs(rows) do
    table.insert(children, row)
  end
  return ui.column({ gap = 10, padding = 12, fill = "surface_variant/0.5", radius = 10 }, children)
end

local function collectChanges(profile)
  local options = {}
  for key, value in pairs(edits) do
    options[key] = value
  end
  for _, key in ipairs(TEXT_KEYS) do
    local original = if profile.overrides ~= nil and profile.overrides[key] ~= nil then tostring(profile.overrides[key]) else ""
    local draft = drafts[key] or ""
    if key == "proxy-password" then
      if draft ~= "" then
        options[key] = draft
      end
    elseif draft ~= original then
      options[key] = draft
    end
  end
  local rename = if draftName ~= profile.name and draftName ~= "" then draftName else nil
  return options, rename
end

local function applyDrafts(profile)
  local options, rename = collectChanges(profile)
  if next(options) == nil and rename == nil then
    noctalia.notify(noctalia.tr("title"), noctalia.tr("panel.no-changes"))
    return
  end
  local command = { path = profile.path, rename = rename }
  command.options = options
  send("set-options", command)
  -- The password is write-only: forget it as soon as it has been sent.
  drafts["proxy-password"] = ""
  formKey += 1
end

local function renderDetail()
  local profile = selectedProfile()
  if profile == nil then
    view = "list"
    renderList()
    return
  end
  local armed = removeArmed == profile.path

  local body = {
    section(noctalia.tr("panel.sec.general"), {
      ui.column({ gap = 4 }, {
        ui.label({ text = noctalia.tr("panel.opt.rename"), fontSize = 13, fontWeight = "bold" }),
        ui.input({
          key = `opt-{formKey}-name`, value = draftName,
          onChange = function(text) draftName = text or "" end,
        }),
      }),
      toggleRow(profile, "dco", noctalia.tr("panel.dco"), noctalia.tr("panel.dco-hint")),
      toggleRow(profile, "persist-tun", noctalia.tr("panel.persist-tun"), noctalia.tr("panel.persist-tun-hint")),
      toggleRow(profile, "autoconnect", noctalia.tr("panel.opt.autoconnect"), noctalia.tr("panel.opt.autoconnect-hint")),
      toggleRow(profile, "auth-fail-retry", noctalia.tr("panel.opt.auth-fail-retry"), noctalia.tr("panel.opt.auth-fail-retry-hint")),
      selectRow(profile, "automatic-restart", noctalia.tr("panel.opt.restart")),
    }),
    section(noctalia.tr("panel.sec.connection"), {
      textRow("server-override", noctalia.tr("panel.opt.server"), noctalia.tr("panel.opt.server-hint"), false),
      textRow("port-override", noctalia.tr("panel.opt.port"), noctalia.tr("panel.opt.port-hint"), false),
      selectRow(profile, "ipv6", noctalia.tr("panel.opt.ipv6")),
      selectRow(profile, "allow-compression", noctalia.tr("panel.opt.compression")),
    }),
    section(noctalia.tr("panel.sec.security"), {
      selectRow(profile, "tls-version-min", noctalia.tr("panel.opt.tls-min")),
      selectRow(profile, "tls-cert-profile", noctalia.tr("panel.opt.tls-profile")),
      toggleRow(profile, "enable-legacy-algorithms", noctalia.tr("panel.opt.legacy"), noctalia.tr("panel.opt.legacy-hint")),
    }),
    section(noctalia.tr("panel.sec.dns"), {
      selectRow(profile, "dns-scope", noctalia.tr("panel.opt.dns-scope")),
      toggleRow(profile, "dns-fallback-google", noctalia.tr("panel.opt.dns-google"), noctalia.tr("panel.opt.dns-google-hint")),
      toggleRow(profile, "dns-setup-disabled", noctalia.tr("panel.opt.dns-disabled"), noctalia.tr("panel.opt.dns-disabled-hint")),
      toggleRow(profile, "dns-sync-lookup", noctalia.tr("panel.opt.dns-sync"), nil),
    }),
    section(noctalia.tr("panel.sec.proxy"), {
      textRow("proxy-host", noctalia.tr("panel.opt.proxy-host"), "proxy.example.com", false),
      textRow("proxy-port", noctalia.tr("panel.opt.proxy-port"), "8080", false),
      textRow("proxy-username", noctalia.tr("panel.opt.proxy-user"), "", false),
      textRow("proxy-password", noctalia.tr("panel.opt.proxy-password"), noctalia.tr("panel.opt.proxy-password-hint"), true),
      toggleRow(profile, "proxy-auth-cleartext", noctalia.tr("panel.opt.proxy-cleartext"), nil),
    }),
    section(noctalia.tr("panel.sec.logging"), {
      selectRow(profile, "log-level", noctalia.tr("panel.opt.log-level")),
    }),
  }
  panel.render(page({
    headerRow(profile.name, noctalia.tr("panel.options"), backButton(), nil),
    ui.scroll({ flexGrow = 1, gap = 10 }, body),
    ui.row({ gap = 8, justify = "space_between" }, {
      ui.button({
        text = if armed then noctalia.tr("panel.remove-confirm") else noctalia.tr("panel.remove"),
        glyph = "trash", variant = if armed then "destructive" else "outline", enabled = not status.busy,
        onClick = function()
          if armed then
            removeArmed = ""
            view = "list"
            send("remove", { path = profile.path })
          else
            removeArmed = profile.path
            render()
          end
        end,
      }),
      ui.button({
        text = noctalia.tr("panel.apply"), glyph = "check", variant = if next(edits) ~= nil then "primary" else "outline", enabled = not status.busy,
        onClick = function() applyDrafts(profile) end,
      }),
    }),
  }, if profile.valid then nil else profile.invalidReason))
end

local function renderLog()
  local rows = {}
  -- Newest first, so the latest events are visible without scrolling.
  for index = #logLines, 1, -1 do
    table.insert(rows, ui.label({ text = logLines[index], fontSize = 10, color = "on_surface_variant", maxLines = 3 }))
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.log-empty"), fontSize = 12, color = "on_surface_variant", maxLines = 3 }))
  end
  panel.render(page({
    headerRow(noctalia.tr("panel.log"), "", backButton(), {
      ui.button({
        glyph = "copy", variant = "ghost", tooltip = noctalia.tr("panel.copy"),
        onClick = function() noctalia.copyToClipboard(table.concat(logLines, "\n")) end,
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 3 }, rows),
  }, nil))
end

render = function()
  if status.pending ~= nil then
    renderAuth()
  elseif view == "log" then
    renderLog()
  elseif view == "add" then
    renderAdd()
  elseif view == "detail" then
    renderDetail()
  else
    renderList()
  end
end

local function applyStatus(value)
  if type(value) == "table" then
    local hadPending = status.pending ~= nil
    status.state = value.state or "checking"
    status.available = value.available == true
    status.busy = value.busy == true
    status.busyProfile = value.busyProfile or ""
    status.message = value.message or ""
    status.sessions = value.sessions or {}
    status.profiles = value.profiles or {}
    status.pending = value.pending
    status.notice = value.notice
    if status.pending ~= nil and not hadPending then
      authValues = {}
      authKey += 1
    end
    -- Drop pending edits the profile now reflects (they were just saved).
    local current = selectedProfile()
    if current ~= nil then
      for key, value in pairs(edits) do
        if value == originalValue(current, key) then
          edits[key] = nil
        end
      end
    end
    -- Return to the list after an import or removal completes.
    local notice = status.notice
    if notice ~= nil and (lastNotice == nil or notice.nonce ~= lastNotice) then
      lastNotice = notice.nonce
      if notice.kind == "imported" or notice.kind == "removed" then
        view = "list"
        addFile = ""
        addUrl = ""
        addName = ""
        formKey += 1
      end
    end
  end
  render()
end

-- The floating picker reports the chosen file through this state key.
local function applyPicked(value)
  if type(value) == "table" and type(value.path) == "string" and value.path ~= "" then
    addFile = value.path
    addMode = "file"
    view = "add"
    formKey += 1
    render()
  end
end

local function applyLog(value)
  if type(value) == "table" and value.path == logPath then
    logLines = value.lines or {}
    if view == "log" then
      render()
    end
  end
end

function onClose()
  noctalia.state.set("openvpn3.panelopen", { open = false })
end

function onOpen(_context)
  noctalia.state.set("openvpn3.panelopen", { open = true })
  view = "list"
  local resume = noctalia.state.get("openvpn3.resume")
  if type(resume) == "table" and resume.view == "add" then
    view = "add"
    noctalia.state.set("openvpn3.resume", { view = "" })
  end
  removeArmed = ""
  applyStatus(noctalia.state.get("openvpn3.status"))
  send("refresh")
end

applyStatus(noctalia.state.get("openvpn3.status"))
noctalia.state.watch("openvpn3.status", applyStatus)
noctalia.state.watch("openvpn3.picked", applyPicked)
noctalia.state.watch("openvpn3.log", applyLog)
