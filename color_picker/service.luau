-- [[service]] entry:
-- owns all hyprpicker interaction, color history, and disk persistence.
-- Headless -- no UI. Widget and panel talk to it via onIpc, never touch
-- hyprpicker or the history file directly.
--!nocheck
--!nolint UnknownGlobal

--==============================================
-- CONSTANTS
--==============================================
local MAX_HISTORY = 7 -- selected color (index 1) + 6 recent
local STATE_DIR = "~/.local/state/noctalia/plugin-cache/color_picker"
local HISTORY_FILE = STATE_DIR .. "/history.json"

local tr_color_picker = noctalia.tr("color_picker")

local function tr(key: string, subst: table?): string
  if subst then
    return noctalia.tr(key, subst)
  end
  return noctalia.tr(key)
end

--==============================================
-- HYPRPICKER COMMAND BUILDER
--==============================================

-- Builds the hyprpicker argv from plugin settings. Returns an array of
-- shell-safe tokens; join with spaces before passing to noctalia.runAsync,
-- which only accepts a single command string.
local function buildHyprpickerArgs(): { string }
  local args = { "hyprpicker", "-a" }

  if noctalia.getConfig("hyprpicker-format") == "rgb" then
    table.insert(args, "-f")
    table.insert(args, "rgb")
  end

  if noctalia.getConfig("hyprpicker-cursor") then
    table.insert(args, "--cursor")
  end

  if noctalia.getConfig("hyprpicker-disable-preview") then
    table.insert(args, "--disable-preview")
  end

  if noctalia.getConfig("hyprpicker-lowercase") then
    table.insert(args, "--lowercase-hex")
  end

  if noctalia.getConfig("hyprpicker-no-zoom") then
    table.insert(args, "--no-zoom")
    return args -- returns earlier since next args apply only when zoom is enabled
  end

  local scale = noctalia.getConfig("hyprpicker-scale")
  if scale ~= nil then
    table.insert(args, "--scale=" .. tostring(scale))
  end

  local radius = noctalia.getConfig("hyprpicker-radius")
  if radius ~= nil then
    table.insert(args, "--radius=" .. tostring(radius))
  end

  return args
end

local function hyprpickerCommand(): string
  return table.concat(buildHyprpickerArgs(), " ")
end

local function parsePickerOutput(output: string): string?
  -- Tries Hex first
  local hex = output:match("#%x%x%x%x%x%x")
  if hex then
    -- Garante que o retorno é maiúsculo
    return hex:upper()
  end

  -- Then tries RGB
  local r, g, b = output:match("(%d+)%s+(%d+)%s+(%d+)")
  if r and g and b then
    -- Usa %02X (X MAIÚSCULO) para retornar Hex maiúsculo
    return string.format("#%02X%02X%02X", tonumber(r), tonumber(g), tonumber(b))
  end

  return nil
end

local function formatRgb(hex: string): string
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  return string.format("rgb(%d, %d, %d)", r, g, b)
end

--==============================================
-- STATE MODEL
--
-- selectedColor / selectedOpacity: ephemeral, what the panel is currently
-- showing. Set here on every successful pick; also updated by the panel
-- itself for pure-UI interactions (history swatch click, field edit,
-- opacity slider) that don't touch hyprpicker or disk.
--
-- colorHistory: persisted list (index 1 = most recently committed color).
-- Only mutated by pushCurrentColor(), called on immediate-commit picks
-- (widget right-click) and on "commit" (panel close).
--==============================================

local function setSelected(hex: string, opacity: number)
  noctalia.state.set("selectedColor", hex)
  noctalia.state.set("selectedOpacity", opacity)
end

-- Moves (or inserts) a color to the front of colorHistory, capped at
-- MAX_HISTORY entries. Memory only -- callers decide when to persist.
local function pushCurrentColor(hex: string, opacity: number)
  hex = hex:upper() -- Garante o padrão maiúsculo
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
  local content = noctalia.readFile(HISTORY_FILE)
  if content == nil or content == "" then return end

  local decoded = noctalia.json.decode(content)
  if type(decoded) ~= "table" then return end

  noctalia.state.set("colorHistory", decoded)
end

