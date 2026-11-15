--!nonstrict
-- Plugin Hub panel: Noctalia's own panels, every plugin you use and your own commands, each
-- with what it can do. A plugin's switch turns it on or off and its gear opens its settings
-- page: its own settings and each of its widgets', in one list. Each action runs with ▶ and
-- gets a key with its key button. Renders "hub.model" and "hub.settings", and sends actions
-- on "hub.command".

local CONTROL_WIDTH = 170

-- A scroll takes its content's height when it is first laid out, so each list sits in a
-- column whose height the panel works out from its rows (DESIGN.md, section 6.3). The
-- limits keep the panel within its max_height of 640, less padding, title and gaps.
local LIST_MAX = 536
local LIST_MAX_NO_KEYS = 494
local HEADER_HEIGHT = 40
local ROW_HEIGHT = 36
local NOTE_HEIGHT = 20
local INPUT_HEIGHT = 32
local GROUP_GAP = 4
local LIST_GAP = 10
local PAGE_GAP = 14
local SECTION_GAP = 10

local model = nil
local search = ""
local editing = nil -- the command whose key is being typed
local expanded = {} -- group id -> true while it shows its actions; a search shows them all
local pageId = nil -- the plugin whose settings page is open
local pageModel = nil
local showAdvanced = false

local render

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("hub.command", command)
end

local function matches(group, action)
  if search == "" then
    return true
  end
  local text = (group.title .. " " .. (action and (action.title .. " " .. action.command) or "")):lower()
  return text:find(search:lower(), 1, true) ~= nil
end

-- The key of an action: a field while it is typed, its key, or a button to add one.
local function keyControl(action)
  if not model.canBind then
    return nil
  end
  if editing == action.command then
    return ui.row({ gap = 4, align = "center" }, {
      ui.input({
        key = "key-" .. action.command,
        width = 130,
        controlSize = "sm",
        focus = true,
        value = model.keys[action.command] or "",
        placeholder = noctalia.tr("key.placeholder"),
        onSubmit = function(value)
          editing = nil
          send({ action = "set_key", command = action.command, key = value })
          render()
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          editing = nil
          render()
        end,
      }),
    })
  end
  local key = model.keys[action.command]
  local state = key and model.status[key]
  local children = {}
  if state == "taken" or state == "invalid" then
    table.insert(children, ui.label({ text = noctalia.tr("key." .. state), color = "error", fontSize = 11 }))
  end
  table.insert(children, ui.button({
    text = key,
    glyph = key == nil and "keyboard" or nil,
    variant = key and "default" or "ghost",
    controlSize = "sm",
    onClick = function()
      editing = action.command
      render()
    end,
  }))
  return ui.row({ gap = 6, align = "center" }, children)
end

local function actionRow(action)
  local children = {
    ui.glyph({ name = action.kind == "panel" and "layout-sidebar" or "terminal-2", size = 16, color = "on_surface_variant" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = action.title, maxLines = 1 }),
      action.kind == "command" and action.title ~= action.command
          and ui.label({ text = action.command, color = "on_surface_variant", fontSize = 11, maxLines = 1 })
        or nil,
    }),
  }
  local control = keyControl(action)
  if control then
    table.insert(children, control)
  end
  table.insert(children, ui.button({
    glyph = "player-play",
    variant = "ghost",
    controlSize = "sm",
    onClick = function()
      send({ action = "run", command = action.command })
      if action.kind == "panel" then
        panel.close()
      end
    end,
  }))
  if action.custom then
    table.insert(children, ui.button({
      glyph = "trash",
      variant = "ghost",
      controlSize = "sm",
      onClick = function() send({ action = "remove_custom", command = action.command }) end,
    }))
  end
  return ui.row({ key = action.command, gap = 8, align = "center", paddingH = 4, height = ROW_HEIGHT }, children)
end

