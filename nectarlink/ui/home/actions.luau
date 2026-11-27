--!nonstrict
-- Action tiles and the remote typing form share the same explicit command path.
local palette = require("../palette.luau")

local M = { primaryHeight = 100, secondaryHeight = 62, typingHeight = 86 }
local gap, padding = 8, 10

local function tile(spec, width, compact, model, components, actions)
  local accent = spec.active or (spec.enabled and (spec.primary or model.hovered == spec.key))
  local props = {
    key = spec.key,
    width = width,
    height = compact and M.secondaryHeight or M.primaryHeight,
    padding = padding,
    gap = compact and 10 or 4,
    align = compact and "center" or "start",
    justify = compact and "start" or "center",
    radius = 12,
    fill = accent and "primary/0.16" or palette("card"),
    border = spec.active and "primary/0.65" or palette("muted_border", 0.32),
    borderWidth = 1,
    opacity = spec.enabled and 1 or 0.55,
    tooltip = spec.tooltip or spec.title,
    onHover = spec.enabled and "onTileHover" or nil,
    onClick = spec.enabled and (spec.onClick or function()
      actions.send(spec.command, spec.device, spec.value)
    end) or nil,
  }
  local icon = ui.glyph({ name = spec.icon, size = compact and 23 or 25, color = accent and "primary" or "on_surface" })
  local textWidth = width - 2 * padding - (compact and 33 or 0)
  local title = components.label(spec.title, 13, "on_surface", true, textWidth)
  local caption = components.label(spec.caption, 10, "on_surface_variant", false, textWidth)
  if compact then
    return ui.row(props, {
      icon,
      ui.column({ width = textWidth, gap = 2, align = "start", justify = "center" }, { title, caption }),
    })
  end
  return ui.column(props, { icon, title, caption })
end

