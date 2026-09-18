--!nonstrict
-- Panel entry: declarative pop-up panel for DNF Updater (DNF5 + Flatpak).
-- Renders summary cards, categorized update lists, storage metrics, and execution triggers.

local enableDnf = noctalia.getConfig("enable_dnf") ~= false
local enableFlatpak = noctalia.getConfig("enable_flatpak") ~= false

local updateState = noctalia.state.get("update_state")

local excludedDnf = {}
local excludedFlatpak = {}

local dnfCollapsed = false
local flatpakCollapsed = false

local render -- forward declaration

local function formatBytes(bytes)
  if not bytes or bytes <= 0 then
    return "0 B"
  end
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local b = tonumber(bytes) or 0
  local uIndex = 1
  while b >= 1024 and uIndex < #units do
    b = b / 1024
    uIndex = uIndex + 1
  end
  if uIndex == 1 then
    return string.format("%d %s", b, units[uIndex])
  else
    return string.format("%.1f %s", b, units[uIndex])
  end
end

local function toggleExcludeDnf(name)
  if excludedDnf[name] then
    excludedDnf[name] = nil
  else
    excludedDnf[name] = true
  end
  if render then
    render()
  end
end

local function toggleExcludeFlatpak(id)
  if excludedFlatpak[id] then
    excludedFlatpak[id] = nil
  else
    excludedFlatpak[id] = true
  end
  if render then
    render()
  end
end

local function toggleAllDnf(packages)
  local anyExcluded = false
  for _, pkg in ipairs(packages) do
    if excludedDnf[pkg.name] then
      anyExcluded = true
      break
    end
  end
  if anyExcluded then
    for _, pkg in ipairs(packages) do
      excludedDnf[pkg.name] = nil
    end
  else
    for _, pkg in ipairs(packages) do
      excludedDnf[pkg.name] = true
    end
  end
  if render then
    render()
  end
end

local function toggleAllFlatpak(packages)
  local anyExcluded = false
  for _, pkg in ipairs(packages) do
    local k = pkg.id or pkg.name
    if excludedFlatpak[k] then
      anyExcluded = true
      break
    end
  end
  if anyExcluded then
    for _, pkg in ipairs(packages) do
      excludedFlatpak[pkg.id or pkg.name] = nil
    end
  else
    for _, pkg in ipairs(packages) do
      excludedFlatpak[pkg.id or pkg.name] = true
    end
  end
  if render then
    render()
  end
end

local function tr(key, params)
  local text = noctalia.tr(key) or key
  if params and type(params) == "table" then
    for k, v in pairs(params) do
      text = text:gsub("{" .. k .. "}", tostring(v))
    end
  end
  return text
end

local function formatLastChecked(state)
  if state and state.last_check and state.last_check ~= "" then
    return tr("status.last_checked", { time = state.last_check })
  end
  return tr("status.never_checked")
end

