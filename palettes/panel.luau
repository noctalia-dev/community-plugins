--!nonstrict
-- Palette manager: your own palettes (saved) + built-in read-only palettes (shipped file).

local EDIT_GRACE = 60   -- seconds; reopen within this window and edit mode stays on

-- ---------- state ----------
local columns = 2
local palettes = {}     -- the user's palettes: editable, saved to the data dir
local builtin = {}      -- shipped in builtin.json: read-only, never saved
local builtinAll = {}   -- every shipped palette, loaded even when hidden (used for name checks)
local showBuiltin = true
local current = 1       -- index into the combined list: user palettes first, then built-in
local defaultName = ""  -- "" means no default chosen
local newPalette, newName = "", ""
local nameRev, palRev = 0, 0
local pickedHex = "#ffffff"
local status, statusIsError = "", false
local editMode = false

local render -- declared early so the functions below can call it

-- ---------- translations ----------
-- t("status.color_added", { name = "Red" }) -> looks up the string, then fills {name}
local function t(key, vars)
  local s = noctalia.tr(key) or key
  if vars then
    s = s:gsub("{([%w_]+)}", function(k) return tostring(vars[k] or "") end)
  end
  return s
end

-- ---------- combined list helpers ----------
local function count() return #palettes + #builtin end
local function isBuiltin(i) return i > #palettes end
local function palAt(i) return palettes[i] or builtin[i - #palettes] end

-- ---------- settings / storage ----------
local function readSettings()
  local n = tonumber(noctalia.getConfig("columns")) or 2
  columns = math.max(1, math.min(3, math.floor(n)))
  local v = noctalia.getConfig("show_builtin")
  showBuiltin = not (v == false or v == "false")   -- unset counts as true
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
    setStatus(t("status.encode_failed", { err = encodeErr }), true)
    return
  end
  local ok, err = noctalia.writeFile(path(), text)
  if not ok then setStatus(t("status.save_failed", { err = err }), true) end
end

local function savePrefs()
  local text = noctalia.json.encode({ defaultPalette = defaultName })
  if not text then return end
  local ok, err = noctalia.writeFile(prefsPath(), text)
  if not ok then setStatus(t("status.default_save_failed", { err = err }), true) end
end

-- returns the decoded table, or nil if the file is missing or invalid
local function readJson(p)
  local raw = noctalia.readFile(p)
  if not raw then return nil end
  local data = noctalia.json.decode(raw)
  if type(data) ~= "table" then return nil end
  return data
end

-- keeps only well-formed palettes and colors; returns {} for nil or junk
local function cleanPalettes(data)
  local out = {}
  for _, p in ipairs(data or {}) do
    if type(p) == "table" and type(p.name) == "string" and type(p.colors) == "table" then
      local colors = {}
      for _, c in ipairs(p.colors) do
        if type(c) == "table" and type(c.name) == "string" and type(c.hex) == "string"
            and c.hex:match("^#%x%x%x%x%x%x$") then
          table.insert(colors, c)
        end
      end
      table.insert(out, { name = p.name, colors = colors })
    end
  end
  return out
end

-- position of the first palette with this name in the combined list, or nil
local function indexByName(name)
  for i = 1, count() do
    if palAt(i).name == name then return i end
  end
  return nil
end

-- true if any palette, visible or not, already has this name
local function nameTaken(name)
  for _, p in ipairs(palettes) do
    if p.name == name then return true end
  end
  for _, p in ipairs(builtinAll) do
    if p.name == name then return true end
  end
  return false
end

-- "base", or "base 2", "base 3", ... until the name is free
local function uniqueName(base)
  local name, n = base, 1
  while nameTaken(name) do
    n += 1
    name = `{base} {n}`
  end
  return name
end

local function load()
  local raw = noctalia.readFile(path())
  local saved = readJson(path())
  if raw and not saved then
    noctalia.writeFile(path() .. ".bak", raw)   -- keep the unreadable file before a save replaces it
    setStatus(t("status.palettes_corrupt"), true)
  end
  palettes = cleanPalettes(saved)
  builtinAll = cleanPalettes(readJson(builtinPath()))
  builtin = showBuiltin and builtinAll or {}
  if #builtinAll == 0 then setStatus(t("status.builtin_missing"), true) end
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
  noctalia.copyToClipboard(hex, "text/plain;charset=utf-8")
  noctalia.notify(t("notify.title"), t("notify.copied", { hex = hex }))
end

local function removeColor(i)
  table.remove(palettes[current].colors, i)
  save(); render()
end

local function addColor()
  if isBuiltin(current) then
    setStatus(t("status.builtin_readonly_add"), true)
    render(); return
  end
  if newName == "" then
    setStatus(t("status.color_name_required"), true)
    render(); return
  end
  table.insert(palettes[current].colors, { name = newName, hex = pickedHex })
  setStatus(t("status.color_added", { name = newName }))
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
    setStatus(t("status.color_rename_required"), true)
    render(); return
  end
  if value == c.name then return end   -- nothing changed
  local old = c.name
  c.name = value
  setStatus(t("status.color_renamed", { old = old, name = value }))
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
    setStatus(t("status.picker_open"), true)
    render()
  end
end

local function addPalette()
  if newPalette == "" then
    setStatus(t("status.palette_name_required"), true)
    render(); return
  end
  if nameTaken(newPalette) then
    setStatus(t("status.palette_exists"), true)
    render(); return
  end
  table.insert(palettes, { name = newPalette, colors = {} })
  current = #palettes
  setStatus(t("status.palette_created", { name = newPalette }))
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
    setStatus(t("status.palette_rename_required"), true)
    render(); return
  end
  local old = palettes[current].name
  if value == old then return end      -- nothing changed
  if nameTaken(value) then             -- any match is another palette now
    setStatus(t("status.palette_exists"), true)
    render(); return
  end
  palettes[current].name = value
  if defaultName == old then
    defaultName = value
    savePrefs()
  end
  setStatus(t("status.palette_renamed", { old = old, name = value }))
  save(); render()
end

-- copies any palette (built-in or yours) into your own list
local function duplicatePalette()
  local src = palAt(current)
  if not src then return end
  local copy = { name = uniqueName(t("palette.copy_name", { name = src.name })), colors = {} }
  for _, c in ipairs(src.colors) do
    table.insert(copy.colors, { name = c.name, hex = c.hex })
  end
  table.insert(palettes, copy)
  current = #palettes
  setStatus(t("status.palette_duplicated", { name = copy.name }))
  save(); render()
end

local function deletePalette()
  if isBuiltin(current) then
    setStatus(t("status.builtin_no_delete"), true)
    render(); return
  end
  table.remove(palettes, current)
  if defaultName ~= "" and not nameTaken(defaultName) then
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
    setStatus(t("status.default_cleared"))
  else
    defaultName = pal.name
    setStatus(t("status.default_set", { name = pal.name }))
  end
  savePrefs(); render()
end

local function pickColor()
  local accepted = noctalia.openColorPicker(pickedHex, function(color)
    if color ~= nil then pickedHex = color:lower() end
    render()
  end)
  if not accepted then
    setStatus(t("status.picker_open"), true)
    render()
  end
end

-- ---------- UI ----------
local function swatch(hex, size)
  return ui.box({ width = size, height = size, radius = 6, fill = hex, border = "outline_variant", borderWidth = 1 })
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
    ui.button({ key = `recolor_{i}`, glyph = "palette", width = 32, height = 32, tooltip = t("ui.change_color"),
      onClick = function() recolor(c) end }),
    ui.button({ key = `del_{i}`, glyph = "trash", variant = "destructive", width = 32, height = 32,
      tooltip = t("ui.delete_color"), onClick = function() removeColor(i) end }),
  })
