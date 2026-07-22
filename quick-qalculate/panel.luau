local MAX_HISTORY = 30

local inputText = ""
local calculating = false
local submittedText = ""
local resultText = ""
local answerText = ""
local warningText = ""
local errorText = ""
local expressionText = ""
local history = {}

local HOME = noctalia.getenv("HOME") or ""
local HISTORY_DIR = HOME .. "/.config/quick-qalculate"
local HISTORY_PATH = HISTORY_DIR .. "/history.json"

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function clampHistory()
  if #history > MAX_HISTORY then
    history = { table.unpack(history, 1, MAX_HISTORY) }
  end
end

local function loadHistory()
  local data, _ = noctalia.readFile(HISTORY_PATH)
  if data then
    local decoded = noctalia.json.decode(data)
    if type(decoded) == "table" then
      history = decoded
      clampHistory()
    end
  end
end

local function saveHistory()
  clampHistory()
  noctalia.mkdirAll(HISTORY_DIR)
  noctalia.writeFile(HISTORY_PATH, noctalia.json.encode(history, true))
end

local function addToHistory()
  table.insert(history, 1, { expression = expressionText, result = answerText })
  clampHistory()
  saveHistory()
  render()
end

local function clearResults()
  resultText = ""
  answerText = ""
  warningText = ""
  errorText = ""
  expressionText = ""
end

local function parseQalcOutput(output)
  clearResults()
  local trimmed = noctalia.string.trim(output)
  if trimmed == "" then
    return
  end

  local resultLine = trimmed
  local newlinePos = trimmed:find("\n")
  if newlinePos then
    local firstLine = noctalia.string.trim(trimmed:sub(1, newlinePos - 1))
    resultLine = noctalia.string.trim(trimmed:sub(newlinePos + 1))
    if firstLine:lower():match("^warning") then
      warningText = noctalia.string.trim(firstLine:sub(9))
    elseif firstLine:lower():match("^error") then
      errorText = noctalia.string.trim(firstLine:sub(7))
    end
  end

  if resultLine == "" then
    return
  end

  local expr, val = resultLine:match("^(.-)%s*≈%s*(.-)$")
  if not (expr and val) then
    expr, val = resultLine:match("^(.-)%s*=%s*(.-)$")
  end
  if expr and val then
    expressionText = noctalia.string.trim(expr)
    local v = noctalia.string.trim(val)
    if v:match("^≈ ") then
      v = v:sub(3)
    elseif v:match("^approx%. ") then
      v = v:sub(9)
    end
    answerText = v
    resultText = resultLine
  else
    resultText = resultLine
  end
end

function onOpen(_context)
  inputText = ""
  calculating = false
  clearResults()
  loadHistory()
  render()
end

function onInputChange(value)
  inputText = value
  if value == "" then
    clearResults()
    render()
    return
  end

  if calculating then
    return
  end

  local function generateQalcCommand(inputText)
    local command = { "qalc" }

    if noctalia.getConfig("unicode") then
      table.insert(command, "-u8")
    else
      table.insert(command, "+u8")
    end

    table.insert(command, "-s 'update exchange rates 1'")
    table.insert(command, "-s 'decimal comma off'")

    table.insert(command, shellQuote(value))

    return table.concat(command, " ")
  end

  local function onQalcResult(res)
    calculating = false
    if inputText ~= value then
      if inputText ~= "" then
        onInputChange(inputText)
      end
      return
    end
    if res and res.stdout then
      parseQalcOutput(res.stdout)
      if inputText == submittedText and inputText ~= "" and answerText ~= "" then
        submittedText = ""
        addToHistory()
        return
      end
    else
      clearResults()
      errorText = "qalc failed"
    end
    render()
  end

  calculating = true
  local ok = noctalia.runAsync( generateQalcCommand(), onQalcResult )

  if not ok then
    calculating = false
    clearResults()
    errorText = "failed to start qalc"
    render()
  end
end

function onInputSubmit(value)
  inputText = value
  if inputText ~= "" then
    if answerText ~= "" then
      addToHistory()
    else
      submittedText = value
    end
  end
end

function onCopyResult()
  if answerText ~= "" then
    noctalia.copyToClipboard(answerText, "text/plain")
  elseif resultText ~= "" then
    noctalia.copyToClipboard(resultText, "text/plain")
  end
end

function onClearHistory()
  history = {}
  saveHistory()
  render()
end