local function groupHeader(group, open)
  local children = {
    ui.glyph({ name = open and "chevron-down" or "chevron-right", size = 16, color = "on_surface_variant" }),
    ui.label({ text = group.title, fontWeight = "semibold", flexGrow = 1, maxLines = 1 }),
  }
  if not open and group.enabled ~= false and #group.actions > 0 then
    table.insert(children, ui.label({ text = tostring(#group.actions), color = "on_surface_variant", fontSize = 11 }))
  end
  if group.plugin then
    if group.settings then
      table.insert(children, ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          pageId = group.id
          pageModel = nil
          showAdvanced = false
          send({ action = "load_settings", id = group.id })
          render()
        end,
      }))
    end
    table.insert(children, ui.toggle({
      checked = group.enabled == true,
      onChange = function(value) send({ action = "enable", id = group.id, on = value == "true" }) end,
    }))
  end
  return ui.row({
    gap = 8,
    align = "center",
    paddingH = 4,
    height = HEADER_HEIGHT,
    radius = 8,
    onClick = function()
      expanded[group.id] = not expanded[group.id] or nil
      render()
    end,
  }, children)
end

local function note(text)
  return ui.row({ height = NOTE_HEIGHT, align = "center" }, {
    ui.label({ text = text, color = "on_surface_variant", fontSize = 11, maxLines = 1 }),
  })
end

-- A group's block and its height.
local function groupBlock(group)
  local rows = {}
  local headerMatches = matches(group, nil)
  if group.enabled ~= false then
    for _, action in ipairs(group.actions) do
      if headerMatches or matches(group, action) then
        table.insert(rows, actionRow(action))
      end
    end
  end
  if not headerMatches and #rows == 0 then
    return nil, 0
  end
  local open = search ~= "" or expanded[group.id] == true
  local children = { groupHeader(group, open) }
  local height = HEADER_HEIGHT
  if not open then
    return ui.column({ key = "group-" .. group.id, gap = GROUP_GAP }, children), height
  end
  if group.enabled == false then
    table.insert(children, note(noctalia.tr("plugin.off")))
    height += GROUP_GAP + NOTE_HEIGHT
  elseif group.custom then
    for _, row in ipairs(rows) do
      table.insert(children, row)
    end
    height += #rows * (GROUP_GAP + ROW_HEIGHT) + GROUP_GAP + INPUT_HEIGHT
    table.insert(children, ui.input({
      key = "add-custom-" .. #group.actions,
      controlSize = "sm",
      placeholder = noctalia.tr("custom.placeholder"),
      onSubmit = function(value)
        if noctalia.string.trim(value) ~= "" then
          send({ action = "add_custom", command = value })
        end
      end,
    }))
  elseif #rows == 0 then
    table.insert(children, note(noctalia.tr("plugin.nothing")))
    height += GROUP_GAP + NOTE_HEIGHT
  else
    for _, row in ipairs(rows) do
      table.insert(children, row)
    end
    height += #rows * (GROUP_GAP + ROW_HEIGHT)
  end
  return ui.column({ key = "group-" .. group.id, gap = GROUP_GAP }, children), height
end

-- A list of <blocks> as tall as <height>, up to <limit>; above it the list scrolls.
local function scrollList(key, gap, height, limit, blocks)
  return ui.column({ height = math.min(height, limit) }, {
    ui.scroll({ key = key, flexGrow = 1, gap = gap }, blocks),
  })
end

-- About how tall a label of <text> is at font size 11, wrapped to at most <maxLines>.
local function textHeight(text, maxLines)
  return 2 + 14 * math.min(maxLines, math.ceil(#text / 60))
end

local function groupTitle(id)
  for _, group in ipairs(model and model.groups or {}) do
    if group.id == id then
      return group.title
    end
  end
  return id
end

-- Opens the place in Noctalia's own settings where <section> is edited.
local function openInNoctalia(section)
  if section.kind == "plugin" then
    send({ action = "settings", id = pageId })
  elseif section.kind == "widget" then
    send({ action = "open_widget", bar = section.bar, instance = section.instance })
  else
    send({ action = "open_desktop", lockscreen = section.kind == "lockscreen" })
  end
  panel.close()
end

local function isVisible(field, section, own)
  local rule = field.visibleWhen
  if rule == nil then
    return true
  end
  local value = nil
  for _, list in ipairs({ section.fields, own and own.fields or {} }) do
    for _, other in ipairs(list) do
      if value == nil and other.key == rule.key then
        value = other.value
      end
    end
  end
  for _, wanted in ipairs(rule.values) do
    if tostring(value) == tostring(wanted) then
      return true
    end
  end
  return false
end

local function fieldControl(field, at, section)
  local function save(value)
    send({ action = "save_setting", id = pageId, section = at, key = field.key, value = value })
  end
  local kind = field.type
  if field.secret or kind == "string_list" or kind == "string_map" then
    local summary
    if field.secret then
      summary = noctalia.tr(field.set and "page.secret_set" or "page.secret_unset")
    elseif kind == "string_list" then
      summary = noctalia.trp("page.items", #(type(field.value) == "table" and field.value or {}))
    else
      local count = 0
      for _ in pairs(type(field.value) == "table" and field.value or {}) do
        count += 1
      end
      summary = noctalia.trp("page.items", count)
    end
    return ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = summary, color = "on_surface_variant", fontSize = 11 }),
      ui.button({
        glyph = "external-link",
        variant = "ghost",
        controlSize = "sm",
        onClick = function() openInNoctalia(section) end,
      }),
    })
  elseif kind == "bool" then
    return ui.toggle({ checked = field.value == true, onChange = save })
  elseif kind == "select" then
    local labels, selected = {}, -1
    for index, option in ipairs(field.options) do
      table.insert(labels, option.label)
      if option.value == tostring(field.value) then
        selected = index - 1
      end
    end
    return ui.select({
      key = `select-{at}-{field.key}-{tostring(field.value)}`,
      width = CONTROL_WIDTH,
      controlSize = "sm",
      options = labels,
      selectedIndex = selected,
      onChange = function(index)
        local option = field.options[(tonumber(index) or -1) + 1]
        if option then
          save(option.value)
        end
      end,
    })
  end
  local placeholder = nil
  if (kind == "int" or kind == "double") and field.min ~= nil and field.max ~= nil then
    placeholder = `{field.min}–{field.max}`
  end
  return ui.input({
    -- A new key after each save shows the value that was saved.
    key = `input-{at}-{field.key}-{tostring(field.value)}`,
    width = CONTROL_WIDTH,
    controlSize = "sm",
    value = field.value ~= nil and tostring(field.value) or "",
    placeholder = placeholder,
    onSubmit = save,
  })
end

-- A setting's row and about how tall it is.
local function fieldRow(field, at, section)
  local problem = pageModel.errors and pageModel.errors[`{at}/{field.key}`]
  local height = ROW_HEIGHT
  if field.description then
    height += textHeight(field.description, 4)
  end
  if problem then
    height += textHeight(problem, 3)
  end
  return ui.column({ key = `field-{at}-{field.key}`, gap = 2 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = field.label, flexGrow = 1, maxLines = 2 }),
      fieldControl(field, at, section),
    }),
    field.description and ui.label({ text = field.description, color = "on_surface_variant", fontSize = 11, maxLines = 4 }) or nil,
    problem and ui.label({ text = problem, color = "error", fontSize = 11, maxLines = 3 }) or nil,
  }), height
