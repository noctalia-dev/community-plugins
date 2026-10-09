--!nonstrict
-- The settings panel. Holds the unsaved draft (in noctalia.state, so it
-- survives closing the panel), sends apply/keep/revert to the service and
-- shows its countdown. All saving logic lives in service.luau and txn.lua.

local catalog = require("./lib/catalog.luau")
local monitors = require("./lib/monitors.luau")
local draftlib = require("./lib/draft.luau")

local tr = noctalia.tr
local PAGES = {
  { id = "appearance", glyph = "palette" },
  { id = "input", glyph = "keyboard" },
  { id = "system", glyph = "settings" },
  { id = "animations", glyph = "movie" },
  { id = "displays", glyph = "device-desktop" },
}

local isOpen = false
local page = noctalia.state.get("hs.page") or "appearance"
local live = noctalia.state.get("hs.live") or { values = {}, monitors = {}, errors = {} }
local saved = noctalia.state.get("hs.saved") or {}
local txn = noctalia.state.get("hs.txn") or { status = "idle" }
local setup = noctalia.state.get("hs.setup") -- nil until the service has checked
local draft = noctalia.state.get("hs.draft") or draftlib.copy(saved)
local expanded = {} -- rows with the reason field open
local dismissed = nil -- txn id whose final banner was dismissed
local render

-- A control the user has touched keeps its own position, whatever value a
-- later render passes. After undo, erase or discard it therefore gets a new
-- key, so the host builds it fresh from the draft value.
local generation, generationAll = {}, 0
local function gk(name, id)
  return name .. "-" .. id .. "-" .. generationAll .. "." .. (generation[id] or 0)
end
local function refreshControls(id)
  if id then generation[id] = (generation[id] or 0) + 1 else generationAll += 1 end
end

local function commit()
  noctalia.state.set("hs.draft", draft)
  render()
end

local function send(op, extra)
  local request = { seq = noctalia.nowMs(), op = op }
  for k, v in pairs(extra or {}) do request[k] = v end
  noctalia.state.set("hs.request", request)
end

