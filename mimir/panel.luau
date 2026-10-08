local inputText = ""
local inputKey = 0
local modelIdx = 0

-- ui.scroll follow-scroll (plugin_api >= 21): stickToBottom pins the chat to the
-- newest message while the user is already at the bottom; onScroll reports when
-- they scroll away, and bumping scrollToBottomRev re-pins (after sending, not
-- while they are reading older messages).
local atBottom = true
local scrollRev = 0

-- Self-contained copy: the live clipboard write happens in the button's own
-- closure on message click, using the message index captured at that render.
-- Replaces the old "show message in a textarea" flow, which depended on a
-- mimir.copy_target watcher that no copy action ever read.
local function copyMessage(idx)
  local messages = noctalia.state.get("mimir.messages") or {}
  local msg = messages[idx]
  local content = type(msg) == "table" and msg.content or nil
  if type(content) ~= "string" or content == "" then return end
  if noctalia.copyToClipboard(content, "text/plain;charset=utf-8") then
    noctalia.notify("Mimir", "Message copied to clipboard.")
  else
    noctalia.notifyError("Mimir", "Failed to copy message.")
  end
end

local function toolCommand(toolCall)
  local fn = toolCall["function"]
  if not fn or type(fn.arguments) ~= "string" then return nil end
  local ok, args = pcall(noctalia.json.decode, fn.arguments)
  if ok and type(args) == "table" and type(args.command) == "string" then
    return args.command
  end
  return nil
end
function render()
  local models = noctalia.state.get("mimir.models") or {}
  local messages = noctalia.state.get("mimir.messages") or {}
  local status = noctalia.state.get("mimir.status") or "idle"
  local commandLog = noctalia.state.get("mimir.command_log") or {}
  local showCommands = noctalia.getConfig("show_commands") ~= false
  local commandsByToolCall = {}
  for _, entry in ipairs(commandLog) do
    commandsByToolCall[entry.tool_call_id] = entry.command
  end

  local statusColors = { idle = "on_surface/0.4", thinking = "primary", running_tool = "primary", searching = "primary", fetching = "primary", error = "error" }
  local statusTexts = { idle = "Ready", thinking = "Thinking...", running_tool = "Running command...", searching = "Searching web...", fetching = "Fetching page...", error = "Error" }

  local displayMsgs = {}
  for i, msg in ipairs(messages) do
    if msg.role ~= "system" and msg.role ~= "tool" then
      local isUser = msg.role == "user"
      local content = msg.content
      local hasText = type(content) == "string" and content:match("%S") ~= nil
      local contentNodes = {}
      if hasText then
        -- ui.markdown (plugin_api >= 21): the host parses and renders the
        -- markdown (headings, lists, code blocks, tables) and re-parses only
        -- when the text changes, so a growing chat stays cheap.
        table.insert(contentNodes, ui.markdown({ text = content, width = 380 }))
      end
      if msg.tool_calls then
        for _, toolCall in ipairs(msg.tool_calls) do
          local command = showCommands and (toolCommand(toolCall) or commandsByToolCall[toolCall.id])
          if command then
            table.insert(contentNodes, ui.column({ gap = 2, padding = 8, fill = "surface_variant", radius = 6 }, {
              ui.label({ text = "Command", fontSize = 11, color = "on_surface/0.5" }),
              ui.label({ text = "$ " .. command, fontSize = 12, color = "primary", maxWidth = 380 }),
            }))
          end
        end
      end
      if #contentNodes > 0 then
        table.insert(displayMsgs, ui.column({ key = "m" .. i, gap = 4, paddingH = 4, align = isUser and "end" or "start" }, {
          ui.row({ gap = 4, align = "center" }, {
            ui.label({ text = isUser and "You" or "Mimir", fontSize = 11, color = "on_surface/0.5" }),
            ui.button({ glyph = "copy", variant = "ghost", tooltip = "Copy message", onClick = function() copyMessage(i) end }),
          }),
          table.unpack(contentNodes),
        }))
      end
    end
  end

  local pendingTool = noctalia.state.get("mimir.pending_tool")
  if pendingTool and type(pendingTool) == "table" and pendingTool.commands then
    local approvalChildren = {
      ui.label({ text = "Mimir wants to run:", fontSize = 12, color = "on_surface" }),
    }
    for _, c in ipairs(pendingTool.commands) do
      table.insert(approvalChildren, ui.label({ text = c.command or "", fontSize = 12, color = "primary", maxWidth = 380 }))
    end
    table.insert(approvalChildren, ui.row({ gap = 8, align = "center" }, {
      ui.button({ text = "Approve", variant = "primary", onClick = "onApproveTool" }),
      ui.button({ text = "Deny", variant = "ghost", onClick = "onDenyTool" }),
    }))
    table.insert(displayMsgs, ui.column({ key = "tool-approval", gap = 8, padding = 12, fill = "surface_variant", radius = 8 }, approvalChildren))
  end

  local layout = {
    ui.row({ gap = 6, padding = 12, align = "center" }, {
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshModels" }),
      ui.select({ options = models, selectedIndex = modelIdx, flexGrow = 1, placeholder = "No models", onChange = "onModelChange" }),
    }),
    ui.separator({ thickness = 1, color = "surface_variant" }),
    ui.scroll({ flexGrow = 1, gap = 4, padding = 12, stickToBottom = true, onScroll = "onChatScroll", scrollToBottomRev = atBottom and scrollRev or nil }, displayMsgs),
    ui.separator({ thickness = 1, color = "surface_variant" }),
  }
  table.insert(layout, ui.row({ gap = 8, padding = { left = 12, right = 12, top = 8, bottom = 4 }, align = "center" }, {
    ui.input({ key = "msg-input-" .. inputKey, value = inputText, placeholder = "Ask me anything...", flexGrow = 1, focus = true, onChange = "onInputChange", onSubmit = "onSubmit", submitOnEnter = true }),
    ui.button({ glyph = "send", variant = "primary", onClick = "onSubmit" }),
  }))
  table.insert(layout, ui.row({ gap = 12, padding = { left = 12, right = 12, top = 4, bottom = 12 }, align = "center" }, {
    ui.label({ text = statusTexts[status] or "Ready", fontSize = 11, color = statusColors[status] or "on_surface/0.4" }),
    ui.button({ glyph = "eraser", variant = "ghost", onClick = "onClear" }),
  }))
  panel.render(ui.column({ flexGrow = 1, gap = 0, align = "stretch" }, layout))
