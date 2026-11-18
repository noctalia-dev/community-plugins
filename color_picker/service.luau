--!nonstrict
local picker = require("./picker.luau")

local MAX_HISTORY = 12
local PERSISTENT_DIR = noctalia.pluginDataDir()
local HISTORY_FILE = PERSISTENT_DIR .. "/history.json"
local SELECTED_FILE = PERSISTENT_DIR .. "/selected.json"
local tr_color_picker = noctalia.tr("color_picker")

local function tr(key, subst)
  if subst then
    return noctalia.tr(key, subst)
  end
  return noctalia.tr(key)
end

local function customNotify(title: string, body: string?)
  if noctalia.getConfig("notify-on-copy") == false then
    return
  end
  noctalia.notify(title, body)
end

local function setSelected(hex, opacity)
  noctalia.state.set("selectedColor", hex)
  noctalia.state.set("selectedOpacity", opacity)
end

local function pushCurrentColor(hex, opacity)
  hex = hex:upper()
  local history = noctalia.state.get("colorHistory") or {}
  for i, entry in ipairs(history) do
    if entry.hex and entry.hex:upper() == hex then
      table.remove(history, i)
      break
    end
  end
  table.insert(history, 1, { hex = hex, opacity = opacity })
  while #history > MAX_HISTORY do
    table.remove(history)
  end
  noctalia.state.set("colorHistory", history)
end

local function loadHistoryFromDisk()
  local raw = noctalia.readFile(HISTORY_FILE)
  if raw == nil or raw == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end
  noctalia.state.set("colorHistory", decoded)
end

local function saveHistoryToDisk()
  local history = noctalia.state.get("colorHistory") or {}
  local encoded = noctalia.json.encode(history)
  if encoded ~= nil then
    noctalia.writeFile(HISTORY_FILE, encoded)
  end
end

local function loadSelectedFromDisk()
  local raw = noctalia.readFile(SELECTED_FILE)
  if raw == nil or raw == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" or decoded.hex == nil then
    return
  end
  setSelected(decoded.hex, decoded.opacity or 1)
end

local function saveSelectedToDisk()
  local hex = noctalia.state.get("selectedColor")
  if hex == nil then
    return
  end
  local opacity = tonumber(noctalia.state.get("selectedOpacity")) or 1
  local encoded = noctalia.json.encode({ hex = hex, opacity = opacity })
  if encoded ~= nil then
    noctalia.writeFile(SELECTED_FILE, encoded)
  end
end

local function handlePick()
  picker.runPicker(function(hex, copyText)
    if hex == nil then
      return
    end
    setSelected(hex, 1)
    pushCurrentColor(hex, 1)
    saveHistoryToDisk()
    customNotify(tr_color_picker, tr("color_picked", { color = copyText }))
  end)
end

local function handlePickFromPanel()
  picker.runPicker(function(hex, copyText)
    if hex == nil then
      return
    end
    setSelected(hex, 1)
    customNotify(tr_color_picker, tr("color_picked", { color = copyText }))
  end)
end

local function handlePushToHistory(payload)
  if payload == nil then
    return
  end
  local hex, opacityStr = payload:match("^(#%x%x%x%x%x%x):([%d%.]+)$")
  if hex == nil then
    return
  end
  pushCurrentColor(hex, tonumber(opacityStr) or 1)
  saveHistoryToDisk()
end

function onIpc(event, payload)
  if event == "pick" then
    handlePick()
  elseif event == "pick-panel" then
    handlePickFromPanel()
  elseif event == "push-to-history" then
    handlePushToHistory(payload)
  elseif event == "save-selected" then
    saveSelectedToDisk()
  end
end

function load()
  noctalia.mkdirAll(PERSISTENT_DIR)
  loadHistoryFromDisk()
  loadSelectedFromDisk()
end
load()
