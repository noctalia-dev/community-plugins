--!nonstrict
-- Thunderbird Companion — recent unread-message panel.

local snapshot = {
  status = "starting",
  unreadCount = 0,
  messages = {},
  accounts = {},
  receivedAt = 0,
  thunderbirdAvailable = false,
  setupStatus = "idle",
  setupError = "",
  xpiPath = "",
}
local command_seq = 0
local render

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function send_command(op, id)
  command_seq += 1
  local command = {
    op = op,
    seq = tostring(os.time()) .. "-panel-" .. tostring(command_seq),
  }
  if id ~= nil then
    command.id = id
  end
  noctalia.state.set("thunderbird.command", command)
end

local function status_details()
  local status = snapshot.status
  if status == "online" then
    return noctalia.tr("panel.status_online"), "primary"
  end
  if status == "stale" then
    return noctalia.tr("panel.status_stale"), "warning"
  end
  if status == "setup_required" then
    return noctalia.tr("panel.status_setup_required"), "warning"
  end
  if status == "bridge_incompatible" then
    return noctalia.tr("panel.status_bridge_incompatible"), "warning"
  end
  if status == "thunderbird_missing" then
    return noctalia.tr("panel.status_thunderbird_missing"), "error"
  end
  return noctalia.tr("panel.status_offline"), "error"
end

local function status_chip()
  local text, color = status_details()
  return ui.row({
    gap = 6,
    align = "center",
    fill = "surface_variant/0.5",
    radius = 999,
    paddingH = 9,
    paddingV = 4,
  }, {
    ui.box({ width = 7, height = 7, radius = 4, fill = color }),
    ui.label({ text = text, fontSize = 11, color = "on_surface_variant" }),
  })
end

local function formatted_time(milliseconds)
  local value = tonumber(milliseconds) or 0
  if value <= 0 then
    return ""
  end
  return noctalia.formatTime("%b %d, %H:%M", math.floor(value / 1000))
end

local function message_location(message)
  local parts = {}
  local account = trim(message.accountName)
  local folder = trim(message.folderName)
  local when = formatted_time(message.date)
  if account ~= "" then
    table.insert(parts, account)
  end
  if folder ~= "" then
    table.insert(parts, folder)
  end
  if when ~= "" then
    table.insert(parts, when)
  end
  return #parts > 0 and table.concat(parts, " · ") or noctalia.tr("panel.unknown_folder")
end

local function message_row(message)
  local id = tonumber(message.id)
  local subject = trim(message.subject)
  local author = trim(message.author)

  return ui.row({
    key = "message-" .. tostring(id),
    gap = 8,
    padding = 10,
    radius = 9,
    fill = "surface_variant/0.35",
    border = "outline",
    borderWidth = 1,
    align = "center",
  }, {
    ui.column({
      gap = 3,
      flexGrow = 1,
      onClick = function()
        if id ~= nil then
          send_command("open_message", id)
        end
      end,
    }, {
      ui.row({ gap = 5, align = "center" }, {
        message.flagged == true
          and ui.glyph({ name = "star-filled", size = 12, color = "warning" })
          or ui.box({ width = 0, height = 0 }),
        ui.label({
          text = subject ~= "" and subject or noctalia.tr("panel.no_subject"),
          fontWeight = "bold",
          maxLines = 1,
          flexGrow = 1,
        }),
      }),
      ui.label({
        text = author ~= "" and author or noctalia.tr("panel.unknown_sender"),
        fontSize = 12,
        color = "on_surface_variant",
        maxLines = 1,
      }),
      ui.label({
        text = message_location(message),
        fontSize = 10,
        color = "outline",
        maxLines = 1,
      }),
    }),
    ui.column({ gap = 3 }, {
      ui.row({ gap = 3 }, {
        ui.button({
          glyph = "external-link",
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.open_message"),
          enabled = id ~= nil,
          onClick = function()
            if id ~= nil then
              send_command("open_message", id)
            end
          end,
        }),
        ui.button({
          glyph = "arrow-back-up",
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.reply"),
          enabled = id ~= nil,
          onClick = function()
            if id ~= nil then
              send_command("reply", id)
            end
          end,
        }),
      }),
      ui.row({ gap = 3 }, {
        ui.button({
          glyph = "check",
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.mark_read"),
          enabled = id ~= nil,
          onClick = function()
            if id ~= nil then
              send_command("mark_read", id)
            end
          end,
        }),
        ui.button({
          glyph = "archive",
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.archive"),
          enabled = id ~= nil,
          onClick = function()
            if id ~= nil then
              send_command("archive", id)
            end
          end,
        }),
      }),
    }),
  })
end

