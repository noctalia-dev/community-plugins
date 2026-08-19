--!nonstrict

local snapshot = noctalia.state.get("voice_snapshot") or {
  status = "starting",
  status_message = "",
  authenticated = false,
  user = {},
  channel = nil,
  recent_channels = {},
  favorite_channels = {},
  participants = {},
  voice = { mute = false, deaf = false, input_volume = 100 },
  connection = { state = "DISCONNECTED", average_ping = 0, last_ping = 0, hostname = "" },
  connected_since = nil,
}
local isOpen = false
local actionPending = false
local actionError = ""

local render
local ACTION_BUTTON_WIDTH = 112
local CENTERED_LAYOUT = { flexGrow = 1, align = "center", justify = "center", gap = 10, padding = 20 }
local micVolumeDraft = snapshot.voice.input_volume
local micVolumeEditing = false
local participantVolumeDraft = {}
local participantVolumeEditing = {}

local tr = noctalia.tr

local function quoteShellArgument(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function discordBinary()
  local configured = noctalia.getConfig("discord_binary")
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  return "/usr/bin/discord"
end

local function openDiscord()
  local binary = quoteShellArgument(discordBinary())
  local channel = snapshot.channel
  if channel == nil then
    noctalia.runAsync(binary)
    return
  end
  local guildId = channel.guild_id
  local channelId = channel.id
  if guildId ~= "" and channelId ~= "" then
    local uri = `discord://-/channels/{guildId}/{channelId}`
    noctalia.runAsync(binary .. " --url -- " .. quoteShellArgument(uri))
  else
    noctalia.runAsync(binary)
  end
end

local function durationText()
  local since = snapshot.connected_since
  if since == nil then
    return "—"
  end
  local total = math.max(0, (tonumber(noctalia.formatTime("%s")) or 0) - since)
  local hours = math.floor(total / 3600)
  local minutes = math.floor((total % 3600) / 60)
  local seconds = math.floor(total % 60)
  if hours > 0 then
    return string.format("%d:%02d:%02d", hours, minutes, seconds)
  end
  return string.format("%d:%02d", minutes, seconds)
end

local function appendCommandArgument(command, value)
  if value == nil then
    return command
  end
  if type(value) == "boolean" then
    return command .. (value and " true" or " false")
  end
  return command .. " " .. quoteShellArgument(tostring(value))
end

local function runBridgeCommand(name, value, secondValue)
  if actionPending then
    return
  end
  actionPending = true
  actionError = ""
  render()

  local script = noctalia.pluginDir() .. "/discord_bridge.py"
  local command = "python3 " .. quoteShellArgument(script) .. " command " .. name
  command = appendCommandArgument(command, value)
  command = appendCommandArgument(command, secondValue)
  local started = noctalia.runAsync(command, function(result)
    actionPending = false
    local decoded = noctalia.json.decode(result.stdout or "")
    if result.exitCode ~= 0 then
      if type(decoded) == "table" and type(decoded.error) == "string" then
        actionError = decoded.error
      else
        local message = noctalia.string.trim(result.stderr or ""):match("^[^\r\n]+") or ""
        actionError = message ~= "" and message or tr("error.command")
      end
    end
    render()
  end)
  if not started then
    actionPending = false
    actionError = tr("error.command")
    render()
  end
end

local function roundedVolume(value, maximum)
  return math.max(0, math.min(maximum, math.floor(value + 0.5)))
end

local function syncVolumeDrafts()
  if not micVolumeEditing then
    micVolumeDraft = roundedVolume(snapshot.voice.input_volume, 100)
  end
  local present = {}
  for _, participant in ipairs(snapshot.participants) do
    local userId = participant.id
    present[userId] = true
    if not participantVolumeEditing[userId] then
      participantVolumeDraft[userId] = roundedVolume(participant.volume, 200)
    end
  end
  for userId, _ in pairs(participantVolumeDraft) do
    if not present[userId] then
      participantVolumeDraft[userId] = nil
      participantVolumeEditing[userId] = nil
    end
  end
end

local function changeMicVolume(value)
  micVolumeEditing = true
  micVolumeDraft = roundedVolume(value, 100)
  render()
end

local function commitMicVolume()
  micVolumeEditing = false
  runBridgeCommand("set-mic-volume", micVolumeDraft)
end

local function changeParticipantVolume(userId, value)
  participantVolumeEditing[userId] = true
  participantVolumeDraft[userId] = roundedVolume(value, 200)
  render()
end

local function commitParticipantVolume(userId)
  local volume = participantVolumeDraft[userId]
  participantVolumeEditing[userId] = false
  runBridgeCommand("set-user-volume", userId, volume)
end

local function connectionAppearance()
  local connection = snapshot.connection
  local state = connection.state
  local ping = connection.average_ping
  if state == "VOICE_CONNECTED" then
    if ping <= 0 then
      return "wifi", "primary", tr("connection.connected")
    elseif ping <= 60 then
      return "wifi", "primary", tr("connection.ping", { ping = math.floor(ping) })
    elseif ping <= 120 then
      return "wifi", "tertiary", tr("connection.ping", { ping = math.floor(ping) })
    end
    return "wifi", "error", tr("connection.ping", { ping = math.floor(ping) })
  elseif state == "NO_ROUTE" then
    return "wifi-off", "error", tr("connection.no_route")
  elseif state == "DISCONNECTED" or state == "VOICE_DISCONNECTED" then
    return "wifi-off", "on_surface_variant", tr("connection.disconnected")
  end
  return "loader-2", "tertiary", tr("connection.connecting")
end

local function participantVisual(participant)
  local speaking = participant.speaking
  if participant.avatar_path ~= "" then
    return ui.image({
      key = "avatar:" .. participant.id,
      path = participant.avatar_path,
      width = 36,
      height = 36,
      radius = 18,
      fit = "cover",
      border = speaking and "primary" or "outline",
      borderWidth = speaking and 2 or 1,
    })
  end
  return ui.glyph({
    key = "avatar-fallback:" .. participant.id,
    name = "user-circle",
    size = 36,
    color = speaking and "primary" or "on_surface_variant",
  })
end

local function participantRow(participant)
  local speaking = participant.speaking
  local displayName = participant.nick
  if participant.id == snapshot.user.id then
    displayName ..= " " .. tr("participant.you")
  end
  local isSelf = participant.id == snapshot.user.id
  local muted = participant.mute or participant.self_mute or participant.local_mute
  local deafened = participant.deaf or participant.self_deaf

  local indicators = {}
  if speaking then
    table.insert(indicators, ui.glyph({ name = "volume", size = 15, color = "primary" }))
  end
  if muted then
    table.insert(indicators, ui.glyph({ name = "microphone-off", size = 15, color = "error" }))
  end
  if deafened then
    table.insert(indicators, ui.glyph({ name = "headphones-off", size = 15, color = "error" }))
  end

  local participantDetails = {
    ui.row({ align = "center", gap = 6 }, {
      ui.label({
        text = displayName,
        color = speaking and "primary" or "on_surface",
        fontWeight = speaking and "bold" or "medium",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.label({
        text = speaking and tr("participant.speaking") or tr("participant.listening"),
        color = "on_surface_variant",
        fontSize = 10,
      }),
      ui.row({ gap = 4, align = "center" }, indicators),
    }),
  }

  local userId = participant.id
  local volume = isSelf
    and roundedVolume(micVolumeDraft, 100)
    or (participantVolumeDraft[userId] or roundedVolume(participant.volume, 200))
  local maximum = isSelf and 100 or 200
  local volumeGlyph = isSelf
    and (volume == 0 and "microphone-off" or "microphone")
    or (volume == 0 and "volume-off" or "volume")
  table.insert(participantDetails, ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = volumeGlyph, size = 13, color = "on_surface_variant" }),
    ui.slider({
      key = "participant-volume:" .. userId,
      min = 0,
      max = maximum,
      step = 1,
      value = volume,
      enabled = not actionPending,
      flexGrow = 1,
      onChange = function(value)
        if isSelf then
          changeMicVolume(value)
        else
          changeParticipantVolume(userId, value)
        end
      end,
      onDragEnd = function()
        if isSelf then
          commitMicVolume()
        else
          commitParticipantVolume(userId)
        end
      end,
    }),
    ui.label({ text = tostring(volume) .. "%", width = 38, fontSize = 10, color = "on_surface_variant", textAlign = "end" }),
  }))

  return ui.row({
    key = "participant:" .. participant.id,
    gap = 10,
    align = "center",
    paddingH = 10,
    paddingV = 6,
    fill = speaking and "primary/0.10" or "surface_variant/0.24",
    border = speaking and "primary/0.55" or "outline/0.32",
    borderWidth = 1,
    radius = 11,
  }, {
    participantVisual(participant),
    ui.column({ gap = 1, flexGrow = 1, align = "stretch" }, participantDetails),
  })