local function fmt(v)
  if type(v) == "number" then
    if v == math.floor(v) then return string.format("%d", v) end
    return (string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", ""))
  end
  if type(v) == "table" then return string.format("%d %d %d %d", v.top, v.right, v.bottom, v.left) end
  return tostring(v)
end

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n += 1 end
  return n
end

-- Revert reasons arrive as codes from the service.
local function reasonText(r)
  if r == nil or r == "" then return "" end
  local err = r:match("^config_error:(.*)$")
  if err then return tr("reason.config_error", { error = err }) end
  local key = "reason." .. r
  local s = tr(key)
  return s ~= key and s or r
end

-- Unsaved changes: options, preset and monitor rules that differ from saved.
local function changes()
  local n = 0
  local paths = {}
  for p in pairs(draft.options or {}) do paths[p] = true end
  for p in pairs(saved.options or {}) do paths[p] = true end
  for p in pairs(paths) do
    if not draftlib.equal((draft.options or {})[p], (saved.options or {})[p]) then n += 1 end
  end
  if not draftlib.equal(draft.preset, saved.preset) then n += 1 end
  if not draftlib.equal(draft.monitors or {}, saved.monitors or {}) then n += 1 end
  return n
end

-- ------------------------------------------------------------ option rows

local function setValue(option, value)
  draftlib.setOption(draft, option.path, value)
  commit()
end

local function slider(option, value)
  local v = type(value) == "table" and value.top or value or option.min or 0
  return ui.row({ gap = 8, align = "center", width = 260 }, {
    ui.slider({
      key = gk("s", option.path), min = option.min, max = option.max, step = option.step or 1, value = v,
      controlSize = "sm", flexGrow = 1,
      onChange = function(text)
        local x = draftlib.snap(option, text)
        if x ~= nil then setValue(option, x) end
      end,
    }),
    ui.label({ text = fmt(v) .. (option.unit and (" " .. option.unit) or ""), width = 64, textAlign = "end", color = "on_surface_variant" }),
  })
end

local function selector(option, value, labels, values)
  local selected = -1
  for i, v in ipairs(values) do
    if v == value then selected = i - 1 end
  end
  return ui.select({
    key = gk("c", option.path), options = labels, selectedIndex = selected, controlSize = "sm", width = 260,
    onChange = function(index) setValue(option, values[(tonumber(index) or 0) + 1]) end,
  })
end

local function control(option, value)
  local kind = option.kind
  if value == nil and kind ~= "string" then
    return ui.label({ text = tr("ui.unavailable"), color = "on_surface_variant", fontSize = 12 })
  end
  if kind == "bool" then
    return ui.toggle({ key = gk("t", option.path), checked = value == true,
      onChange = function(v) setValue(option, v == "true") end })
  elseif kind == "int" or kind == "float" or kind == "gaps" then
    return slider(option, value)
  elseif kind == "choice" then
    local labels = {}
    for _, c in ipairs(option.choices) do
      table.insert(labels, tr("choice." .. option.path .. "." .. (c == "" and "default" or c)))
    end
    return selector(option, value, labels, option.choices)
  elseif kind == "enum" then
    local labels = {}
    for _, c in ipairs(option.choices) do table.insert(labels, tr("enum." .. option.path .. "." .. c)) end
    return selector(option, value, labels, option.choices)
  end
  -- string: the input owns its text; the draft follows it
  return ui.input({
    key = gk("i", option.path), value = value or "", controlSize = "sm", width = 260,
    onChange = function(text)
      draftlib.setOption(draft, option.path, text)
      noctalia.state.set("hs.draft", draft)
    end,
    onSubmit = function() render() end,
  })
end

local function optionRow(option)
  local path = option.path
  local entry = draft.options and draft.options[path]
  local value = draftlib.value(draft, live, path)
  local savedEntry = saved.options and saved.options[path]

  local name = ui.label({ text = tr("opt." .. path), fontSize = 14, color = entry and "primary" or "on_surface" })
  if not draftlib.equal(entry, savedEntry) then
    name = ui.row({ gap = 6, align = "center" }, { name, ui.glyph({ name = "point-filled", size = 10, color = "primary" }) })
  end
  local text = {
    name,
    ui.label({ text = tr("desc." .. path), fontSize = 12, color = "on_surface_variant", maxLines = 2 }),
  }
  if entry and entry.why and not expanded[path] then
    table.insert(text, ui.label({ text = "“" .. entry.why .. "”", fontSize = 12, color = "on_surface_variant", maxLines = 2 }))
  end

  local tail = {}
  if savedEntry and live.values[path] ~= nil and not draftlib.equal(savedEntry.value, live.values[path])
      and draftlib.equal(entry and entry.value, savedEntry.value) then
    table.insert(tail, ui.box({ tooltip = tr("ui.not_effective", { saved = fmt(savedEntry.value), live = fmt(live.values[path]) }) }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
    }))
  end
  table.insert(tail, ui.button({
    glyph = "notes", variant = "ghost", controlSize = "sm", tooltip = tr("ui.why"), selected = expanded[path] == true,
    onClick = function()
      if entry == nil and value ~= nil then draftlib.setOption(draft, path, value) end
      expanded[path] = not expanded[path] or nil
      commit()
    end,
  }))
  -- ↶ undoes this row's unsaved change; the eraser takes the value out of
  -- the file. Placeholders keep the column aligned.
  local function slot(visible, button)
    table.insert(tail, visible and button or ui.row({ width = 32, height = 32 }, {}))
  end
  slot(not draftlib.equal(entry, savedEntry), ui.button({
    glyph = "arrow-back-up", variant = "ghost", controlSize = "sm", tooltip = tr("ui.undo"),
    onClick = function()
      draftlib.revertOption(draft, saved, path)
      refreshControls(path)
      commit()
    end,
  }))
  slot(entry ~= nil, ui.button({
    glyph = "eraser", variant = "ghost", controlSize = "sm", tooltip = tr("ui.unmanage"),
    onClick = function()
      draftlib.unmanage(draft, path)
      expanded[path] = nil
      refreshControls(path)
      commit()
    end,
  }))

  local row = ui.row({ key = "row-" .. path, gap = 12, align = "center" }, {
    ui.column({ gap = 2, flexGrow = 1 }, text),
    control(option, value),
    ui.row({ gap = 0, align = "center", width = 128, justify = "end" }, tail),
  })
  local parts = { row }
  if option.kind == "gaps" and type(value) == "table" then
    table.insert(parts, ui.label({ text = tr("ui.gaps_sides", { sides = fmt(value) }), fontSize = 12, color = "on_surface_variant" }))
  end
  if expanded[path] then
    table.insert(parts, ui.input({
      key = gk("why", path), value = entry and entry.why or "", placeholder = tr("ui.why_placeholder"),
      controlSize = "sm", focus = true,
      onChange = function(t)
        draftlib.setWhy(draft, path, t)
        noctalia.state.set("hs.draft", draft)
      end,
      onSubmit = function()
        expanded[path] = nil
        render()
      end,
    }))
  end
  return ui.column({ key = "opt-" .. path, gap = 6, paddingV = 4 }, parts)
