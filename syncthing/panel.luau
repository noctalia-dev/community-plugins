--!nonstrict
-- Syncthing detail panel — the [[panel]] entry.
--
-- Header with live state + refresh and pause-all/resume-all buttons, stat
-- tiles (devices / folders / pending), a scrolling folder list with
-- per-folder pause/resume and rescan actions, then details, recent errors,
-- and connection info.
--
-- Per-folder buttons use the predeclared-slot pattern (onPause0…, onRescan0…):
-- ui.* callbacks are global function *names*, so each rendered row binds its
-- folder id into a slot table the numbered globals read back.

local MAX_FOLDER_SLOTS = 16

local snapshot = nil
local isOpen = false
local cmdNonce = 0
-- Active list tab: "folders" | "devices" (Syncthing Tray-style tabs).
local view = "folders"
-- Slot table: index → { kind = "folder"|"device", id = <target id> }.
local folderSlots = {}

local STATE_COLORS = {
  idle = "primary",
  syncing = "secondary",
  paused = "outline",
  disconnected = "secondary",
  offline = "error",
  unauthorized = "error",
  error = "error",
  unconfigured = "outline",
  disabled = "outline",
}

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function sendCmd(action, folderId)
  cmdNonce += 1
  noctalia.state.set("st.cmd", noctalia.json.encode({ n = cmdNonce, action = action, folder = folderId }))
end

local function formatBytes(bytes)
  local units = { "B", "KB", "MB", "GB", "TB" }
  local value = tonumber(bytes) or 0
  local index = 1
  while value >= 1024 and index < #units do
    value /= 1024
    index += 1
  end
  local rounded = (value >= 10 or index == 1) and tostring(math.round(value)) or string.format("%.1f", value)
  return `{rounded} {units[index]}`
end

local function statusSummary()
  if not snapshot then
    return tr("state.unconfigured")
  end
  local state = snapshot.state
  if state == "idle" then
    if snapshot.devices.configured > 0 then
      return tr("summary.idle-devices", {
        connected = snapshot.devices.connected,
        configured = snapshot.devices.configured,
      })
    end
    return tr("summary.idle-no-devices")
  end
  if state == "syncing" then
    if snapshot.totals.needItems > 0 then
      return tr("summary.syncing-items", { count = snapshot.totals.needItems })
    end
    return tr("summary.syncing-folders", { count = math.max(snapshot.totals.syncingFolders, 1) })
  end
  return tr(`summary.{state}`)
end

local function detailText()
  if not snapshot or snapshot.detail == "" then
    return ""
  end
  -- Structured details are translation keys; anything else passes through.
  if snapshot.detail == "no-url" or snapshot.detail == "no-api-key" or snapshot.detail == "no-folders" then
    return tr(`detail.{snapshot.detail}`)
  end
  return snapshot.detail
end

local function allPaused()
  return snapshot ~= nil
    and snapshot.devices.configured > 0
    and snapshot.devices.paused >= snapshot.devices.configured
end

-- ── Sections ─────────────────────────────────────────────────────────────────

local function header()
  local state = snapshot and snapshot.state or "unconfigured"
  local paused = allPaused()
  return ui.row({ gap = 8, align = "center" }, {
    ui.image({
      path = noctalia.isDarkMode() and "icon.svg" or "icon-light.svg",
      width = 20,
      height = 20,
      fit = "contain",
    }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = tr(`state.{state}`), fontSize = 12, color = STATE_COLORS[state] or "outline" }),
    }),
    ui.button({
      glyph = paused and "player-play" or "player-pause",
      variant = "outline",
      controlSize = "sm",
      tooltip = paused and tr("panel.resume-all") or tr("panel.pause-all"),
      onClick = paused and "onResumeAll" or "onPauseAll",
    }),
    ui.button({
      glyph = "external-link",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.open-gui"),
      onClick = "onOpenGui",
    }),
    ui.button({
      glyph = "refresh",
      variant = "primary",
      controlSize = "sm",
      tooltip = tr("panel.refresh"),
      onClick = "onRefresh",
    }),
  })
end

local function formatRate(bytesPerSec)
  if bytesPerSec < 1024 then
    return nil
  end
  return `{formatBytes(bytesPerSec)}/s`
end

local function ratesLabel()
  -- Always returns a node (an invisible one when idle): a nil in the middle of
  -- a children array literal would truncate the siblings after it.
  local down = snapshot and formatRate(snapshot.rateIn or 0) or nil
  local up = snapshot and formatRate(snapshot.rateOut or 0) or nil
  return ui.label({
    text = `↓ {down or "0 B/s"} · ↑ {up or "0 B/s"}`,
    fontSize = 11,
    color = "secondary",
    visible = (down or up) ~= nil,
  })
end

local function statTile(value, label)
  return ui.column({ gap = 2, padding = 8, fill = "surface_variant/0.5", radius = 8, align = "center", flexGrow = 1 }, {
    ui.label({ text = value, fontSize = 15, fontWeight = "bold" }),
    ui.label({ text = label, fontSize = 11, color = "on_surface/0.6" }),
  })
