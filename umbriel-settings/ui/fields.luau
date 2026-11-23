--!nonstrict
-- One settings row per field: label, default, Override badge + Reset, a compact control, undo and help.
local kit = require("./kit.luau")
local format = require("./format.luau")
local ctrl = require("./controls.luau")

local M = {}

-- Key of a setting's row (and prefix of its controls' keys); routes reveal it.
function M.rowKey(fid) return "f:" .. fid end

local function indexOf(list, value)
  for index, item in ipairs(list or {}) do
    if item == value then return index end
  end
  return nil
end

local function inRange(field, number)
  if field.min ~= nil and number < field.min then return nil end
  if field.max ~= nil and number > field.max then return nil end
  return number
end

-- Rule fields have no default: an absent key means "match anything" or "leave unchanged".
local function unsetLabel(field)
  return string.sub(field.path, 1, 6) == "match." and "Any" or "Not set"
end

local function hasDefault(field) return field.default ~= nil end

-- A switch for a number's special value (-1 = automatic, 0 = never, ...): on writes that value; off goes back
-- to the last other value, else the default or the initial value.
local function specialChip(ctx, spec, effective)
  local field, view, key = spec.field, ctx.view, spec.key
  local special = field.special
  local active = effective == special.value
  return ui.button({
    key = key .. ":special", text = special.label, controlSize = "sm", selected = active,
    variant = active and "primary" or "outline",
    tooltip = active and ("Uses " .. string.lower(special.label) .. "; click to choose a number")
      or ("Use " .. string.lower(special.label)),
    onClick = function()
      if active then
        local back = view.lastNumber[key]
        if back == nil and field.default ~= nil and field.default ~= special.value then back = field.default end
        if back == nil and field.initial ~= nil and field.initial ~= special.value then back = field.initial end
        if back == nil then back = math.max(field.min or 0, special.value + 1) end
        spec.onSet(back)
      else
        if type(effective) == "number" then view.lastNumber[key] = effective end
        spec.onSet(special.value)
      end
      ctx.bump(key)
      ctx.render()
    end,
  })
end

local function numberControl(ctx, spec, effective)
  local field, view, key = spec.field, ctx.view, spec.key
  local integer = field.kind == "int"
  local controls = {}
  local special = field.special
  local isSpecial = special ~= nil and effective == special.value
  local low = field.min
  -- the special value has its own switch, so the slider starts above it
  if special and low ~= nil and low <= special.value then low = special.value + 1 end
  local hasRange = low ~= nil and field.max ~= nil and field.max > low and field.max - low <= 100000
  if special then table.insert(controls, specialChip(ctx, spec, effective)) end
  if hasRange then
    local step = integer and 1 or ((field.max - low) <= 2 and 0.01 or (field.max - low) <= 20 and 0.05 or 0.5)
    local function whole(number) return integer and math.floor(number + 0.5) or number end
    local shown = effective
    if shown == nil or isSpecial then shown = view.lastNumber[key] or field.initial or low end
    if special and shown == special.value then shown = low end
    table.insert(controls, ctrl.slider(ctx, {
      key = key .. ":slider", min = low, max = field.max, step = step, value = shown, flexGrow = 1,
      controlSize = "sm", opacity = isSpecial and 0.4 or nil,
    }, function() ctx.bump(key) end, function(number)
      spec.onSet(whole(number))
      ctx.bump(key)
    end))
  end
  -- While a slider gesture runs, the box shows the value it would set.
  local preview = ctrl.sliding(ctx, key .. ":slider")
  if preview ~= nil then preview = integer and math.floor(preview + 0.5) or preview end
  local boxValue = preview ~= nil and preview or effective
  if isSpecial and preview == nil then boxValue = nil end  -- the switch says it; the box stays empty
  table.insert(controls, ui.input({
    key = key .. ":num:" .. ctx.gen(key), value = boxValue ~= nil and format.value(field, boxValue) or "",
    width = hasRange and 84 or nil, flexGrow = (not hasRange) and 1 or nil, controlSize = "sm",
    placeholder = (effective == nil and field.initial ~= nil) and ("e.g. " .. format.value(field, field.initial))
      or (field.min ~= nil and field.max ~= nil) and (format.number(field.min) .. " – " .. format.number(field.max)) or "number",
    onChange = function(text)
      local number = ctrl.parseNumber(text, integer)
      if number ~= nil and inRange(field, number) ~= nil then
        view.invalid[key] = nil
        spec.onSet(number)
      elseif noctalia.string.trim(text) == "" then
        view.invalid[key] = nil  -- an empty box is still being typed into, not an error
      else
        local range = ""
        if field.min ~= nil and field.max ~= nil then
          range = " between " .. format.number(field.min) .. " and " .. format.number(field.max)
        elseif field.min ~= nil then range = " of at least " .. format.number(field.min)
        elseif field.max ~= nil then range = " of at most " .. format.number(field.max) end
        view.invalid[key] = (integer and "Enter a whole number" or "Enter a number") .. range
      end
      ctx.render()
    end,
  }))
  if field.unit then table.insert(controls, kit.muted(field.unit, { fontSize = kit.FONT.caption })) end
  return controls