end

local function section(title, children)
  local body = { ui.label({ text = title, fontSize = 12, fontWeight = "bold", color = "primary" }) }
  for _, c in ipairs(children) do table.insert(body, c) end
  return ui.column({ gap = 4, padding = 12, radius = 12, fill = "surface_variant/0.45" }, body)
end

local function legend(key, warn)
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "info-circle", size = 16, color = warn and "error" or "on_surface_variant" }),
    ui.label({ text = tr(key), fontSize = 12, color = warn and "error" or "on_surface_variant", flexGrow = 1, maxLines = 2 }),
  })
end

local function optionPage(id)
  local sections, current, rows = { legend("ui.legend") }, nil, nil
  for _, option in ipairs(catalog.options) do
    local hidden = option.dependsOn and draftlib.value(draft, live, option.dependsOn) ~= true
    if option.page == id and not hidden then
      if option.group ~= current then
        if rows then table.insert(sections, section(tr("group." .. current), rows)) end
        current, rows = option.group, {}
      end
      table.insert(rows, optionRow(option))
    end
  end
  if rows then table.insert(sections, section(tr("group." .. current), rows)) end
  return sections
end

-- ------------------------------------------------------------ animations

local function animationsPage()
  local sections = optionPage("animations")
  local names = { "", "futurista" }
  local selected = draft.preset and draft.preset.name == "futurista" and 1 or 0
  table.insert(sections, section(tr("anim.section"), {
    ui.row({ gap = 12, align = "center" }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("anim.preset"), fontSize = 14, color = draft.preset and "primary" or "on_surface" }),
        ui.label({ text = tr("anim.preset_desc"), fontSize = 12, color = "on_surface_variant", maxLines = 2 }),
      }),
      ui.select({
        key = gk("preset", "preset"), options = { tr("anim.none"), tr("anim.futurista") }, selectedIndex = selected,
        controlSize = "sm", width = 260,
        onChange = function(index)
          local name = names[(tonumber(index) or 0) + 1]
          draft.preset = name ~= "" and { name = name, why = draft.preset and draft.preset.why } or nil
          commit()
        end,
      }),
      ui.row({ width = 128 }, {}),
    }),
    ui.label({ text = tr("anim.credit"), fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
  }))
  return sections
end

-- ------------------------------------------------------------ displays

local function changeMonitor(name, patch)
  local ok, err = draftlib.changeMonitor(monitors, draft, live, name, patch)
  if not ok then noctalia.log("hyprland-settings: " .. tostring(err)) end
  commit()
end

