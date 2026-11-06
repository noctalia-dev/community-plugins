--!nonstrict
-- Compact popup (290x76) that hangs right under the bar capsule.

local player = noctalia.state.get("player")
local panelIsOpen = false
local commandSerial = 0

local ART = 34

local function request(action)
  commandSerial += 1
  noctalia.state.set("command", {
    action = action,
    nonce = tostring(noctalia.nowMs()) .. ":" .. tostring(commandSerial),
  })
end

local function readConfig(key)
  if panel and panel.getConfig then
    return panel.getConfig(key)
  end
  return noctalia.getConfig(key)
end

local function formatTime(microseconds)
  local seconds = math.max(0, math.floor((tonumber(microseconds) or 0) / 1000000))
  if readConfig("show_hours") == true and seconds >= 3600 then
    return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
  end
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function artworkNode(media)
  local path = tostring(media.artPath or "")
  if path ~= "" and noctalia.fileExists(path) then
    return ui.image({
      key = "art-" .. tostring(media.trackKey or path),
      path = path,
      width = ART,
      height = ART,
      radius = 10,
      fit = "cover",
    })
  end

  return ui.column({
    width = ART,
    height = ART,
    radius = 10,
    fill = "surface_variant",
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = "music", size = 18, color = "on_surface_variant" }),
  })
end

local function renderEmpty()
  panel.render(ui.row({
    padding = 6,
    gap = 6,
    align = "center",
  }, {
    ui.column({
      width = ART,
      height = ART,
      radius = 10,
      fill = "surface_variant",
      align = "center",
      justify = "center",
    }, {
      ui.glyph({ name = "music-off", size = 18, color = "on_surface_variant" }),
    }),
    ui.column({ gap = 2 }, {
      ui.label({
        text = noctalia.tr("panel.no-media"),
        fontSize = 13,
        fontWeight = "bold",
        color = "on_surface",
      }),
      ui.label({
        text = noctalia.tr("panel.no-media-detail"),
        fontSize = 10,
        color = "on_surface_variant",
        maxLines = 1,
        maxWidth = 240,
      }),
    }),
  }))
end

local function render()
  if type(player) ~= "table" then
    renderEmpty()
    return
  end

  local title = tostring(player.title or "")
  if title == "" then
    title = noctalia.tr("widget.unknown-title")
  end
  local artist = tostring(player.artist or "")
  local album = tostring(player.album or "")
  local subtitle = artist
  if artist ~= "" and album ~= "" then
    subtitle = artist .. " · " .. album
  elseif album ~= "" then
    subtitle = album
  end

  local lengthUs = tonumber(player.lengthUs) or 0
  local positionUs = tonumber(player.positionUs) or 0

  local progress = lengthUs > 0 and math.max(0, math.min(1, positionUs / lengthUs)) or 0

  panel.render(ui.column({
    padding = 6,
    gap = 3,
    align = "stretch",
  }, {
    ui.row({ gap = 6, align = "center" }, {
      artworkNode(player),
      ui.column({ width = 120, gap = 2, align = "stretch" }, {
        ui.label({
          text = title,
          fontSize = 13,
          fontWeight = "bold",
          color = "on_surface",
          maxLines = 1,
          maxWidth = 120,
        }),
        ui.label({
          text = subtitle,
          fontSize = 10,
          color = "on_surface_variant",
          maxLines = 1,
          maxWidth = 120,
        }),
      }),
      ui.row({ gap = 0, align = "center" }, {
        ui.button({
          glyph = "player-skip-back-filled",
          variant = "ghost",
          controlSize = "sm",
          enabled = player.canGoPrevious ~= false,
          tooltip = noctalia.tr("panel.previous"),
          onClick = function() request("previous") end,
        }),
        ui.button({
          glyph = player.playing and "player-pause-filled" or "player-play-filled",
          variant = "primary",
          controlSize = "sm",
          tooltip = player.playing and noctalia.tr("panel.pause") or noctalia.tr("panel.play"),
          onClick = function() request("toggle") end,
        }),
        ui.button({
          glyph = "player-skip-forward-filled",
          variant = "ghost",
          controlSize = "sm",
          enabled = player.canGoNext ~= false,
          tooltip = noctalia.tr("panel.next"),
          onClick = function() request("next") end,
        }),
      }),
    }),
    ui.row({ gap = 6, align = "center", justify = "center" }, {
      ui.label({
        text = formatTime(positionUs),
        width = 44,
        fontSize = 9,
        color = "on_surface_variant",
        textAlign = "end",
      }),
      ui.progress({
        progress = progress,
        width = 90,
        height = 3,
        radius = 2,
        fill = "primary",
        track = "surface_variant",
      }),
      ui.label({
        text = formatTime(lengthUs),
        width = 44,
        fontSize = 9,
        color = "on_surface_variant",
      }),
    }),
  }))
end

noctalia.state.watch("player", function(value)
  player = value
  if panelIsOpen then
    render()
  end
end)

function onOpen()
  panelIsOpen = true
  player = noctalia.state.get("player")
  noctalia.state.set("panel-open", true)
  render()
end

function onClose()
  panelIsOpen = false
  noctalia.state.set("panel-open", false)
end

function onExit()
  noctalia.state.set("panel-open", false)
end

render()
