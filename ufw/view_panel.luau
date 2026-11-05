--!nonstrict
-- Pure panel view: the ufw.state snapshot in, a ui tree out. No noctalia calls; panel.luau
-- passes `ui`, the translation function and the callbacks.
--
--   view_panel.build(snap, ui, tr, h) -> UiNode
--
-- snap may be nil (no snapshot yet). tr(key, subst) translates. h holds:
--   h.toggle(on)                  the header switch (on = true / false)
--   h.confirmOff                  flag: show the "Turn off the firewall?" row (only while on
--                                 and not busy); h.confirmTurnOff() / h.cancelOff() answer it
--   h.toggleSeq                   bumped by the panel to remount the switch (see header)
--   h.primary(name)               "turn_on" | "start_service" | "load_rules" | "enable_at_boot"
--   h.stageAdd(port, proto, comment)   the Add button / Enter, with the form's raw text
--   h.stageRemove(ruleId)         ✕ on a rule row
--   h.unstage(opId)               undo on a removed row, ✕ on a pending add row
--   h.discard(), h.save()         the footer
--   h.fallback(kind)              "polkit_agent" | "terminal" (no polkit agent)
--   h.dismiss(key)                ✕ on an error or notice (key nil: clear everything shown)
--   h.setForm(patch)              typing and the protocol choice: { port | comment | proto }
--   h.form = { port, comment, proto = "both"|"tcp"|"udp", seq, errorKey }   read only here;
--     the inputs are keyed "add.port#<seq>" / "add.comment#<seq>", so a new seq mounts them
--     with `port` / `comment` as their text (inputs are uncontrolled).
--
-- Button styles (Mullvad c11bc56): exactly one primary (filled) button per state, or none when
-- nothing is the main action (see primaryAction); the Both/TCP/UDP choice is ghost buttons with
-- the active one in a primary-bordered box (no `selected`, which paints a fill); every other
-- action is "outline" (the host fills "secondary" too, which reads as a second main button)
-- or "ghost".

local model = require("./model.luau")
local commands = require("./commands.luau")

local view_panel = {}

local GREEN = "#22c55e"
local AMBER = "#f59e0b"
local MUTED = "on_surface_variant"
local ROW_FILL = "surface_container_high"
local SCROLL_AFTER = 6

local DOT = { on = GREEN, off = "error", stopped = "error", not_running = AMBER, failed = AMBER }
-- Header actions to their button text (literal keys, so the translation check sees them).
local ACTION_TEXT = {
  turn_on = "action.turn_on",
  start_service = "action.start_service",
  load_rules = "action.load_rules",
}
local PROTO_TEXT = { tcp = "proto.tcp", udp = "proto.udp", any = "proto.any", both = "proto.any" }
local CHOICES = {
  { id = "both", text = "add.both" },
  { id = "tcp", text = "proto.tcp" },
  { id = "udp", text = "proto.udp" },
}
local ACTION_META = { limit = "rules.limited", deny = "rules.denied", reject = "rules.rejected" }
-- In these states the header's own action is the main one, even with changes pending.
local ACTION_FIRST = { off = true, stopped = true, missing = true, unknown = true }

-- The one action drawn as the primary button: "save", a header action name, or nil.
local function primaryAction(status, headerPrimary, pendingCount, unreadable)
  local own = headerPrimary
  if own == nil and status == "failed" then
    own = "start_service"
  end
  if own == nil and unreadable then
    own = "load_rules"
  end
  if ACTION_FIRST[status] then
    return own
  end
  if pendingCount > 0 then
    return "save"
  end
  return own
end

local function isAddKey(key)
  return type(key) == "string" and string.sub(key, 1, 4) == "add."
end

-- tr for a message that may carry a count n (see model.countKey).
local function countText(tr, key, n)
  if type(n) == "number" then
    return tr(model.countKey(key, n), { n = n })
  end
  return tr(key)
end

local function portText(tr, rule)
  if rule.app ~= nil then
    return (string.gsub(rule.app, "%%20", " "))
  end
  if rule.port == nil then
    return tr("rules.any_port")
  end
  return (string.gsub(rule.port, ":", "–"))
end

