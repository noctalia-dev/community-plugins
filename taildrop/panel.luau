--!nonstrict
-- Taildrop send dialog: choose a device on the tailnet and confirm.

local STATE_KEY = "taildrop_snapshot"
local COMMAND_KEY = "taildrop_command"
local RESULT_KEY = "taildrop_result"
local TRANSFER_KEY = "taildrop_transfer"

local snapshot = noctalia.state.get(STATE_KEY) or {}
local transfer = noctalia.state.get(TRANSFER_KEY) or {}

local shownJobId = ""
local targetSelection = ""
local feedback = ""
local feedbackError = false
local dirty = true
local requestCounter = 0
local autoCloseTicks = 0 -- counts down after a successful send, then closes

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function nextRequestId()
  requestCounter += 1
  return `panel-{requestCounter}`
end

local function send(action, values)
  local command = { action = action, requestId = nextRequestId() }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
end

local function selectedTarget()
  if type(transfer) ~= "table" then
    return nil
  end
  for _, t in ipairs(transfer.eligible or {}) do
    if t.name == targetSelection or t.ip == targetSelection then
      return t
    end
  end
  return nil
end

local function targetRows()
  local rows = {}
  local eligible = transfer.eligible or {}
  if #eligible == 0 then
    table.insert(rows, ui.label({
      text = (transfer.error ~= "" and transfer.error) or tr("send.loading"),
      color = transfer.error ~= "" and "error" or "on_surface_variant",
      maxLines = 3,
    }))
    return rows
  end
  for _, t in ipairs(eligible) do
    local selected = t.name == targetSelection or t.ip == targetSelection
    local text = `{t.name}  ·  {t.ip}` .. (t.online and "" or "  ·  offline")
    table.insert(rows, ui.button({
      key = "target-" .. t.name,
      text = text,
      glyph = t.online and "device-desktop" or "device-desktop-off",
      variant = selected and "primary" or "outline",
      selected = selected,
      contentAlign = "start",
      controlSize = "md",
      onClick = function()
        targetSelection = t.name
        dirty = true
      end,
    }))
  end
  return rows
end

local function filesRows()
  local rows = {}
  for _, f in ipairs(transfer.paths or {}) do
    local info = noctalia.fileInfo(f)
    local isDir = type(info) == "table" and info.isDir == true
    local prefix = isDir and tr("send.folder") or tr("send.file")
    table.insert(rows, ui.label({
      text = prefix .. " " .. f,
      maxLines = 2,
      fontSize = 12,
      color = "on_surface_variant",
    }))
  end
  return rows
end