end

local function sectionTitle(section)
  if section.kind == "plugin" then
    return noctalia.tr("page.section_plugin"), nil
  elseif section.kind == "widget" then
    return noctalia.tr("page.section_widget", { bar = section.bar }), section.instance
  elseif section.kind == "desktop" then
    return noctalia.tr("page.section_desktop"), section.output
  end
  return noctalia.tr("page.section_lockscreen"), section.output
end

local function settingsPage()
  local blocks = {}
  local height = 0
  local hasAdvanced = false
  local loading = pageModel == nil or pageModel.loading
  if loading then
    table.insert(blocks, ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }))
  elseif pageModel.error then
    table.insert(blocks, ui.label({ text = pageModel.error, color = "error", maxLines = 4 }))
  elseif #pageModel.sections == 0 then
    table.insert(blocks, ui.label({ text = noctalia.tr("page.none"), color = "on_surface_variant", maxLines = 3 }))
  else
    local own = pageModel.sections[1].kind == "plugin" and pageModel.sections[1] or nil
    for at, section in ipairs(pageModel.sections) do
      local title, detail = sectionTitle(section)
      local rows = {
        ui.row({ gap = 8, align = "center" }, {
          ui.label({ text = title, fontWeight = "semibold", color = "primary", flexGrow = 1, maxLines = 1 }),
          detail and ui.label({ text = tostring(detail), color = "on_surface_variant", fontSize = 11, maxLines = 1 }) or nil,
        }),
      }
      local sectionHeight = NOTE_HEIGHT
      for _, field in ipairs(section.fields) do
        hasAdvanced = hasAdvanced or field.advanced
        if (showAdvanced or not field.advanced) and isVisible(field, section, own) then
          local row, rowHeight = fieldRow(field, at, section)
          table.insert(rows, row)
          sectionHeight += SECTION_GAP + rowHeight
        end
      end
      -- A section whose settings are all advanced shows once they are.
      if #rows > 1 then
        if #blocks > 0 then
          table.insert(blocks, ui.separator({}))
          height += 2 * PAGE_GAP + 1
        end
        table.insert(blocks, ui.column({ key = `section-{at}`, gap = SECTION_GAP }, rows))
        height += sectionHeight
      end
    end
  end
  if hasAdvanced then
    table.insert(blocks, ui.separator({}))
    height += 2 * PAGE_GAP + 1 + INPUT_HEIGHT
    table.insert(blocks, ui.row({ gap = 8, align = "center", height = INPUT_HEIGHT }, {
      ui.label({ text = noctalia.tr("page.advanced"), color = "on_surface_variant", flexGrow = 1 }),
      ui.toggle({
        checked = showAdvanced,
        onChange = function(value)
          showAdvanced = value == "true"
          render()
        end,
      }),
    }))
  end
  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.button({
        glyph = "arrow-left",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          pageId = nil
          pageModel = nil
          send({ action = "close_settings" })
          render()
        end,
      }),
      ui.label({ text = groupTitle(pageId), fontWeight = "semibold", flexGrow = 1, maxLines = 1 }),
      ui.button({
        text = noctalia.tr("page.open_noctalia"),
        glyph = "external-link",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          send({ action = "settings", id = pageId })
          panel.close()
        end,
      }),
    }),
    -- Placeholders, errors and an empty page show without a scroll.
    not loading and not pageModel.error and #pageModel.sections > 0
        and scrollList(`settings-{pageId}`, PAGE_GAP, height, LIST_MAX, blocks)
      or blocks[1],
  }))
