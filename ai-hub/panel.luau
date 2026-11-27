--!nonstrict
--[[
  panel.luau - the chat panel.

  The panel owns presentation only. It renders whatever the service publishes
  under `hub.*` and sends commands back through `hub.cmd`; it never touches the
  network or the credentials itself, and the key never reaches this VM.

  Two UI decisions are load-bearing:

    * the model list is a search box plus a filtered list, not a dropdown,
      because OmniRoute-style gateways expose thousands of ids and a 2730-entry
      `ui.select` is unusable;
    * the composer input is uncontrolled, so sending a message bumps its `key`
      to get a fresh, empty field.
]]

local providers = require("./lib/providers.luau")
local text = require("./lib/text.luau")

local KEY_COMMAND = "hub.cmd"
local modelIdx = 0

-- Rendered message nodes are immutable for a given content, so they are reused
-- across the frequent re-renders (see history_node below).
local message_node_cache = {}

local view = {
  open = false,
  composer_gen = 0,
  draft = "",
  expanded = {},
  models_requested = false,
  status = "idle",
  messages = {},
  stream = { active = false },
  models = {},
  pending = nil,
  info = {},
  test = nil,
  command_seq = 0,
  visible_messages = 12,
  picker = false,
  filter = "",
  filter_free = false,
  filter_tools = false,
}

local function trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Commands are numbered so the service can ignore a repeat of the pub/sub
-- channel's last value; the panel continues the sequence it finds in state, so
-- reopening the panel never goes backwards.
local function send(kind, fields)
  view.command_seq = view.command_seq + 1
  local command = { seq = view.command_seq, kind = kind }
  if type(fields) == "table" then
    for key, value in pairs(fields) do
      command[key] = value
    end
  end
  noctalia.state.set(KEY_COMMAND, command)
end

-- Sections that do not apply right now are passed as nil. They are collected as
-- varargs because `ipairs` stops at the first nil: fed a list with a hole in the
-- middle, it would silently drop every section after it.
local function nodes(...)
  local out = {}
  for index = 1, select("#", ...) do
    local item = select(index, ...)
    if item ~= nil then
      table.insert(out, item)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function onLoadModels()
  send("models")
end

function onTest()
  send("test")
end

function onOpenSettings()
  noctalia.openSettings("robpidev/ai-hub")
end

function onClear()
  view.expanded = {}
  message_node_cache = {}
  view.visible_messages = 12
  send("clear")
end

function onShowMore()
  view.visible_messages = view.visible_messages + 12
  render()
end

function onClosePanel()
  panel.close()
end

function onStop()
  send("stop")
end

function onRetry()
  send("retry")
end

-- Update the model dropdown selection to match the current model from the
-- service (0-based index, like ui.select expects).
local function updateModelIdx()
  local ids = view.models.ids or {}
  local current = tostring((view.info or {}).model or "")
  modelIdx = 0
  for i, id in ipairs(ids) do
    if id == current then
      modelIdx = i - 1
      break
    end
  end
end

-- Mimir-style model selection: a native ui.select dropdown fires onChange with
-- (index, text); we map back to the model id and tell the service.
function onModelChange(index, text)
  local ids = (view.models or {}).ids or {}
  local idx = tonumber(index)
  if idx == nil and text then
    for i, m in ipairs(ids) do
      if m == text then
        idx = i - 1
        break
      end
    end
  end
  local selected = idx ~= nil and ids[idx + 1] or nil
  if type(selected) == "string" and selected ~= "" then
    modelIdx = idx
    send("set_model", { model = selected })
    noctalia.log("onModelChange selected: " .. selected)
  end
end

function onTogglePicker()
  view.picker = not view.picker
  if view.picker then
    local models = view.models or {}
    if #(models.ids or {}) == 0 and models.loading ~= true then
      send("models")
    end
  end
  render()
end

function onFilterChange(value)
  view.filter = type(value) == "table" and (value.value or "") or value or ""
  render()
end

function onToggleFree()
  view.filter_free = not view.filter_free
  render()
end

function onToggleTools()
  view.filter_tools = not view.filter_tools
  render()
end

function onToggleExpand(key)
  view.expanded[key] = not view.expanded[key]
  render()
end

function onUseTypedId()
  local wanted = trim(view.filter)
  if wanted == "" then
    return
  end
  send("set_model", { model = wanted })
  view.picker = false
  view.filter = ""
  render()