end

local function colorControl(ctx, spec, effective)
  local key, view = spec.key, ctx.view
  local value = type(effective) == "string" and effective or ctrl.NO_COLOR
  local controls = {
    ui.box({ width = 34, height = 22, radius = kit.RADIUS.sm, fill = value, border = "outline_variant", borderWidth = 1,
             onClick = function()
               view.openColor = view.openColor ~= key and key or nil
               ctx.render()
             end, tooltip = "Pick a color" }),
    ui.input({ key = key .. ":hex:" .. ctx.gen(key), value = effective or "", width = 120, controlSize = "sm",
               placeholder = "#RRGGBBAA",
               onChange = function(text)
                 text = noctalia.string.trim(text)
                 if string.match(text, "^#%x%x%x%x%x%x$") or string.match(text, "^#%x%x%x%x%x%x%x%x$") then
                   view.invalid[key] = nil
                   spec.onSet(string.upper(text))
                 else
                   view.invalid[key] = text ~= "" and "Use #RRGGBB or #RRGGBBAA" or nil
                 end
                 ctx.render()
               end }),
  }
  for _, source in ipairs(spec.kdeColors or {}) do
    local followed = spec.follow ~= nil and spec.follow.source == source.source
    table.insert(controls, ui.button({
      key = key .. ":kde:" .. source.label, text = source.label, controlSize = "sm", variant = "ghost",
      selected = followed,
      tooltip = spec.onFollow and source.source and ("Follow Noctalia: keep using " .. source.tooltip
        .. " after palette changes") or ("Use " .. tostring(source.hex) .. " from " .. source.tooltip),
      onClick = function()
        local alpha = string.len(value) == 9 and string.sub(value, 8, 9) or "FF"
        if spec.onFollow and source.source then
          spec.onFollow(source.source, tonumber(alpha, 16) / 255)
        else
          spec.onSet(string.sub(source.hex, 1, 7) .. alpha)
        end
        ctx.bump(key)
        ctx.render()
      end,
    }))
  end
  return controls
end

local function choiceControl(ctx, spec, effective)
  local field, key, view = spec.field, spec.key, ctx.view
  local choices = field.choices or {}
  if field.names_from then
    local extra = field.names_from == "output" and ctx.liveOutputs() or nil
    choices = ctx.store.namedChoices(field.names_from, choices, extra)
  end
  local options, offset = {}, 0
  local unsettable = spec.onUnset ~= nil and not hasDefault(field)
  if unsettable then table.insert(options, unsetLabel(field)); offset = 1 end
  local labels = field.choice_labels or choices
  for i, choice in ipairs(choices) do
    local label = labels[i] or choice
    table.insert(options, label == "" and "None" or label)
  end
  local index = indexOf(choices, effective)
  local custom = field.kind == "combo" and (view.custom[key] or (effective ~= nil and index == nil))
  if field.kind == "combo" then table.insert(options, "Custom…") end
  -- A value from the file that is not among the choices is shown as itself, not as the first choice.
  local stray = field.kind ~= "combo" and effective ~= nil and index == nil
  if stray then table.insert(options, tostring(effective) .. " (not a known value)") end
  local selected
  if custom or stray then selected = #options
  elseif index then selected = index + offset
  else selected = 1 end
  local controls = { ui.select({
    key = key .. ":select", options = options, selectedIndex = selected - 1, flexGrow = 1, controlSize = "sm",
    onChange = function(text)
      local chosen = (tonumber(text) or 0) + 1
      if stray and chosen == #options then
        return
      elseif field.kind == "combo" and chosen == #options then
        view.custom[key] = true
      elseif unsettable and chosen == 1 then
        view.custom[key] = nil
        spec.onUnset()
      else
        view.custom[key] = nil
        spec.onSet(choices[chosen - offset])
      end
      ctx.render()
    end,
  }) }
  if custom then
    table.insert(controls, ui.input({
      key = key .. ":custom:" .. ctx.gen(key), value = (index == nil and effective) or "", flexGrow = 1,
      controlSize = "sm", placeholder = "Custom value", focus = true,
      onChange = function(text) spec.onSet(text); ctx.render() end,
    }))
  end
  return controls
end

