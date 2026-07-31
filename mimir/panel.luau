local inputText = ""
local inputKey = 0
local copyTarget = nil
local modelIdx = 0

noctalia.state.watch("mimir.copy_target", function(value)
  copyTarget = (value == -1) and nil or value
  render()
end)

local function renderText(text, color)
  text = text:gsub("%*%*(.-)%*%*", function(s)
    local bold = ""
    for i = 1, #s do
      local c = s:sub(i, i)
      local code = c:byte()
      if code >= 97 and code <= 122 then
        bold = bold .. utf8.char(code - 97 + 0x1D41A)
      elseif code >= 65 and code <= 90 then
        bold = bold .. utf8.char(code - 65 + 0x1D400)
      else
        bold = bold .. c
      end
    end
    return bold
  end)
  text = text:gsub("`(.-)`", "%1")
  text = text:gsub("%[([^%]]*)%]%(([^%)]+)%)", "%1 (%2)")
  text = text:gsub("^#+%s*", "")
  return ui.label({ text = text, fontSize = 13, color = color, maxWidth = 380 })
end

local function parseMessage(content)
  local nodes = {}
  local pos = 1
  while pos <= #content do
    local open = content:find("```", pos)
    if not open then
      table.insert(nodes, { type = "text", content = content:sub(pos) })
      break
    end
    if open > pos then
      table.insert(nodes, { type = "text", content = content:sub(pos, open - 1) })
    end
    local close = content:find("```", open + 3)
    if close then
      local raw = content:sub(open + 3, close - 1)
      local nl = raw:find("\n")
      if nl then raw = raw:sub(nl + 1) end
      table.insert(nodes, { type = "code", content = raw })
      pos = close + 3
    else
      table.insert(nodes, { type = "text", content = content:sub(open) })
      break
    end
  end
  return nodes
end

function render()
  local models = noctalia.state.get("mimir.models") or {}
  local messages = noctalia.state.get("mimir.messages") or {}
  local status = noctalia.state.get("mimir.status") or "idle"

  local statusColors = { idle = "on_surface/0.4", thinking = "primary", running_tool = "primary", error = "error" }
  local statusTexts = { idle = "Ready", thinking = "Thinking...", running_tool = "Running command...", error = "Error" }

  local displayMsgs = {}
  local copyContent = nil
  for i, msg in ipairs(messages) do
    if msg.role ~= "system" and msg.role ~= "tool" and msg.content then
      local isUser = msg.role == "user"
      local isCopying = copyTarget == i
      if isCopying then copyContent = msg.content end
      local nodes = parseMessage(msg.content or "")
      local contentNodes = {}
      for _, node in ipairs(nodes) do
        if node.type == "text" then
          table.insert(contentNodes, renderText(node.content, isUser and "primary" or "on_surface"))
        elseif node.type == "code" then
          table.insert(contentNodes, ui.column({ fill = "surface_variant", padding = 8, maxWidth = 380 }, {
            ui.label({ text = node.content, fontSize = 12, color = "on_surface_variant" }),
          }))
        end
      end
      table.insert(displayMsgs, ui.column({ key = "m" .. i, gap = 4, paddingH = 4, align = isUser and "end" or "start" }, {
        ui.row({ gap = 4, align = "center" }, {
          ui.label({ text = isUser and "You" or "Mimir", fontSize = 11, color = "on_surface/0.5" }),
          ui.button({ glyph = isCopying and "close" or "copy", variant = "ghost", onClick = function() noctalia.state.set("mimir.copy_target", isCopying and -1 or i) end }),
        }),
        table.unpack(contentNodes),
      }))
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
    ui.scroll({ flexGrow = 1, gap = 4, padding = 12 }, displayMsgs),
    ui.separator({ thickness = 1, color = "surface_variant" }),
  }
  if copyContent then
    table.insert(layout, ui.column({ flexGrow = 1, padding = 8, fill = "surface_variant" }, {
      ui.input({ key = "copy-area", multiline = true, value = copyContent, focus = true, flexGrow = 1, onChange = function() end }),
    }))
  end
  table.insert(layout, ui.row({ gap = 8, padding = { left = 12, right = 12, top = 8, bottom = 4 }, align = "center" }, {
    ui.input({ key = "msg-input-" .. inputKey, value = inputText, placeholder = "Ask me anything...", flexGrow = 1, focus = true, onChange = "onInputChange", onSubmit = "onSubmit" }),
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
    noctalia.state.set("mimir.copy_target", -1)
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
  if noctalia.state.get("mimir.pending_tool") then
    noctalia.state.set("mimir.copy_target", -1)
  end
  render()
end)

function onApproveTool()
  noctalia.state.set("mimir.tool_approved", true)
end

function onDenyTool()
  noctalia.state.set("mimir.tool_denied", true)
end

function onOpen()
  noctalia.state.set("mimir.refresh_models", true)
  render()
end