end

function onModelChange(index, text)
  local models = noctalia.state.get("mimir.models") or {}
  local idx = tonumber(index)
  if idx == nil and text then
    for i, m in ipairs(models) do
      if m == text then
        idx = i - 1
        break
      end
    end
  end
  if idx ~= nil and models[idx + 1] then
    modelIdx = idx
    noctalia.state.set("mimir.model", models[idx + 1])
    render()
  end
end

function onClear()
  noctalia.state.set("mimir.clear", true)
end

function onRefreshModels()
  noctalia.state.set("mimir.refresh_models", true)
end

function onInputChange(v)
  inputText = type(v) == "table" and (v.value or "") or v or ""
end

function onSubmit(v)
  local text = v
  if type(text) == "table" then text = text.value end
  if type(text) ~= "string" or text == "" then text = inputText end
  inputText = ""
  if text and text ~= "" then
    inputKey += 1
    atBottom = true
    scrollRev += 1
    noctalia.state.set("mimir.status", "thinking")
    noctalia.state.set("mimir.input", text)
    render()
  end
end

noctalia.state.watch("mimir.messages", function()
  render()
end)

noctalia.state.watch("mimir.status", function()
  render()
end)

noctalia.state.watch("mimir.models", function()
  local models = noctalia.state.get("mimir.models") or {}
  local currentModel = noctalia.state.get("mimir.model") or ""
  modelIdx = 0
  for i, m in ipairs(models) do
    if m == currentModel then
      modelIdx = i - 1
      break
    end
  end
  render()
end)

noctalia.state.watch("mimir.pending_tool", function()
  render()
end)

noctalia.state.watch("mimir.command_log", function()
  render()
end)

function onApproveTool()
  noctalia.state.set("mimir.tool_approved", true)
end

function onDenyTool()
  noctalia.state.set("mimir.tool_denied", true)
end

function onChatScroll(offset, maxOffset)
  -- Both arrive as strings; at the bottom (or empty chat, max = 0) stay pinned.
  atBottom = tonumber(maxOffset) == 0 or tonumber(offset) >= tonumber(maxOffset) - 2
end

function onOpen()
  atBottom = true
  scrollRev += 1
  noctalia.state.set("mimir.refresh_models", true)
  render()
end