end

local function participantList()
  local rows = {}
  for _, participant in ipairs(snapshot.participants) do
    table.insert(rows, participantRow(participant))
  end
  if #rows == 0 then
    table.insert(rows, ui.column({ paddingV = 20, align = "center" }, {
      ui.label({
        text = tr("participants.empty"),
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }))
  end
  return rows
end

local function recentChannelRow(channel, favorite)
  local serverName = channel.guild_name ~= "" and channel.guild_name or tr("unknown_server")
  local participantCount = channel.participant_count
  local children = {
    ui.button({
      glyph = favorite and "star-filled" or "star",
      variant = "ghost",
      selected = favorite,
      enabled = not actionPending,
      onClick = function()
        runBridgeCommand(favorite and "unfavorite-channel" or "favorite-channel", channel.id)
      end,
    }),
    ui.label({ text = serverName, width = 120, fontWeight = "bold", color = "primary", maxLines = 1 }),
    ui.label({ text = "/", color = "on_surface_variant" }),
    ui.label({ text = channel.name, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
  }
  if participantCount > 0 then
    table.insert(children, ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "users", size = 14, color = "primary" }),
      ui.label({ text = tostring(participantCount), fontSize = 12, fontWeight = "bold", color = "primary" }),
    }))
  end
  table.insert(children, ui.button({
    text = tr("saved.join"),
    glyph = "phone",
    variant = "primary",
    width = ACTION_BUTTON_WIDTH,
    enabled = not actionPending,
    onClick = function()
      runBridgeCommand("join-channel", channel.id)
    end,
  }))
  return ui.row({
    key = "recent:" .. channel.id,
    fill = "surface_variant/0.26",
    border = "outline/0.34",
    borderWidth = 1,
    radius = 10,
    paddingH = 10,
    paddingV = 8,
    gap = 7,
    align = "center",
  }, children)
