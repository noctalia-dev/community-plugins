local inputText = ""
local inputKey = 0
local copyTarget = nil
local modelIdx = 0

noctalia.state.watch("mimir.copy_target", function(value)
  copyTarget = (value == -1) and nil or value
  render()
end)

local function mapUnicode(text, lowerBase, upperBase)
  local out = ""
  for i = 1, #text do
    local c = text:sub(i, i)
    local code = c:byte()
    if code >= 97 and code <= 122 then
      out = out .. utf8.char(code - 97 + lowerBase)
    elseif code >= 65 and code <= 90 then
      out = out .. utf8.char(code - 65 + upperBase)
    else
      out = out .. c
    end
  end
  return out
end

local function inlineMarkdown(text)
  text = text:gsub("%*%*%*([^%*]-)%*%*%*", function(s) return mapUnicode(s, 0x1D482, 0x1D468) end)
  text = text:gsub("%*%*([^%*]-)%*%*", function(s) return mapUnicode(s, 0x1D41A, 0x1D400) end)
  text = text:gsub("%*([^%*]-)%*", function(s) return mapUnicode(s, 0x1D44E, 0x1D434) end)
  text = text:gsub("~~([^~]-)~~", "%1")
  text = text:gsub("`(.-)`", "%1")
  text = text:gsub("%[([^%]]*)%]%(([^%)]+)%)", "%1 (%2)")
  return text
end

local function renderText(text, color, fontSize, fontWeight)
  return ui.label({ text = inlineMarkdown(text), fontSize = fontSize or 13, fontWeight = fontWeight, color = color, maxWidth = 380 })
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

local function parseMessage(content)
  local nodes = {}
  local lines = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  local i = 1
  local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
  end
  while i <= #lines do
    local line = lines[i]
    if line:find("^```") then
      local buf = {}
      local lang = line:sub(4)
      i = i + 1
      while i <= #lines and not lines[i]:find("^```") do
        table.insert(buf, lines[i])
        i = i + 1
      end
      i = i + 1
      table.insert(nodes, { type = "code", language = trim(lang), content = table.concat(buf, "\n") })
    elseif line:match("^#+") and line:gsub("#+", ""):match("%S") then
      local level, text = line:match("^(#+)%s*(.-)%s*$")
      level = #level
      text = text:gsub("#+%s*$", "")
      table.insert(nodes, { type = "heading", level = level, content = text })
      i = i + 1
    elseif line:match("^%s*[-*_]+%s*$") and #line:gsub("%s", "") >= 3 then
      table.insert(nodes, { type = "hr" })
      i = i + 1
    elseif line:match("^%s*>") then
      local buf = {}
      while i <= #lines and lines[i]:match("^%s*>") do
        local t = lines[i]:gsub("^%s*>%s?", "")
        if t == "" then t = " " end
        table.insert(buf, t)
        i = i + 1
      end
      table.insert(nodes, { type = "quote", content = table.concat(buf, " ") })
    elseif line:match("^%s*[-*+]%s+") or line:match("^%s*%d+[.)]%s+") then
      local items = {}
      while i <= #lines do
        local l = lines[i]
        local bullet = l:match("^%s*[-*+]%s+(.*)")
        local numbered = l:match("^%s*%d+[.)]%s+(.*)")
        if bullet then
          table.insert(items, { ordered = false, content = bullet })
          i = i + 1
        elseif numbered then
          table.insert(items, { ordered = true, content = numbered })
          i = i + 1
        else
          break
        end
      end
      table.insert(nodes, { type = "list", items = items })
    else
      local buf = {}
      while i <= #lines and not lines[i]:match("^```") and not (lines[i]:match("^#+") and lines[i]:gsub("#+", ""):match("%S"))
        and not (lines[i]:match("^%s*[-*_]+%s*$") and #lines[i]:gsub("%s", "") >= 3) and not lines[i]:match("^%s*>")
        and not lines[i]:match("^%s*[-*+]%s+") and not lines[i]:match("^%s*%d+[.)]%s+") do
        table.insert(buf, lines[i])
        i = i + 1
      end
      local para = table.concat(buf, "\n")
      if trim(para) ~= "" then
        table.insert(nodes, { type = "text", content = para })
      end
    end
  end
  return nodes
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
          table.insert(contentNodes, ui.column({ fill = "surface_variant", padding = 8, radius = 6 }, {
            ui.label({ text = node.content, fontSize = 12, color = "on_surface_variant" }),
          }))
        elseif node.type == "heading" then
          local sizes = { 17, 15, 14, 13, 13, 13 }
          table.insert(contentNodes, renderText(node.content, isUser and "primary" or "on_surface", sizes[node.level] or 13, "bold"))
        elseif node.type == "quote" then
          table.insert(contentNodes, ui.column({ fill = "surface_variant", padding = 8, radius = 4 }, {
            renderText(node.content, isUser and "primary" or "on_surface_variant", 12),
          }))
        elseif node.type == "hr" then
          table.insert(contentNodes, ui.separator({ thickness = 1, color = "surface_variant" }))
        elseif node.type == "list" then
          local listChildren = {}
          for n, item in ipairs(node.items) do
            local prefix = item.ordered and (n .. ". ") or "• "
            table.insert(listChildren, renderText(prefix .. item.content, isUser and "primary" or "on_surface"))
          end
          table.insert(contentNodes, ui.column({ gap = 2 }, listChildren))
        end
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

noctalia.state.watch("mimir.command_log", function()
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
