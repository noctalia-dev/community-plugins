--!nonstrict
-- Containers panel: Modern tabular and card views for Docker, Podman, and Host services.

local KEY_SNAPSHOT = "snapshot"
local KEY_REFRESH_NONCE = "refresh"
local MAX_CHIPS = 4
local ROOT_HEIGHT = 560

local snapshot = nil
local isOpen = false
local refreshNonce = 0
local viewMode = "table"
local hideMissing = true
local searchQuery = ""

local function shellQuote(value)
  return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function openUrl(url)
  if url == nil or url == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("panel.no-ports"))
    return
  end

  local browser = noctalia.getConfig("browser_command")
  if type(browser) ~= "string" then browser = "" end
  browser = noctalia.string.trim(browser)

  local command = browser == "" and ("xdg-open " .. shellQuote(url)) or (browser .. " " .. shellQuote(url))

  noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      local detail = noctalia.string.trim(result.stderr or "")
      if detail == "" then detail = command end
      noctalia.notifyError(noctalia.tr("errors.open_failed", { url = url }), detail)
    end
  end)
end

local function copyUrl(url)
  if noctalia.copyToClipboard(url, "text/plain") then
    noctalia.notify(noctalia.tr("notify.copied.title"), noctalia.tr("notify.copied.body", { url = url }))
  end
end

local function requestRefresh()
  refreshNonce = refreshNonce + 1
  noctalia.state.set(KEY_REFRESH_NONCE, refreshNonce)
  render()
end

local function matchesSearch(container)
  if searchQuery == "" then return true end
  local q = searchQuery:lower()
  if container.name:lower():find(q, 1, true) then return true end
  if container.image:lower():find(q, 1, true) then return true end
  for _, p in ipairs(container.ports) do
    if tostring(p.hostPort):find(q, 1, true) or tostring(p.containerPort):find(q, 1, true) then
      return true
    end
  end
  return false
end

local function portChip(port)
  local text = port.hostPort == port.containerPort and tostring(port.hostPort)
    or string.format("%d->%d", port.hostPort, port.containerPort)

  return ui.button({
    key = "port_" .. tostring(port.hostPort),
    text = text,
    glyph = "external-link",
    glyphSize = 10,
    fontSize = 10,
    variant = port.internal == true and "outline" or "secondary",
    controlSize = "sm",
    height = 22,
    tooltip = port.internal == true
      and noctalia.tr("panel.port.internal", { url = port.url })
      or port.url,
    onClick = function() openUrl(port.url) end,
    onRightClick = function() copyUrl(port.url) end,
  })
end

