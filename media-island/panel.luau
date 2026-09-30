--!nonstrict
-- Top-center persistent panel used as a self-contained media island.

local player = noctalia.state.get("player")
local panelIsOpen = false
local commandSerial = 0

local function request(action)
  commandSerial += 1
  noctalia.state.set("command", {
    action = action,
    nonce = tostring(noctalia.nowMs()) .. ":" .. tostring(commandSerial),
  })
end

local function formatTime(microseconds)
  local seconds = math.max(0, math.floor((tonumber(microseconds) or 0) / 1000000))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function artworkNode(media)
  local path = tostring(media.artPath or "")
  if path ~= "" and noctalia.fileExists(path) then
    return ui.image({
      key = "art-" .. tostring(media.trackKey or path),
      path = path,
      width = 62,
      height = 62,
      radius = 14,
      fit = "cover",
    })
  end

  return ui.column({
    width = 62,
    height = 62,
    radius = 14,
    fill = "surface_variant",
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = "music", size = 26, color = "on_surface_variant" }),
  })
end

local function closeButton()
  return ui.button({
    glyph = "x",
    variant = "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr("panel.close"),
    onClick = function()
      request("close-panel")
    end,
  })
end

local function renderEmpty()
  panel.render(ui.row({
    padding = 14,
    gap = 12,
    align = "center",
  }, {
    ui.column({
      width = 54,
      height = 54,
      radius = 14,
      fill = "surface_variant",
      align = "center",
      justify = "center",
    }, {
      ui.glyph({ name = "music-off", size = 24, color = "on_surface_variant" }),
    }),
    ui.column({ flexGrow = 1, gap = 3 }, {
      ui.label({
        text = noctalia.tr("panel.no-media"),
        fontSize = 16,
        fontWeight = "bold",
        color = "on_surface",
      }),
      ui.label({
        text = noctalia.tr("panel.no-media-detail"),
        fontSize = 12,
        color = "on_surface_variant",
      }),
    }),
    closeButton(),
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
    padding = 12,
    gap = 8,
    align = "stretch",
  }, {
    ui.row({ gap = 12, align = "center" }, {
      artworkNode(player),
      ui.column({ flexGrow = 1, gap = 4, align = "stretch" }, {
        ui.label({
          text = title,
          fontSize = 17,
          fontWeight = "bold",
          color = "on_surface",
          maxLines = 1,
          maxWidth = 280,
        }),
        ui.label({
          text = subtitle,
          fontSize = 12,
          color = "on_surface_variant",
          maxLines = 1,
          maxWidth = 280,
        }),
      }),
      ui.row({ gap = 4, align = "center" }, {
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
          controlSize = "md",
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
      closeButton(),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = formatTime(positionUs),
        width = 36,
        fontSize = 10,
        color = "on_surface_variant",
      }),
      ui.progress({
        progress = progress,
        height = 3,
        radius = 2,
        flexGrow = 1,
        fill = "primary",
        track = "surface_variant",
      }),
      ui.label({
        text = formatTime(lengthUs),
        width = 36,
        fontSize = 10,
        color = "on_surface_variant",
        textAlign = "end",
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