end

function onPickModel(id)
  noctalia.log("onPickModel called with id: " .. tostring(id))
  send("set_model", { model = id })
  view.picker = false
  view.filter = ""
  render()
end

function onDraftChange(value)
  view.draft = type(value) == "string" and value or ""
end

function onComposerSubmit(value)
  local body = type(value) == "string" and value or view.draft
  if trim(body) == "" then
    return
  end
  send("send", { text = body })
  view.draft = ""
  -- a fresh key recreates the uncontrolled input, i.e. clears it
  view.composer_gen = view.composer_gen + 1
  render()
end

-- The host passes ("", "") to a button click, never nil, so the send button
-- cannot share onComposerSubmit: it would read "" as the text and return early.
-- Use the live draft instead and let onComposerSubmit handle Enter.
function onSendClick()
  onComposerSubmit(view.draft)
end

function onApprove()
  local pending = view.pending
  if pending ~= nil then
    send("approve", { id = pending.id })
  end
end

function onDeny()
  local pending = view.pending
  if pending ~= nil then
    send("deny", { id = pending.id })
  end
end

function onCopyMessage(index)
  local message = view.messages[index]
  if message == nil then
    return
  end
  if noctalia.copyToClipboard(message.content or "", "text/plain") then
    noctalia.notify(noctalia.tr("panel.copied"), noctalia.tr("panel.copied_body"))
  else
    noctalia.notifyError(noctalia.tr("panel.copy_failed"), noctalia.tr("panel.copy_failed_body"))
  end
end

function onCopyCodeBlock(code)
  if noctalia.copyToClipboard(code or "", "text/plain") then
    noctalia.notify(noctalia.tr("panel.copied"), noctalia.tr("panel.code_copied"))
  else
    noctalia.notifyError(noctalia.tr("panel.copy_failed"), noctalia.tr("panel.copy_failed_body"))
  end
end

function onCopyCode()
  local last = nil
  for index = #view.messages, 1, -1 do
    local message = view.messages[index]
    if message.role == "assistant" then
      last = text.last_code_block(message.content)
      if last ~= nil then
        break
      end
    end
  end
  if last == nil and view.stream.active then
    last = text.last_code_block(view.stream.content)
  end
  if last == nil then
    noctalia.notify(noctalia.tr("panel.no_code"), noctalia.tr("panel.no_code_body"))
    return
  end
  if noctalia.copyToClipboard(last.code, "text/plain") then
    noctalia.notify(noctalia.tr("panel.copied"), noctalia.tr("panel.code_copied"))
  else
    noctalia.notifyError(noctalia.tr("panel.copy_failed"), noctalia.tr("panel.copy_failed_body"))
  end
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function role_style(role)
  if role == "user" then
    return noctalia.tr("role.user"), "on_surface/0.65"
  elseif role == "assistant" then
    return noctalia.tr("role.assistant"), "primary"
  elseif role == "error" then
    return noctalia.tr("role.error"), "error"
  elseif role == "notice" then
    return noctalia.tr("role.notice"), "on_surface/0.65"
  elseif role == "tool" then
    return noctalia.tr("role.tool"), "on_surface/0.65"
  end
  return tostring(role or "?"), "on_surface/0.65"
end

local function usage_line(message)
  local bits = {}
  if type(message.model) == "string" and message.model ~= "" then
    table.insert(bits, message.model)
  end
  local usage = message.usage
  if type(usage) == "table" and usage.total ~= nil then
    table.insert(bits, string.format("%d tokens", usage.total))
  end
  if type(usage) == "table" and usage.cost ~= nil then
    table.insert(bits, string.format("$%.6f", usage.cost))
  end
  if #bits == 0 then
    return nil
  end
  return table.concat(bits, " · ")
end