local function monitorCard(row, index, rows)
  local m, rule = row.monitor, row.rule
  local on = not rule.disabled
  local enabledCount = 0
  for _, r in ipairs(rows) do
    if not r.rule.disabled then enabledCount += 1 end
  end

  -- modes: the monitor's own list, highest first as Hyprland lists them
  local modeLabels, modeValues, current = {}, {}, monitors.resolveMode(rule.mode, m)
  for _, available in ipairs(m.availableModes or {}) do
    local w, h, hz = monitors.parseMode(available)
    table.insert(modeLabels, string.format("%d × %d  @ %s Hz", w, h, fmt(math.round(hz * 100) / 100)))
    table.insert(modeValues, monitors.ruleMode(available))
  end
  local modeIndex = -1
  for i, v in ipairs(modeValues) do
    if v == current then modeIndex = i - 1 end
  end

  local scales = draftlib.scales(monitors, current or modeValues[1] or "", rule.scale)
  local scaleLabels, scaleIndex = {}, -1
  for i, s in ipairs(scales) do
    table.insert(scaleLabels, fmt(s) .. "×")
    if math.abs(s - rule.scale) < 1e-6 then scaleIndex = i - 1 end
  end
  local tLabels = {}
  for t = 0, 7 do table.insert(tLabels, tr("disp.t" .. t)) end

  local header = ui.row({ gap = 10, align = "center" }, {
    ui.glyph({ name = m.name:match("^eDP") and "device-laptop" or "device-desktop", size = 22, color = on and "primary" or "on_surface_variant" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = (m.make ~= "" and (m.make .. " " .. m.model) or m.name), fontSize = 14, fontWeight = "bold" }),
      ui.label({ text = m.name .. " · " .. (row.managed and tr("disp.saved") or tr("disp.live")) .. " · "
        .. tr("disp.position", { pos = rule.position }), fontSize = 12, color = "on_surface_variant" }),
    }),
    ui.button({ glyph = "arrow-left", variant = "ghost", controlSize = "sm", tooltip = tr("disp.left"),
      enabled = on and index > 1, onClick = function() changeMonitor(m.name, { move = -1 }) end }),
    ui.button({ glyph = "arrow-right", variant = "ghost", controlSize = "sm", tooltip = tr("disp.right"),
      enabled = on and rows[index + 1] ~= nil and not rows[index + 1].rule.disabled,
      onClick = function() changeMonitor(m.name, { move = 1 }) end }),
    ui.toggle({ key = gk("on", m.name), checked = on, enabled = not on or enabledCount > 1,
      onChange = function(v) changeMonitor(m.name, { disabled = v ~= "true" }) end }),
  })

  local function field(label, ctl)
    return ui.row({ gap = 12, align = "center" }, {
      ui.label({ text = label, fontSize = 13, color = "on_surface_variant", flexGrow = 1 }), ctl,
    })
  end
  local body = { header }
  if on then
    table.insert(body, field(tr("disp.mode"), ui.select({ key = gk("mode", m.name), options = modeLabels, selectedIndex = modeIndex,
      controlSize = "sm", width = 300,
      onChange = function(i)
        local mode = modeValues[(tonumber(i) or 0) + 1]
        local patch = { mode = mode }
        -- keep the scale valid for the new mode
        if not monitors.logicalSize(mode, rule.scale, 0) then patch.scale = 1 end
        changeMonitor(m.name, patch)
      end })))
    table.insert(body, field(tr("disp.scale"), ui.select({ key = gk("scale", m.name), options = scaleLabels, selectedIndex = scaleIndex,
      controlSize = "sm", width = 300,
      onChange = function(i) changeMonitor(m.name, { scale = scales[(tonumber(i) or 0) + 1] }) end })))
    table.insert(body, field(tr("disp.rotation"), ui.select({ key = gk("rot", m.name), options = tLabels, selectedIndex = rule.transform or 0,
      controlSize = "sm", width = 300,
      onChange = function(i) changeMonitor(m.name, { transform = tonumber(i) or 0 }) end })))
  elseif enabledCount == 0 then
    table.insert(body, ui.label({ text = tr("disp.last"), fontSize = 12, color = "error" }))
  end
  if row.managed then
    local stored = monitors.ruleFor(draft.monitors or {}, m)
    table.insert(body, ui.input({ key = gk("why-mon", m.name), value = stored and stored.why or "", placeholder = tr("disp.why"),
      controlSize = "sm",
      onChange = function(t)
        local r = monitors.ruleFor(draft.monitors or {}, m)
        if r then r.why = t ~= "" and t or nil end
        noctalia.state.set("hs.draft", draft)
      end }))
  end
  return ui.column({ key = "mon-" .. m.name, gap = 10, padding = 14, radius = 12,
    fill = on and "surface_variant/0.45" or "surface_variant/0.2" }, body)
