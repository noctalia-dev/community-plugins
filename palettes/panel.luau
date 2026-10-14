--!nonstrict
-- Palette manager: your own palettes (saved) + built-in read-only palettes (shipped file).

local EDIT_GRACE = 60   -- seconds; reopen within this window and edit mode stays on

-- ---------- state ----------
local columns = 2
local palettes = {}     -- the user's palettes: editable, saved to the data dir
local builtin = {}      -- shipped in builtin.json: read-only, never saved
local current = 1       -- index into the combined list: user palettes first, then built-in
local defaultName = ""  -- "" means no default chosen
local newPalette, newName = "", ""
local nameRev, palRev = 0, 0
local pickedHex = "#ffffff"
local status, statusIsError = "", false
local editMode = false

local render -- declared early so the functions below can call it

-- ---------- combined list helpers ----------
local function count() return #palettes + #builtin end
local function isBuiltin(i) return i > #palettes end
local function palAt(i) return palettes[i] or builtin[i - #palettes] end

-- ---------- settings / storage ----------
local function readColumns()
  local n = tonumber(noctalia.getConfig("columns")) or 2
  columns = math.max(1, math.min(3, math.floor(n)))
end

local function path()
  local dir = noctalia.pluginDataDir() or ""
  return dir .. "/palettes.json"
end

local function builtinPath()
  local dir = noctalia.pluginDir() or ""
  return dir .. "/builtin.json"
end

local function prefsPath()
  local dir = noctalia.pluginDataDir() or ""
  return dir .. "/prefs.json"
end

local function setStatus(msg, isError)
  status, statusIsError = msg, isError or false
end

local function save()
  local text, encodeErr = noctalia.json.encode(palettes)
  if not text then
    setStatus(`Encode failed: {encodeErr}`, true)
    return
  end
  local ok, err = noctalia.writeFile(path(), text)
  if not ok then setStatus(`Save failed: {err}`, true) end
end

local function savePrefs()
  local text = noctalia.json.encode({ defaultPalette = defaultName })
  if not text then return end
  local ok, err = noctalia.writeFile(prefsPath(), text)
  if not ok then setStatus(`Couldn't save default: {err}`, true) end
end

-- returns the decoded table, or nil if the file is missing or invalid
local function readJson(p)
  local raw = noctalia.readFile(p)
  if not raw then return nil end
  local data = noctalia.json.decode(raw)
  if type(data) ~= "table" then return nil end
  return data
end

-- position of the first palette with this name in the combined list, or nil
local function indexByName(name)
  for i = 1, count() do
    if palAt(i).name == name then return i end
  end
  return nil
end

-- "base", or "base 2", "base 3", ... until the name is free
local function uniqueName(base)
  local name, n = base, 1
  while indexByName(name) do
    n += 1
    name = `{base} {n}`
  end
  return name
end

local function load()
  palettes = readJson(path()) or {}          -- fresh install: no saved file -> empty
  builtin = readJson(builtinPath()) or {}
  if #builtin == 0 then setStatus("Couldn't read builtin.json", true) end
  local prefs = readJson(prefsPath())
  defaultName = (prefs and prefs.defaultPalette) or ""
  current = indexByName(defaultName) or 1    -- falls back to the first palette
end

local function setEditMode(on)
  editMode = on
  noctalia.state.set("editMode", on)
end

-- ---------- actions ----------
local function copyHex(hex)
  noctalia.copyToClipboard(hex, "text/plain")
  noctalia.notify("Palettes", `Copied {hex}`)
end

local function removeColor(i)
  table.remove(palettes[current].colors, i)
  save(); render()
end

local function addColor()
  if isBuiltin(current) then
    setStatus("Built-in palettes are read-only. Duplicate or create one first", true)
    render(); return
  end
  if newName == "" then
    setStatus("Give the color a name", true)
    render(); return
  end
  table.insert(palettes[current].colors, { name = newName, hex = pickedHex })
  setStatus(`Added {newName}`)
  newName = ""
  nameRev += 1
  save(); render()
end

local function onNameSubmit(value)
  newName = value
  addColor()
end

local function renameColor(c, value)
  if value == "" then
    setStatus("A color needs a name", true)
    render(); return
  end
  c.name = value
  setStatus(`Renamed to {value}`)
  save(); render()
end

local function recolor(c)
  local accepted = noctalia.openColorPicker(c.hex, function(color)
    if color ~= nil then
      c.hex = color:lower()
      save()
    end
    render()
  end)
  if not accepted then
    setStatus("A picker is already open", true)
    render()
  end
end

local function addPalette()
  if newPalette == "" then
    setStatus("Give the palette a name", true)
    render(); return
  end
  if indexByName(newPalette) then
    setStatus("A palette with that name already exists", true)
    render(); return
  end
  table.insert(palettes, { name = newPalette, colors = {} })
  current = #palettes
  setStatus(`Created {newPalette}`)
  newPalette = ""
  palRev += 1
  save(); render()
end

local function onPaletteSubmit(value)
  newPalette = value
  addPalette()
end

local function renamePalette(value)
  if value == "" then
    setStatus("A palette needs a name", true)
    render(); return
  end
  local taken = indexByName(value)
  if taken and taken ~= current then
    setStatus("A palette with that name already exists", true)
    render(); return
  end
  local old = palettes[current].name
  palettes[current].name = value
  if defaultName == old then
    defaultName = value
    savePrefs()
  end
  setStatus(`Renamed palette to {value}`)
  save(); render()
end

-- copies any palette (built-in or yours) into your own list
local function duplicatePalette()
  local src = palAt(current)
  if not src then return end
  local copy = { name = uniqueName(src.name .. " copy"), colors = {} }
  for _, c in ipairs(src.colors) do
    table.insert(copy.colors, { name = c.name, hex = c.hex })
  end
  table.insert(palettes, copy)
  current = #palettes
  setStatus(`Duplicated into {copy.name}`)
  save(); render()
end

local function deletePalette()
  if isBuiltin(current) then
    setStatus("Built-in palettes can't be deleted", true)
    render(); return
  end
  table.remove(palettes, current)
  if defaultName ~= "" and not indexByName(defaultName) then
    defaultName = ""
    savePrefs()
  end
  current = math.max(1, current - 1)
  save(); render()
end

local function toggleDefault()
  local pal = palAt(current)
  if not pal then return end
  if defaultName == pal.name then
    defaultName = ""
    setStatus("Default palette cleared")
  else
    defaultName = pal.name
    setStatus(`{pal.name} will open by default`)
  end
  savePrefs(); render()
end

local function pickColor()
  local accepted = noctalia.openColorPicker(pickedHex, function(color)
    if color ~= nil then pickedHex = color:lower() end
    render()
  end)
  if not accepted then
    setStatus("A picker is already open", true)
    render()
  end
end

-- ---------- UI ----------
local function swatch(hex, size)
  return ui.box({ width = size, height = size, radius = 6, fill = hex, border = "outline", borderWidth = 1 })
end

local function colorCell(i, c)
  return ui.row({ key = `view_{i}`, gap = 6, align = "center", flexGrow = 1 }, {
    swatch(c.hex, 32),
    ui.label({ text = c.name, flexGrow = 1 }),
    ui.button({ key = `copy_{i}`, text = c.hex, onClick = function() copyHex(c.hex) end }),
  })
end

local function editCell(i, c)
  return ui.row({ key = `edit_{i}`, gap = 6, align = "center", flexGrow = 1 }, {
    swatch(c.hex, 32),
    ui.input({ key = `cn_{current}_{i}_{c.name}`, value = c.name, controlSize = "sm", flexGrow = 1,
      onSubmit = function(v) renameColor(c, v) end }),
    ui.button({ key = `recolor_{i}`, glyph = "palette", width = 32, height = 32, tooltip = "Change color",
      onClick = function() recolor(c) end }),
    ui.button({ key = `del_{i}`, glyph = "trash", variant = "destructive", width = 32, height = 32,
      tooltip = "Delete color", onClick = function() removeColor(i) end }),
  })
end

render = function()
  if editMode then noctalia.state.set("editSeen", os.time()) end

  local readOnly = isBuiltin(current)
  local editing = editMode and not readOnly

  local names = {}
  for i = 1, count() do
    local p = palAt(i)
    names[i] = isBuiltin(i) and (p.name .. " (built-in)") or p.name
  end

  local pal = palAt(current)
  local colors = pal and pal.colors or {}
  local rows = {}
  for start = 1, #colors, columns do
    local cells = {}
    for i = start, math.min(start + columns - 1, #colors) do
      table.insert(cells, editing and editCell(i, colors[i]) or colorCell(i, colors[i]))
    end
    while #cells < columns do
      table.insert(cells, ui.label({ text = "", flexGrow = 1 }))
    end
    table.insert(rows, ui.row({ gap = 12 }, cells))
  end

  local palettePart = {
    ui.row({ gap = 8, align = "center" }, {
      ui.select({ options = names, selectedIndex = current - 1, placeholder = "No palettes yet",
        flexGrow = 1,
        onChange = function(index) current = (tonumber(index) or 0) + 1; render() end }),
      ui.button({ key = "pal_default", glyph = "star", enabled = pal ~= nil,
        variant = (pal ~= nil and defaultName == pal.name) and "primary" or "default",
        controlSize = "md", tooltip = "Open this palette by default", onClick = toggleDefault }),
    }),
    ui.row({ gap = 8 }, {
      ui.input({ key = `pname_{palRev}`, placeholder = "New palette name", flexGrow = 1,
        onChange = function(v) newPalette = v end, onSubmit = onPaletteSubmit }),
      ui.button({ key = "pal_create", text = "Create", onClick = addPalette }),
      ui.button({ key = "pal_dup", glyph = "copy", tooltip = "Duplicate palette",
        enabled = pal ~= nil, onClick = duplicatePalette }),
      ui.button({ key = "pal_del", text = "Delete", glyph = "trash", variant = "destructive",
        enabled = not readOnly, onClick = deletePalette }),
    }),
  }
  if editing then
    table.insert(palettePart, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Rename (Enter)", color = "on_surface_variant" }),
      ui.input({ key = `prn_{current}_{palettes[current].name}`, value = palettes[current].name,
        controlSize = "sm", flexGrow = 1, onSubmit = renamePalette }),
    }))
  elseif editMode and readOnly and pal then
    table.insert(palettePart, ui.label({
      text = "Built-in palettes are read-only. Duplicate to edit.", fontSize = 12, color = "on_surface_variant" }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Palettes", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = "Edit", color = "on_surface_variant" }),
      ui.toggle({ checked = editMode, onChange = function(v) setEditMode(v == "true"); render() end }),
      ui.button({ glyph = "close", onClick = function() panel.close() end }),
    }),

    ui.column({ gap = 8 }, palettePart),

    ui.scroll({ flexGrow = 1, gap = 8 }, rows),
    ui.label({ text = status, color = statusIsError and "error" or "primary" }),

    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = `cname_{nameRev}`, placeholder = "New color name", flexGrow = 1, focus = nameRev > 0,
        enabled = not readOnly,
        onChange = function(v) newName = v end, onSubmit = onNameSubmit }),
      swatch(pickedHex, 38),
      ui.button({ key = "pick", text = "Pick", enabled = not readOnly, onClick = pickColor }),
      ui.button({ key = "add", text = "Add", variant = "primary", enabled = not readOnly, onClick = addColor }),
    }),
  }))
end

function onOpen(_context)
  setStatus("")   -- clear any message left from the last open
  readColumns()
  load()
  local wasEditing = noctalia.state.get("editMode") == true
  local seen = tonumber(noctalia.state.get("editSeen")) or 0
  setEditMode(wasEditing and (os.time() - seen) <= EDIT_GRACE)
  render()
end