end

render = function()
  if pageId ~= nil then
    settingsPage()
    return
  end
  if model == nil or not model.ready then
    panel.render(ui.column({ gap = 12, padding = 16 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "semibold" }),
      ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }),
    }))
    return
  end
  local blocks = {}
  local height = 0
  for _, group in ipairs(model.groups) do
    local block, blockHeight = groupBlock(group)
    if block then
      if #blocks > 0 then
        table.insert(blocks, ui.separator({}))
        height += 2 * LIST_GAP + 1
      end
      table.insert(blocks, block)
      height += blockHeight
    end
  end
  if #blocks == 0 then
    table.insert(blocks, ui.row({ height = NOTE_HEIGHT, align = "center" }, {
      ui.label({ text = noctalia.tr("panel.no_match"), color = "on_surface_variant" }),
    }))
    height = NOTE_HEIGHT
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "apps", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "semibold", flexGrow = 1 }),
      ui.input({
        key = "search",
        width = 180,
        controlSize = "sm",
        placeholder = noctalia.tr("panel.search"),
        onChange = function(value)
          search = noctalia.string.trim(value)
          render()
        end,
      }),
    }),
  }
  if not model.canBind then
    table.insert(children, ui.label({ text = noctalia.tr("panel.no_keys"), color = "on_surface_variant", fontSize = 11, maxLines = 2 }))
  end
  table.insert(children, scrollList("list", LIST_GAP, height, model.canBind and LIST_MAX or LIST_MAX_NO_KEYS, blocks))
  panel.render(ui.column({ gap = 12, padding = 16 }, children))
end

noctalia.state.watch("hub.model", function(value)
  model = value
  render()
end)

noctalia.state.watch("hub.settings", function(value)
  if pageId ~= nil and type(value) == "table" and value.id == pageId then
    pageModel = value
    render()
  end
end)

-- A plugin id as the context opens that plugin's settings page.
function onOpen(context)
  send({ action = "refresh" })
  model = noctalia.state.get("hub.model") or model
  if type(context) == "string" and context:find("/", 1, true) then
    pageId = context
    pageModel = nil
    showAdvanced = false
    send({ action = "load_settings", id = context })
  end
  render()
end

function onClose()
  editing = nil
  if pageId ~= nil then
    pageId = nil
    pageModel = nil
    send({ action = "close_settings" })
  end
end