end

local function stats()
  local devices = snapshot and `{snapshot.devices.connected}/{snapshot.devices.configured}` or "-"
  local folders = snapshot and tostring(snapshot.totals.monitoredFolders) or "-"
  local pending = "-"
  if snapshot then
    pending = snapshot.totals.needItems > 0
      and tostring(snapshot.totals.needItems)
      or formatBytes(snapshot.totals.needBytes)
  end
  return ui.row({ gap = 8 }, {
    statTile(devices, tr("panel.devices")),
    statTile(folders, tr("panel.folders")),
    statTile(pending, tr("panel.pending")),
  })
end

local function folderStateText(folder)
  if folder.state == "syncing" then
    local base = `{tr(`state.{folder.state}`)} {folder.completion}%`
    if folder.needItems > 0 then
      base = tr("panel.folder-state", { state = base, count = folder.needItems })
    end
    return base
  end
  if folder.state == "error" and folder.detail ~= "" then
    return folder.detail
  end
  if folder.state == "idle" and folder.lastActivity ~= "" then
    return tr("panel.last-activity", { value = folder.lastActivity })
  end
  return tr(`state.{folder.state}`)
end

local function tabs()
  local folderCount = snapshot and snapshot.totals.monitoredFolders or 0
  local connected = snapshot and snapshot.devices.connected or 0
  local configured = snapshot and snapshot.devices.configured or 0
  return ui.row({ gap = 6 }, {
    ui.button({
      text = `{tr("panel.tab-folders")} ({folderCount})`,
      glyph = "folder",
      variant = view == "folders" and "secondary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = "onTabFolders",
    }),
    ui.button({
      text = `{tr("panel.tab-devices")} ({connected}/{configured})`,
      glyph = "devices-pc",
      variant = view == "devices" and "secondary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = "onTabDevices",
    }),
  })
end

local function folderRow(folder, slot)
  folderSlots[slot] = { kind = "folder", id = folder.id }
  local color = STATE_COLORS[folder.state] or "outline"
  return ui.row({
    key = `folder-{folder.id}`,
    gap = 8,
    padding = 8,
    align = "center",
    fill = "surface_variant/0.5",
    radius = 8,
    border = `{color}/0.5`,
    borderWidth = 1,
  }, {
    ui.box({ width = 8, height = 8, radius = 4, fill = color }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = folder.label, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
      ui.label({ text = folderStateText(folder), fontSize = 11, color = "on_surface/0.65", maxLines = 1 }),
      ui.progress({
        progress = folder.completion / 100,
        height = 3,
        fill = "secondary",
        visible = folder.state == "syncing",
      }),
    }),
    ui.button({
      glyph = folder.paused and "player-play" or "player-pause",
      variant = "ghost",
      controlSize = "sm",
      tooltip = folder.paused and tr("panel.folder-resume") or tr("panel.folder-pause"),
      onClick = (folder.paused and "onResume" or "onPause") .. slot,
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      enabled = not folder.paused,
      tooltip = tr("panel.folder-rescan"),
      onClick = "onRescan" .. slot,
    }),
  })
end

local function deviceRow(device, slot)
  folderSlots[slot] = { kind = "device", id = device.id }
  local color = device.connected and "primary" or "outline"
  local subtitle
  if device.paused then
    subtitle = tr("device.paused")
  elseif device.connected then
    subtitle = device.address ~= "" and device.address or tr("device.connected")
    if device.version ~= "" then
      subtitle = `{subtitle} · {device.version}`
    end
  else
    subtitle = tr("device.disconnected")
  end
  return ui.row({
    key = `device-{device.shortId}`,
    gap = 8,
    padding = 8,
    align = "center",
    fill = "surface_variant/0.5",
    radius = 8,
    border = `{color}/0.5`,
    borderWidth = 1,
    opacity = device.connected and 1 or 0.7,
  }, {
    ui.box({ width = 8, height = 8, radius = 4, fill = color }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = device.name, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
      ui.label({ text = subtitle, fontSize = 11, color = "on_surface/0.65", maxLines = 1 }),
    }),
    ui.button({
      glyph = device.paused and "player-play" or "player-pause",
      variant = "ghost",
      controlSize = "sm",
      tooltip = device.paused and tr("panel.device-resume") or tr("panel.device-pause"),
      onClick = (device.paused and "onResume" or "onPause") .. slot,
    }),
  })
end

local function folderList()
  local rows = {}
  if snapshot then
    if view == "devices" then
      for index, device in snapshot.devicesList do
        if index > MAX_FOLDER_SLOTS then
          break
        end
        table.insert(rows, deviceRow(device, index - 1))
      end
    else
      for index, folder in snapshot.folders do
        if index > MAX_FOLDER_SLOTS then
          break
        end
        table.insert(rows, folderRow(folder, index - 1))
      end
    end
  end
  if #rows == 0 then
    local emptyKey = view == "devices" and "panel.no-devices" or "panel.no-folders"
    table.insert(rows, ui.label({ text = tr(emptyKey), fontSize = 12, color = "on_surface/0.6" }))
  end
  return ui.scroll({ gap = 6, flexGrow = 1 }, rows)