end

render = function()
  if editMode then noctalia.state.set("editSeen", os.time()) end

  local readOnly = isBuiltin(current)
  local editing = editMode and not readOnly

  local names = {}
  for i = 1, count() do
    local p = palAt(i)
    names[i] = isBuiltin(i) and t("palette.builtin_name", { name = p.name }) or p.name
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
      ui.select({ options = names, selectedIndex = current - 1, placeholder = t("ui.no_palettes"),
        flexGrow = 1,
        onChange = function(index) current = (tonumber(index) or 0) + 1; render() end }),
      ui.button({ key = "pal_default", glyph = "star", enabled = pal ~= nil,
        variant = (pal ~= nil and defaultName == pal.name) and "primary" or "default",
        controlSize = "md", tooltip = t("ui.set_default"), onClick = toggleDefault }),
    }),
    ui.row({ gap = 8 }, {
      ui.input({ key = `pname_{palRev}`, placeholder = t("ui.new_palette"), flexGrow = 1,
        onChange = function(v) newPalette = v end, onSubmit = onPaletteSubmit }),
      ui.button({ key = "pal_create", text = t("ui.create"), onClick = addPalette }),
      ui.button({ key = "pal_dup", glyph = "copy", tooltip = t("ui.duplicate"),
        enabled = pal ~= nil, onClick = duplicatePalette }),
      ui.button({ key = "pal_del", text = t("ui.delete"), glyph = "trash", variant = "destructive",
        enabled = not readOnly, onClick = deletePalette }),
    }),
  }
  if editing then
    table.insert(palettePart, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = t("ui.rename"), color = "on_surface_variant" }),
      ui.input({ key = `prn_{current}_{palettes[current].name}`, value = palettes[current].name,
        controlSize = "sm", flexGrow = 1, onSubmit = renamePalette }),
    }))
  elseif editMode and readOnly and pal then
    table.insert(palettePart, ui.label({
      text = t("ui.builtin_hint"), fontSize = 12, color = "on_surface_variant" }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = t("ui.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = t("ui.edit"), color = "on_surface_variant" }),
      ui.toggle({ checked = editMode, onChange = function(v) setEditMode(v == "true"); render() end }),
      ui.button({ glyph = "close", onClick = function() panel.close() end }),
    }),

    ui.column({ gap = 8 }, palettePart),

    ui.scroll({ flexGrow = 1, gap = 8 }, rows),
    ui.label({ text = status, color = statusIsError and "error" or "primary" }),

    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = `cname_{nameRev}`, placeholder = t("ui.new_color"), flexGrow = 1, focus = nameRev > 0,
        enabled = not readOnly,
        onChange = function(v) newName = v end, onSubmit = onNameSubmit }),
      swatch(pickedHex, 38),
      ui.button({ key = "pick", text = t("ui.pick"), enabled = not readOnly, onClick = pickColor }),
      ui.button({ key = "add", text = t("ui.add"), variant = "primary", enabled = not readOnly, onClick = addColor }),
    }),
  }))
end

function onOpen(_context)
  setStatus("")   -- clear any message left from the last open
  readSettings()
  load()
  local wasEditing = noctalia.state.get("editMode") == true
  local seen = tonumber(noctalia.state.get("editSeen")) or 0
  setEditMode(wasEditing and (os.time() - seen) <= EDIT_GRACE)
  render()
end