local function statusCard(state)
  local status = state and state.status or "IDLE"
  local total = state and state.total_count or 0

  if status == "CHECKING" then
    return ui.row({
      key = "status-card-checking",
      padding = 12,
      paddingH = 14,
      fill = "surface",
      radius = 8,
      align = "center",
      gap = 10,
    }, {
      ui.glyph({ name = "refresh", size = 18, color = "primary" }),
      ui.label({
        text = tr("status.checking"),
        fontSize = 13,
        fontWeight = "semibold",
        color = "on_surface",
        flexGrow = 1,
      }),
    })
  elseif status == "UPDATING" then
    local dnfStatus = state.dnf and state.dnf.status or "idle"
    local flatpakStatus = state.flatpak and state.flatpak.status or "idle"

    local dnfText = tr("status.dnf_" .. dnfStatus)
    local flatpakText = tr("status.flatpak_" .. flatpakStatus)

    return ui.column({
      key = "status-card-updating",
      padding = 12,
      paddingH = 14,
      fill = "surface",
      radius = 8,
      gap = 6,
    }, {
      ui.row({ align = "center", gap = 10 }, {
        ui.glyph({ name = "refresh", size = 18, color = "primary" }),
        ui.label({
          text = tr("status.updating"),
          fontSize = 13,
          fontWeight = "semibold",
          color = "on_surface",
          flexGrow = 1,
        }),
      }),
      ui.row({ align = "center", gap = 16, paddingH = 28 }, {
        ui.label({ text = dnfText, fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = flatpakText, fontSize = 11, color = "on_surface_variant" }),
      }),
    })
  elseif status == "ERROR" and total == 0 then
    local errMsg = (state and state.error_message) or tr("status.dnf_error")
    return ui.row({
      key = "status-card-error",
      padding = 12,
      paddingH = 14,
      fill = "surface",
      radius = 8,
      align = "center",
      gap = 10,
    }, {
      ui.glyph({ name = "alert-circle", size = 18, color = "error" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({
          text = errMsg,
          fontSize = 12,
          color = "error",
          maxLines = 2,
        }),
        ui.label({
          text = formatLastChecked(state),
          fontSize = 10,
          color = "on_surface_variant",
        }),
      }),
    })
  elseif total == 0 then
    -- Clean state: everything up to date
    return ui.column({
      key = "status-card-clean",
      padding = 20,
      paddingH = 16,
      fill = "surface",
      radius = 8,
      align = "center",
      justify = "center",
      gap = 8,
    }, {
      ui.glyph({ name = "check", size = 28, color = "secondary" }),
      ui.label({
        text = tr("status.everything_up_to_date"),
        fontSize = 14,
        fontWeight = "semibold",
        color = "on_surface",
      }),
      ui.label({
        text = formatLastChecked(state),
        fontSize = 11,
        color = "on_surface_variant",
      }),
    })
  else
    -- Updates available: overview metrics (DNF, Flatpak, Total only)
    local dnfCount = state and state.dnf and state.dnf.count or 0
    local flatpakCount = state and state.flatpak and state.flatpak.count or 0

    return ui.row({
      key = "status-card-summary",
      padding = 8,
      paddingH = 10,
      fill = "surface",
      radius = 8,
      align = "center",
      gap = 8,
    }, {
      ui.row({
        key = "summary-dnf-chip",
        flexGrow = 1,
        padding = 6,
        paddingH = 10,
        fill = "surface_variant",
        radius = 6,
        align = "center",
        justify = "space_between",
      }, {
        ui.label({ text = tr("summary.dnf"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = tostring(dnfCount), fontSize = 12, fontWeight = "bold", color = "primary" }),
      }),
      ui.row({
        key = "summary-flatpak-chip",
        flexGrow = 1,
        padding = 6,
        paddingH = 10,
        fill = "surface_variant",
        radius = 6,
        align = "center",
        justify = "space_between",
      }, {
        ui.label({ text = tr("summary.flatpak"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = tostring(flatpakCount), fontSize = 12, fontWeight = "bold", color = "secondary" }),
      }),
      ui.row({
        key = "summary-total-chip",
        flexGrow = 1,
        padding = 6,
        paddingH = 10,
        fill = "surface_variant",
        radius = 6,
        align = "center",
        justify = "space_between",
      }, {
        ui.label({ text = tr("summary.total"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = tostring(total), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
      }),
    })
  end
end

local function renderDnfSection(state)
  local dnf = state and state.dnf
  local packages = (dnf and dnf.packages) or {}
  local isBusy = state and (state.status == "CHECKING" or state.status == "UPDATING")

  if not enableDnf then
    return nil, 0, 0
  end

  local selectedCount = 0
  local selectedBytes = 0
  for _, pkg in ipairs(packages) do
    if not excludedDnf[pkg.name] then
      selectedCount += 1
      selectedBytes += (pkg.download_bytes or 0)
    end
  end

  local dnfTitle
  if #packages == 0 then
    dnfTitle = "DNF"
  elseif selectedCount == #packages then
    dnfTitle = tr("sections.dnf", { count = #packages })
  else
    dnfTitle = tr("sections.dnf_selected", { selected = selectedCount, total = #packages })
  end
  if selectedBytes > 0 then
    dnfTitle = dnfTitle .. " (" .. formatBytes(selectedBytes) .. ")"
  end

  local allSelected = #packages > 0 and selectedCount == #packages

  local headerChildren = {
    ui.button({
      key = "btn-collapse-dnf",
      glyph = dnfCollapsed and "chevron-right" or "chevron-down",
      variant = "ghost",
      controlSize = "sm",
      tooltip = dnfCollapsed and tr("actions.expand") or tr("actions.collapse"),
      onClick = function()
        dnfCollapsed = not dnfCollapsed
        render()
      end,
    }),
    ui.label({
      text = dnfTitle,
      fontSize = 12,
      fontWeight = "bold",
      color = "on_surface",
      flexGrow = 1,
    }),
  }

  if #packages > 0 then
    table.insert(headerChildren, ui.button({
      key = "btn-toggle-all-dnf",
      glyph = allSelected and "square-check" or "square",
      variant = "ghost",
      controlSize = "sm",
      tooltip = allSelected and tr("actions.deselect_all") or tr("actions.select_all"),
      enabled = not isBusy,
      onClick = function()
        toggleAllDnf(packages)
      end,
    }))
  end

  local items = {}
  local header = ui.row({ key = "dnf-section-header", align = "center", gap = 8, paddingV = 4 }, headerChildren)
  table.insert(items, header)

  if not dnfCollapsed then

  for idx, pkg in ipairs(packages) do
    local isExcluded = excludedDnf[pkg.name] == true
    local badge = pkg.arch
    if pkg.repo and pkg.repo ~= "" then
      badge = badge ~= "" and (badge .. " · " .. pkg.repo) or pkg.repo
    end

    local sizeLabel = (pkg.download_formatted and pkg.download_formatted ~= "") and pkg.download_formatted or ""

    local nameRowChildren = {
      ui.label({
        text = pkg.name or "Unknown",
        fontSize = 12,
        fontWeight = "semibold",
        color = isExcluded and "on_surface_variant" or "on_surface",
      }),
    }
    if isExcluded then
      table.insert(nameRowChildren, ui.label({
        text = "(" .. tr("status.skipped") .. ")",
        fontSize = 10,
        color = "on_surface_variant",
      }))
    end

    table.insert(items, ui.row({
      key = "dnf-pkg-" .. tostring(idx) .. "-" .. (pkg.name or "pkg"),
      padding = 8,
      paddingH = 12,
      fill = isExcluded and "surface_variant" or "surface",
      radius = 6,
      align = "center",
      gap = 8,
      tooltip = isExcluded and tr("actions.include_pkg") or tr("actions.exclude_pkg"),
      onClick = function()
        if not isBusy then
          toggleExcludeDnf(pkg.name)
        end
      end,
    }, {
      ui.glyph({
        name = isExcluded and "square" or "square-check",
        size = 18,
        color = isExcluded and "on_surface_variant" or "primary",
      }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.row({ align = "center", gap = 6 }, nameRowChildren),
        ui.label({
          text = pkg.evr or "",
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.column({ align = "end", gap = 2 }, {
        ui.label({
          text = sizeLabel,
          fontSize = 11,
          fontWeight = "bold",
          color = isExcluded and "on_surface_variant" or "on_surface",
        }),
        ui.label({
          text = badge or "",
          fontSize = 10,
          color = isExcluded and "on_surface_variant" or "primary",
          fontWeight = "semibold",
        }),
      }),
    }))
  end
  end

  return items, selectedCount, selectedBytes
end

local function renderFlatpakSection(state)
  local flatpak = state and state.flatpak
  local packages = (flatpak and flatpak.packages) or {}
  local isBusy = state and (state.status == "CHECKING" or state.status == "UPDATING")

  if not enableFlatpak then
    return nil, 0, 0
  end

  local selectedCount = 0
  local selectedBytes = 0
  for _, pkg in ipairs(packages) do
    local k = pkg.id or pkg.name
    if not excludedFlatpak[k] then
      selectedCount += 1
      selectedBytes += (pkg.download_bytes or pkg.install_bytes or 0)
    end
  end

  local flatpakTitle
  if #packages == 0 then
    flatpakTitle = "Flatpak"
  elseif selectedCount == #packages then
    flatpakTitle = tr("sections.flatpak", { count = #packages })
  else
    flatpakTitle = tr("sections.flatpak_selected", { selected = selectedCount, total = #packages })
  end
  if selectedBytes > 0 then
    flatpakTitle = flatpakTitle .. " (" .. formatBytes(selectedBytes) .. ")"
  end

  local allSelected = #packages > 0 and selectedCount == #packages

  local headerChildren = {
    ui.button({
      key = "btn-collapse-flatpak",
      glyph = flatpakCollapsed and "chevron-right" or "chevron-down",
      variant = "ghost",
      controlSize = "sm",
      tooltip = flatpakCollapsed and tr("actions.expand") or tr("actions.collapse"),
      onClick = function()
        flatpakCollapsed = not flatpakCollapsed
        render()
      end,
    }),
    ui.label({
      text = flatpakTitle,
      fontSize = 12,
      fontWeight = "bold",
      color = "on_surface",
      flexGrow = 1,
    }),
  }

  if #packages > 0 then
    table.insert(headerChildren, ui.button({
      key = "btn-toggle-all-flatpak",
      glyph = allSelected and "square-check" or "square",
      variant = "ghost",
      controlSize = "sm",
      tooltip = allSelected and tr("actions.deselect_all") or tr("actions.select_all"),
      enabled = not isBusy,
      onClick = function()
        toggleAllFlatpak(packages)
      end,
    }))
  end

  local items = {}
  local header = ui.row({ key = "flatpak-section-header", align = "center", gap = 8, paddingV = 4 }, headerChildren)
  table.insert(items, header)

  if not flatpakCollapsed then

  for idx, pkg in ipairs(packages) do
    local pkgKey = pkg.id or pkg.name or tostring(idx)
    local isExcluded = excludedFlatpak[pkgKey] == true

    local subtitle = pkg.id or pkg.branch or ""
    if pkg.origin and pkg.origin ~= "" then
      subtitle = subtitle ~= "" and (subtitle .. " · " .. pkg.origin) or pkg.origin
    end

    local sizeLabel = (pkg.download_formatted and pkg.download_formatted ~= "") and pkg.download_formatted or (pkg.install_formatted or "")

    local nameRowChildren = {
      ui.label({
        text = pkg.name or "Unknown",
        fontSize = 12,
        fontWeight = "semibold",
        color = isExcluded and "on_surface_variant" or "on_surface",
      }),
    }
    if isExcluded then
      table.insert(nameRowChildren, ui.label({
        text = "(" .. tr("status.skipped") .. ")",
        fontSize = 10,
        color = "on_surface_variant",
      }))
    end

    table.insert(items, ui.row({
      key = "flatpak-pkg-" .. tostring(idx) .. "-" .. pkgKey,
      padding = 8,
      paddingH = 12,
      fill = isExcluded and "surface_variant" or "surface",
      radius = 6,
      align = "center",
      gap = 8,
      tooltip = isExcluded and tr("actions.include_pkg") or tr("actions.exclude_pkg"),
      onClick = function()
        if not isBusy then
          toggleExcludeFlatpak(pkgKey)
        end
      end,
    }, {
      ui.glyph({
        name = isExcluded and "square" or "square-check",
        size = 18,
        color = isExcluded and "on_surface_variant" or "secondary",
      }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.row({ align = "center", gap = 6 }, nameRowChildren),
        ui.label({
          text = subtitle,
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.column({ align = "end", gap = 2 }, {
        ui.label({
          text = sizeLabel,
          fontSize = 11,
          fontWeight = "bold",
          color = isExcluded and "on_surface_variant" or "secondary",
        }),
        ui.label({
          text = pkg.version or "",
          fontSize = 10,
          color = "on_surface_variant",
          fontWeight = "semibold",
        }),
      }),
    }))
  end
  end

  return items, selectedCount, selectedBytes
end

render = function()
  enableDnf = noctalia.getConfig("enable_dnf") ~= false
  enableFlatpak = noctalia.getConfig("enable_flatpak") ~= false

  local state = updateState
  local isBusy = state and (state.status == "CHECKING" or state.status == "UPDATING")
  local total = state and state.total_count or 0

  local header = ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "package", size = 16, color = "primary" }),
    ui.label({
      key = "panel-title",
      text = tr("title"),
      fontSize = 15,
      fontWeight = "bold",
      color = "on_surface",
    }),
    ui.spacer({ key = "header-spacer", flexGrow = 1 }),
    ui.button({
      key = "header-refresh",
      glyph = "refresh",
      variant = "ghost",
      enabled = not isBusy,
      tooltip = tr("actions.check_now"),
      onClick = "onCheckNow",
    }),
    ui.button({
      key = "header-settings",
      glyph = "settings",
      variant = "ghost",
      tooltip = tr("actions.open_settings"),
      onClick = "onOpenSettings",
    }),
    ui.button({
      key = "header-close",
      glyph = "close",
      variant = "ghost",
      tooltip = tr("actions.close"),
      onClick = "onClosePanel",
    }),
  })

  local card = statusCard(state)

  -- Package list rows
  local scrollItems = {}
  local dnfItems, dnfSelCount, dnfSelBytes = renderDnfSection(state)
  if dnfItems then
    for _, item in ipairs(dnfItems) do
      table.insert(scrollItems, item)
    end
  end

  local flatpakItems, fpSelCount, fpSelBytes = renderFlatpakSection(state)
  if flatpakItems then
    for _, item in ipairs(flatpakItems) do
      table.insert(scrollItems, item)
    end
  end

  local listContainer
  if #scrollItems > 0 then
    listContainer = ui.scroll({ key = "packages-scroll", flexGrow = 1, gap = 6 }, scrollItems)
  else
    listContainer = ui.column({ key = "empty-filler", flexGrow = 1 }, {})
  end

  local totalSelected = (dnfSelCount or 0) + (fpSelCount or 0)
  local totalSelectedBytes = (dnfSelBytes or 0) + (fpSelBytes or 0)

  local btnText
  if totalSelected == total then
    if totalSelectedBytes > 0 then
      btnText = tr("actions.update_all_size", { count = total, size = formatBytes(totalSelectedBytes) })
    else
      btnText = tr("actions.update_all")
    end
  else
    if totalSelectedBytes > 0 then
      btnText = tr("actions.update_selected_size", { count = totalSelected, size = formatBytes(totalSelectedBytes) })
    else
      btnText = tr("actions.update_selected", { count = totalSelected })
    end
  end

  local footer = ui.column({ gap = 8 }, {
    ui.separator({ orientation = "horizontal" }),
    ui.row({ align = "center", gap = 8 }, {
      ui.button({
        key = "btn-update-all",
        text = btnText,
        glyph = "download",
        variant = "primary",
        flexGrow = 1,
        enabled = (totalSelected > 0 and not isBusy),
        onClick = "onUpdateAll",
      }),
    }),
  })

  panel.render(ui.column({ flexGrow = 1, gap = 6, align = "stretch" }, {
    header,
    card,
    listContainer,
    footer,
  }))
end

function onOpen(_context)
  updateState = noctalia.state.get("update_state")
  render()
end

function onClose()
  -- Panel close hook
end

function onCheckNow()
  noctalia.state.set("service_command", { action = "check_now", ts = os.time() })
end

function onUpdateAll()
  local excludedDnfList = {}
  if updateState and updateState.dnf and updateState.dnf.packages then
    for _, pkg in ipairs(updateState.dnf.packages) do
      if excludedDnf[pkg.name] then
        table.insert(excludedDnfList, pkg.name)
      end
    end
  end

  local selectedFlatpakList = {}
  if updateState and updateState.flatpak and updateState.flatpak.packages then
    for _, pkg in ipairs(updateState.flatpak.packages) do
      local k = pkg.id or pkg.name
      if not excludedFlatpak[k] then
        table.insert(selectedFlatpakList, pkg.id or pkg.name)
      end
    end
  end

  noctalia.state.set("service_command", {
    action = "update_all",
    excluded_dnf = excludedDnfList,
    selected_flatpak = selectedFlatpakList,
    ts = os.time(),
  })
end

function onUpdateDnf()
  local excludedDnfList = {}
  if updateState and updateState.dnf and updateState.dnf.packages then
    for _, pkg in ipairs(updateState.dnf.packages) do
      if excludedDnf[pkg.name] then
        table.insert(excludedDnfList, pkg.name)
      end
    end
  end

  noctalia.state.set("service_command", {
    action = "update_dnf",
    excluded_dnf = excludedDnfList,
    ts = os.time(),
  })
end

function onUpdateFlatpak()
  local selectedFlatpakList = {}
  if updateState and updateState.flatpak and updateState.flatpak.packages then
    for _, pkg in ipairs(updateState.flatpak.packages) do
      local k = pkg.id or pkg.name
      if not excludedFlatpak[k] then
        table.insert(selectedFlatpakList, pkg.id or pkg.name)
      end
    end
  end

  noctalia.state.set("service_command", {
    action = "update_flatpak",
    selected_flatpak = selectedFlatpakList,
    ts = os.time(),
  })
end

function onOpenSettings()
  noctalia.openSettings()
end

function onClosePanel()
  panel.close()
end

-- Subscribe to state changes from background service
noctalia.state.watch("update_state", function(newState)
  updateState = newState
  render()
end)

render()