end

local function footer()
  local children = {}
  local detail = detailText()
  if detail ~= "" then
    table.insert(children, ui.label({
      text = detail,
      fontSize = 11,
      color = (snapshot and STATE_COLORS[snapshot.state] == "error") and "error" or "on_surface/0.75",
      maxLines = 3,
    }))
  end
  if snapshot then
    for _, err in snapshot.recentErrors do
      if #children >= 4 then
        break
      end
      table.insert(children, ui.label({ text = err.message, fontSize = 11, color = "error/0.85", maxLines = 2 }))
    end
    table.insert(children, ui.label({
      text = tr("panel.last-check-info", { value = snapshot.checkedAt }),
      fontSize = 11,
      color = "on_surface/0.55",
    }))
    if snapshot.sources.resolvedUrl ~= "" then
      table.insert(children, ui.label({
        text = snapshot.sources.resolvedUrl,
        fontSize = 11,
        color = "on_surface/0.55",
        maxLines = 1,
      }))
    end
  end
  return ui.column({ gap = 3 }, children)
end

local function render()
  if not isOpen then
    return
  end
  folderSlots = {}
  -- height pins the root to the [[panel]] size so the folder list scrolls
  -- instead of growing past the panel background
  panel.render(ui.column({ gap = 12, padding = 14, height = 500 }, {
    header(),
    ui.label({ text = statusSummary(), fontSize = 12, color = "on_surface/0.8" }),
    stats(),
    tabs(),
    folderList(),
    ratesLabel(),
    ui.separator({}),
    footer(),
  }))
end

-- ── Lifecycle & callbacks ────────────────────────────────────────────────────

noctalia.state.watch("st.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function onOpen(_context)
  isOpen = true
  local encoded = noctalia.state.get("st.snapshot")
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
  sendCmd("refresh")
end

function onClose()
  isOpen = false
end

function onRefresh()
  sendCmd("refresh")
end

function onOpenGui()
  sendCmd("open_gui")
end

function onPauseAll()
  sendCmd("pause_all")
end

function onResumeAll()
  sendCmd("resume_all")
end

function onTabFolders()
  view = "folders"
  render()
end

function onTabDevices()
  view = "devices"
  render()
end

local function pauseAt(slot)
  local target = folderSlots[slot]
  if target then
    sendCmd(target.kind == "device" and "device_pause" or "folder_pause", target.id)
  end
end

local function resumeAt(slot)
  local target = folderSlots[slot]
  if target then
    sendCmd(target.kind == "device" and "device_resume" or "folder_resume", target.id)
  end
end

local function rescanAt(slot)
  local target = folderSlots[slot]
  if target and target.kind == "folder" then
    sendCmd("rescan", target.id)
  end
end

function onPause0() pauseAt(0) end
function onPause1() pauseAt(1) end
function onPause2() pauseAt(2) end
function onPause3() pauseAt(3) end
function onPause4() pauseAt(4) end
function onPause5() pauseAt(5) end
function onPause6() pauseAt(6) end
function onPause7() pauseAt(7) end
function onPause8() pauseAt(8) end
function onPause9() pauseAt(9) end
function onPause10() pauseAt(10) end
function onPause11() pauseAt(11) end
function onPause12() pauseAt(12) end
function onPause13() pauseAt(13) end
function onPause14() pauseAt(14) end
function onPause15() pauseAt(15) end

function onResume0() resumeAt(0) end
function onResume1() resumeAt(1) end
function onResume2() resumeAt(2) end
function onResume3() resumeAt(3) end
function onResume4() resumeAt(4) end
function onResume5() resumeAt(5) end
function onResume6() resumeAt(6) end
function onResume7() resumeAt(7) end
function onResume8() resumeAt(8) end
function onResume9() resumeAt(9) end
function onResume10() resumeAt(10) end
function onResume11() resumeAt(11) end
function onResume12() resumeAt(12) end
function onResume13() resumeAt(13) end
function onResume14() resumeAt(14) end
function onResume15() resumeAt(15) end

function onRescan0() rescanAt(0) end
function onRescan1() rescanAt(1) end
function onRescan2() rescanAt(2) end
function onRescan3() rescanAt(3) end
function onRescan4() rescanAt(4) end
function onRescan5() rescanAt(5) end
function onRescan6() rescanAt(6) end
function onRescan7() rescanAt(7) end
function onRescan8() rescanAt(8) end
function onRescan9() rescanAt(9) end
function onRescan10() rescanAt(10) end
function onRescan11() rescanAt(11) end
function onRescan12() rescanAt(12) end
function onRescan13() rescanAt(13) end
function onRescan14() rescanAt(14) end
function onRescan15() rescanAt(15) end