local function metaText(tr, rule)
  local parts = {}
  local function add(text)
    parts[#parts + 1] = text
  end
  if ACTION_META[rule.action] then
    add(tr(ACTION_META[rule.action]))
  end
  if rule.route then
    add(tr("rules.routed"))
  end
  if rule.direction == "out" then
    add(tr("rules.outgoing"))
  end
  if rule.sapp ~= nil then
    add(tr("rules.from_app", { app = (string.gsub(rule.sapp, "%%20", " ")) }))
  elseif rule.from == nil or rule.from == "any" then
    add(tr("rules.from_anywhere"))
  else
    add(tr("rules.from_only", { from = rule.from }))
  end
  if rule.fromPort ~= nil then
    add(tr("rules.from_port", { port = (string.gsub(rule.fromPort, ":", "–")) }))
  end
  if rule.to ~= nil and rule.to ~= "any" then
    add(tr("rules.to", { to = rule.to }))
  end
  if rule.iface ~= nil then
    add(tr("rules.on_iface", { iface = (string.gsub(rule.iface, ">", " → ")) }))
  end
  return table.concat(parts, " · ")
end

local function protoTag(ui, tr, key, proto)
  local text = PROTO_TEXT[proto]
  if text ~= nil then
    text = tr(text)
  elseif type(proto) == "string" then
    text = string.upper(proto)
  else
    return nil
  end
  return ui.row({ key = key, border = "outline_variant", borderWidth = 1, radius = 4, paddingH = 4, align = "center" }, {
    ui.label({ text = text, fontSize = 9, fontWeight = "bold", color = MUTED }),
  })
end

local function opErrorLabel(ui, tr, key, op)
  if op == nil then
    return nil
  end
  local text = nil
  if op.errorKey ~= nil then
    text = tr(op.errorKey)
  elseif op.error ~= nil then
    text = op.error
  end
  if text == nil then
    return nil
  end
  return ui.label({ key = key, text = text, fontSize = 11, color = "error", maxLines = 3 })
end

-- Port, tag, the meta / comment column, then the trailing control.
local function rowBody(ui, tr, key, port, proto, metaChildren, trailing)
  local children = {
    ui.row({ gap = 6, align = "center", minWidth = 92 }, {
      ui.label({ text = port, fontSize = 13, fontWeight = "semibold" }),
      protoTag(ui, tr, key .. ".tag", proto),
    }),
    ui.column({ gap = 2, flexGrow = 1 }, metaChildren),
  }
  if trailing ~= nil then
    children[#children + 1] = trailing
  end
  return children
end

local function wrapWithError(ui, rowNode, errorNode)
  if errorNode == nil then
    return rowNode
  end
  return ui.column({ gap = 2 }, { rowNode, errorNode })
end

local function ruleRow(ui, tr, h, rule, removeOp, canStage)
  local key = "row." .. rule.id
  local meta = { ui.label({ text = metaText(tr, rule), fontSize = 11, color = MUTED, maxLines = 2 }) }
  if rule.comment ~= nil and rule.comment ~= "" then
    meta[#meta + 1] = ui.label({ text = rule.comment, fontSize = 11, maxLines = 2 })
  end
  local trailing
  if removeOp ~= nil then
    meta[#meta + 1] = ui.label({ key = key .. ".removed", text = tr("rules.will_be_removed"), fontSize = 11, color = AMBER })
    local opId = removeOp.id
    trailing = ui.button({
      key = key .. ".undo",
      text = tr("action.undo"),
      variant = "ghost",
      controlSize = "sm",
      enabled = canStage,
      onClick = function()
        h.unstage(opId)
      end,
    })
  elseif rule.removable then
    local id = rule.id
    trailing = ui.button({
      key = key .. ".remove",
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("action.remove"),
      enabled = canStage,
      onClick = function()
        h.stageRemove(id)
      end,
    })
  else
    trailing = ui.label({ key = key .. ".terminal", text = tr("rules.remove_in_terminal"), fontSize = 10, color = MUTED, maxWidth = 80, maxLines = 2 })
  end
  local props = { key = key, gap = 8, align = "center", paddingH = 10, paddingV = 6, radius = 8, fill = ROW_FILL }
  if removeOp ~= nil then
    props.opacity = 0.5
  end
  local rowNode = ui.row(props, rowBody(ui, tr, key, portText(tr, rule), rule.proto, meta, trailing))
  return wrapWithError(ui, rowNode, opErrorLabel(ui, tr, key .. ".error", removeOp))
end

local function addOpRow(ui, tr, h, op, canStage)
  local key = "op." .. op.id
  local meta = { ui.label({ text = tr("rules.from_anywhere"), fontSize = 11, color = MUTED }) }
  local tail = {}
  if op.comment ~= nil and op.comment ~= "" then
    tail[#tail + 1] = ui.label({ text = op.comment, fontSize = 11, maxLines = 2 })
  end
  tail[#tail + 1] = ui.label({ key = key .. ".new", text = tr("rules.new"), fontSize = 11, color = GREEN })
  meta[#meta + 1] = ui.row({ gap = 6, align = "center" }, tail)
  local opId = op.id
  local trailing = ui.button({
    key = key .. ".remove",
    glyph = "x",
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr("action.remove"),
    enabled = canStage,
    onClick = function()
      h.unstage(opId)
    end,
  })
  local body = ui.row({ gap = 8, align = "center", paddingH = 10, paddingV = 6, flexGrow = 1 },
    rowBody(ui, tr, key, tostring(op.port), op.proto or "both", meta, trailing))
  local rowNode = ui.row({ key = key, radius = 8, fill = ROW_FILL }, {
    ui.box({ key = key .. ".accent", width = 3, radius = 2, fill = GREEN }),
    body,
  })
  return wrapWithError(ui, rowNode, opErrorLabel(ui, tr, key .. ".error", op))
end

local function actionButton(ui, tr, h, name, primary, busy)
  return ui.button({
    key = "btn." .. name,
    text = tr(ACTION_TEXT[name]),
    variant = primary == name and "primary" or "outline",
    controlSize = "sm",
    enabled = not busy,
    onClick = function()
      h.primary(name)
    end,
  })
end

local function header(ui, tr, h, snap, head, busy)
  local status = head and head.status
  local lineKey = head and head.lineKey or "panel.loading"
  local canToggle = snap ~= nil and not busy and status ~= "missing" and status ~= "unknown" and snap.testMode ~= true
  local children = {
    ui.row({ gap = 10, align = "center" }, {
      ui.box({ key = "hdr.dot", width = 10, height = 10, radius = 5, fill = DOT[status] or MUTED }),
      ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      -- A new h.toggleSeq remounts the switch, so after an unconfirmed flip it shows the real
      -- state again even though `checked` itself did not change.
      ui.row({ key = "hdr.toggle_box#" .. tostring(h.toggleSeq or 0), align = "center" }, {
        ui.toggle({
          key = "hdr.toggle",
          checked = model.switchOn(snap),
          enabled = canToggle,
          onChange = function(value)
            h.toggle(value == "true")
          end,
        }),
      }),
    }),
    ui.label({
      key = "hdr.line",
      text = tr(lineKey),
      fontSize = 12,
      color = lineKey == "header.on_open" and AMBER or MUTED,
      maxLines = 2,
    }),
  }
  if snap ~= nil and snap.testMode == true then
    children[#children + 1] = ui.label({ key = "hdr.test", text = tr("panel.test_mode"), fontSize = 11, color = AMBER, maxLines = 2 })
  end
  return ui.column({ gap = 4 }, children)
end

local function box(ui, key, border, fill, children)
  return ui.column({ key = key, gap = 8, padding = 10, radius = 8, border = border, borderWidth = border and 1 or nil, fill = fill }, children)
end

local function warningBox(ui, tr, h, head, primary, busy)
  local action = head.primary
  if action == nil and head.status == "failed" then
    action = "start_service"
  end
  local off = head.status == "off" or head.status == "stopped"
  local children = { ui.label({ text = tr(head.warningKey), fontSize = 12, maxLines = 3 }) }
  if action ~= nil then
    children[#children + 1] = ui.row({ gap = 8 }, { actionButton(ui, tr, h, action, primary, busy) })
  end
  return box(ui, "box.warning", off and "error" or AMBER, off and "error/0.12" or "#f59e0b1f", children)
end

local function dismissButton(ui, tr, key, onClick)
  return ui.button({ key = key, glyph = "x", variant = "ghost", controlSize = "sm", tooltip = tr("panel.dismiss"), onClick = onClick })
end

local function errorBox(ui, tr, h, err)
  local key = err.key
  local lines = { ui.label({ text = countText(tr, key, err.n), fontSize = 12, color = "error", maxLines = 4 }) }
  if type(err.detail) == "string" and err.detail ~= "" then
    lines[#lines + 1] = ui.label({ text = err.detail, fontSize = 11, color = MUTED, maxLines = 3 })
  end
  return ui.row({ key = "box.error", gap = 8, align = "center", padding = 8, radius = 8, fill = "error/0.12" }, {
    ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
    ui.column({ gap = 2, flexGrow = 1 }, lines),
    dismissButton(ui, tr, "btn.dismiss_error", function()
      h.dismiss(key)
    end),
  })
end

local function noticeBox(ui, tr, h, notice)
  local key = notice.key
  return ui.row({ key = "box.notice", gap = 8, align = "center", padding = 8, radius = 8, fill = ROW_FILL }, {
    ui.label({ text = countText(tr, key, notice.n), fontSize = 12, flexGrow = 1, maxLines = 3 }),
    dismissButton(ui, tr, "btn.dismiss_notice", function()
      h.dismiss(key)
    end),
  })
end

local function fallbackBox(ui, tr, h, snap, busy)
  local kind = snap.polkitFallback["for"]
  local terminal = type(kind) == "string" and commands.terminalKey(kind, snap) ~= nil
  local buttons = {
    ui.button({
      key = "btn.polkit_agent",
      text = tr("action.polkit_agent"),
      variant = "outline",
      controlSize = "sm",
      enabled = not busy,
      onClick = function()
        h.fallback("polkit_agent")
      end,
    }),
  }
  if terminal then
    buttons[#buttons + 1] = ui.button({
      key = "btn.run_in_terminal",
      text = tr("action.run_in_terminal"),
      variant = "outline",
      controlSize = "sm",
      enabled = not busy,
      onClick = function()
        h.fallback("terminal")
      end,
    })
  end
  local errKey = snap.lastError and snap.lastError.key
  local dismissKey = nil
  if errKey == "error.no_polkit_agent" then
    dismissKey = errKey
  end
  return box(ui, "box.fallback", nil, "error/0.12", {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "lock", size = 16, color = "error" }),
      ui.label({ text = tr("error.no_polkit_agent"), fontSize = 12, color = "error", flexGrow = 1, maxLines = 2 }),
      dismissButton(ui, tr, "btn.dismiss_fallback", function()
        h.dismiss(dismissKey)
      end),
    }),
    ui.label({ text = tr(terminal and "fallback.hint" or "fallback.hint_prompt_only"), fontSize = 11, color = MUTED, maxLines = 3 }),
    ui.row({ gap = 8 }, buttons),
  })
end

local function ruleList(ui, tr, h, snap, status, canStage)
  local removes = {}
  for _, op in ipairs(snap.pending or {}) do
    if op.kind == "remove" and op.ruleId ~= nil then
      removes[op.ruleId] = op
    end
  end
  local rows = {}
  for _, rule in ipairs(snap.rules or {}) do
    rows[#rows + 1] = ruleRow(ui, tr, h, rule, removes[rule.id], canStage)
  end
  local newest = nil
  for _, op in ipairs(snap.pending or {}) do
    if op.kind == "add" then
      rows[#rows + 1] = addOpRow(ui, tr, h, op, canStage)
      newest = "op." .. op.id
    end
  end
  local title = ui.label({
    text = tr((status == "off" or status == "stopped") and "rules.title_off" or "rules.title"),
    fontSize = 11,
    fontWeight = "semibold",
    color = MUTED,
  })
  local list
  if #rows == 0 then
    list = ui.label({ key = "list", text = tr("rules.empty"), fontSize = 12, color = MUTED })
  elseif #rows > SCROLL_AFTER then
    -- grows into what the panel's max_height leaves after the other sections
    -- the newest staged add sits last; revealKey scrolls it into view when it appears
    list = ui.scroll({ key = "list", gap = 6, flexGrow = 1, revealKey = newest }, rows)
  else
    list = ui.column({ key = "list", gap = 6 }, rows)
  end
  return ui.column({ gap = 6, flexGrow = #rows > SCROLL_AFTER and 1 or nil }, { title, list })
end

local function addForm(ui, tr, h, snap, canStage)
  local form = h.form or {}
  local seq = tostring(form.seq or 0)
  local proto = form.proto or "both"
  local choices = {}
  for _, choice in ipairs(CHOICES) do
    local id = choice.id
    local active = id == proto
    -- The host keeps a prop that disappears between renders, so every visual prop is
    -- set explicitly each time: active = primary border at full opacity, inactive =
    -- a transparent border at half opacity (never border = nil).
    local inner
    if active then
      -- the selected option is a plain label: nothing to click, no hover look
      inner = ui.label({
        key = "form.proto." .. id .. ".on",
        text = tr(choice.text),
        fontSize = 12,
        fontWeight = "medium",
        textAlign = "center",
        flexGrow = 1,
      })
    else
      inner = ui.button({
        key = "form.proto." .. id,
        text = tr(choice.text),
        variant = "ghost",
        controlSize = "sm",
        flexGrow = 1,
        enabled = canStage,
        onClick = function()
          h.setForm({ proto = id })
        end,
      })
    end
    choices[#choices + 1] = ui.row({
      key = "form.box." .. id,
      flexGrow = 1,
      radius = 8,
      align = "center",
      minHeight = 28,
      border = active and "primary" or "#00000000",
      borderWidth = 1,
      opacity = active and 1 or 0.5,
    }, { inner })
  end
  local function submit()
    local current = h.form or {}
    h.stageAdd(current.port or "", current.proto or "both", current.comment)
  end
  local children = {
    ui.row({ gap = 10, align = "center" }, {
      ui.input({
        key = "add.port#" .. seq,
        value = form.port or "",
        placeholder = tr("add.port"),
        width = 96,
        controlSize = "sm",
        enabled = canStage,
        onChange = function(value)
          h.setForm({ port = value })
        end,
        onSubmit = function(value)
          h.setForm({ port = value })
          submit()
        end,
      }),
      ui.row({ gap = 6, flexGrow = 1 }, choices),
    }),
    ui.row({ gap = 10, align = "center" }, {
      ui.input({
        key = "add.comment#" .. seq,
        value = form.comment or "",
        placeholder = tr("add.comment"),
        flexGrow = 1,
        controlSize = "sm",
        enabled = canStage,
        onChange = function(value)
          h.setForm({ comment = value })
        end,
        onSubmit = function(value)
          h.setForm({ comment = value })
          submit()
        end,
      }),
      ui.row({
        key = "btn.add",
        align = "center",
        justify = "center",
        paddingH = 14,
        paddingV = 9,
        radius = 8,
        border = GREEN,
        borderWidth = 1,
        opacity = canStage and 1 or 0.4,
        onClick = canStage and submit or nil,
      }, {
        ui.label({ key = "btn.add.label", text = tr("add.button"), fontSize = 12, fontWeight = "medium", color = GREEN }),
      }),
    }),
  }
  local errorKey = form.errorKey
  if errorKey == nil and snap.lastError ~= nil and isAddKey(snap.lastError.key) then
    errorKey = snap.lastError.key
  end
  if errorKey ~= nil then
    children[#children + 1] = ui.label({ key = "form.error", text = tr(errorKey), fontSize = 11, color = "error", maxLines = 3 })
  end
  return ui.column({ key = "form", gap = 10 }, children)
end

local function footer(ui, tr, h, n, primary, busy, saving)
  return ui.row({ key = "footer", gap = 10, align = "center" }, {
    ui.label({ text = tr(model.countKey("footer.unsaved", n), { n = n }), fontSize = 12, color = AMBER, flexGrow = 1 }),
    ui.button({
      key = "btn.discard",
      text = tr("action.discard"),
      variant = "ghost",
      controlSize = "sm",
      enabled = not saving,
      onClick = function()
        h.discard()
      end,
    }),
    ui.button({
      key = "btn.save",
      text = tr("action.save"),
      variant = primary == "save" and "primary" or "outline",
      controlSize = "sm",
      enabled = not busy,
      onClick = function()
        h.save()
      end,
    }),
  })
end

function view_panel.build(snap, ui, tr, h)
  if type(snap) ~= "table" then
    return ui.column({ gap = 12, padding = 14 }, { header(ui, tr, h, nil, nil, false) })
  end
  local head = model.header(snap)
  local status = head.status
  local busy = snap.busy == true
  local saving = busy and snap.busyAction == "save"
  local canStage = not saving
  local installed = status ~= "missing"
  -- "loading" (nothing read yet) is not unreadable: no Load rules, no empty rule list
  local loading = snap.source == "loading"
  local unreadable = installed and not loading and (snap.enabled == nil or snap.source == "none")
  local pending = snap.pending or {}
  -- While "Turn off the firewall?" is open its destructive button is the one strong button.
  local confirming = h.confirmOff == true and model.switchOn(snap) and not busy
  local primary = nil
  if not confirming then
    primary = primaryAction(status, head.primary, #pending, unreadable)
  end

  local children = { header(ui, tr, h, snap, head, busy) }
  local function add(node)
    if node ~= nil then
      children[#children + 1] = node
    end
  end

  if head.warningKey ~= nil then
    add(warningBox(ui, tr, h, head, primary, busy))
  end
  if head.bootNotice then
    add(ui.row({ key = "box.boot", gap = 8, align = "center", padding = 10, radius = 8, fill = ROW_FILL }, {
      ui.label({ text = tr("boot.notice"), fontSize = 12, flexGrow = 1, maxLines = 2 }),
      ui.button({
        key = "btn.start_at_boot",
        text = tr("action.start_at_boot"),
        variant = "outline",
        controlSize = "sm",
        enabled = not busy,
        onClick = function()
          h.primary("enable_at_boot")
        end,
      }),
    }))
  end
  if not installed then
    add(box(ui, "box.missing", nil, ROW_FILL, {
      ui.label({ text = tr("missing.body"), fontSize = 12, maxLines = 3 }),
    }))
  elseif unreadable then
    add(box(ui, "box.unreadable", nil, ROW_FILL, {
      ui.label({ text = tr("unreadable.body"), fontSize = 12, maxLines = 3 }),
      ui.row({ gap = 8 }, { actionButton(ui, tr, h, "load_rules", primary, busy) }),
    }))
  elseif loading and snap.rulesIncomplete == true then
    -- the rules never parsed complete: a line instead of an empty body
    add(ui.label({ key = "rules.incomplete", text = tr("rules.incomplete"), fontSize = 12, color = MUTED, maxLines = 2 }))
  end

  local fallback = type(snap.polkitFallback) == "table"
  local err = snap.lastError
  if type(err) == "table" and err.key ~= nil and not isAddKey(err.key)
    and not (fallback and err.key == "error.no_polkit_agent") then
    add(errorBox(ui, tr, h, err))
  end
  if fallback then
    add(fallbackBox(ui, tr, h, snap, busy))
  end
  if type(snap.notice) == "table" and snap.notice.key ~= nil then
    add(noticeBox(ui, tr, h, snap.notice))
  end
  -- Turning off asks first (panel.luau sets h.confirmOff after the switch is flipped off).
  if confirming then
    add(ui.column({ key = "box.confirm", gap = 8, padding = 10, radius = 8, border = "error", borderWidth = 1, fill = "error/0.12" }, {
      ui.label({ text = tr("confirm.turn_off"), fontSize = 12, color = "error", maxLines = 3 }),
      ui.row({ gap = 8, justify = "end" }, {
        ui.button({
          key = "btn.cancel_off",
          text = tr("confirm.cancel"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            h.cancelOff()
          end,
        }),
        ui.button({
          key = "btn.confirm_off",
          text = tr("action.turn_off"),
          variant = "destructive",
          controlSize = "sm",
          onClick = function()
            h.confirmTurnOff()
          end,
        }),
      }),
    }))
  end
  if busy then
    add(ui.label({ key = "busy", text = tr("panel.busy"), fontSize = 11, color = "primary" }))
  end

  if installed and not unreadable and not loading then
    add(ruleList(ui, tr, h, snap, status, canStage))
    add(addForm(ui, tr, h, snap, canStage))
  end
  if installed and #pending > 0 then
    add(ui.separator({}))
    add(footer(ui, tr, h, #pending, primary, busy, saving))
  end
  return ui.column({ gap = 12, padding = 14, flexGrow = 1 }, children)
end

return view_panel