end

local function recentChannelRows()
  local rows = {}
  local favoriteIds = {}

  for _, channel in ipairs(snapshot.favorite_channels) do
    favoriteIds[channel.id] = true
    table.insert(rows, recentChannelRow(channel, true))
  end

  for _, channel in ipairs(snapshot.recent_channels) do
    if not favoriteIds[channel.id] then
      table.insert(rows, recentChannelRow(channel, false))
    end
  end

  if #rows == 0 then
    table.insert(rows, ui.column({ paddingV = 12, align = "center" }, {
      ui.label({ text = tr("saved.empty"), color = "on_surface_variant", textAlign = "center" }),
    }))
  end
  return rows
end

local function disconnectedBody()
  local status = snapshot.status
  local message = snapshot.status_message
  if status == "auth_required" then
    local children = {
      ui.glyph({ name = "brand-discord", size = 46, color = "primary" }),
      ui.label({ text = tr("auth.title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = message ~= "" and message or tr("auth.description"), color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
      ui.button({
        text = tr("auth.button"),
        glyph = "external-link",
        variant = "primary",
        enabled = not actionPending,
        onClick = function()
          runBridgeCommand("authorize")
        end,
      }),
    }
    return ui.column(CENTERED_LAYOUT, children)
  elseif status == "authorizing" or status == "authenticating" then
    return ui.column(CENTERED_LAYOUT, {
      ui.glyph({ name = "loader-2", size = 42, color = "primary" }),
      ui.label({ text = tr("auth.waiting"), fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = tr("auth.waiting_description"), color = "on_surface_variant", textAlign = "center" }),
    })
  elseif status == "discord_unavailable" then
    return ui.column(CENTERED_LAYOUT, {
      ui.glyph({ name = "brand-discord", size = 46, color = "on_surface_variant" }),
      ui.label({ text = tr("offline.title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = message ~= "" and message or tr("offline.description"), color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
      ui.button({ text = tr("open_discord"), glyph = "brand-discord", variant = "primary", onClick = openDiscord }),
    })
  elseif status == "error" then
    return ui.column(CENTERED_LAYOUT, {
      ui.glyph({ name = "alert-circle", size = 42, color = "error" }),
      ui.label({ text = tr("error.title"), fontWeight = "bold", color = "error" }),
      ui.label({ text = message, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
    })
  end
  return ui.column(CENTERED_LAYOUT, {
    ui.glyph({ name = "loader-2", size = 42, color = "primary" }),
    ui.label({ text = tr("starting"), color = "on_surface_variant" }),
  })
end

local function voiceBody()
  if snapshot.channel == nil then
    return ui.column({ flexGrow = 1, gap = 10, align = "stretch", padding = 4 }, {
      ui.row({
        align = "center",
        justify = "center",
        gap = 8,
        paddingH = 12,
        paddingV = 12,
        fill = "surface_variant/0.24",
        border = "outline/0.34",
        borderWidth = 1,
        radius = 11,
      }, {
        ui.glyph({ name = "headphones", size = 20, color = "on_surface_variant" }),
        ui.label({ text = tr("not_in_voice.title"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
      }),
      ui.row({ align = "center", gap = 8, paddingH = 2 }, {
        ui.glyph({ name = "history", size = 18, color = "primary" }),
        ui.label({ text = tr("saved.channels"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
        ui.button({ glyph = "external-link", variant = "ghost", onClick = openDiscord }),
      }),
      ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, recentChannelRows()),
    })
  end

  local channel = snapshot.channel
  local voice = snapshot.voice
  local connectionGlyph, connectionColor, connectionLabel = connectionAppearance()
  local serverName = channel.guild_name ~= "" and channel.guild_name or tr("unknown_server")
  local participants = snapshot.participants
  local favorite = false
  for _, savedChannel in ipairs(snapshot.favorite_channels) do
    if savedChannel.id == channel.id then
      favorite = true
      break
    end
  end

  return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.column({
      fill = "surface_variant/0.24",
      border = "outline/0.38",
      borderWidth = 1,
      radius = 13,
      padding = 13,
      gap = 8,
    }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "server", size = 17, color = "on_surface_variant" }),
        ui.label({ text = serverName, fontWeight = "bold", color = "on_surface", flexGrow = 1, maxLines = 1 }),
        ui.button({
          glyph = favorite and "star-filled" or "star",
          variant = favorite and "secondary" or "ghost",
          enabled = not actionPending,
          onClick = function()
            runBridgeCommand(favorite and "unfavorite-channel" or "favorite-channel", channel.id)
          end,
        }),
        ui.button({ glyph = "external-link", variant = "ghost", onClick = openDiscord }),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "volume", size = 18, color = "primary" }),
        ui.label({ text = channel.name, fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1, maxLines = 1 }),
      }),
      ui.row({ gap = 14, align = "center" }, {
        ui.row({ gap = 5, align = "center" }, {
          ui.glyph({ name = "clock", size = 14, color = "on_surface_variant" }),
          ui.label({ text = durationText(), fontSize = 12, color = "on_surface_variant" }),
        }),
        ui.row({
          gap = 5,
          align = "center",
          fill = connectionColor .. "/0.13",
          border = connectionColor .. "/0.30",
          borderWidth = 1,
          radius = 8,
          paddingH = 8,
          paddingV = 3,
        }, {
          ui.glyph({ name = connectionGlyph, size = 14, color = connectionColor }),
          ui.label({ text = connectionLabel, fontSize = 12, color = connectionColor }),
        }),
        ui.row({ gap = 5, align = "center" }, {
          ui.glyph({ name = "users", size = 14, color = "on_surface_variant" }),
          ui.label({ text = tostring(#participants), fontSize = 12, color = "on_surface_variant" }),
        }),
      }),
    }),
    ui.row({
      gap = 9,
      align = "center",
      padding = 8,
      fill = "surface_variant/0.18",
      border = "outline/0.30",
      borderWidth = 1,
      radius = 12,
    }, {
      ui.button({
        text = voice.mute and tr("controls.unmute") or tr("controls.mute"),
        glyph = voice.mute and "microphone-off" or "microphone",
        variant = voice.mute and "secondary" or "outline",
        selected = voice.mute,
        enabled = not actionPending,
        flexGrow = 1,
        onClick = function()
          runBridgeCommand("set-mute", not voice.mute)
        end,
      }),
      ui.button({
        text = voice.deaf and tr("controls.undeafen") or tr("controls.deafen"),
        glyph = voice.deaf and "headphones-off" or "headphones",
        variant = voice.deaf and "secondary" or "outline",
        selected = voice.deaf,
        enabled = not actionPending,
        flexGrow = 1,
        onClick = function()
          runBridgeCommand("set-deaf", not voice.deaf)
        end,
      }),
      ui.button({
        text = tr("controls.hang_up"),
        glyph = "phone-off",
        variant = "destructive",
        enabled = not actionPending,
        flexGrow = 1,
        onClick = function()
          runBridgeCommand("hang-up")
        end,
      }),
    }),
    ui.label({ text = tr("participants.title", { count = #participants }), fontSize = 13, fontWeight = "bold", color = "on_surface_variant" }),
    ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, participantList()),
  })
end

render = function()
  if not isOpen then
    return
  end
  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
        ui.glyph({ name = "brand-discord", size = 20, color = "primary" }),
        ui.label({ text = tr("title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
      }),
      ui.button({ glyph = "close", variant = "ghost", onClick = panel.close }),
    }),
  }
  if actionError ~= "" then
    table.insert(children, ui.label({ text = actionError, fontSize = 11, color = "error", maxLines = 3 }))
  end
  local body = snapshot.authenticated and voiceBody() or disconnectedBody()
  table.insert(children, body)
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

noctalia.state.watch("voice_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    syncVolumeDrafts()
    actionError = snapshot.authenticated and snapshot.status_message or ""
    render()
  end
end)

function onOpen(_context)
  snapshot = noctalia.state.get("voice_snapshot") or snapshot
  micVolumeEditing = false
  participantVolumeEditing = {}
  syncVolumeDrafts()
  isOpen = true
  panel.setWantsSecondTicks(true)
  render()
  runBridgeCommand("refresh")
end

function onClose()
  isOpen = false
  micVolumeEditing = false
  participantVolumeEditing = {}
  panel.setWantsSecondTicks(false)
end

function update()
  render()
end