local function saveHistoryToDisk()
  local history = noctalia.state.get("colorHistory") or {}
  local encoded = noctalia.json.encode(history)
  if encoded ~= nil then
    noctalia.writeFile(HISTORY_FILE, encoded)
  end
end

--==============================================
-- PICKING
--==============================================

-- Runs hyprpicker and invokes onResult(hex) on success. onResult is nil-safe
-- to call with nil (caller decides what "no result" means for that flow).
local function runPicker(onResult: (string?, string?) -> ())
  if not noctalia.commandExists("hyprpicker") then
    noctalia.notifyError(tr_color_picker, tr("hyprpicker_not_installed"))
    onResult(nil, nil)
    return
  end

  noctalia.runAsync(hyprpickerCommand(), function(result)
    if result.exitCode ~= 0 then
      onResult(nil, nil)
      return
    end

    local hex = parsePickerOutput(result.stdout or "")
    if hex == nil then
      noctalia.notifyError(tr_color_picker, tr("could_not_parse"))
      onResult(nil, nil)
      return
    end

    local copyText = hex
    if noctalia.getConfig("hyprpicker-format") == "rgb" then
      copyText = formatRgb(hex)
    elseif noctalia.getConfig("hyprpicker-lowercase") then
      copyText = hex:lower()
    end

    noctalia.copyToClipboard(copyText, "text/plain")
    onResult(hex, copyText)
  end)
end

--==============================================
-- IPC
--
-- "pick"        - immediate commit (widget right-click). Picks, pushes to
--                 history, saves to disk right away.
-- "pick-panel"  - panel's own pick button. Picks and updates the selection
--                 only; history/disk are untouched until "commit".
-- "commit"      - panel is closing. payload = "<hex>:<opacity>", the
--                 selection at close time. Pushes it to history and saves.
--==============================================

local function handlePick()
  runPicker(function(hex, copyText)
    if hex == nil then return end

    setSelected(hex, 1)
    pushCurrentColor(hex, 1)
    saveHistoryToDisk()
    noctalia.notify(tr_color_picker, tr("color_picked", { color = copyText }))
  end)
end

local function handlePickFromPanel()
  runPicker(function(hex, copyText)
    if hex == nil then return end

    setSelected(hex, 1)
    noctalia.notify(tr_color_picker, tr("color_picked", { color = copyText }))
  end)
end

local function handleCommit(payload: string?)
  if payload == nil then return end

  local hex, opacityStr = payload:match("^(#%x%x%x%x%x%x):([%d%.]+)$")
  if hex == nil then return end

  pushCurrentColor(hex, tonumber(opacityStr) or 1)
  saveHistoryToDisk()
end

-- Opens Noctalia's native color picker dialog (canvas + hue slider).
-- Only updates the selection, same as the hyprpicker panel button --
-- history commit still happens on panel close, not here. The panel
-- re-renders on its own via noctalia.state.watch("selectedColor", ...).
local function handleNativePicker()
  local current = noctalia.state.get("selectedColor") or "#FFFFFF"
  local accepted = noctalia.openColorPicker(current, function(color)
    if color == nil then
      return
    end

    local copyText = color
    if noctalia.getConfig("hyprpicker-format") == "rgb" then
      copyText = formatRgb(color)
    elseif noctalia.getConfig("hyprpicker-lowercase") then
      copyText = color:lower()
    end
    noctalia.notify(tr_color_picker, tr("color_picked", { color = copyText }))
    setSelected(color, noctalia.state.get("selectedOpacity") or 1)
    pushCurrentColor(color, 1)
    saveHistoryToDisk()
  end)

  if not accepted then
    noctalia.notify(tr_color_picker, tr("picker_already_open"))
  end
end

function onIpc(event: string, payload: string?)
  if event == "pick" then
    handlePick()
  elseif event == "picker-dialog" then
    handleNativePicker()
  elseif event == "pick-panel" then
    handlePickFromPanel()
  elseif event == "commit" then
    handleCommit(payload)
  end
end

--==============================================
-- BOOT (runs once at load)
--==============================================

noctalia.mkdirAll(STATE_DIR)
loadHistoryFromDisk()

local bootHistory = noctalia.state.get("colorHistory") or {}
local bootTop = bootHistory[1]
if bootTop ~= nil then
  setSelected(bootTop.hex, bootTop.opacity or 1)
end