local function toolbar()
  local phase = transfer.phase or ""
  local items = {}

  if phase == "sending" then
    table.insert(items, ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "world-upload", size = 18, color = "primary" }),
      ui.label({ text = tr("send.sending", { target = transfer.target or "…" }), flexGrow = 1, maxLines = 2 }),
    }))
  elseif phase == "succeeded" or phase == "failed" or phase == "cancelled" then
    local msg = (phase == "succeeded" and tr("result.sent_to", { n = #(transfer.paths or {}), target = transfer.target or "" }))
      or (phase == "failed" and (transfer.error ~= "" and transfer.error or "send failed"))
      or tr("result.cancelled")
    local color = (phase == "failed") and "error" or (phase == "succeeded" and "primary" or "on_surface_variant")
    table.insert(items, ui.row({ gap = 8, align = "center" }, {
      ui.glyph({
        name = (phase == "failed" and "alert-triangle") or (phase == "succeeded" and "world-upload") or "x",
        size = 18,
        color = color,
      }),
      ui.label({ text = msg, flexGrow = 1, maxLines = 3, color = color }),
    }))
    -- Failed sends stay open with a Retry so you can re-run the same send; a
    -- successful (or cancelled) send closes itself shortly after.
    if phase ~= "failed" then
      table.insert(items, ui.label({
        text = tr("send.auto_close"),
        color = "on_surface_variant",
        fontSize = 11,
      }))
    end
    if phase == "failed" then
      table.insert(items, ui.row({ gap = 6 }, {
        ui.button({ text = tr("send.retry"), glyph = "refresh", variant = "primary", onClick = "onRetrySend" }),
        ui.button({ text = tr("send.done"), glyph = "x", variant = "ghost", onClick = "onDismissSend" }),
      }))
    end
  else
    local sel = selectedTarget()
    table.insert(items, ui.label({ text = tr("send.files", { n = #(transfer.paths or {}) }), color = "on_surface_variant", fontSize = 12 }))
    table.insert(items, ui.row({ gap = 6 }, {
      ui.button({
        text = sel and tr("send.send_to", { name = sel.name }) or tr("send.select"),
        glyph = "world-upload",
        variant = "primary",
        enabled = sel ~= nil,
        onClick = "onConfirmSend",
      }),
      ui.button({ text = tr("send.cancel"), glyph = "x", variant = "outline", onClick = "onCancelSend" }),
    }))
  end

  if feedback ~= "" then
    table.insert(items, ui.label({
      text = feedback,
      color = feedbackError and "error" or "tertiary",
      maxLines = 2,
    }))
  end

  return ui.column({ gap = 6, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, items)
end

local function render()
  dirty = false

  local notes = {}
  if snapshot.available == false then
    table.insert(notes, ui.label({ text = tr("panel.not_installed"), color = "error", maxLines = 3 }))
  end
  if type(snapshot.updatedAt) == "number" and snapshot.updatedAt == 0 then
    table.insert(notes, ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.image({
        path = snapshot.available == false and "assets/tailscale-grey.png" or "assets/tailscale-green.png",
        width = 22,
        height = 22,
        fit = "contain",
      }),
      ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onClosePanel" }),
    }),

    ui.column({ gap = 4, align = "stretch" }, filesRows()),
    ui.label({ text = "", fontSize = 4 }),

    ui.scroll({ key = "send-targets", flexGrow = 1, gap = 8, align = "stretch" }, {
      ui.column({ key = "send-targets-col", align = "stretch", justify = "start", gap = 8, flexGrow = 1 }, targetRows()),
    }),

    ui.column({ gap = 3, align = "stretch" }, notes),
    toolbar(),
  }))
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  snapshot = value
  dirty = true
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" then
    return
  end
  if type(result.requestId) ~= "string" or not result.requestId:match("^panel%-") then
    return
  end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  dirty = true
end)

noctalia.state.watch(TRANSFER_KEY, function(value)
  if type(value) ~= "table" then
    value = {}
  end
  local jobId = type(value.requestId) == "string" and value.requestId or ""
  transfer = value
  if jobId ~= "" and jobId ~= shownJobId then
    -- A brand-new request: reset the picker.
    shownJobId = jobId
    targetSelection = ""
  elseif jobId == "" then
    shownJobId = ""
    targetSelection = ""
  end
  -- Auto-close after a successful send; keep failures open for inspection.
  autoCloseTicks = (transfer.phase == "succeeded") and 2 or 0
  dirty = true
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  feedback = ""
  render()
end

function update()
  if dirty then
    render()
  end
  if autoCloseTicks > 0 then
    autoCloseTicks = autoCloseTicks - 1
    if autoCloseTicks == 0 and transfer.phase == "succeeded" then
      panel.close()
    end
  end
end

function onClosePanel()
  panel.close()
end

function onConfirmSend()
  local sel = selectedTarget()
  if sel then
    send("taildrop_confirm", { jobId = transfer.requestId, target = sel.name })
  end
end

function onCancelSend()
  send("taildrop_cancel", { jobId = transfer.requestId })
  panel.close()
end

function onRetrySend()
  send("taildrop_retry", { jobId = transfer.requestId })
end

function onDismissSend()
  send("taildrop_dismiss", { jobId = transfer.requestId })
  panel.close()
end