-- Three-way switch for optional booleans without a default (the app's tri-state).
local function triControl(ctx, spec)
  local field, key = spec.field, spec.key
  local current = spec.set and (spec.value and 2 or 3) or 1
  local controls = {}
  for index, label in ipairs({ unsetLabel(field), "On", "Off" }) do
    -- "Any" (no key) is the quiet state: selected, but only a chosen On/Off is filled
    local selected = current == index
    table.insert(controls, ui.button({
      key = key .. ":tri:" .. index, text = label, controlSize = "sm", flexGrow = 1, selected = selected,
      variant = not selected and "ghost" or (index == 1 and "secondary" or "primary"),
      onClick = function()
        if index == 1 then spec.onUnset() else spec.onSet(index == 2) end
        ctx.render()
      end,
    }))
  end
  return controls
end

local function textControl(ctx, spec, effective, placeholder)
  local key = spec.key
  return { ui.input({
    key = key .. ":text:" .. ctx.gen(key), value = effective ~= nil and tostring(effective) or "",
    flexGrow = 1, controlSize = "sm", placeholder = placeholder,
    onChange = function(text) spec.onSet(text); ctx.render() end,
  }) }
end

-- spec: key, field, value, set, changed, onSet(v), onUnset() or nil, onRevert() or nil, diagnostic, kdeColors
function M.row(ctx, spec)
  local field, view, key = spec.field, ctx.view, spec.key
  local effective = spec.value
  if not spec.set then effective = field.default end
  local follow = spec.follow
  if follow and follow.color then effective = follow.color end
  local kind = field.kind
  local controls, below = {}, nil
  if kind == "bool" and spec.onUnset and not hasDefault(field) then
    controls = triControl(ctx, spec)
  elseif kind == "bool" then
    controls = { ui.toggle({ key = key .. ":toggle", checked = effective == true,
                             onChange = function(text) spec.onSet(text == "true"); ctx.render() end }) }
  elseif kind == "int" or kind == "float" then
    controls = numberControl(ctx, spec, effective)
  elseif kind == "color" then
    controls = colorControl(ctx, spec, effective)
  elseif kind == "choice" or kind == "combo" then
    controls = choiceControl(ctx, spec, effective)
    if field.picker == "file" then  -- e.g. an ICC profile next to "none"/"edid": the path becomes the custom value
      table.insert(controls, ctrl.browseButton(ctx, spec, function(path)
        ctx.view.custom[spec.key] = true
        spec.onSet(path)
        ctx.bump(spec.key)  -- the custom text box shows the chosen path
      end))
    end
  elseif kind == "table" then
    controls = ctrl.tableControl(ctx, spec, effective)
  elseif kind == "list" or kind == "command_list" then
    below = ctrl.listRows(ctx, spec, spec.set and spec.value or nil)
  else
    local hint = field.default ~= nil and field.default or field.initial
    local placeholder = field.placeholder or (hint ~= nil and format.value(field, hint) or "")
    if placeholder == "empty" or placeholder == "not set" then placeholder = "" end
    if kind == "raw" then placeholder = "TOML value" .. (placeholder ~= "" and (", e.g. " .. placeholder) or "") end
    controls = field.picker == "mode" and ctrl.modeControl(ctx, spec)
      or textControl(ctx, spec, spec.set and spec.value or nil, placeholder)
    if field.picker == "file" then
      table.insert(controls, ctrl.browseButton(ctx, spec, function(path)
        spec.onSet(path)
        ctx.bump(spec.key)  -- the text box shows the chosen path
      end))
    end
    if field.picker == "xkb" then
      local entry = spec.entry or {}
      table.insert(controls, ui.button({ key = key .. ":pick", text = "Choose…", glyph = "keyboard",
        controlSize = "sm", variant = "outline", tooltip = "Pick from the layouts XKB knows",
        onClick = function() ctx.go({ name = "xkb", editor = entry.editor, index = entry.index }) end }))
    end
  end

  local labelRow = { ui.label({ text = field.label, fontSize = kit.FONT.body, maxLines = 2 }) }
  if field.restart then
    -- glyphs take no tooltip in Noctalia: the row around it does
    table.insert(labelRow, ui.row({ tooltip = "Takes effect after restarting Umbriel" }, {
      ui.glyph({ name = "refresh-alert", size = kit.GLYPH.small, color = "tertiary" }),
    }))
  end
  -- One quiet line: a hint, then "Default 2"; an overridden key gets the Override badge instead of a color.
  local defaultText = hasDefault(field) and format.value(field, field.default) or nil
  if defaultText == "empty" then defaultText = nil end
  local customized = spec.set and (defaultText == nil or ctx.store.differs(field, spec.value))
  local status
  if follow then
    status = "Follows Noctalia · " .. (follow.source == "kde" and "KDE" or "KDE header")
  elseif defaultText then
    status = "Default " .. defaultText
  end
  if field.hint and not follow then status = status and (field.hint .. " · " .. status) or field.hint end

  local actions = {}
  if spec.onRevert then
    table.insert(actions, ui.button({ key = key .. ":undo", glyph = "arrow-back-up", variant = "ghost", controlSize = "sm",
      tooltip = "Undo this change", onClick = function() spec.onRevert(); ctx.bump(key); ctx.render() end }))
  end
  table.insert(actions, ui.button({ key = key .. ":help", glyph = "info-circle", variant = "ghost", controlSize = "sm",
    tooltip = "Show help", selected = view.help[key] == true,
    onClick = function() view.help[key] = not view.help[key] or nil; ctx.render() end }))

  local main = {
    ui.column({ gap = 2, flexGrow = 1, tooltip = field.help }, {
      ui.row({ gap = 6, align = "center" }, labelRow),
      status and kit.muted(status, { maxLines = 1 }) or nil,
    }),
  }
  -- centered on the whole row like the control, not on the label's line
  if spec.changed then table.insert(main, kit.badge("unsaved", "primary", key .. ":b1")) end
  if follow then
    table.insert(main, ui.button({ key = key .. ":unfollow", text = "Stop following", variant = "ghost",
      controlSize = "sm", tooltip = "Stop following Noctalia",
      onClick = function() spec.onFollow(nil); ctx.bump(key); ctx.render() end }))
  else
    if customized then table.insert(main, kit.overrideBadge(key .. ":override")) end
    -- Like Noctalia: the first click asks to confirm; any edit or leaving the page cancels that.
    if spec.onUnset and spec.set then
      local pending = view.confirmReset
      pending = pending ~= nil and pending.key == key and pending.serial == ctx.store.serial
      table.insert(main, ui.button({ key = key .. ":reset", text = pending and "Confirm Reset" or "Reset",
        variant = pending and "destructive" or "ghost", controlSize = "sm",
        tooltip = "Remove the key and use Umbriel's default", onClick = function()
          if not pending then
            view.confirmReset = { key = key, serial = ctx.store.serial }
            ctx.render()
            return
          end
          view.confirmReset = nil
          spec.onUnset(); ctx.bump(key); view.custom[key] = nil; ctx.render()
        end }))
    end
  end
  -- Keyed: the badges and Reset before them come and go with edits, and an unkeyed row that moves is rebuilt,
  -- which would replace the input being typed in.
  table.insert(main, ui.row({ key = key .. ":controls", width = ctrl.EDITOR_WIDTH, gap = 6, align = "center",
                              opacity = spec.set and 1 or 0.75 }, controls))
  table.insert(main, ui.row({ key = key .. ":actions", width = ctrl.ACTIONS_WIDTH, gap = 0, justify = "end",
                              align = "center" }, actions))
  local children = { ui.row({ key = key .. ":main", gap = 12, align = "center" }, main) }
  if below then
    table.insert(children, ui.column({ key = key .. ":list", gap = 4, paddingH = 8 }, below))
  end
  if kind == "color" and field.opacity then
    local row = ctrl.opacityRow(ctx, spec, effective)
    if row then table.insert(children, row) end
  end
  if view.openColor == key and kind == "color" then
    table.insert(children, ui.row({ key = key .. ":picker", justify = "end" }, {
      ui.colorPicker({ key = key .. ":cp", value = type(effective) == "string" and effective or ctrl.NO_COLOR,
                       alpha = true, inputs = "hex", width = 300, swatches = ctx.swatches(),
                       onChangeEnd = function(color) spec.onSet(string.upper(color)); ctx.bump(key); ctx.render() end }),
    }))
  end
  if view.help[key] then
    table.insert(children, ui.column({ key = key .. ":helptext", gap = 2, padding = 8, radius = kit.RADIUS.md,
                                       fill = "surface_container_high" }, {
      ui.label({ text = field.help or "", fontSize = kit.FONT.small, maxLines = 12 }),
      ui.row({ key = key .. ":keyrow", gap = 4, align = "center" }, {
        kit.muted("Config key: " .. field.path, { fontSize = kit.FONT.caption, flexGrow = 1 }),
        kit.iconButton("copy", "Copy config key", function()
          local copied = noctalia.copyToClipboard(field.path, "text/plain")
          ctx.flash(copied and ("Copied “" .. field.path .. "”.") or "Could not copy the config key.",
                    copied and "info" or "error")
          ctx.render()
        end, true, key .. ":copykey"),
      }),
    }))
  end
  local problem = view.invalid[key] or spec.diagnostic
  if problem then table.insert(children, kit.notice(problem, "error", nil, key .. ":problem")) end
  return ui.column({ key = key, gap = 4, paddingV = 6, paddingH = 4 }, children)
end

return M