local function tileRow(key, specs, width, compact, model, components, actions)
  local usable = width - (#specs - 1) * gap
  local base = math.floor(usable / #specs)
  local extra = usable % #specs
  local tiles = {}
  -- Distribute leftover pixels so the card edges align with the device card.
  for i, spec in ipairs(specs) do
    tiles[i] = tile(spec, base + (i <= extra and 1 or 0), compact, model, components, actions)
  end
  return ui.row({
    key = key, width = width, height = compact and M.secondaryHeight or M.primaryHeight, gap = gap,
  }, tiles)
end

local function typingForm(width, model, actions)
  local id = model.selected
  local function submit()
    if not model.snapshot.typeBusy and model.drafts[id] and model.drafts[id] ~= "" then
      model.sentDrafts[id] = model.drafts[id]
      actions.send("type_text", id, model.drafts[id])
    end
  end
  return ui.column({
    key = "typing-form",
    width = width,
    height = M.typingHeight,
    gap = 5,
    padding = 8,
    radius = 12,
    fill = palette("card"),
  }, {
    ui.row({ gap = 6, height = 32, align = "center" }, {
      ui.input({
        key = "draft-" .. id .. "-" .. tostring(model.draftRevisions[id] or 0),
        value = model.drafts[id] or "",
        placeholder = noctalia.tr("home.type_placeholder"),
        controlSize = "sm",
        flexGrow = 1,
        enabled = not model.snapshot.typeBusy,
        onChange = function(value)
          model.drafts[id] = value
          actions.render()
        end,
        onSubmit = submit,
      }),
      ui.button({
        text = model.snapshot.typeBusy and noctalia.tr("common.sending") or noctalia.tr("common.send"),
        controlSize = "sm",
        variant = "secondary",
        enabled = not model.snapshot.typeBusy and (model.drafts[id] or "") ~= "",
        onClick = submit,
      }),
      ui.button({
        text = noctalia.tr("common.clear"),
        controlSize = "sm",
        variant = "ghost",
        enabled = not model.snapshot.typeBusy,
        onClick = function()
          model.drafts[id] = ""
          model.draftRevisions[id] = (model.draftRevisions[id] or 0) + 1
          actions.render()
        end,
      }),
      ui.button({
        text = noctalia.tr("home.stop_typing"),
        controlSize = "sm",
        variant = "ghost",
        enabled = not model.snapshot.sessionBusy,
        onClick = function()
          actions.send("session", id, { kind = "keyboard", on = false })
        end,
      }),
    }),
    ui.label({
      text = noctalia.tr("home.transport_only"),
      maxWidth = width - 16,
      fontSize = 10,
      color = "on_surface_variant",
      visible = not model.snapshot.typeBusy
        and model.snapshot.typeDeliveryDevice == id
        and model.drafts[id] == model.sentDrafts[id],
      maxLines = 2,
    }),
  })
end

function M.render(context, width, model, components, actions)
  local phone, online, snapshot = context.phone, context.online, model.snapshot
  local id = model.selected
  local scope = model.actionScope
  local screen = components.activeSession(context.session, "screen")
  local webcam = components.activeSession(context.session, "webcam")
  local ringing = phone and phone.ringing == true
  local ringKnown = phone and type(phone.ringing) == "boolean"
  local transfer = online and #snapshot.devices == 1
  local transferReason = not online and context.unavailable or noctalia.tr("home.select_recipient")
  local ringReason = not online and context.unavailable
    or (snapshot.ringBusy and noctalia.tr("home.waiting"))
    or (not ringKnown and noctalia.tr("home.update_app"))
  local ringTitle = snapshot.ringBusy and noctalia.tr("common.sending")
    or noctalia.tr(ringing and "home.stop_ring" or "home.find_phone")

  local primary = tileRow("primary-actions", {
    {
      key = "screen", icon = "devices-pc", command = "session",
      title = noctalia.tr(screen and "home.stop_screen" or "home.screen"),
      caption = noctalia.tr("home.screen_caption"), tooltip = noctalia.tr("home.screen_hint"),
      enabled = context.canSession("screen"), device = id, value = { kind = "screen", on = not screen },
      active = screen, primary = true,
    },
    {
      key = "files", icon = "folder", onClick = function() actions.openFiles(id, scope) end,
      title = noctalia.tr("home.files"), caption = noctalia.tr("home.files_caption"),
      tooltip = transfer and noctalia.tr("home.files_hint") or transferReason, enabled = transfer,
    },
    {
      key = "clipboard", icon = "clipboard", command = "clipboard",
      title = noctalia.tr("home.clipboard"), caption = noctalia.tr("home.clipboard_caption"),
      tooltip = transfer and noctalia.tr("home.clipboard_hint") or transferReason, enabled = transfer,
    },
    {
      key = "ring", icon = ringing and "player-stop" or "target", command = "ring",
      title = ringTitle, caption = noctalia.tr("home.ring_caption"), tooltip = ringReason,
      enabled = online and ringKnown and not snapshot.ringBusy, device = id, value = not ringing, active = ringing,
    },
  }, width, false, model, components, actions)

  if components.activeSession(context.session, "keyboard") then
    return primary, typingForm(width, model, actions), M.primaryHeight + M.typingHeight
  end

  local secondary = tileRow("secondary-actions", {
    {
      key = "camera", icon = "camera", command = "camera", device = id,
      title = noctalia.tr(snapshot.cameraBusy and "common.starting" or "home.camera"),
      caption = noctalia.tr("home.camera_caption"),
      tooltip = not online and context.unavailable or noctalia.tr("home.camera_hint"),
      enabled = online and not snapshot.cameraBusy,
    },
    {
      key = "webcam", icon = "video", command = "session",
      title = noctalia.tr(webcam and "home.stop_webcam" or "home.webcam"),
      caption = noctalia.tr("home.webcam_caption"), tooltip = noctalia.tr("home.webcam_hint"),
      enabled = context.canSession("webcam"), device = id, value = { kind = "webcam", on = not webcam },
      active = webcam,
    },
    {
      key = "typing", icon = "keyboard", command = "session",
      title = noctalia.tr("home.typing"), caption = noctalia.tr("home.typing_caption"),
      tooltip = noctalia.tr("home.typing_hint"), enabled = context.canSession("keyboard"),
      device = id, value = { kind = "keyboard", on = true },
    },
  }, width, true, model, components, actions)
  return primary, secondary, M.primaryHeight + M.secondaryHeight
end

return M