end

-- The row to scale: one box per enabled screen, sized by its logical size.
local function minimap(rows)
  local boxes, sizes, width, height = {}, {}, 0, 0
  for _, row in ipairs(rows) do
    if not row.rule.disabled then
      local w, h = monitors.logicalSize(monitors.resolveMode(row.rule.mode, row.monitor) or "", row.rule.scale, row.rule.transform)
      if w then
        table.insert(sizes, { row = row, w = w, h = h })
        width += w
        height = math.max(height, h)
      end
    end
  end
  if #sizes == 0 then return nil end
  local k = math.min(560 / width, 96 / height)
  for _, s in ipairs(sizes) do
    table.insert(boxes, ui.column({ key = "map-" .. s.row.monitor.name, width = math.floor(s.w * k), height = math.floor(s.h * k),
      radius = 6, fill = "primary/0.18", border = "primary/0.6", borderWidth = 1, justify = "center", align = "center" }, {
      ui.label({ text = s.row.monitor.name, fontSize = 11, color = "on_surface" }),
      ui.label({ text = string.format("%d × %d", s.w, s.h), fontSize = 10, color = "on_surface_variant" }),
    }))
  end
  return ui.row({ gap = 3, justify = "center", align = "start", paddingV = 4 }, boxes)
end

local function displaysPage()
  local rows = draftlib.monitorRows(monitors, draft, live)
  local out = { legend(draftlib.isRow(rows) and "disp.row_hint" or "disp.not_row", not draftlib.isRow(rows)) }
  local map = minimap(rows)
  if map then table.insert(out, map) end
  for i, row in ipairs(rows) do table.insert(out, monitorCard(row, i, rows)) end
  local offline = draftlib.offlineRules(monitors, draft, live)
  if #offline > 0 then
    local items = {}
    for _, o in ipairs(offline) do
      table.insert(items, ui.row({ key = "off-" .. o.rule.output, gap = 10, align = "center" }, {
        ui.glyph({ name = "plug-connected-x", size = 18, color = "on_surface_variant" }),
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = o.rule.output:gsub("^desc:", ""), fontSize = 13 }),
          ui.label({ text = string.format("%s · %s× · %s", o.rule.mode, fmt(o.rule.scale), o.rule.position)
            .. (o.rule.why and ("  “" .. o.rule.why .. "”") or ""), fontSize = 12, color = "on_surface_variant", maxLines = 2 }),
        }),
        ui.button({ glyph = "trash", variant = "ghost", controlSize = "sm", tooltip = tr("disp.remove"),
          onClick = function() draftlib.removeRule(draft, o.index); commit() end }),
      }))
    end
    table.insert(out, section(tr("disp.offline"), items))
  end
  return out
end

-- ------------------------------------------------------------ first-run setup