function onCloseClicked()
  panel.close()
end

function render()
  local historyItems = {}
  for idx, entry in ipairs(history) do
    local i = idx - 1
    table.insert(historyItems,
      ui.row({ gap = 8, align = "center", key = `h{i}`, fill = "surface_variant", radius = 8, paddingH = 12 }, {
        ui.label({
          text = `{entry.expression}`,
          maxLines = 1,
          color = "secondary",
        }),
        ui.label({
          text = "=",
          color = "on_surface_variant",
        }),
        ui.label({
          text = `{entry.result}`,
          flexGrow = 1,
          maxLines = 1,
          color = "tertiary",
        }),
        ui.button({ glyph = "copy", variant = "ghost", onClick = `onCopy_{i}` }),
        ui.button({ glyph = "trash", variant = "ghost", onClick = `onRemove_{i}` }),
      }))
  end
  if #history > 0 then
    table.insert(historyItems, ui.button({
      text = "Clear history",
      variant = "ghost",
      onClick = "onClearHistory",
    }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.input({
      key = "input",
      placeholder = noctalia.tr("expression_prompt"),
      focus = true,
      onChange = "onInputChange",
      onSubmit = "onInputSubmit",
    }),

    ui.row({ gap = 8, align = "center", height = 28 }, {
      ui.label({
        text = resultText,
        color = "primary",
        flexGrow = 1,
      }),
      ui.button({ glyph = "copy", variant = "ghost", onClick = "onCopyResult", visible = answerText ~= "" }),
    }),

    ui.label({
      text = warningText,
      color = "secondary",
      visible = warningText ~= "",
    }),

    ui.label({
      text = errorText,
      color = "error",
      visible = errorText ~= "",
    }),

    ui.scroll({ flexGrow = 1, gap = 6 }, {
      ui.column({ gap = 6, align = "stretch" }, historyItems),
    }),
  }))
end

do
  local function c(i)
    return function()
      local e = history[i]
      if e then noctalia.copyToClipboard(e.result, "text/plain") end
    end
  end
  local function r(i)
    return function()
      if history[i] then
        table.remove(history, i)
        saveHistory()
        render()
      end
    end
  end
  -- TODO: This is very ugly, but I can't found another way to dynamically bind functions to history rows,
  -- stole the solution from an official plugin.
  -- https://github.com/noctalia-dev/official-plugins/blob/4527b56f988369110e0b371cba88a911fb51e165/mpvpaper/panel.luau#L468
  onCopy_0 = c(1); onRemove_0 = r(1)
  onCopy_1 = c(2); onRemove_1 = r(2)
  onCopy_2 = c(3); onRemove_2 = r(3)
  onCopy_3 = c(4); onRemove_3 = r(4)
  onCopy_4 = c(5); onRemove_4 = r(5)
  onCopy_5 = c(6); onRemove_5 = r(6)
  onCopy_6 = c(7); onRemove_6 = r(7)
  onCopy_7 = c(8); onRemove_7 = r(8)
  onCopy_8 = c(9); onRemove_8 = r(9)
  onCopy_9 = c(10); onRemove_9 = r(10)
  onCopy_10 = c(11); onRemove_10 = r(11)
  onCopy_11 = c(12); onRemove_11 = r(12)
  onCopy_12 = c(13); onRemove_12 = r(13)
  onCopy_13 = c(14); onRemove_13 = r(14)
  onCopy_14 = c(15); onRemove_14 = r(15)
  onCopy_15 = c(16); onRemove_15 = r(16)
  onCopy_16 = c(17); onRemove_16 = r(17)
  onCopy_17 = c(18); onRemove_17 = r(18)
  onCopy_18 = c(19); onRemove_18 = r(19)
  onCopy_19 = c(20); onRemove_19 = r(20)
  onCopy_20 = c(21); onRemove_20 = r(21)
  onCopy_21 = c(22); onRemove_21 = r(22)
  onCopy_22 = c(23); onRemove_22 = r(23)
  onCopy_23 = c(24); onRemove_23 = r(24)
  onCopy_24 = c(25); onRemove_24 = r(25)
  onCopy_25 = c(26); onRemove_25 = r(26)
  onCopy_26 = c(27); onRemove_26 = r(27)
  onCopy_27 = c(28); onRemove_27 = r(28)
  onCopy_28 = c(29); onRemove_28 = r(29)
  onCopy_29 = c(30); onRemove_29 = r(30)
end
