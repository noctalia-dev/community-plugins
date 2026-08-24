--!nonstrict

local PANEL_ID = "raycursive/discord-voice:panel"
local snapshot = noctalia.state.get("voice_snapshot") or {
  status = "starting",
  status_message = "",
  channel = nil,
  recent_channels = {},
  favorite_channels = {},
  participants = {},
  voice = { mute = false, deaf = false, input_volume = 100 },
  connection = { state = "DISCONNECTED", average_ping = 0 },
  connected_since = nil,
}

local tr = noctalia.tr

local function shortened(text, limit)
  local length = utf8.len(text)
  if length <= limit then
    return text
  end
  local cut = utf8.offset(text, limit + 1)
  return text:sub(1, cut - 1) .. "…"
end

local function activeSpeaker()
  for _, participant in ipairs(snapshot.participants) do
    if participant.speaking then
      return participant
    end
  end
  return nil
end

local function statusLabel()
  if snapshot.status == "auth_required" then
    return tr("bar.authorize")
  elseif snapshot.status == "authorizing" or snapshot.status == "authenticating" then
    return tr("bar.authorizing")
  elseif snapshot.status == "discord_unavailable" then
    return tr("bar.offline")
  elseif snapshot.status == "error" then
    return "!"
  end
  return ""
end

local function render()
  local disconnected = snapshot.channel == nil
  if disconnected and noctalia.getConfig("hide_when_disconnected") == true then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local glyph = noctalia.getConfig("glyph")
  if type(glyph) ~= "string" or glyph == "" then
    glyph = "brand-discord"
  end

  local children = {}
  local voice = snapshot.voice
  local speaker = activeSpeaker()
  local glyphColor = "on_surface_variant"
  if speaker ~= nil then
    glyphColor = "primary"
  elseif not disconnected then
    glyphColor = (voice.mute or voice.deaf) and "error" or "primary"
  elseif snapshot.status == "error" then
    glyphColor = "error"
  end
  if speaker and speaker.avatar_path ~= "" then
    table.insert(children, ui.image({
      key = "speaker:" .. speaker.id,
      path = speaker.avatar_path,
      width = 20,
      height = 20,
      radius = 10,
      fit = "cover",
      border = "primary",
      borderWidth = 2,
    }))
  elseif speaker then
    table.insert(children, ui.glyph({ name = "volume", size = 16, color = glyphColor }))
  else
    table.insert(children, ui.glyph({ name = glyph, size = 15, color = glyphColor }))
  end

  if disconnected then
    local label = statusLabel()
    if label ~= "" then
      table.insert(children, ui.label({ text = label, color = "on_surface_variant", fontSize = 12 }))
    end
  else
    if noctalia.getConfig("show_channel_name") ~= false then
      table.insert(children, ui.label({
        text = shortened(snapshot.channel.name, 18),
        color = "on_surface",
        fontWeight = "bold",
      }))
    end
    table.insert(children, ui.label({
      text = tostring(#snapshot.participants),
      color = "on_surface_variant",
      fontSize = 12,
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center", paddingH = 4, paddingV = 2 }, children))
  barWidget.setTooltip({})
end

noctalia.state.watch("voice_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.setUpdateInterval(1000)
render()

function update()
  render()
end

function onClick()
  if snapshot.status == "discord_unavailable" then
    local binary = noctalia.getConfig("discord_binary")
    if type(binary) ~= "string" or binary == "" then
      binary = "/usr/bin/discord"
    end
    noctalia.runAsync("'" .. binary:gsub("'", "'\\''") .. "'")
    return
  end
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end
