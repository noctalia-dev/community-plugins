--!nonstrict
-- Floating file picker used by "Add profile": navigate folders, pick a profile file.
-- The service lists directories (state "openvpn3.dir"); the choice goes back to the
-- add-profile page through state "openvpn3.picked".

local listing = { dir = "", parent = "", entries = {} }
local goTo = ""
local goKey = 0

local function send(extra)
  local command = { action = "list-dir", nonce = noctalia.nowMs() }
  for k, v in pairs(extra) do
    command[k] = v
  end
  noctalia.state.set("openvpn3.command", command)
end

local function navigate(dir)
  goTo = dir
  goKey += 1
  send({ dir = dir })
end

local function place(label, glyph, subdir)
  local home = noctalia.getenv("HOME") or "/"
  return ui.button({
    text = label, glyph = glyph, variant = "ghost",
    onClick = function() navigate(if subdir == "" then home else `{home}/{subdir}`) end,
  })
end

local function entryRow(entry)
  local full = (if listing.dir == "/" then "" else listing.dir) .. "/" .. entry.name
  return ui.button({
    text = entry.name, glyph = if entry.isDir then "folder" else "key", variant = "ghost", contentAlign = "start",
    onClick = function()
      if entry.isDir then
        navigate(full)
      else
        noctalia.state.set("openvpn3.picked", { path = full, nonce = noctalia.nowMs() })
        panel.close()
      end
    end,
  })
end

local function render()
  local rows = {}
  if listing.parent ~= "" then
    table.insert(rows, ui.button({
      text = "..", glyph = "arrow-left", variant = "ghost", contentAlign = "start",
      onClick = function() navigate(listing.parent) end,
    }))
  end
  for _, entry in ipairs(listing.entries) do
    table.insert(rows, entryRow(entry))
  end
  if #listing.entries == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.browse-empty"), color = "on_surface_variant", fontSize = 12 }))
  end

  panel.render(ui.column({ gap = 10, padding = 14, flexGrow = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "folder-open", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.browse-title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", onClick = function() panel.close() end }),
    }),
    ui.row({ gap = 6 }, {
      place(noctalia.tr("panel.place-home"), "home", ""),
      place(noctalia.tr("panel.place-downloads"), "download", "Downloads"),
      place(noctalia.tr("panel.place-documents"), "file-text", "Documents"),
      place(noctalia.tr("panel.place-desktop"), "device-desktop", "Desktop"),
    }),
    ui.input({
      key = `picker-go-{goKey}`, value = if goTo ~= "" then goTo else listing.dir, placeholder = noctalia.tr("panel.go-to"),
      onChange = function(text) goTo = text or "" end,
      onSubmit = function(text) navigate(text or "") end,
    }),
    ui.scroll({ flexGrow = 1, gap = 2 }, rows),
  }))
end

local function applyDir(value)
  if type(value) == "table" and type(value.dir) == "string" then
    listing = { dir = value.dir, parent = value.parent or "", entries = value.entries or {} }
    goTo = value.dir
    goKey += 1
    render()
  end
end

-- Whatever way the picker closes (a pick, the X, Escape), bring the main panel
-- back if it went away while this window was open.
function onClose()
  local state = noctalia.state.get("openvpn3.panelopen")
  if type(state) == "table" and state.open == false then
    -- Ask the bar widget to reopen it: a panel opened by the widget is placed next to
    -- the widget, while one opened from here would appear at the screen centre.
    noctalia.state.set("openvpn3.command", { action = "reopen-panel", nonce = noctalia.nowMs() })
  end
end

function onOpen(_context)
  local current = noctalia.state.get("openvpn3.dir")
  applyDir(current)
  send({ dir = if type(current) == "table" then current.dir else "" })
  render()
end

applyDir(noctalia.state.get("openvpn3.dir"))
render()
noctalia.state.watch("openvpn3.dir", applyDir)