local function header_node()
  local info = view.info or {}
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "sparkles", size = 16, color = "primary" }),
    ui.label({ text = "AI Hub", fontSize = 14, fontWeight = "bold" }),
    ui.label({
      text = tostring(info.provider_label or ""),
      fontSize = 11,
      color = "on_surface/0.6",
      maxWidth = 150,
      maxLines = 1,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.load_models"), onClick = "onLoadModels" }),
    ui.button({ glyph = "plug", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.test"), onClick = "onTest" }),
    ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.settings"), onClick = "onOpenSettings" }),
    ui.button({ glyph = "trash", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.clear"), onClick = "onClear" }),
    ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.close"), onClick = "onClosePanel" }),
  })
end

local function warning_node()
  local info = view.info or {}
  local lines = {}
  if info.needs_endpoint == true then
    table.insert(lines, noctalia.tr("warning.no_endpoint"))
  end
  if info.key_error ~= nil then
    table.insert(lines, tostring(info.key_error))
  elseif info.needs_key == true then
    table.insert(lines, noctalia.tr("warning.no_key"))
  end
  if #lines == 0 then
    return nil
  end
  local children = {
    ui.row({ align = "center", gap = 6 }, {
      ui.glyph({ name = "alert-triangle", size = 13, color = "error" }),
      ui.label({ text = table.concat(lines, " "), fontSize = 11, color = "error", flexGrow = 1 }),
    }),
  }
  return ui.column({ gap = 6, padding = 8, radius = 8, fill = "surface_container/0.5" }, children)
end

local function model_bar_node()
  local models = view.models or {}
  local ids = models.ids or {}
  return ui.row({ align = "center", gap = 6 }, {
    ui.select({
      options = ids,
      selectedIndex = modelIdx,
      flexGrow = 1,
      placeholder = noctalia.tr("panel.no_model_selected"),
      onChange = "onModelChange",
      controlSize = "sm",
    }),
    ui.label({ text = tostring(#ids), fontSize = 10, color = "on_surface/0.5" }),
  })
end

local function make_model_button(model_id, label_text, selected)
  return ui.button({
    key = "model-" .. model_id,
    text = text.truncate(label_text, 56),
    variant = selected and "secondary" or "ghost",
    contentAlign = "start",
    controlSize = "sm",
    tooltip = model_id,
    onClick = function()
      onPickModel(model_id)
    end,
  })
end

local function picker_nodes()
  local models = view.models or {}
  local ids = models.ids or {}
  local tools_set = models.tools or {}
  local tools_known = models.tools_known == true
  local pattern = trim(view.filter)

  -- A catalogue can carry thousands of ids and every render walks all of them,
  -- so the unfiltered path keeps the ids themselves instead of building a table
  -- per model: this runs inside the same 25 ms per-call budget as everything
  -- else the host calls.
  local matched, scores = {}, {}
  for _, id in ipairs(ids) do
    local keep = (not view.filter_free or providers.looks_free(id))
      and (not view.filter_tools or tools_set[id] == true)
    if keep then
      if pattern == "" then
        table.insert(matched, id)
      else
        local score = noctalia.fuzzyScore(pattern, id)
        if score ~= nil then
          scores[id] = score
          table.insert(matched, id)
        end
      end
    end
  end
  if pattern ~= "" then
    table.sort(matched, function(a, b)
      return (scores[a] or 0) > (scores[b] or 0)
    end)
  end

  local rows = {}
  for index = 1, #matched do
    local id = matched[index]
    local badges = {}
    if providers.looks_free(id) then
      table.insert(badges, noctalia.tr("badge.free"))
    end
    if tools_set[id] then
      table.insert(badges, noctalia.tr("badge.tools"))
    end
    local label = id
    if #badges > 0 then
      label = label .. "  ·  " .. table.concat(badges, " ")
    end
    table.insert(rows, make_model_button(id, label, id == tostring(view.info.model or "")))
  end
  if #rows == 0 then
    table.insert(rows, ui.column({ padding = 6 }, {
      ui.label({
        text = #ids == 0 and noctalia.tr("panel.no_models") or noctalia.tr("panel.no_matches"),
        fontSize = 11,
        color = "on_surface/0.6",
      }),
    }))
  end

  local footer = {}
  if models.error ~= nil then
    table.insert(footer, ui.label({ text = tostring(models.error), fontSize = 10, color = "error" }))
  end
  if models.loading == true then
    table.insert(footer, ui.label({ text = noctalia.tr("panel.loading"), fontSize = 10, color = "on_surface/0.6" }))
  end

  return ui.column({ gap = 6, padding = 8, radius = 8, fill = "surface_container/0.4" }, nodes(
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "model-filter",
        value = view.filter,
        placeholder = noctalia.tr("panel.filter_placeholder"),
        controlSize = "sm",
        flexGrow = 1,
        focus = true,
        onChange = "onFilterChange",
        onSubmit = "onUseTypedId",
      }),
      ui.button({
        text = noctalia.tr("panel.use_typed"),
        controlSize = "sm",
        enabled = pattern ~= "",
        tooltip = noctalia.tr("panel.use_typed_tooltip"),
        onClick = "onUseTypedId",
      }),
    }),
    ui.row({ gap = 6, align = "center" }, nodes(
      ui.button({
        text = noctalia.tr("panel.filter_free"),
        controlSize = "sm",
        selected = view.filter_free,
        onClick = "onToggleFree",
      }),
      tools_known and ui.button({
        text = noctalia.tr("panel.filter_tools"),
        controlSize = "sm",
        selected = view.filter_tools,
        onClick = "onToggleTools",
      }) or nil,
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = noctalia.tr("panel.refresh_hint"), fontSize = 10, color = "on_surface/0.45" })
    )),
    ui.scroll({ height = 200, radius = 6, fill = "surface/0.5" }, {
      ui.column({ gap = 2 }, rows),
    }),
    #footer > 0 and ui.column({ gap = 2 }, footer) or nil
  ))
end

-- A user bubble that is only right-aligned is measured without an exact width,
-- so code blocks inside it get no wrap budget. Detect them to stretch that
-- bubble to the transcript width.
local function contains_code_block(markdown)
  for _, seg in ipairs(text.split_markdown_code_blocks(markdown or "")) do
    if seg.is_code then
      return true
    end
  end
  return false
end

-- Build a fenced code block from native controls instead of `ui.markdown`.
-- The host's markdown view does not track code labels as wrappable, so a long
-- line measured at its intrinsic width and overflowed the panel; a stretched
-- `ui.label` receives the parent width budget and wraps instead.
local function code_block_node(seg, msg_index, seg_index)
  return ui.column({
    key = "code-" .. msg_index .. "-" .. seg_index,
    gap = 4,
    padding = 8,
    radius = 6,
    fill = "surface_container_low",
    align = "stretch",
  }, {
    ui.row({ align = "center", justify = "space_between", gap = 6 }, {
      ui.label({ text = trim(seg.lang or ""), fontSize = 10, color = "on_surface_variant/0.7" }),
      ui.button({
        glyph = "copy",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.copy_code_block"),
        onClick = function()
          onCopyCodeBlock(seg.code)
        end,
      }),
    }),
    ui.label({
      text = seg.code,
      fontFamily = "monospace",
      fontSize = 11,
      color = "on_surface_variant",
    }),
  })
end

-- Render markdown and inject copy buttons for each fenced code block.
-- Returns a column of alternating markdown segments and code blocks.
local function render_markdown_with_code_copy(markdown, msg_index)
  if trim(markdown) == "" then
    return ui.label({ text = "", fontSize = 12 })
  end
  local segments = text.split_markdown_code_blocks(markdown)
  local children = {}
  for seg_index, seg in ipairs(segments) do
    if seg.is_code then
      table.insert(children, code_block_node(seg, msg_index, seg_index))
    else
      if trim(seg.text) ~= "" then
        table.insert(children, ui.markdown({ text = seg.text }))
      end
    end
  end
  if #children == 0 then
    return ui.label({ text = "", fontSize = 12 })
  end
  return ui.column({ gap = 4 }, children)
end

local function message_node(index, message)
  local role = message.role
  local role_text, role_color = role_style(role)
  local is_user = role == "user"
  local _is_assistant = role == "assistant" -- kept for readability
  local is_tool = role == "tool"
  local is_error = role == "error"

  -- A right-aligned bubble has no exact width during measurement, so wrapping
  -- content would overflow. Stretch user messages that carry code so the block
  -- can wrap at the transcript width.
  local user_has_code = is_user and contains_code_block(message.content or "")

  local header_children = {
    ui.label({ text = role_text, fontSize = 11, fontWeight = "bold", color = role_color }),
    ui.label({
      text = noctalia.formatTime("{:%H:%M}", message.ts),
      fontSize = 10,
      color = "on_surface/0.45",
      flexGrow = 1,
    }),
  }

  if is_tool then
    table.insert(header_children, ui.label({
      text = tostring(message.name or ""),
      fontSize = 10,
      color = "on_surface/0.5",
    }))
  end
  if not is_tool then
    table.insert(header_children, ui.button({
      glyph = "copy",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.copy"),
      onClick = function()
        onCopyMessage(index)
      end,
    }))
  end

  local body = {}
  local expanded_key = "message-" .. tostring(index)
  if is_tool then
    table.insert(body, ui.row({ align = "center", gap = 6 }, {
      ui.label({
        text = tostring(message.summary or noctalia.tr("role.tool")),
        fontSize = 11,
        color = "on_surface/0.6",
        flexGrow = 1,
      }),
      ui.button({
        text = view.expanded[expanded_key] and noctalia.tr("panel.hide") or noctalia.tr("panel.show"),
        controlSize = "sm",
        variant = "ghost",
        onClick = function()
          onToggleExpand(expanded_key)
        end,
      }),
    }))
    if view.expanded[expanded_key] then
      table.insert(body, ui.label({ text = text.truncate(message.content or "", 4000), fontSize = 11 }))
    end
  elseif is_error then
    table.insert(body, ui.label({ text = message.content or "", fontSize = 12, color = "error" }))
  elseif role == "assistant" and trim(message.content or "") == "" and message.tool_calls ~= nil then
    table.insert(body, ui.label({
      text = tostring(message.summary or noctalia.tr("panel.tool_calls", { count = #message.tool_calls })),
      fontSize = 11,
      color = "on_surface/0.7",
    }))
  else
    table.insert(body, render_markdown_with_code_copy(message.content or "", index))
  end

  if message.reasoning ~= nil and trim(message.reasoning) ~= "" then
    table.insert(body, ui.label({
      text = noctalia.tr("panel.reasoning", { text = text.one_line(message.reasoning, 240) }),
      fontSize = 10,
      color = "on_surface/0.5",
      maxLines = 3,
    }))
  end
  if message.stopped == true then
    table.insert(body, ui.label({ text = noctalia.tr("panel.stopped"), fontSize = 10, color = "on_surface/0.6" }))
  end
  if message.notice ~= nil then
    table.insert(body, ui.label({ text = tostring(message.notice), fontSize = 10, color = "on_surface/0.7" }))
  end
  local usage = usage_line(message)
  if usage ~= nil then
    table.insert(body, ui.label({ text = usage, fontSize = 10, color = "on_surface/0.45" }))
  end

  local bubble_fill = is_user and "primary/0.08" or "surface_container/0.4"
  local bubble_props = { gap = 2, padding = 10, radius = 16, fill = bubble_fill }
  if not is_user then
    bubble_props.flexGrow = 1
  end
  local bubble = ui.column(bubble_props, nodes(
    ui.row({ align = "center", gap = 6 }, header_children),
    table.unpack(body, 1, math.min(#body, 12))
  ))

  local bubble_align = (is_user and not user_has_code) and "end" or "stretch"
  return ui.column({ align = bubble_align, gap = 4 }, {
    bubble,
  })
end

local function streaming_node()
  local header = ui.row({ align = "center", gap = 6 }, {
    ui.label({ text = noctalia.tr("role.assistant"), fontSize = 11, fontWeight = "bold", color = "primary" }),
    ui.glyph({ name = "loader", size = 12, color = "on_surface/0.5" }),
    ui.label({ text = noctalia.tr("status." .. tostring(view.status)), fontSize = 10, color = "on_surface/0.45", flexGrow = 1 }),
  })
  local stream = view.stream or {}
  local body_node
  if trim(stream.content or "") ~= "" then
    -- Streaming content doesn't have a fixed index for code-copy, but we pass 0 and render inline
    body_node = render_markdown_with_code_copy(stream.content, 0)
  elseif trim(stream.reasoning or "") ~= "" then
    body_node = ui.label({
      text = noctalia.tr("panel.reasoning", { text = text.one_line(stream.reasoning, 240) }),
      fontSize = 10,
      color = "on_surface/0.5",
    })
  else
    body_node = ui.label({ text = noctalia.tr("panel.waiting_tokens"), fontSize = 11, color = "on_surface/0.5" })
  end
  return ui.row({ align = "start", gap = 8 }, {
    ui.column({ gap = 2, flexGrow = 1, padding = 10, radius = 16, fill = "surface_container/0.4" }, nodes(header, body_node)),
  })
end

local function approval_node()
  local pending = view.pending
  if pending == nil then
    return nil
  end
  local children = {
    ui.row({ align = "center", gap = 6 }, {
      ui.glyph({ name = "alert-triangle", size = 14, color = "primary" }),
      ui.label({ text = tostring(pending.title or ""), fontSize = 12, fontWeight = "bold", flexGrow = 1 }),
      ui.label({
        text = string.format("%d/%d", pending.position or 1, pending.total or 1),
        fontSize = 10,
        color = "on_surface/0.5",
      }),
    }),
    ui.label({
      text = text.truncate(tostring(pending.body or ""), 600),
      fontSize = 11,
      fontFamily = "monospace",
    }),
  }
  if pending.blocked ~= nil then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.blocked", { pattern = tostring(pending.blocked) }),
      fontSize = 11,
      color = "error",
    }))
    table.insert(children, ui.row({ gap = 6 }, {
      ui.button({ text = noctalia.tr("panel.deny"), variant = "destructive", controlSize = "sm", onClick = "onDeny" }),
    }))
  else
    table.insert(children, ui.row({ gap = 6 }, {
      ui.button({ text = noctalia.tr("panel.approve"), variant = "primary", controlSize = "sm", onClick = "onApprove" }),
      ui.button({ text = noctalia.tr("panel.deny"), variant = "destructive", controlSize = "sm", onClick = "onDeny" }),
    }))
  end
  return ui.column({ gap = 6, padding = 8, radius = 8, fill = "surface_container/0.6" }, children)
end

local function test_node()
  local test = view.test
  if test == nil then
    return nil
  end
  local children = {
    ui.row({ align = "center", gap = 6 }, {
      ui.glyph({ name = test.ok and "check" or "alert-triangle", size = 13, color = test.ok and "primary" or "error" }),
      ui.label({ text = noctalia.tr("panel.test_result"), fontSize = 11, fontWeight = "bold", flexGrow = 1 }),
    }),
  }
  for _, line in ipairs(test.lines or {}) do
    table.insert(children, ui.label({
      text = (line:sub(1, 1) == "!" and line:sub(3) or line),
      fontSize = 10,
      color = line:sub(1, 1) == "!" and "error" or "on_surface/0.7",
    }))
  end
  return ui.column({ gap = 2, padding = 8, radius = 8, fill = "surface_container/0.4" }, children)
end

local function composer_node()
  local busy = view.status == "thinking" or view.status == "streaming" or view.status == "waiting"
  local children = {
    ui.input({
      key = "composer-" .. tostring(view.composer_gen),
      placeholder = busy and noctalia.tr("panel.placeholder_busy") or noctalia.tr("panel.placeholder"),
      multiline = true,
      submitOnEnter = true,
      flexGrow = 1,
      height = 64,
      controlSize = "sm",
      -- focus only applies when the control is created, so a fresh key after a
      -- send re-focuses the composer and typing can continue without a click
      focus = true,
      onChange = "onDraftChange",
      onSubmit = "onComposerSubmit",
    }),
  }
  if busy then
    table.insert(children, ui.button({
      glyph = "player-stop",
      variant = "destructive",
      tooltip = noctalia.tr("panel.stop"),
      onClick = "onStop",
    }))
  else
    table.insert(children, ui.button({
      glyph = "send",
      variant = "primary",
      tooltip = noctalia.tr("panel.send"),
      onClick = "onSendClick",
    }))
  end

  local hint = { noctalia.tr("panel.composer_hint") }
  if view.status == "waiting" then
    table.insert(hint, noctalia.tr("panel.composer_waiting"))
  end
  return ui.column({ gap = 4 }, {
    ui.row({ gap = 6, align = "end" }, children),
    ui.label({ text = table.concat(hint, "  ·  "), fontSize = 10, color = "on_surface/0.45" }),
  })
end

-- A cached node is rebuilt only when this signature changes.
local function message_signature(index, message)
  local usage = message.usage or {}
  return table.concat({
    tostring(index), tostring(message.role), tostring(message.content or ""),
    tostring(message.reasoning or ""), tostring(message.summary or ""),
    tostring(message.name or ""), tostring(message.notice or ""),
    tostring(message.stopped), tostring(message.tool_calls ~= nil),
    tostring(usage.total or ""), tostring(usage.cost or ""),
    tostring(view.expanded["message-" .. tostring(index)]),
  }, "\1")
end

local function history_node()
  local children = {}
  local count = #view.messages
  if count == 0 and not view.stream.active then
    table.insert(children, ui.column({ gap = 6, padding = 16 }, {
      ui.label({ text = noctalia.tr("panel.empty_title"), fontSize = 13, fontWeight = "bold", color = "on_surface/0.8" }),
      ui.label({ text = noctalia.tr("panel.empty_body"), fontSize = 11, color = "on_surface/0.6" }),
    }))
  else
    -- Show the newest messages first; older ones are one click away. This
    -- keeps a single render bounded no matter how long the session is.
    local first = math.max(1, count - view.visible_messages + 1)
    if first > 1 then
      table.insert(children, ui.row({ align = "center", gap = 6 }, {
        ui.label({
          text = noctalia.tr("panel.history_truncated", { count = first - 1 }),
          fontSize = 10,
          color = "on_surface/0.5",
          flexGrow = 1,
        }),
        ui.button({
          text = noctalia.tr("panel.show_more"),
          controlSize = "sm",
          variant = "ghost",
          onClick = "onShowMore",
        }),
      }))
    end
    for index = first, count do
      local message = view.messages[index]
      local signature = message_signature(index, message)
      local cached = message_node_cache[index]
      if cached == nil or cached.signature ~= signature then
        cached = { signature = signature, node = message_node(index, message) }
        message_node_cache[index] = cached
      end
      table.insert(children, cached.node)
    end
    if view.stream.active then
      table.insert(children, streaming_node())
    end
  end
  if view.stream.active and view.stream.content ~= nil and trim(view.stream.content) ~= "" then
    view.bottom_rev = (view.bottom_rev or 0) + 1
  end
  return ui.scroll({
    key = "history",
    flexGrow = 1,
    gap = 8,
    stickToBottom = true,
    scrollToBottomRev = view.bottom_rev or 0,
    padding = 4,
  }, children)
end

function render()
  if not view.open then
    return
  end
  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10, align = "stretch" }, nodes(
    header_node(),
    warning_node(),
    model_bar_node(),
    history_node(),
    approval_node(),
    test_node(),
    composer_node()
  )))
