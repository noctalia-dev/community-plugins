--!nonstrict
-- Resurrect panel: when the setup was last saved and where, shared files that wait for a
-- choice, packages and services other devices have or removed, what is saved, and the Save
-- and Restore buttons. Renders "resurrect.model" and sends actions on "resurrect.command".

local model = nil
local confirming = false

-- The cards scroll inside a column of their height, up to what fits in the panel
-- (DESIGN.md, section 6.3). Rows have fixed heights; labels that wrap are estimated, and
-- cards keep their own height, so a label that wraps more than estimated scrolls instead
-- of being cut off.
local LIST_MAX = 560
local CARD_GAP = 14
local CARD_PADDING = 12
local ROW_GAP = 8
local TITLE_HEIGHT = 24
local LINE_HEIGHT = 20
local BUTTON_ROW_HEIGHT = 28
local CHARS_PER_LINE = 34

-- About how tall a label of <text> is, wrapped to at most <maxLines>.
local function textHeight(text, maxLines)
  return LINE_HEIGHT * math.clamp(math.ceil(#text / CHARS_PER_LINE), 1, maxLines)
end

-- A card of <rows>, which together are <height> tall, and the card's own height.
local function card(rows, height)
  height += 2 * CARD_PADDING + ROW_GAP * (#rows - 1)
  return ui.column({ gap = ROW_GAP, padding = CARD_PADDING, radius = 12, fill = "surface_container_high" }, rows), height
end

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("resurrect.command", command)
end

local render

local function statusCard()
  local title, color, glyph
  if model.running then
    title, color, glyph = noctalia.tr("status.saving"), "primary", "loader-2"
  elseif model.error then
    title, color, glyph = noctalia.tr("status.failed"), "error", "alert-circle"
  elseif model.lastMs then
    local time = noctalia.formatTime("%Y-%m-%d %H:%M", math.floor(model.lastMs / 1000))
    title, color, glyph = noctalia.tr("status.saved", { time = time }), "primary", "circle-check"
  else
    title, color, glyph = noctalia.tr("status.never"), "on_surface_variant", "clock"
  end
  local lines = {
    ui.row({ gap = 8, align = "center", height = TITLE_HEIGHT }, {
      ui.glyph({ name = glyph, size = 20, color = color }),
      ui.label({ text = title, fontWeight = "semibold", flexGrow = 1 }),
    }),
  }
  local height = TITLE_HEIGHT
  local function line(text, textColor, maxLines)
    table.insert(lines, ui.label({ text = text, color = textColor, maxLines = maxLines }))
    height += textHeight(text, maxLines)
  end
  if model.error then
    line(model.error, "error", 3)
  end
  line(noctalia.tr("status.folder", { folder = model.folder }), "on_surface_variant", 2)
  line(model.remote ~= "" and noctalia.tr("status.remote", { remote = model.remote }) or noctalia.tr("status.local"),
    "on_surface_variant", 2)
  if model.share and model.remote ~= "" then
    line(noctalia.tr("status.shared"), "on_surface_variant", 2)
  end
  return card(lines, height)
end

-- At most this many waiting files are listed; the rest are counted.
local MAX_WAITING = 5

-- One shared file that waits for the owner: changed on two devices, or held back because it
-- gave Hyprland config errors here.
local function waitingRow(path, isHeld)
  local choice = model.choices and model.choices[path]
  local children = {
    ui.label({ text = path, maxLines = 2, flexGrow = 1 }),
  }
  if choice then
    table.insert(children, ui.label({ text = noctalia.tr("waiting.chosen"), color = "on_surface_variant" }))
  else
    table.insert(children, ui.button({ text = noctalia.tr("waiting.mine"), variant = "ghost", controlSize = "sm",
      onClick = function() send({ action = "resolve", path = path, choice = "mine" }) end }))
    table.insert(children, ui.button({ text = noctalia.tr("waiting.theirs"), variant = "ghost", controlSize = "sm",
      tooltip = isHeld and noctalia.tr("waiting.theirs_held") or nil,
      onClick = function() send({ action = "resolve", path = path, choice = "theirs" }) end }))
  end
  return ui.row({ gap = 6, align = "center", height = 2 * LINE_HEIGHT }, children)
end

local function waiting()
  local total = #model.conflicts + #model.held
  if total == 0 then
    return nil
  end
  local rows = {
    ui.row({ gap = 8, align = "center", height = TITLE_HEIGHT }, {
      ui.glyph({ name = "git-merge", size = 18, color = "error" }),
      ui.label({ text = noctalia.trp("waiting.title", total), fontWeight = "semibold", flexGrow = 1 }),
    }),
  }
  local height = TITLE_HEIGHT
  local shown = 0
  for _, path in ipairs(model.conflicts) do
    if shown < MAX_WAITING then
      table.insert(rows, waitingRow(path, false))
      height += 2 * LINE_HEIGHT
      shown += 1
    end
  end
  if #model.held > 0 and shown < MAX_WAITING then
    local note = noctalia.tr("waiting.held")
    table.insert(rows, ui.label({ text = note, color = "on_surface_variant", maxLines = 2 }))
    height += textHeight(note, 2)
    for _, path in ipairs(model.held) do
      if shown < MAX_WAITING then
        table.insert(rows, waitingRow(path, true))
        height += 2 * LINE_HEIGHT
        shown += 1
      end
    end
  end
  if total > shown then
    table.insert(rows, ui.label({ text = noctalia.tr("waiting.more", { count = total - shown }), color = "on_surface_variant",
      maxLines = 1 }))
    height += LINE_HEIGHT
  end
  return card(rows, height)
end

-- The list a package or service comes from, as the panel names it.
local function listName(list)
  if list == "system" or list == "user" then
    return noctalia.tr("lists." .. list)
  end
  return list
end

-- Packages and services other devices have and this one does not, with Install and Not here.
local function missingCard()
  local missing = model.missing or {}
  if #missing == 0 then
    return nil
  end
  local rows = {
    ui.row({ gap = 8, align = "center", height = TITLE_HEIGHT }, {
      ui.glyph({ name = "package", size = 18, color = "primary" }),
      ui.label({ text = noctalia.trp("missing.title", #missing), fontWeight = "semibold", flexGrow = 1 }),
    }),
  }
  local height = TITLE_HEIGHT + BUTTON_ROW_HEIGHT
  for index, package in ipairs(missing) do
    if index > MAX_WAITING then
      table.insert(rows, ui.label({ text = noctalia.tr("waiting.more", { count = #missing - MAX_WAITING }),
        color = "on_surface_variant", maxLines = 1 }))
      height += LINE_HEIGHT
      break
    end
    height += BUTTON_ROW_HEIGHT
    table.insert(rows, ui.row({ gap = 6, align = "center", height = BUTTON_ROW_HEIGHT }, {
      ui.label({ text = package.name, flexGrow = 1, maxLines = 1 }),
      ui.label({ text = listName(package.list), color = "on_surface_variant" }),
      ui.button({ text = noctalia.tr("missing.skip"), variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("missing.skip_tooltip"),
        onClick = function() send({ action = "skip", names = { package.name } }) end }),
    }))
  end
  local names = {}
  for _, package in ipairs(missing) do
    table.insert(names, package.name)
  end
  table.insert(rows, ui.row({ gap = 8, justify = "end", height = BUTTON_ROW_HEIGHT }, {
    ui.button({ text = noctalia.tr("missing.skip_all"), variant = "ghost", controlSize = "sm",
      onClick = function() send({ action = "skip", names = names }) end }),
    ui.button({ text = noctalia.tr("missing.install"), glyph = "terminal-2", variant = "primary", controlSize = "sm",
      tooltip = noctalia.tr("missing.install_tooltip"),
      onClick = function()
        send({ action = "install" })
        panel.close()
      end }),
  }))
  return card(rows, height)
end

-- Packages and services another device removed and this one still has, with Share again
-- and Only here.
local function leftCard()
  local left = model.left or {}
  if #left == 0 then
    return nil
  end
  local title = noctalia.trp("left.title", #left)
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "package-off", size = 18, color = "primary" }),
      ui.label({ text = title, fontWeight = "semibold", flexGrow = 1, maxLines = 2 }),
    }),
  }
  local height = math.max(TITLE_HEIGHT, textHeight(title, 2))
  for index, item in ipairs(left) do
    if index > MAX_WAITING then
      table.insert(rows, ui.label({ text = noctalia.tr("waiting.more", { count = #left - MAX_WAITING }),
        color = "on_surface_variant", maxLines = 1 }))
      height += LINE_HEIGHT
      break
    end
    height += LINE_HEIGHT + 2 + BUTTON_ROW_HEIGHT
    -- The name has a line of its own, as two buttons beside it leave it too little room.
    table.insert(rows, ui.column({ gap = 2, height = LINE_HEIGHT + 2 + BUTTON_ROW_HEIGHT }, {
      ui.row({ gap = 6, align = "center", height = LINE_HEIGHT }, {
        ui.label({ text = item.name, flexGrow = 1, maxLines = 1 }),
        ui.label({ text = listName(item.list), color = "on_surface_variant" }),
      }),
      ui.row({ gap = 6, justify = "end", height = BUTTON_ROW_HEIGHT }, {
        ui.button({ text = noctalia.tr("left.again"), variant = "ghost", controlSize = "sm",
          tooltip = noctalia.tr("left.again_tooltip"),
          onClick = function() send({ action = "again", items = { item } }) end }),
        ui.button({ text = noctalia.tr("left.only"), variant = "ghost", controlSize = "sm",
          tooltip = noctalia.tr("left.only_tooltip"),
          onClick = function() send({ action = "only", items = { item } }) end }),
      }),
    }))
  end
  if #left > 1 then
    height += BUTTON_ROW_HEIGHT
    table.insert(rows, ui.row({ gap = 8, justify = "end", height = BUTTON_ROW_HEIGHT }, {
      ui.button({ text = noctalia.tr("left.again_all"), variant = "ghost", controlSize = "sm",
        onClick = function() send({ action = "again", items = left }) end }),
      ui.button({ text = noctalia.tr("left.only_all"), variant = "ghost", controlSize = "sm",
        onClick = function() send({ action = "only", items = left }) end }),
    }))
  end
  return card(rows, height)
end

-- One kind of thing a save holds, with how many the last save had.
local function includedRow(glyph, text, on, count)
  local height = math.max(BUTTON_ROW_HEIGHT, textHeight(text, 2))
  local children = {
    ui.glyph({ name = on and glyph or "minus", size = 16, color = on and "primary" or "on_surface_variant" }),
    ui.label({ text = text, color = on and "on_surface" or "on_surface_variant", maxLines = 2, flexGrow = 1 }),
  }
  if on and count then
    table.insert(children, ui.label({ text = tostring(count), color = "on_surface_variant" }))
  end
  return ui.row({ gap = 8, align = "center", flexGrow = 1 }, children), height
end

local function included()
  local counts = model.counts
  local files = #model.files > 0 and table.concat(model.files, ", ") or noctalia.tr("saved.no_files")
  -- Until a save has counted them, the steps are named without a number.
  local hookText = counts.hooks and noctalia.trp("saved.hooks", counts.hooks) or noctalia.tr("saved.hooks_any")
  local hookItem, hookHeight = includedRow("terminal-2", hookText, counts.hooks ~= 0)
  local hookRow = { hookItem }
  if model.canOpen then
    table.insert(hookRow, ui.button({ glyph = "folder", variant = "ghost", controlSize = "sm",
      tooltip = noctalia.tr("saved.open_hooks"), onClick = function() send({ action = "hooks" }) end }))
  end
  local rows = { ui.label({ text = noctalia.tr("saved.title"), color = "on_surface_variant", maxLines = 1 }) }
  local height = LINE_HEIGHT + hookHeight
  local function add(row, rowHeight)
    table.insert(rows, row)
    height += rowHeight
  end
  add(includedRow("package", noctalia.tr("saved.packages"), model.packages, counts.packages))
  add(includedRow("file-text", noctalia.tr(model.share and "saved.files_shared" or "saved.files", { files = files }),
    #model.files > 0, counts.files and (counts.files + (model.share and counts.shared or 0)) or nil))
  add(includedRow("settings", noctalia.tr("saved.services"), model.services, counts.services))
  add(includedRow("adjustments", noctalia.tr("saved.noctalia"), model.noctalia, counts.plugins))
  table.insert(rows, ui.row({ gap = 4, align = "center" }, hookRow))
  height += 6 * (#rows - 1)
  return ui.column({ gap = 6 }, rows), height
end

local function actions()
  if confirming then
    return ui.column({ gap = 8 }, {
      ui.label({ text = noctalia.tr("restore.confirm") }),
      ui.row({ gap = 8, justify = "end" }, {
        ui.button({ text = noctalia.tr("restore.cancel"), variant = "ghost", onClick = function()
          confirming = false
          render()
        end }),
        ui.button({ text = noctalia.tr("restore.start"), glyph = "terminal-2", variant = "primary", onClick = function()
          confirming = false
          send({ action = "restore" })
          panel.close()
        end }),
      }),
    })
  end
  local buttons = {}
  if model.canOpen then
    table.insert(buttons, ui.button({ glyph = "folder", variant = "ghost", tooltip = noctalia.tr("actions.open"),
      onClick = function() send({ action = "open" }) end }))
  end
  table.insert(buttons, ui.spacer({ flexGrow = 1 }))
  table.insert(buttons, ui.button({
    text = noctalia.tr("actions.restore"),
    variant = "ghost",
    enabled = model.canRestore,
    onClick = function()
      confirming = true
      render()
    end,
  }))
  table.insert(buttons, ui.button({
    text = noctalia.tr("actions.save"),
    glyph = "device-floppy",
    variant = "primary",
    enabled = not model.running,
    onClick = function() send({ action = "save" }) end,
  }))
  return ui.row({ gap = 8, align = "center" }, buttons)
end

render = function()
  if model == nil then
    panel.render(ui.column({ padding = 16 }, {
      ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }),
    }))
    return
  end
  local header = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "lifebuoy", size = 20, color = "primary" }),
    ui.label({ text = noctalia.tr("panel.title"), fontWeight = "semibold" }),
  })
  if not model.ready then
    panel.render(ui.column({ gap = 12, padding = 16 }, {
      header,
      ui.label({ text = noctalia.tr("setup.body"), color = "on_surface_variant" }),
    }))
    return
  end
  -- The cards scroll between the fixed header and buttons when they do not fit.
  local cards, height = {}, -CARD_GAP
  local function add(item, itemHeight)
    if item then
      table.insert(cards, item)
      height += itemHeight + CARD_GAP
    end
  end
  add(statusCard())
  add(waiting())
  add(missingCard())
  add(leftCard())
  add(included())
  panel.render(ui.column({ gap = 14, padding = 16 }, {
    header,
    ui.column({ height = math.min(height, LIST_MAX) }, {
      ui.scroll({ key = "cards", gap = CARD_GAP, flexGrow = 1 }, cards),
    }),
    ui.separator({}),
    actions(),
  }))
end

noctalia.state.watch("resurrect.model", function(value)
  model = value
  render()
end)

function onOpen(_context)
  confirming = false
  model = noctalia.state.get("resurrect.model") or model
  render()
end
