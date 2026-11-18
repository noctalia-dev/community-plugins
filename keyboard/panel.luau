--!nonstrict
-- Keyboard panel: every language you type in, from the compositor's layouts and fcitx5's
-- input methods, with the active one marked. A click switches to it, ✕ removes it, and the
-- picker below adds a layout or an input method. Buttons that may vanish under the pointer
-- carry no tooltip: a tooltip opening as its row goes away has closed Noctalia's connection
-- to the compositor. Renders "keyboard.model" and sends actions
-- on "keyboard.command".

local model = nil

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("keyboard.command", command)
end

local function entryRow(entry)
  local active = entry.key == model.current
  return ui.row({
    key = entry.key,
    gap = 10,
    align = "center",
    paddingH = 8,
    paddingV = 6,
    radius = 8,
    -- A transparent fill, not nil, so the highlight leaves the row that was active.
    fill = active and "primary/0.12" or "primary/0",
    onClick = function() send({ action = "choose", key = entry.key }) end,
  }, {
    ui.label({ text = entry.short, width = 32, fontWeight = "semibold", color = active and "primary" or "on_surface" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = entry.name, maxLines = 1 }),
      ui.label({
        text = noctalia.tr(entry.kind == "layout" and "entry.layout" or "entry.input_method"),
        color = "on_surface_variant",
        fontSize = 11,
      }),
    }),
    active and ui.glyph({ name = "check", size = 16, color = "primary" }) or ui.box({ width = 16 }),
    entry.removable and ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        if entry.kind == "layout" then
          send({ action = "remove_layout", index = entry.index })
        else
          send({ action = "remove_im", id = entry.id })
        end
      end,
    }) or ui.box({ width = 32 }),
  })
end

-- What can be added: fcitx5's input methods, as there are few, then the layouts not in the
-- list yet. One picker for both, like the list above it.
local function addable(catalog)
  local have = {}
  for _, entry in ipairs(model.entries) do
    if entry.kind == "layout" then
      have[entry.code] = true
    end
  end
  local items = {}
  for _, im in ipairs(catalog.ims) do
    table.insert(items, {
      label = noctalia.tr("panel.option_im", { name = im.name }),
      command = { action = "add_im", id = im.id },
    })
  end
  for _, layout in ipairs(catalog.layouts) do
    if not have[layout.code] then
      table.insert(items, {
        label = noctalia.tr("panel.option_layout", { name = layout.name }),
        command = { action = "add_layout", code = layout.code },
      })
    end
  end
  return items
end

-- Adding a language, and giving the layouts back to Hyprland's config.
local function addBlock()
  local catalog = model.catalog
  local children = {
    ui.label({ text = noctalia.tr("panel.add"), fontWeight = "semibold" }),
  }
  if catalog == nil then
    table.insert(children, ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }))
    return ui.column({ gap = 8 }, children)
  end
  local items = addable(catalog)
  -- The first option is the prompt: the select shows its first option when none is picked.
  local options = { noctalia.tr("panel.add_placeholder") }
  for _, item in ipairs(items) do
    table.insert(options, item.label)
  end
  table.insert(children, ui.select({
    -- A new key after each change shows the prompt again.
    key = "add-" .. #items,
    options = options,
    selectedIndex = 0,
    enabled = #items > 0,
    onChange = function(index)
      local item = items[tonumber(index) or 0]
      if item then
        send(item.command)
      end
    end,
  }))
  if model.fcitx and #catalog.ims == 0 then
    table.insert(children, ui.label({ text = noctalia.tr("panel.no_more_ims"), color = "on_surface_variant", fontSize = 11, maxLines = 3 }))
  end
  if model.managed then
    table.insert(children, ui.column({ gap = 4 }, {
      ui.label({ text = noctalia.tr("panel.managed"), color = "on_surface_variant", fontSize = 11, maxLines = 3 }),
      ui.row({}, {
        ui.button({
          text = noctalia.tr("panel.reset"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function() send({ action = "reset_layouts" }) end,
        }),
      }),
    }))
  end
  return ui.column({ gap = 8 }, children)
end

-- The on-screen keyboard's switch, or what it needs first.
local function oskRow()
  if not model.wtype then
    return ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
      ui.label({ text = noctalia.tr("osk.needs_wtype"), color = "on_surface_variant", flexGrow = 1, maxLines = 3 }),
      ui.button({
        text = noctalia.tr("osk.install"),
        glyph = "terminal-2",
        variant = "primary",
        controlSize = "sm",
        onClick = function()
          send({ action = "install_wtype" })
          panel.close()
        end,
      }),
    })
  end
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "keyboard", size = 16, color = model.osk and "primary" or "on_surface_variant" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("osk.title") }),
      (model.oskKey or "") ~= "" and ui.label({ text = model.oskKey, color = "on_surface_variant", fontSize = 11 }) or nil,
    }),
    ui.toggle({
      checked = model.osk == true,
      onChange = function(value) send({ action = "osk", open = value == "true" }) end,
    }),
  })
end

local function render()
  if model == nil then
    panel.render(ui.column({ padding = 16 }, {
      ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }),
    }))
    return
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "keyboard", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "semibold" }),
    }),
  }
  if not model.ready then
    table.insert(children, ui.label({ text = noctalia.tr("panel.none"), color = "on_surface_variant", maxLines = 3 }))
  else
    local rows = {}
    for _, entry in ipairs(model.entries) do
      table.insert(rows, entryRow(entry))
    end
    table.insert(children, ui.column({ gap = 4 }, rows))
  end
  table.insert(children, ui.separator({}))
  table.insert(children, addBlock())
  table.insert(children, ui.separator({}))
  table.insert(children, oskRow())
  panel.render(ui.column({ gap = 12, padding = 16 }, children))
end

noctalia.state.watch("keyboard.model", function(value)
  model = value
  render()
end)

function onOpen(_context)
  send({ action = "open" })
  model = noctalia.state.get("keyboard.model") or model
  render()
end