end

-- ---------------------------------------------------------------------------
-- State plumbing
-- ---------------------------------------------------------------------------

local function watch(key, apply)
  noctalia.state.watch(key, function(value)
    apply(value)
    render()
  end)
end

watch("hub.status", function(value)
  view.status = value or "idle"
end)
watch("hub.messages", function(value)
  view.messages = type(value) == "table" and value or {}
  if #view.messages == 0 then
    message_node_cache = {}
    view.visible_messages = 12
  end
end)
watch("hub.stream", function(value)
  view.stream = type(value) == "table" and value or { active = false }
end)
watch("hub.models", function(value)
  view.models = type(value) == "table" and value or {}
  updateModelIdx()
end)
watch("hub.pending", function(value)
  view.pending = type(value) == "table" and value or nil
end)
watch("hub.info", function(value)
  view.info = type(value) == "table" and value or {}
end)
watch("hub.test", function(value)
  view.test = type(value) == "table" and value or nil
end)

local existing = noctalia.state.get(KEY_COMMAND)
if type(existing) == "table" then
  view.command_seq = tonumber(existing.seq) or 0
end

function onOpen()
  view.open = true
  view.status = noctalia.state.get("hub.status") or "idle"
  view.messages = noctalia.state.get("hub.messages") or {}
  view.stream = noctalia.state.get("hub.stream") or { active = false }
  view.models = noctalia.state.get("hub.models") or {}
  view.pending = noctalia.state.get("hub.pending")
  view.info = noctalia.state.get("hub.info") or {}
  view.test = noctalia.state.get("hub.test")
  updateModelIdx()
  render()

  -- One list request per session when the panel first opens with nothing to
  -- pick from, and only when the configuration could actually answer.
  local info = view.info or {}
  local models = view.models or {}
  if not view.models_requested and #(models.ids or {}) == 0 and models.loading ~= true then
    view.models_requested = true
    if info.needs_endpoint ~= true and info.needs_key ~= true and info.key_error == nil then
      send("models")
    end
  end
end

function onClose()
  view.open = false
end