-- "/home/me/.config/hypr/x" -> "~/.config/hypr/x" for display.
local function short(path)
  local home = noctalia.getenv("HOME")
  if path and home and path:sub(1, #home + 1) == home .. "/" then return "~" .. path:sub(#home + 1) end
  return path or ""
end

local function code(text)
  return ui.label({ text = text, fontFamily = "monospace", fontSize = 13, color = "on_surface",
    maxLines = 2 })
end

-- Shown until Hyprland has loaded the settings file. Asks once; after "No"
-- it shows what to do by hand.
local function setupCard()
  if setup == nil or setup.loaded then return nil end
  local body = {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "plug-connected-x", size = 20, color = "primary" }),
      ui.label({ text = tr("setup.title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
    }),
  }
  local function add(node) table.insert(body, node) end
  local line = 'require("' .. (setup.module or "hyprland-settings") .. '")'

  if setup.state == "working" then
    add(ui.label({ text = tr("setup.working"), fontSize = 13, color = "on_surface_variant" }))
  elseif setup.module == nil then
    add(ui.label({ text = tr("setup.custom_path", { file = short(setup.file) }), fontSize = 13, maxLines = 4 }))
  elseif not setup.declined and setup.state ~= "error" then
    add(ui.label({ text = tr("setup.ask", { conf = short(setup.conf) }), fontSize = 13, maxLines = 4 }))
    add(code(line))
    add(ui.row({ gap = 8, justify = "end" }, {
      ui.button({ text = tr("setup.no"), variant = "ghost", controlSize = "sm",
        onClick = function() send("setup_decline") end }),
      ui.button({ text = tr("setup.yes"), glyph = "check", variant = "primary", controlSize = "sm",
        onClick = function() send("setup") end }),
    }))
  else
    if setup.state == "error" then
      local message = setup.message == "not_loaded" and tr("setup.not_loaded")
        or setup.code == 3 and tr("setup.no_lua")
        or tr("setup.failed", { reason = setup.message or "" })
      add(ui.label({ text = message, fontSize = 13, color = "error", maxLines = 4 }))
    end
    add(ui.label({ text = tr("setup.manual"), fontSize = 13, maxLines = 2 }))
    add(ui.label({ text = tr("setup.step1"), fontSize = 13, color = "on_surface_variant" }))
    add(code("touch " .. short(setup.file)))
    add(ui.label({ text = tr("setup.step2", { conf = short(setup.conf) }), fontSize = 13, color = "on_surface_variant", maxLines = 3 }))
    add(code(line))
    add(ui.label({ text = tr("setup.step3"), fontSize = 13, color = "on_surface_variant", maxLines = 2 }))
    add(ui.row({ gap = 8, justify = "end" }, {
      ui.button({ text = tr("setup.auto"), variant = "ghost", controlSize = "sm",
        onClick = function() send("setup") end }),
      ui.button({ text = tr("setup.check"), glyph = "refresh", variant = "outline", controlSize = "sm",
        onClick = function() send("setup_check") end }),
    }))
  end
  return ui.column({ gap = 8, padding = 14, radius = 12, fill = "primary/0.12", border = "primary/0.5", borderWidth = 1 }, body)
end

-- ------------------------------------------------------------ banner, frame

local function banner()
  local s = txn.status
  if s == "idle" or (txn.id ~= nil and txn.id == dismissed) then return nil end
  local reason = txn.message or ""
  local text, color, buttons = nil, "on_surface", {}
  if s == "applying" or s == "verifying" or s == "keeping" or s == "reverting" then
    text = tr("banner." .. s)
  elseif s == "pending" then
    local left = math.max(0, math.ceil((txn.deadline or 0) - (txn.now or 0)))
    text = tr("banner.pending", { s = left })
    color = "primary"
    buttons = {
      ui.button({ text = tr("banner.revert"), variant = "outline", controlSize = "sm", onClick = function() send("revert") end }),
      ui.button({ text = tr("banner.keep"), variant = "primary", controlSize = "sm", onClick = function() send("keep") end }),
    }
  elseif s == "failed" and txn.code == 7 then
    text = tr("banner.not_ours") .. " " .. reason
    color = "error"
    buttons = { ui.button({ text = tr("banner.adopt"), variant = "outline", controlSize = "sm",
      onClick = function() send("apply", { state = draft, adopt = true }) end }) }
  else
    local key = ({ confirmed = "banner.confirmed", reverted = "banner.reverted", conflict = "banner.conflict",
      failed = "banner.failed", revert_failed = "banner.revert_failed" })[s] or "banner.failed"
    text = tr(key, { reason = s == "reverted" and reasonText(reason) or reason })
    color = (s == "confirmed") and "primary" or "error"
  end
  if s == "confirmed" or s == "reverted" or s == "conflict" or s == "failed" then
    table.insert(buttons, ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = tr("banner.dismiss"),
      onClick = function() dismissed = txn.id; render() end }))
  end
  local body = { ui.row({ gap = 10, align = "center" }, {
    ui.label({ text = text, color = color, fontSize = 13, flexGrow = 1, maxLines = 3 }),
    ui.row({ gap = 6, align = "center" }, buttons),
  }) }
  if s == "pending" and txn.not_effective and #txn.not_effective > 0 then
    local names = {}
    for _, p in ipairs(txn.not_effective) do
      table.insert(names, p:match("^monitor ") and p or tr("opt." .. p))
    end
    table.insert(body, ui.label({ text = tr("banner.not_effective", { list = table.concat(names, ", ") }),
      fontSize = 12, color = "on_surface_variant", maxLines = 3 }))
  end
  return ui.column({ gap = 6, padding = 12, radius = 12, fill = s == "pending" and "primary/0.12" or "surface_variant/0.6" }, body)