local function tableRow(container)
  local chips = {}
  local shown = math.min(#container.ports, MAX_CHIPS)
  for index = 1, shown do chips[#chips + 1] = portChip(container.ports[index]) end
  if #container.ports > shown then
    chips[#chips + 1] = ui.label({
      key = "overflow_" .. container.key,
      text = noctalia.tr("panel.ports-overflow", { count = #container.ports - shown }),
      fontSize = 10,
      color = "on_surface_variant",
    })
  end

  local statusColor = container.running and "primary" or "outline"
  local statusDot = container.running and "●" or "○"
  local meta = container.image ~= "" and container.image or noctalia.tr("panel.no-image")
  if container.status ~= "" then
    meta = meta .. " · " .. container.status
  end

  local props = {
    key = container.key,
    gap = 8,
    align = "center",
    justify = "space_between",
    paddingH = 8,
    paddingV = 5,
    fill = container.running and "surface" or "surface_variant",
    border = "outline",
    borderWidth = 1,
    radius = 6,
  }
  if container.webUrl ~= "" then
    props.onClick = function() openUrl(container.webUrl) end
  end

  local left = {
    ui.row({ gap = 5, align = "center", width = 135 }, {
      ui.label({ text = statusDot, fontSize = 9, color = statusColor }),
      ui.label({
        key = "name_" .. container.key,
        text = container.name,
        fontSize = 12,
        fontWeight = "medium",
        color = "on_surface",
        maxLines = 1,
      }),
    }),
    ui.label({
      key = "image_" .. container.key,
      text = meta,
      fontSize = 10,
      color = not container.running and "error" or "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    }),
  }

  local trailing = #chips > 0 and ui.row({ key = "chips_" .. container.key, gap = 4, align = "center" }, chips)
    or ui.label({
      key = "noports_" .. container.key,
      text = noctalia.tr("panel.no-ports"),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
    })

  return ui.row(props, {
    ui.row({ gap = 6, align = "center", flexGrow = 1 }, left),
    trailing,
  })
end

local function cardRow(container)
  local chips = {}
  local shown = math.min(#container.ports, MAX_CHIPS)
  for index = 1, shown do chips[#chips + 1] = portChip(container.ports[index]) end
  if #container.ports > shown then
    chips[#chips + 1] = ui.label({
      key = "overflow_" .. container.key,
      text = noctalia.tr("panel.ports-overflow", { count = #container.ports - shown }),
      fontSize = 10,
      color = "on_surface_variant",
    })
  end

  local meta = container.image ~= "" and container.image or noctalia.tr("panel.no-image")
  if container.running and container.status ~= "" then
    meta = meta .. " · " .. container.status
  end

  local left = {
    ui.label({
      key = "name_" .. container.key,
      text = container.name,
      fontSize = 12,
      fontWeight = "medium",
      color = "on_surface",
      maxLines = 1,
      maxWidth = 140,
    }),
    ui.label({
      key = "image_" .. container.key,
      text = meta,
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
      maxWidth = 130,
    }),
  }
  if not container.running and container.status ~= "" then
    left[#left + 1] = ui.label({
      key = "status_" .. container.key,
      text = container.status,
      fontSize = 10,
      color = "error",
      maxLines = 1,
      maxWidth = 110,
    })
  end

  local props = {
    key = container.key,
    gap = 0,
    paddingH = 8,
    paddingV = 4,
    fill = container.running and "surface_variant" or "surface",
    radius = 6,
  }
  if not container.running then
    props.border = "outline"
    props.borderWidth = 1
  end
  if container.webUrl ~= "" then
    props.onClick = function() openUrl(container.webUrl) end
  end

  local trailing = #chips > 0 and ui.row({ key = "chips_" .. container.key, gap = 4, align = "center" }, chips)
    or ui.label({
      key = "noports_" .. container.key,
      text = noctalia.tr("panel.no-ports"),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
      maxWidth = 90,
    })

  return ui.column(props, {
    ui.row({ gap = 8, align = "center", justify = "space_between" }, {
      ui.row({ gap = 6, align = "center", flexGrow = 1 }, left),
      trailing,
    }),
  })
end

local function runtimeSection(info)
  if hideMissing and not info.available then
    return nil
  end

  local children = {
    ui.row({
      gap = 6,
      align = "center",
      justify = "space_between",
      fill = "surface",
      border = "outline",
      borderWidth = 1,
      radius = 6,
      paddingH = 8,
      paddingV = 3,
    }, {
      ui.row({ gap = 5, align = "center" }, {
        ui.glyph({ name = info.glyph, size = 12, color = "primary" }),
        ui.label({ text = info.label, fontSize = 11, fontWeight = "bold", color = "on_surface" }),
      }),
      ui.label({
        text = string.format("%d %s", info.count, noctalia.trp("panel.unit", info.count)),
        fontSize = 10,
        color = "on_surface_variant",
      }),
    }),
  }

  if not info.available then
    children[#children + 1] = ui.label({
      key = "err_" .. info.id,
      text = noctalia.tr("panel.runtime.missing"),
      fontSize = 11,
      color = "on_surface_variant",
    })
  elseif info.errorKey ~= "" then
    children[#children + 1] = ui.label({
      key = "err_" .. info.id,
      text = noctalia.tr(info.errorKey),
      fontSize = 11,
      color = "error",
    })
  elseif info.count == 0 then
    children[#children + 1] = ui.label({
      key = "empty_" .. info.id,
      text = noctalia.tr(info.emptyKey ~= "" and info.emptyKey or "panel.empty.body"),
      fontSize = 11,
      color = "on_surface_variant",
    })
  else
    for _, container in ipairs(info.containers) do
      if matchesSearch(container) then
        children[#children + 1] = viewMode == "table" and tableRow(container) or cardRow(container)
      end
    end
  end

  return ui.column({ key = "runtime_" .. info.id, gap = 4 }, children)
end

local function summaryLine()
  if snapshot == nil then return "" end
  return string.format(
    "%d / %d %s",
    snapshot.web,
    snapshot.total,
    noctalia.trp("panel.unit_web", snapshot.web == 0 and 1 or snapshot.web)
  )
end

local function buildTree()
  local sections = {}
  if snapshot == nil then
    sections[#sections + 1] = ui.column({ gap = 8, paddingH = 12 }, {
      ui.label({ key = "loading", text = noctalia.tr("panel.loading.title"), fontSize = 12, fontWeight = "medium" }),
      ui.label({ key = "loading_hint", text = noctalia.tr("panel.loading.hint"), fontSize = 11, color = "on_surface_variant" }),
    })
  else
    local visibleCount = 0
    for _, info in ipairs(snapshot.runtimes) do
      local sec = runtimeSection(info)
      if sec ~= nil then
        visibleCount = visibleCount + 1
        if visibleCount > 1 then
          sections[#sections + 1] = ui.separator({
            key = "sep_" .. info.id,
            thickness = 1,
            color = "outline",
            spacing = 8,
          })
        end
        sections[#sections + 1] = sec
      end
    end
    if visibleCount == 0 then
      sections[#sections + 1] = ui.column({ gap = 6, padding = 16, align = "center" }, {
        ui.glyph({ name = "container", size = 24, color = "on_surface_variant" }),
        ui.label({ text = noctalia.tr("panel.empty.title"), fontSize = 13, fontWeight = "medium" }),
      })
    end
  end

  local viewToggleTooltip = viewMode == "table" and noctalia.tr("panel.view_mode_table") or noctalia.tr("panel.view_mode_cards")

  return ui.column({ gap = 0, height = ROOT_HEIGHT }, {
    ui.row({ padding = 10, gap = 10, align = "center", justify = "space_between" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "container", size = 16, color = "primary" }),
        ui.column({ gap = 1 }, {
          ui.label({
            key = "title",
            text = noctalia.tr("panel.title"),
            fontSize = 15,
            fontWeight = "bold",
            color = "on_surface",
          }),
          ui.label({
            key = "summary",
            text = summaryLine(),
            fontSize = 11,
            color = "on_surface_variant",
          }),
        }),
      }),
      ui.row({ gap = 6, align = "center" }, {
        ui.button({
          key = "view_toggle",
          glyph = viewMode == "table" and "layout-grid" or "list",
          glyphSize = 14,
          variant = "ghost",
          controlSize = "sm",
          tooltip = viewToggleTooltip,
          onClick = "onViewToggle",
        }),
        ui.button({
          key = "options",
          glyph = "settings",
          glyphSize = 14,
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.settings"),
          onClick = "onOptions",
        }),
        ui.button({
          key = "refresh",
          glyph = "refresh",
          glyphSize = 14,
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.refresh"),
          onClick = "onRefresh",
        }),
        ui.button({
          key = "close",
          glyph = "x",
          glyphSize = 14,
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.close"),
          onClick = "onClose",
        }),
      }),
    }),
    ui.row({ paddingH = 10, paddingV = 4 }, {
      ui.input({
        key = "search",
        placeholder = noctalia.tr("panel.search_placeholder"),
        value = searchQuery,
        controlSize = "sm",
        flexGrow = 1,
        onChange = "onSearch",
      }),
    }),
    ui.separator({ key = "sep_top", thickness = 1, color = "outline", spacing = 0 }),
    ui.scroll({ key = "body", flexGrow = 1, gap = 6, padding = 8 }, sections),
    ui.separator({ key = "sep_bottom", thickness = 1, color = "outline", spacing = 0 }),
    ui.row({ key = "hint_row", padding = 8 }, {
      ui.label({
        key = "hint",
        text = noctalia.tr("panel.hint"),
        fontSize = 10,
        color = "on_surface_variant",
      }),
    }),
  })
end

local function loadConfig()
  local vm = noctalia.getConfig("view_mode")
  if type(vm) == "string" and (vm == "table" or vm == "cards") then
    viewMode = vm
  end
  hideMissing = noctalia.getConfig("hide_missing_runtimes") ~= false
end

function render()
  if not isOpen then return end
  panel.render(buildTree())
end

function onRefresh() requestRefresh() end

function onOptions()
  noctalia.runAsync("noctalia msg settings-open-plugin davinci13/containers", function() end)
end

function onViewToggle()
  viewMode = viewMode == "table" and "cards" or "table"
  render()
end

function onSearch(val)
  searchQuery = val or ""
  render()
end

function onOpen(_context)
  isOpen = true
  loadConfig()
  snapshot = noctalia.state.get(KEY_SNAPSHOT)
  render()
end

function onClose()
  isOpen = false
  panel.close()
end

loadConfig()
snapshot = noctalia.state.get(KEY_SNAPSHOT)
noctalia.state.watch(KEY_SNAPSHOT, function(value)
  snapshot = value
  render()
end)
