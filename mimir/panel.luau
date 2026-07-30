local inputText = ""
local inputKey = 0

local function stripMarkdown(text)
  text = text:gsub("%*%*(.-)%*%*", "%1")
  text = text:gsub("%*(.-)%*", "%1")
  text = text:gsub("`(.-)`", "%1")
  text = text:gsub("%[([^%]]*)%]%(([^%)]+)%)", "%1 (%2)")
  text = text:gsub("^#+%s*(.-)$", "%1")
  return text
end

local function parseMessage(content)
  local nodes = {}
  local pos = 1
  while pos <= #content do
    local open = content:find("```", pos)
    if not open then
      table.insert(nodes, { type = "text", content = stripMarkdown(content:sub(pos)) })
      break
    end
    if open > pos then
      table.insert(nodes, { type = "text", content = stripMarkdown(content:sub(pos, open - 1)) })
    end
    local close = content:find("```", open + 3)
    if close then
      local raw = content:sub(open + 3, close - 1)
      local nl = raw:find("\n")
      if nl then raw = raw:sub(nl + 1) end
      table.insert(nodes, { type = "code", content = raw })
      pos = close + 3
    else
      table.insert(nodes, { type = "text", content = stripMarkdown(content:sub(open)) })
      break
    end
  end
  return nodes
end

function render()
  local models = noctalia.state.get("mimir.models") or {}
  local currentModel = noctalia.state.get("mimir.model") or ""
  local messages = noctalia.state.get("mimir.messages") or {}
  local status = noctalia.state.get("mimir.status") or "idle"

  local statusColors = { idle = "on_surface/0.4", thinking = "primary", error = "error" }
  local statusTexts = { idle = "Ready", thinking = "Thinking...", error = "Error" }

  local displayMsgs = {}
  for i, msg in ipairs(messages) do
    if msg.role ~= "system" then
      local isUser = msg.role == "user"
      local nodes = parseMessage(msg.content or "")
      local children = {
        ui.label({ text = isUser and "You" or "Mimir", fontSize = 11, color = "on_surface/0.5" }),
      }
      for _, node in ipairs(nodes) do
        if node.type == "text" then
          table.insert(children, ui.label({ text = node.content, fontSize = 13, color = isUser and "primary" or "on_surface", maxWidth = 380 }))
        elseif node.type == "code" then
          table.insert(children, ui.column({ fill = "surface_variant", padding = 8, maxWidth = 380 }, {
            ui.label({ text = node.content, fontSize = 12, color = "on_surface_variant" }),
          }))
        end
      end
      table.insert(displayMsgs, ui.column({ key = "m" .. i, gap = 4, paddingH = 4, align = isUser and "end" or "start" }, children))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 0, fill = "background", align = "stretch" }, {
    ui.row({ gap = 6, padding = 12, align = "center" }, {
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshModels" }),
      ui.select({ options = models, value = currentModel, flexGrow = 1, placeholder = "No models", onChange = "onModelChange" }),
    }),
    ui.separator({ thickness = 1, color = "surface_variant" }),
    ui.scroll({ flexGrow = 1, gap = 4, padding = 12, scrollBottom = true, key = "chat-" .. #messages }, displayMsgs),
    ui.separator({ thickness = 1, color = "surface_variant" }),
    ui.row({ gap = 8, padding = { left = 12, right = 12, top = 8, bottom = 4 }, align = "center" }, {
      ui.input({ key = "msg-input-" .. inputKey, value = inputText, placeholder = "Ask me anything...", flexGrow = 1, focus = true, onChange = "onInputChange", onSubmit = "onSubmit" }),
      ui.button({ glyph = "send", variant = "primary", onClick = "onSubmit" }),
    }),
    ui.row({ gap = 12, padding = { left = 12, right = 12, top = 4, bottom = 12 }, align = "center" }, {
      ui.label({ text = statusTexts[status] or "Ready", fontSize = 11, color = statusColors[status] or "on_surface/0.4" }),
      ui.button({ glyph = "eraser", variant = "ghost", size = 12, onClick = "onClear" }),
    }),
  }))
end

function onModelChange(value)
  local models = noctalia.state.get("mimir.models") or {}
  if type(value) == "number" then
    if models[value + 1] then noctalia.state.set("mimir.model", models[value + 1]) end
  elseif type(value) == "string" then
    for _, m in ipairs(models) do
      if m == value then noctalia.state.set("mimir.model", m) return end
    end
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
    noctalia.state.set("mimir.status", "thinking")
    noctalia.state.set("mimir.input", text)
    render()
  end
end

function update()
  render()
end

noctalia.state.watch("mimir.messages", function()
  render()
end)

noctalia.state.watch("mimir.status", function()
  render()
end)

noctalia.state.watch("mimir.models", function()
  render()
end)

noctalia.setUpdateInterval(500)

function onOpen()
  noctalia.state.set("mimir.refresh_models", true)
  render()
end