end

function render()
  if not isOpen then return end
  local tabs = {}
  for _, p in ipairs(PAGES) do
    table.insert(tabs, ui.button({
      key = "tab-" .. p.id, text = tr("tab." .. p.id), glyph = p.glyph, controlSize = "sm",
      variant = page == p.id and "primary" or "ghost", selected = page == p.id,
      onClick = function()
        page = p.id
        noctalia.state.set("hs.page", page)
        render()
      end,
    }))
  end

  local content
  if page == "animations" then content = animationsPage()
  elseif page == "displays" then content = displaysPage()
  else content = optionPage(page) end

  local n = changes()
  local busy = txn.status == "applying" or txn.status == "verifying" or txn.status == "pending"
    or txn.status == "keeping" or txn.status == "reverting" or txn.status == "revert_failed"

  local children = {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "adjustments", size = 22, color = "primary" }),
      ui.label({ text = tr("panel.title"), fontSize = 17, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = function() panel.close() end }),
    }),
    ui.row({ gap = 4, align = "center" }, tabs),
  }
  if live.error then
    table.insert(children, ui.label({ text = tr("ui.read_error", { error = live.error }), color = "error", fontSize = 12, maxLines = 2 }))
  end
  local card = setupCard()
  if card then table.insert(children, card) end
  local b = banner()
  if b then table.insert(children, b) end
  table.insert(children, ui.scroll({ key = "page-" .. page, flexGrow = 1, gap = 12 }, content))
  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = n > 0 and tr("ui.unsaved", { n = n }) or tr("ui.no_changes"), fontSize = 12,
      color = n > 0 and "primary" or "on_surface_variant", flexGrow = 1 }),
    ui.button({ text = tr("ui.discard"), variant = "ghost", controlSize = "sm", enabled = n > 0 and not busy,
      onClick = function()
        draft = draftlib.copy(saved)
        expanded = {}
        refreshControls()
        commit()
      end }),
    ui.button({ text = tr("ui.apply"), glyph = "check", variant = "primary", controlSize = "sm",
      enabled = n > 0 and not busy and (setup == nil or setup.loaded),
      onClick = function() send("apply", { state = draft }) end }),
  }))
  panel.render(ui.column({ gap = 12, padding = 4, flexGrow = 1 }, children))
end

noctalia.state.watch("hs.live", function(v) live = v or live; render() end)
noctalia.state.watch("hs.txn", function(v) txn = v or txn; render() end)
noctalia.state.watch("hs.setup", function(v) setup = v; render() end)
noctalia.state.watch("hs.saved", function(v)
  local unchanged = draftlib.equal(draft, saved)
  saved = v or {}
  -- After a keep the draft is the saved state; untouched drafts follow along.
  if unchanged or txn.status == "confirmed" then
    draft = draftlib.copy(saved)
    noctalia.state.set("hs.draft", draft)
    refreshControls()
  end
  render()
end)

function onOpen()
  isOpen = true
  send("refresh")
  render()
end

function onClose()
  isOpen = false
end

-- noctalia msg plugin michael-retunzew/hyprland-settings:panel all page displays
function onIpc(event, payload)
  if event == "page" then
    for _, p in ipairs(PAGES) do
      if p.id == payload then page = payload end
    end
    render()
  end
end