local function connection_callout()
  local status = snapshot.status
  if status == "online" then
    return nil
  end

  local never_connected = (tonumber(snapshot.receivedAt) or 0) <= 0
  local setup_status = tostring(snapshot.setupStatus or "idle")
  local bridge_incompatible = status == "bridge_incompatible"
  local setup_possible = status ~= "thunderbird_missing"
    and (
      status == "setup_required"
      or bridge_incompatible
      or never_connected
      or setup_status ~= "idle"
    )
  local running = setup_possible and setup_status == "running"
  local ready = setup_possible and setup_status == "ready" and trim(snapshot.xpiPath) ~= ""
  local failed = setup_possible and setup_status == "error"
  local title
  local body

  if running then
    title = noctalia.tr("panel.setup_running")
    body = noctalia.tr("panel.setup_running_body")
  elseif ready then
    title = noctalia.tr("panel.setup_ready_title")
    body = noctalia.tr("panel.setup_ready_body")
  elseif failed then
    title = noctalia.tr("panel.setup_error_title")
    body = trim(snapshot.setupError) ~= "" and snapshot.setupError or noctalia.tr("panel.setup_body")
  elseif bridge_incompatible then
    title = noctalia.tr("panel.bridge_incompatible_title")
    body = noctalia.tr("panel.bridge_incompatible_body")
  elseif setup_possible then
    title = noctalia.tr("panel.setup_title")
    body = noctalia.tr("panel.setup_body")
  else
    title = select(1, status_details())
    body = noctalia.tr("panel.offline_body")
  end

  local buttons = {}

  if running then
    table.insert(buttons, ui.button({
      text = noctalia.tr("panel.setup_running"),
      glyph = "loader",
      enabled = false,
      variant = "outline",
    }))
  elseif ready then
    table.insert(buttons, ui.button({
      glyph = "external-link",
      tooltip = noctalia.tr("panel.open_addons"),
      variant = "primary",
      onClick = function()
        send_command("open_addons")
      end,
    }))
    table.insert(buttons, ui.button({
      glyph = "folder-open",
      tooltip = noctalia.tr("panel.open_package_folder"),
      variant = "outline",
      onClick = function()
        send_command("open_xpi_directory")
      end,
    }))
    table.insert(buttons, ui.button({
      glyph = "copy",
      tooltip = noctalia.tr("panel.copy_package_path"),
      variant = "ghost",
      onClick = function()
        send_command("copy_xpi_path")
      end,
    }))
  elseif setup_possible then
    table.insert(buttons, ui.button({
      text = failed
        and noctalia.tr("panel.retry_setup")
        or (
          bridge_incompatible
            and noctalia.tr("panel.update_bridge")
            or noctalia.tr("panel.setup_bridge")
        ),
      glyph = failed and "refresh" or "package-import",
      variant = "primary",
      onClick = function()
        send_command("setup")
      end,
    }))
  end
  if not ready and not running and snapshot.thunderbirdAvailable ~= false then
    table.insert(buttons, ui.button({
      text = noctalia.tr("panel.open_thunderbird"),
      glyph = "external-link",
      variant = setup_possible and "outline" or "primary",
      onClick = function()
        send_command("launch")
      end,
    }))
  end

  return ui.column({
    gap = 8,
    padding = 12,
    radius = 10,
    fill = "surface_variant/0.35",
    border = "outline",
    borderWidth = 1,
  }, {
    ui.label({ text = title, fontWeight = "bold" }),
    ui.label({ text = body, color = "on_surface_variant", fontSize = 12, wrap = true }),
    ui.row({ gap = 8 }, buttons),
  })
end

local function empty_state()
  return ui.column({
    gap = 8,
    align = "center",
    justify = "center",
    padding = 32,
    flexGrow = 1,
  }, {
    ui.glyph({ name = "mail-check", size = 34, color = "primary" }),
    ui.label({ text = noctalia.tr("panel.empty"), fontWeight = "bold" }),
    ui.label({
      text = noctalia.tr("panel.empty_body"),
      color = "on_surface_variant",
      fontSize = 12,
      wrap = true,
    }),
  })
end

render = function()
  local unread = math.max(0, math.floor(tonumber(snapshot.unreadCount) or 0))
  local messages = type(snapshot.messages) == "table" and snapshot.messages or {}
  local body = {}
  local callout = connection_callout()
  if callout ~= nil then
    table.insert(body, callout)
  end

  if #messages == 0 and (snapshot.status == "online" or (tonumber(snapshot.receivedAt) or 0) > 0) then
    table.insert(body, empty_state())
  elseif #messages == 0 then
    table.insert(body, ui.box({ flexGrow = 1 }))
  else
    local rows = {}
    for _, message in ipairs(messages) do
      table.insert(rows, message_row(message))
    end
    table.insert(body, ui.scroll({ gap = 7, flexGrow = 1 }, rows))
  end

  local sync_text = formatted_time(snapshot.receivedAt)
  panel.render(ui.column({ gap = 10, padding = 12, flexGrow = 1 }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "mail", size = 18, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        text = noctalia.tr("panel.compose"),
        glyph = "pencil",
        variant = "primary",
        onClick = function()
          send_command("compose")
        end,
      }),
      ui.button({
        glyph = "checks",
        variant = "ghost",
        tooltip = noctalia.tr("panel.mark_all_read"),
        enabled = snapshot.status == "online" and unread > 0,
        onClick = function()
          send_command("mark_all_read")
        end,
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        tooltip = noctalia.tr("panel.refresh"),
        onClick = function()
          send_command("refresh")
        end,
      }),
      ui.button({
        glyph = "close",
        variant = "ghost",
        tooltip = noctalia.tr("panel.close"),
        onClick = function()
          panel.close()
        end,
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      status_chip(),
      ui.label({
        text = noctalia.trp("panel.unread", unread),
        fontSize = 12,
        color = "on_surface_variant",
        flexGrow = 1,
      }),
      ui.label({
        text = sync_text ~= "" and noctalia.tr("panel.last_sync", { time = sync_text }) or "",
        fontSize = 10,
        color = "outline",
      }),
    }),
    ui.separator({}),
    ui.column({ gap = 10, flexGrow = 1 }, body),
  }))
end

noctalia.state.watch("thunderbird.snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function onOpen(_context)
  local current = noctalia.state.get("thunderbird.snapshot")
  if type(current) == "table" then
    snapshot = current
  end
  render()
  if snapshot.status == "online" then
    send_command("refresh")
  end
end

local current = noctalia.state.get("thunderbird.snapshot")
if type(current) == "table" then
  snapshot = current
end
render()
