--!nonstrict
-- Control panel: live lyrics, a manual refresh, copy and a shortcut to the
-- plugin's settings. Settings themselves are edited in Noctalia Settings.

local STATUS_KEYS = {
  idle = "panel.state.idle",
  off = "panel.state.off",
  filtered = "panel.state.filtered",
  loading = "panel.state.loading",
  notfound = "panel.state.notfound",
  instrumental = "panel.state.instrumental",
  error = "panel.state.error",
  plain = "panel.state.plain",
  synced = "panel.state.synced",
}

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function statusText()
  local status = noctalia.state.get("status") or "idle"
  local key = STATUS_KEYS[status] or "panel.state.idle"
  return noctalia.tr(key)
end

local function copyLine()
  local current = noctalia.state.get("current") or ""
  if current ~= "" then
    noctalia.copyToClipboard(current, "text/plain")
    noctalia.notify(noctalia.tr("panel.copied"), current)
  end
end

local function refresh()
  noctalia.state.set("refresh_request", os.time())
  noctalia.notify(noctalia.tr("panel.refreshing"), nil)
end

local function render()
  local title = noctalia.state.get("title") or ""
  local artist = noctalia.state.get("artist") or ""
  local current = noctalia.state.get("current") or ""
  local nextLine = noctalia.state.get("next") or ""
  local previous = noctalia.state.get("previous") or ""
  local index = noctalia.state.get("line_index") or 0
  local count = noctalia.state.get("count") or 0
  local source = noctalia.state.get("source") or ""
  local offset = cfg("sync_offset", 0)
  local mode = cfg("display_mode", "karaoke")

  local header = title
  if artist ~= "" then
    header = (title ~= "" and (title .. " — " .. artist)) or artist
  end
  if header == "" then
    header = noctalia.tr("panel.no_track")
  end

  local lines = {}

  table.insert(lines, ui.row({ gap = 10, align = "center" }, {
    ui.glyph({ name = "music", size = 18, color = "primary" }),
    ui.label({
      text = header,
      fontSize = 15,
      fontWeight = "semibold",
      color = "on_surface",
      maxLines = 1,
      flexGrow = 1,
    }),
  }))

  table.insert(lines, ui.row({ gap = 8, align = "center" }, {
    ui.label({
      text = statusText(),
      fontSize = 12,
      color = "on_surface/0.6",
      maxLines = 1,
      flexGrow = 1,
    }),
    ui.label({
      text = count > 0 and (tostring(index) .. " / " .. tostring(count)) or "",
      fontSize = 12,
      color = "on_surface/0.45",
      maxLines = 1,
    }),
  }))

  table.insert(lines, ui.separator({ color = "on_surface/0.1" }))

  table.insert(lines, ui.column({ gap = 8 }, {
    ui.label({
      text = previous,
      fontSize = 13,
      color = previous ~= "" and "on_surface/0.35" or "on_surface/0.15",
      maxLines = 2,
      visible = previous ~= "",
    }),
    ui.label({
      text = current ~= "" and current or noctalia.tr("panel.no_lyrics"),
      fontSize = 22,
      fontWeight = "bold",
      color = current ~= "" and "on_surface" or "on_surface/0.4",
      maxLines = 3,
    }),
    ui.label({
      text = nextLine,
      fontSize = 13,
      color = "on_surface/0.4",
      maxLines = 2,
      visible = nextLine ~= "",
    }),
  }))

  table.insert(lines, ui.separator({ color = "on_surface/0.1" }))

  table.insert(lines, ui.row({ gap = 8, align = "center" }, {
    ui.label({
      text = noctalia.tr("panel.mode") .. ": " .. nocturnalModeLabel(mode),
      fontSize = 12,
      color = "on_surface/0.6",
      flexGrow = 1,
      maxLines = 1,
    }),
    ui.label({
      text = noctalia.tr("panel.offset") .. ": " .. tostring(offset) .. " ms",
      fontSize = 12,
      color = "on_surface/0.6",
      maxLines = 1,
    }),
  }))

  if source ~= "" then
    table.insert(lines, ui.label({
      text = noctalia.tr("panel.source") .. ": " .. source,
      fontSize = 11,
      color = "on_surface/0.4",
      maxLines = 1,
    }))
  end

  table.insert(lines, ui.spacer({ flexGrow = 1 }))

  table.insert(lines, ui.row({ gap = 8, align = "center" }, {
    ui.button({
      text = noctalia.tr("panel.refresh"),
      variant = "secondary",
      controlSize = "sm",
      onClick = "doRefresh",
    }),
    ui.button({
      text = noctalia.tr("panel.copy"),
      variant = "ghost",
      controlSize = "sm",
      enabled = current ~= "",
      onClick = "doCopy",
    }),
    ui.button({
      text = noctalia.tr("panel.settings"),
      glyph = "settings",
      variant = "primary",
      controlSize = "sm",
      onClick = "openSettings",
    }),
  }))

  panel.render(ui.column({ gap = 14, padding = 18 }, lines))
end

function nocturnalModeLabel(mode)
  if mode == "line" then
    return noctalia.tr("settings.display_mode.line")
  end
  if mode == "focus" then
    return noctalia.tr("settings.display_mode.focus")
  end
  return noctalia.tr("settings.display_mode.karaoke")
end

function onOpen()
  panel.setWantsSecondTicks(true)
  render()
end

function update()
  render()
end

function doRefresh()
  refresh()
  render()
end

function doCopy()
  copyLine()
  render()
end

function openSettings()
  noctalia.openSettings()
end

function onClose()
  panel.setWantsSecondTicks(false)
end
