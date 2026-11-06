-- view_panel.build on stubs.ui, and the panel shell (panel.luau) on the noctalia stub.
local rules = loadModule("rules.luau")
local commands = loadModule("commands.luau")
local view = loadModule("view_panel.luau")

local ui = stubs.ui

-- Shows what would be substituted: "key{k=v,...}", or the bare key.
local function tr(key, subst)
  if subst == nil or next(subst) == nil then return key end
  local parts = {}
  for k, v in pairs(subst) do parts[#parts + 1] = k .. "=" .. tostring(v) end
  table.sort(parts)
  return key .. "{" .. table.concat(parts, ",") .. "}"
end

local function rule(over)
  local r = {
    action = "allow", direction = "in", proto = "tcp", port = "8080", from = "any", to = "any",
    route = false, v4 = true, v6 = true,
  }
  for k, v in pairs(over or {}) do r[k] = v end
  r.id = r.id or rules.ruleId(r)
  if r.removable == nil then r.removable = commands.isRemovableShape(r) end
  return r
end

local BASE_RULES = {
  rule({ port = "22" }),
  rule({ port = "5173", proto = "any", comment = "vite" }),
  rule({ port = "4444", action = "deny", proto = "udp" }),
}

local function snap(over)
  local s = {
    seq = 1, requestSeq = 1, installed = true, hasSystemctl = true, source = "files", enabled = true,
    unit = { active = "active", bootEnabled = true },
    defaults = { input = "DROP", ipv6 = true },
    rules = BASE_RULES, pending = {}, busy = false, testMode = false,
  }
  for k, v in pairs(over or {}) do s[k] = v end
  if s.enabled == "unreadable" then s.enabled = nil end
  return s
end

local function findKey(tree, key)
  if type(tree) ~= "table" then return nil end
  if tree.props and tree.props.key == key then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = findKey(child, key)
    if found then return found end
  end
  return nil
end

local function findText(tree, text)
  if type(tree) ~= "table" then return nil end
  if tree.props and tree.props.text == text then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = findText(child, text)
    if found then return found end
  end
  return nil
end

local function findType(tree, kind)
  if type(tree) ~= "table" then return nil end
  if tree.type == kind then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = findType(child, kind)
    if found then return found end
  end
  return nil
end

local function collect(tree, pred, out)
  out = out or {}
  if type(tree) ~= "table" then return out end
  if pred(tree) then out[#out + 1] = tree end
  for _, child in ipairs(tree.children or {}) do collect(child, pred, out) end
  return out
end

local function findKeyPrefix(tree, prefix)
  local found = collect(tree, function(n)
    return type(n.props.key) == "string" and n.props.key:sub(1, #prefix) == prefix
  end)
  return found[1]
end

-- Buttons the host paints filled or alarming: everything but outline and ghost.
local function strong(tree)
  return collect(tree, function(n)
    return n.type == "button" and n.props.variant ~= "outline" and n.props.variant ~= "ghost"
  end)
end

local function primaries(tree)
  return collect(tree, function(n) return n.type == "button" and n.props.variant == "primary" end)
end

-- Every callback the view may call records { name, args... }.
local function handlers(form)
  local calls = {}
  local h = { form = form or { proto = "both", seq = 1 } }
  for _, name in ipairs({ "toggle", "primary", "stageAdd", "stageRemove", "unstage", "discard", "save",
    "fallback", "dismiss", "setForm", "confirmTurnOff", "cancelOff" }) do
    h[name] = function(...) calls[#calls + 1] = { name, ... } end
  end
  return h, calls
end

local function build(s, form)
  local h, calls = handlers(form)
  return view.build(s, ui, tr, h), calls, h
end

local function rowId(r) return "row." .. r.id end

local ADD_OP = { id = "7", kind = "add", port = 40001, proto = "both" }

-- ── views: one primary button ────────────────────────────────────────────────
local STATES = {
  on = snap(),
  off = snap({ enabled = false }),
  stopped = snap({ unit = { active = "inactive", bootEnabled = true } }),
  not_running = snap({ unit = { active = "inactive", bootEnabled = false } }),
  failed = snap({ unit = { active = "failed", bootEnabled = true } }),
  unknown = snap({ enabled = "unreadable", source = "none", rules = {} }),
  unreadable = snap({ source = "none", rules = {} }),
  missing = snap({ installed = false, rules = {} }),
}
-- The primary button's key per state, without and with a pending change (nil = none).
local WANT = {
  on = { nil, "btn.save" },
  off = { "btn.turn_on", "btn.turn_on" },
  stopped = { "btn.turn_on", "btn.turn_on" },
  not_running = { "btn.start_service", "btn.save" },
  failed = { "btn.start_service", "btn.save" },
  unknown = { "btn.load_rules", "btn.load_rules" },
  unreadable = { "btn.load_rules", "btn.save" },
  missing = { nil, nil },
}
for name, base in pairs(STATES) do
  for i, pending in ipairs({ {}, { ADD_OP } }) do
    local s = {}
    for k, v in pairs(base) do s[k] = v end
    s.pending = pending
    local t = build(s)
    local p = primaries(t)
    local label = "views: one primary button " .. name .. (i == 2 and " pending" or "")
    -- the host fills primary, default and secondary: only the one main action may be filled
    local filled = collect(t, function(n)
      local v = n.props.variant
      return n.type == "button" and v ~= "primary" and v ~= "outline" and v ~= "ghost" and v ~= "destructive"
    end)
    eq(label .. " no other filled button", #filled, 0)
    eq(label .. " count", #p, WANT[name][i] and 1 or 0)
    if WANT[name][i] then
      eq(label .. " is " .. WANT[name][i], p[1] and p[1].props.key, WANT[name][i])
    end
    if i == 2 and name ~= "missing" then
      local save = findKey(t, "btn.save")
      check(label .. " save shown", save ~= nil)
      if WANT[name][2] ~= "btn.save" then
        eq(label .. " save is outline", save and save.props.variant, "outline")
      end
    end
  end
end
eq("views: one primary button while loading", #primaries(build(nil)), 0)
do
  -- the Both/TCP/UDP choice never takes a fill (selected paints one), see Mullvad c11bc56
  local t = build(snap())
  -- exactly one box looks active; the selected one has nothing clickable
  local function choiceState(tree, want)
    for _, id in ipairs({ "both", "tcp", "udp" }) do
      local box = findKey(tree, "form.box." .. id)
      local btn = findKey(tree, "form.proto." .. id)
      local tag = "views: " .. want .. " selected, " .. id
      -- active and inactive look the same except the outline: full opacity on every
      -- box, and the 32px height of a "sm" control (the port input beside it)
      eq(tag .. " is full opacity", box.props.opacity, 1)
      eq(tag .. " is the small control height", box.props.minHeight, 32)
      if id == want then
        eq(tag .. " has the primary border", box.props.border, "primary")
        eq(tag .. " has no button", btn, nil)
        local on = findKey(tree, "form.proto." .. id .. ".on")
        check(tag .. " is a label without onClick", on ~= nil and on.props.onClick == nil)
        -- a ghost button's text is on_surface at the host's default size and weight
        eq(tag .. " label has the ghost button's text colour", on and on.props.color, "on_surface")
        eq(tag .. " label keeps the default text size", on and on.props.fontSize, nil)
        eq(tag .. " label keeps the default weight", on and on.props.fontWeight, nil)
      else
        eq(tag .. " has the explicit transparent border", box.props.border, "#00000000")
        eq(tag .. " button keeps the default text size", btn and btn.props.fontSize, nil)
        eq(tag .. " keeps the border width", box.props.borderWidth, 1)
        check(tag .. " is clickable ghost", btn ~= nil and btn.props.variant == "ghost" and type(btn.props.onClick) == "function")
        eq(tag .. " not host-selected", btn.props.selected, nil)
      end
    end
  end
  choiceState(t, "both")
  choiceState(build(snap(), { proto = "tcp", seq = 1 }), "tcp")
  choiceState(build(snap(), { proto = "udp", seq = 1 }), "udp")
  t = build(snap(), { proto = "udp", seq = 1 })
  local add = findKey(t, "btn.add")
  eq("views: add has a green border", add.props.border, "#22c55e")
  eq("views: add label is green", findKey(t, "btn.add.label").props.color, "#22c55e")
  eq("views: add is not a filled button", add.props.variant, nil)
  check("views: add is clickable when idle", type(add.props.onClick) == "function")
  local off = findKey(build(snap({ busy = true, busyAction = "save" }), { seq = 1 }), "btn.add")
  eq("views: add has no onClick when disabled", off.props.onClick, nil)
  eq("views: add is dimmed when disabled", off.props.opacity, 0.4)
end

-- ── views: toggle reflects enabled and is disabled while busy ───────────────
do
  local t = build(snap())
  local tog = findKey(t, "hdr.toggle")
  eq("views: toggle checked when enabled", tog and tog.props.checked, true)
  eq("views: toggle enabled when idle", tog and tog.props.enabled, true)
  eq("views: toggle unchecked when off", findKey(build(snap({ enabled = false })), "hdr.toggle").props.checked, false)
  eq("views: toggle disabled while busy", findKey(build(snap({ busy = true, busyAction = "enable" })), "hdr.toggle").props.enabled, false)
  eq("views: toggle disabled when missing", findKey(build(STATES.missing), "hdr.toggle").props.enabled, false)
  eq("views: toggle disabled when unknown", findKey(build(STATES.unknown), "hdr.toggle").props.enabled, false)
  eq("views: toggle disabled in test mode", findKey(build(snap({ testMode = true })), "hdr.toggle").props.enabled, false)
  local calls
  t, calls = build(snap())
  findKey(t, "hdr.toggle").props.onChange("false")
  eq("views: toggle off calls h.toggle", calls[1] and calls[1][1], "toggle")
  eq("views: toggle off passes false", calls[1] and calls[1][2], false)
  -- the confirmation row, driven by h.confirmOff
  local hc, cc = handlers()
  hc.confirmOff = true
  local tc = view.build(snap({ pending = { ADD_OP } }), ui, tr, hc)
  check("views: confirmation shown with h.confirmOff", findKey(tc, "box.confirm") ~= nil)
  eq("views: confirmation keeps the switch on", findKey(tc, "hdr.toggle").props.checked, true)
  eq("views: no primary while the confirmation is open", #primaries(tc), 0)
  eq("views: one strong button while the confirmation is open", #strong(tc), 1)
  eq("views: that button is Turn off", strong(tc)[1] and strong(tc)[1].props.key, "btn.confirm_off")
  eq("views: Save is outline while confirming", findKey(tc, "btn.save").props.variant, "outline")
  local tu = view.build(snap({ source = "none", rules = {}, pending = { ADD_OP } }), ui, tr, hc)
  eq("views: confirming in another state still leaves one strong button", #strong(tu), 1)
  findKey(tc, "btn.cancel_off").props.onClick()
  findKey(tc, "btn.confirm_off").props.onClick()
  eq("views: Cancel calls h.cancelOff", cc[1] and cc[1][1], "cancelOff")
  eq("views: Turn off calls h.confirmTurnOff", cc[2] and cc[2][1], "confirmTurnOff")
  check("views: no confirmation when off", findKey(view.build(snap({ enabled = false }), ui, tr, hc), "box.confirm") == nil)
  check("views: no confirmation while busy", findKey(view.build(snap({ busy = true, busyAction = "save" }), ui, tr, hc), "box.confirm") == nil)
  check("views: no confirmation without the flag", findKey(build(snap()), "box.confirm") == nil)
  t, calls = build(snap({ enabled = false }))
  findKey(t, "hdr.toggle").props.onChange("true")
  eq("views: toggle on passes true", calls[1] and calls[1][2], true)
  eq("views: header line", findKey(t, "hdr.line").props.text, "header.off")
  local open = findKey(build(snap({ defaults = { input = "ACCEPT", ipv6 = true } })), "hdr.line")
  eq("views: open header line is amber", open.props.color, "#f59e0b")
  eq("views: blocked header line is muted", findKey(build(snap()), "hdr.line").props.color, "on_surface_variant")
  eq("views: title", findText(build(snap()), "panel.title") ~= nil, true)
  local formNode = findKey(build(snap()), "form")
  eq("views: add rows are spaced", formNode.props.gap, 10)
  eq("views: port and choice are spaced", formNode.children[1].props.gap, 10)
  eq("views: choice buttons are spaced", formNode.children[1].children[2].props.gap, 6)
  eq("views: comment and Add are spaced", formNode.children[2].props.gap, 10)
  eq("views: dot green when on", findKey(build(snap()), "hdr.dot").props.fill, "#22c55e")
  eq("views: dot red when off", findKey(build(snap({ enabled = false })), "hdr.dot").props.fill, "error")
  eq("views: dot amber when not running", findKey(build(STATES.not_running), "hdr.dot").props.fill, "#f59e0b")
end

-- ── views: protocol tag text per proto ──────────────────────────────────────
do
  local t = build(snap())
  local function tagText(r)
    local tag = findKey(t, rowId(r) .. ".tag")
    local label = tag and findType(tag, "label")
    return label and label.props.text
  end
  eq("views: tcp tag", tagText(BASE_RULES[1]), "proto.tcp")
  eq("views: any tag", tagText(BASE_RULES[2]), "proto.any")
  eq("views: udp tag", tagText(BASE_RULES[3]), "proto.udp")
  local tag = findKey(t, rowId(BASE_RULES[1]) .. ".tag")
  eq("views: tag border", tag.props.border, "outline_variant")
  eq("views: tag border width", tag.props.borderWidth, 1)
  eq("views: tag radius", tag.props.radius, 4)
  eq("views: tag paddingH", tag.props.paddingH, 4)
  eq("views: tag font size", findType(tag, "label").props.fontSize, 9)
  check("views: meta from anywhere", findText(findKey(t, rowId(BASE_RULES[1])), "rules.from_anywhere") ~= nil)
  check("views: comment shown", findText(findKey(t, rowId(BASE_RULES[2])), "vite") ~= nil)
  check("views: denied meta", findText(findKey(t, rowId(BASE_RULES[3])), "rules.denied · rules.from_anywhere") ~= nil)
  -- shapes from the fixture: range, source, interface, outgoing, app
  local list = rules.parseRules(fixture("shapes.rules"), fixture("shapes6.rules"), true)
  for _, r in ipairs(list) do r.removable = commands.isRemovableShape(r) end
  local s = snap({ rules = list })
  t = build(s)
  local function rowOf(pred)
    for _, r in ipairs(list) do if pred(r) then return findKey(t, rowId(r)), r end end
    return nil
  end
  local range = rowOf(function(r) return r.port == "60000:60010" end)
  check("views: range shown with an en dash", findText(range, "60000–60010") ~= nil)
  local src = rowOf(function(r) return r.from == "192.0.2.0/24" end)
  check("views: source shown", findText(src, "rules.from_only{from=192.0.2.0/24}") ~= nil)
  local iface = rowOf(function(r) return r.iface == "eth9" and not r.route end)
  check("views: interface shown", findText(iface, "rules.from_anywhere · rules.on_iface{iface=eth9}") ~= nil)
  local out = rowOf(function(r) return r.direction == "out" end)
  check("views: outgoing shown", findText(out, "rules.outgoing · rules.from_anywhere") ~= nil)
  local app = rowOf(function(r) return r.app ~= nil end)
  check("views: app name shown", app ~= nil and findText(app, "WWW") ~= nil)
  local limited = rowOf(function(r) return r.action == "limit" end)
  check("views: limited shown", findText(limited, "rules.limited · rules.from_anywhere") ~= nil)
  local all = rowOf(function(r) return r.port == nil and r.app == nil and not r.route end)
  check("views: no port reads all ports", findText(all, "rules.any_port") ~= nil)
  check("views: more than 6 rows scroll", findType(t, "scroll") ~= nil)
  check("views: 3 rows do not scroll", findType(build(snap()), "scroll") == nil)
  eq("views: the scroll grows into the panel's height", findType(t, "scroll").props.flexGrow, 1)
  eq("views: nothing to reveal without a pending add", findType(t, "scroll").props.revealKey, nil)
  s.pending = { { id = "2", kind = "add", port = 40020, proto = "tcp" }, { id = "9", kind = "add", port = 40021, proto = "udp" } }
  eq("views: the newest pending add is revealed", findType(build(s), "scroll").props.revealKey, "op.9")
end

-- ── views: pending add/remove markers and undo ──────────────────────────────
do
  local target = BASE_RULES[1]
  local s = snap({ pending = {
    { id = "3", kind = "add", port = 40002, proto = "tcp", comment = "dev" },
    { id = "4", kind = "remove", ruleId = target.id },
  } })
  local t, calls = build(s)
  local add = findKey(t, "op.3")
  check("views: pending add row", add ~= nil)
  check("views: pending add shows the port", findText(add, "40002") ~= nil)
  check("views: pending add tag new", findText(add, "rules.new") ~= nil)
  check("views: pending add has a left accent", findKey(add, "op.3.accent") ~= nil)
  eq("views: pending add accent is green", findKey(add, "op.3.accent").props.fill, "#22c55e")
  local tag = findKey(add, "op.3.tag")
  eq("views: pending add proto tag", tag and findType(tag, "label").props.text, "proto.tcp")
  check("views: pending add comment", findText(add, "dev") ~= nil)
  findKey(add, "op.3.remove").props.onClick()
  eq("views: ✕ on a pending add unstages it", calls[1] and calls[1][1], "unstage")
  eq("views: unstage passes the op id", calls[1] and calls[1][2], "3")
  local row = findKey(t, rowId(target))
  eq("views: pending remove row is faded", row.props.opacity, 0.5)
  check("views: pending remove tag", findText(row, "rules.will_be_removed") ~= nil)
  local undo = findKey(row, rowId(target) .. ".undo")
  eq("views: undo is ghost", undo and undo.props.variant, "ghost")
  check("views: removed row has no ✕", findKey(row, rowId(target) .. ".remove") == nil)
  undo.props.onClick()
  eq("views: undo unstages the remove op", calls[2] and calls[2][2], "4")
  local other = findKey(t, rowId(BASE_RULES[2]))
  -- set explicitly, never left out: the host keeps a row's opacity when the prop
  -- disappears, so an undone remove would otherwise stay faded
  eq("views: other rows not faded", other.props.opacity, 1)
  local undone = findKey(build(snap({ pending = {} })), rowId(target))
  eq("views: an undone remove is full opacity again", undone and undone.props.opacity, 1)
  findKey(other, rowId(BASE_RULES[2]) .. ".remove").props.onClick()
  eq("views: ✕ stages a remove", calls[3] and calls[3][1], "stageRemove")
  eq("views: ✕ passes the rule id", calls[3] and calls[3][2], BASE_RULES[2].id)
  eq("views: ✕ is ghost", findKey(other, rowId(BASE_RULES[2]) .. ".remove").props.variant, "ghost")
  t = build(snap({ pending = s.pending, busy = true, busyAction = "save" }))
  eq("views: undo disabled during a save", findKey(t, rowId(target) .. ".undo").props.enabled, false)
  eq("views: ✕ disabled during a save", findKey(t, rowId(BASE_RULES[2]) .. ".remove").props.enabled, false)
  t = build(snap({ pending = s.pending, busy = true, busyAction = "enable" }))
  eq("views: staging allowed while another action runs", findKey(t, rowId(BASE_RULES[2]) .. ".remove").props.enabled, true)
end

-- ── views: unremovable row has no remove button ─────────────────────────────
do
  local odd = rule({ port = "43117", iface = "eth9", removable = false })
  local t = build(snap({ rules = { odd } }))
  local row = findKey(t, rowId(odd))
  check("views: unremovable row has no ✕", findKey(row, rowId(odd) .. ".remove") == nil)
  check("views: unremovable row says remove in a terminal", findText(row, "rules.remove_in_terminal") ~= nil)
end

-- ── views: failed op shows error ────────────────────────────────────────────
do
  local target = BASE_RULES[1]
  local t = build(snap({ pending = {
    { id = "5", kind = "add", port = 40003, proto = "both", error = "ERROR: Bad port" },
    { id = "6", kind = "remove", ruleId = target.id, errorKey = "error.op_failed" },
  } }))
  local err = findKey(t, "op.5.error")
  eq("views: failed add shows ufw's text", err and err.props.text, "ERROR: Bad port")
  eq("views: failed add error colour", err and err.props.color, "error")
  local rerr = findKey(t, rowId(target) .. ".error")
  eq("views: failed remove shows the key", rerr and rerr.props.text, "error.op_failed")
  eq("views: failed remove error colour", rerr and rerr.props.color, "error")
  check("views: rows without an error show none", findKey(t, rowId(BASE_RULES[2]) .. ".error") == nil)
end

-- ── views: footer only with pending, count text ─────────────────────────────
do
  check("views: no footer without pending", findKey(build(snap()), "footer") == nil)
  local t, calls = build(snap({ pending = { ADD_OP, { id = "8", kind = "remove", ruleId = BASE_RULES[1].id } } }))
  local footer = findKey(t, "footer")
  check("views: footer with pending", footer ~= nil)
  check("views: footer count, plural", findText(footer, "footer.unsaved_other{n=2}") ~= nil)
  check("views: footer count, singular", findText(findKey(build(snap({ pending = { ADD_OP } })), "footer"), "footer.unsaved_one{n=1}") ~= nil)
  eq("views: discard is ghost", findKey(footer, "btn.discard").props.variant, "ghost")
  findKey(footer, "btn.discard").props.onClick()
  findKey(footer, "btn.save").props.onClick()
  eq("views: discard calls h.discard", calls[1] and calls[1][1], "discard")
  eq("views: save calls h.save", calls[2] and calls[2][1], "save")
  t = build(snap({ pending = { ADD_OP }, busy = true, busyAction = "save" }))
  eq("views: save disabled while busy", findKey(t, "btn.save").props.enabled, false)
  check("views: busy line shown", findKey(t, "busy") ~= nil)
end

-- ── views: off state shows warning and Turn on ──────────────────────────────
do
  local t, calls = build(STATES.off)
  local box = findKey(t, "box.warning")
  check("views: off warning box", box ~= nil)
  eq("views: off warning border is red", box and box.props.border, "error")
  check("views: off warning text", findText(box, "warning.off") ~= nil)
  local on = findKey(t, "btn.turn_on")
  eq("views: turn on text", on and on.props.text, "action.turn_on")
  on.props.onClick()
  eq("views: turn on calls h.primary", calls[1] and calls[1][1], "primary")
  eq("views: turn on passes turn_on", calls[1] and calls[1][2], "turn_on")
  check("views: rules title says when on", findText(t, "rules.title_off") ~= nil)
  check("views: no warning when on", findKey(build(snap()), "box.warning") == nil)
end

-- ── views: stopped looks like off ────────────────────────────────────────────
do
  local t, calls = build(STATES.stopped)
  eq("views: stopped toggle unchecked", findKey(t, "hdr.toggle").props.checked, false)
  eq("views: stopped header line", findKey(t, "hdr.line").props.text, "header.stopped")
  eq("views: stopped dot red", findKey(t, "hdr.dot").props.fill, "error")
  local box = findKey(t, "box.warning")
  check("views: stopped warning shown", box ~= nil and findText(box, "warning.off") ~= nil)
  eq("views: stopped warning border is red", box and box.props.border, "error")
  eq("views: stopped Turn on is the one primary", #primaries(t), 1)
  findKey(t, "btn.turn_on").props.onClick()
  eq("views: stopped Turn on passes turn_on", calls[1] and calls[1][2], "turn_on")
  check("views: stopped rules title", findText(t, "rules.title_off") ~= nil)
  check("views: stopped no confirmation", findKey(view.build(snap({ unit = { active = "inactive", bootEnabled = true } }), ui, tr, (function() local hh = handlers({ proto = "both", seq = 1 }); hh.confirmOff = true; return hh end)()), "box.confirm") == nil)
end

-- ── views: the switch is off in the amber states, and flipping it on is Turn on ─
do
  for _, name in ipairs({ "not_running", "failed" }) do
    local t, calls = build(STATES[name])
    local tog = findKey(t, "hdr.toggle")
    eq("views: " .. name .. " toggle unchecked", tog and tog.props.checked, false)
    eq("views: " .. name .. " toggle enabled", tog and tog.props.enabled, true)
    tog.props.onChange("true")
    eq("views: " .. name .. " toggle on calls h.toggle", calls[1] and calls[1][1], "toggle")
    eq("views: " .. name .. " toggle on passes true", calls[1] and calls[1][2], true)
    local hh = handlers({ proto = "both", seq = 1 })
    hh.confirmOff = true
    check("views: " .. name .. " shows no turn-off confirmation", findKey(view.build(STATES[name], ui, tr, hh), "box.confirm") == nil)
  end
end

-- ── views: not_running shows Start ufw ──────────────────────────────────────
do
  local t, calls = build(STATES.not_running)
  local box = findKey(t, "box.warning")
  eq("views: not_running warning border is amber", box and box.props.border, "#f59e0b")
  check("views: not_running warning text", findText(box, "warning.not_running") ~= nil)
  local start = findKey(t, "btn.start_service")
  eq("views: start ufw text", start and start.props.text, "action.start_service")
  start.props.onClick()
  eq("views: start ufw passes start_service", calls[1] and calls[1][2], "start_service")
  t = build(STATES.failed)
  check("views: failed warning text", findText(findKey(t, "box.warning"), "warning.failed") ~= nil)
  check("views: failed offers Start ufw", findKey(t, "btn.start_service") ~= nil)
  eq("views: start ufw disabled while busy",
    findKey(build(snap({ unit = { active = "inactive" }, busy = true, busyAction = "refresh" })), "btn.start_service").props.enabled, false)
end

-- ── views: boot notice ──────────────────────────────────────────────────────
do
  local t, calls = build(snap({ unit = { active = "active", bootEnabled = false } }))
  local box = findKey(t, "box.boot")
  check("views: boot notice shown", box ~= nil)
  check("views: boot notice text", findText(box, "boot.notice") ~= nil)
  local b = findKey(box, "btn.start_at_boot")
  eq("views: start at boot is outline", b and b.props.variant, "outline")
  eq("views: start at boot text", b and b.props.text, "action.start_at_boot")
  b.props.onClick()
  eq("views: start at boot passes enable_at_boot", calls[1] and calls[1][2], "enable_at_boot")
  check("views: no boot notice when enabled at boot", findKey(build(snap()), "box.boot") == nil)
  check("views: no boot notice when off", findKey(build(snap({ enabled = false, unit = { active = "active", bootEnabled = false } })), "box.boot") == nil)
end

-- ── views: polkit fallback without terminal for save ────────────────────────
do
  local t, calls = build(snap({ polkitFallback = { ["for"] = "enable" }, lastError = { key = "error.no_polkit_agent" } }))
  local box = findKey(t, "box.fallback")
  check("views: fallback box shown", box ~= nil)
  check("views: fallback says no prompt", findText(box, "error.no_polkit_agent") ~= nil)
  check("views: no separate error box for no_polkit_agent", findKey(t, "box.error") == nil)
  local agent = findKey(box, "btn.polkit_agent")
  local term = findKey(box, "btn.run_in_terminal")
  eq("views: agent button text", agent and agent.props.text, "action.polkit_agent")
  eq("views: terminal button text", term and term.props.text, "action.run_in_terminal")
  agent.props.onClick()
  term.props.onClick()
  eq("views: agent calls h.fallback", calls[1] and calls[1][2], "polkit_agent")
  eq("views: terminal calls h.fallback", calls[2] and calls[2][2], "terminal")
  eq("views: fallback buttons are not primary", agent.props.variant ~= "primary" and term.props.variant ~= "primary", true)
  t = build(snap({ polkitFallback = { ["for"] = "save" }, lastError = { key = "error.no_polkit_agent" }, pending = { ADD_OP } }))
  box = findKey(t, "box.fallback")
  check("views: save fallback offers the prompt", findKey(box, "btn.polkit_agent") ~= nil)
  check("views: save fallback has no terminal", findKey(box, "btn.run_in_terminal") == nil)
  t = build(snap({ polkitFallback = { ["for"] = "load_rules" }, source = "none", rules = {} }))
  check("views: load_rules fallback has no terminal", findKey(t, "btn.run_in_terminal") == nil)
  check("views: no fallback box without polkitFallback", findKey(build(snap()), "box.fallback") == nil)
end

-- ── errors and notices ──────────────────────────────────────────────────────
do
  local t, calls = build(snap({ lastError = { key = "error.save_partial", n = 2 }, pending = { ADD_OP } }))
  local box = findKey(t, "box.error")
  check("views: error box shown", box ~= nil)
  check("views: error n substituted, plural", findText(box, "error.save_partial_other{n=2}") ~= nil)
  findKey(box, "btn.dismiss_error").props.onClick()
  eq("views: dismiss calls h.dismiss", calls[1] and calls[1][1], "dismiss")
  eq("views: dismiss passes the key", calls[1] and calls[1][2], "error.save_partial")
  local function errText(key, n)
    return findText(findKey(build(snap({ lastError = { key = key, n = n } })), "box.error"), key .. (n == 1 and "_one" or "_other") .. "{n=" .. n .. "}") ~= nil
  end
  check("views: save_partial singular", errText("error.save_partial", 1))
  check("views: save_dropped singular", errText("error.save_dropped", 1))
  check("views: save_dropped plural", errText("error.save_dropped", 2))
  local function noticeText(key, n)
    return findText(findKey(build(snap({ notice = { key = key, n = n } })), "box.notice"), key .. (n == 1 and "_one" or "_other") .. "{n=" .. n .. "}") ~= nil
  end
  check("views: notice saved singular", noticeText("notice.saved", 1))
  check("views: notice saved plural", noticeText("notice.saved", 2))
  check("views: notice pending_dropped plural", noticeText("notice.pending_dropped", 3))
  check("views: notice without n is the bare key",
    findText(findKey(build(snap({ notice = { key = "notice.cancelled" } })), "box.notice"), "notice.cancelled") ~= nil)
  t = build(snap({ lastError = { key = "error.command_failed", detail = "ERROR: x" } }))
  check("views: error detail shown", findText(findKey(t, "box.error"), "ERROR: x") ~= nil)
  t = build(snap({ notice = { key = "notice.pending_dropped", n = 1 } }))
  check("views: notice n substituted, singular", findText(findKey(t, "box.notice"), "notice.pending_dropped_one{n=1}") ~= nil)
  t = build(snap({ lastError = { key = "error.test_mode" }, testMode = true }))
  check("views: test mode refusal shown", findText(findKey(t, "box.error"), "error.test_mode") ~= nil)
  check("views: test mode line", findKey(t, "hdr.test") ~= nil)
  t = build(snap({ lastError = { key = "add.error_exists" } }))
  eq("views: add errors show under the add row", findKey(t, "form.error") and findKey(t, "form.error").props.text, "add.error_exists")
  check("views: add errors are not in the error box", findKey(t, "box.error") == nil)
end

-- ── states: missing, unknown, unreadable, loading ───────────────────────────
do
  local t = build(STATES.missing)
  check("views: missing box", findKey(t, "box.missing") ~= nil)
  check("views: the add-row probe finds a drawn form", findKeyPrefix(build(snap()), "add.port#") ~= nil)
  check("views: missing has no add row", findKeyPrefix(t, "add.port#") == nil)
  check("views: missing has no form", findKey(t, "form") == nil)
  check("views: missing has no footer", findKey(build(snap({ installed = false, pending = { ADD_OP } })), "footer") == nil)
  local calls
  t, calls = build(STATES.unknown)
  local box = findKey(t, "box.unreadable")
  check("views: unknown offers load rules", findKey(box, "btn.load_rules") ~= nil)
  findKey(box, "btn.load_rules").props.onClick()
  eq("views: load rules passes load_rules", calls[1] and calls[1][2], "load_rules")
  check("views: unreadable rules hide the add row", findKeyPrefix(build(STATES.unreadable), "add.port#") == nil)
  check("views: unreadable rules hide the form", findKey(build(STATES.unreadable), "form") == nil)
  check("views: unreadable box when rules are unreadable", findKey(build(STATES.unreadable), "box.unreadable") ~= nil)
  -- nothing read yet (source "loading"): no unreadable box, no Load rules, no empty list
  t = build(snap({ enabled = "unreadable", source = "loading", rules = {}, unit = {} }))
  eq("views: not read yet line", findKey(t, "hdr.line").props.text, "panel.loading")
  check("views: not read yet is not unreadable", findKey(t, "box.unreadable") == nil)
  check("views: not read yet offers no Load rules", findKey(t, "btn.load_rules") == nil)
  check("views: not read yet draws no rule list", findText(t, "rules.empty") == nil and findKey(t, "form") == nil)
  eq("views: not read yet has no primary", #primaries(t), 0)
  check("views: not read yet says nothing about an incomplete file", findKey(t, "rules.incomplete") == nil)
  -- the rules file kept parsing incomplete: a line in the body instead of nothing
  t = build(snap({ source = "loading", rules = {}, rulesIncomplete = true }))
  eq("views: incomplete rules file line", findKey(t, "rules.incomplete") and findKey(t, "rules.incomplete").props.text, "rules.incomplete")
  check("views: incomplete rules file draws no rule list", findText(t, "rules.empty") == nil and findKey(t, "form") == nil)
  check("views: incomplete with the previous rules shown has no line",
    findKey(build(snap({ source = "files", rulesIncomplete = true })), "rules.incomplete") == nil)
  -- the unit state is unknown (systemctl show failing): rules still shown, no Load rules
  t = build(snap({ unit = {} }))
  eq("views: unit unknown line", findKey(t, "hdr.line").props.text, "header.unit_unknown")
  check("views: unit unknown is not unreadable", findKey(t, "box.unreadable") == nil)
  check("views: unit unknown shows the rules", findKey(t, rowId(BASE_RULES[1])) ~= nil)
  eq("views: unit unknown toggle disabled", findKey(t, "hdr.toggle").props.enabled, false)
  eq("views: unit unknown dot muted", findKey(t, "hdr.dot").props.fill, "on_surface_variant")
  t = build(nil)
  eq("views: loading line", findKey(t, "hdr.line").props.text, "panel.loading")
  eq("views: loading toggle disabled", findKey(t, "hdr.toggle").props.enabled, false)
  check("views: empty rule list says so", findText(build(snap({ rules = {} })), "rules.empty") ~= nil)
end

-- ── views: add validation error shown, no request sent ──────────────────────
do
  local form = { proto = "tcp", seq = 4, port = "40005", comment = "x", errorKey = "add.error_port" }
  local t, calls = build(snap(), form)
  eq("views: form error shown", findKey(t, "form.error").props.text, "add.error_port")
  eq("views: form error colour", findKey(t, "form.error").props.color, "error")
  local port = findKey(t, "add.port#4")
  check("views: port input keyed by the form seq", port ~= nil)
  eq("views: port input placeholder", port and port.props.placeholder, "add.port")
  eq("views: port input seeded", port and port.props.value, "40005")
  port.props.onChange("40006")
  eq("views: port typing goes to h.setForm", calls[1] and calls[1][1], "setForm")
  eq("views: port typing patch", calls[1] and calls[1][2].port, "40006")
  findKey(t, "add.comment#4").props.onChange("hi")
  eq("views: comment typing patch", calls[2] and calls[2][2].comment, "hi")
  findKey(t, "form.proto.udp").props.onClick()
  eq("views: choice patch", calls[3] and calls[3][2].proto, "udp")
  findKey(t, "btn.add").props.onClick()
  eq("views: add calls h.stageAdd", calls[4] and calls[4][1], "stageAdd")
  eq("views: add passes the port", calls[4] and calls[4][2], "40005")
  eq("views: add passes the proto", calls[4] and calls[4][3], "tcp")
  eq("views: add passes the comment", calls[4] and calls[4][4], "x")
  check("views: no form error when clean", findKey(build(snap()), "form.error") == nil)
end

-- ── panel shell ─────────────────────────────────────────────────────────────
local previousUi, previousPanel = _G.ui, _G.panel
_G.ui = stubs.ui
local current, rendered
local function bootPanel(state)
  if current then current.uninstall() end
  local fake = stubs.newNoctalia()
  fake.state["ufw.state"] = state
  fake.install()
  rendered = nil
  _G.panel = { render = function(t) rendered = t end, close = function() end }
  loadFresh("panel.luau")
  current = fake
  onOpen({})
  return fake
end
local function watchRequests(fake)
  local out = {}
  fake.noctalia.state.watch("ufw.request", function(v) out[#out + 1] = v end)
  return out
end
local function inputKey(prefix)
  local found = collect(rendered, function(n)
    return n.type == "input" and type(n.props.key) == "string" and n.props.key:sub(1, #prefix) == prefix
  end)
  return found[1]
end

local fake = bootPanel(snap())
eq("panel: opening asks for a refresh", fake.state["ufw.request"] and fake.state["ufw.request"].action, "refresh")
check("panel: renders the header", findKey(rendered, "hdr.toggle") ~= nil)
local got = watchRequests(fake)

-- invalid port: error under the add row, nothing sent
inputKey("add.port").props.onChange("abc")
findKey(rendered, "btn.add").props.onClick()
eq("panel: invalid add sends nothing", #got, 0)
eq("panel: invalid add shows the error", findKey(rendered, "form.error") and findKey(rendered, "form.error").props.text, "add.error_port")
inputKey("add.port").props.onChange("40007/tcp")
inputKey("add.port").props.onSubmit("40007/tcp")
eq("panel: proto in port sends nothing", #got, 0)
eq("panel: proto in port error", findKey(rendered, "form.error").props.text, "add.error_proto_in_port")
inputKey("add.comment").props.onChange("bad'quote")
inputKey("add.port").props.onChange("40007")
findKey(rendered, "btn.add").props.onClick()
eq("panel: bad comment sends nothing", #got, 0)
eq("panel: bad comment error", findKey(rendered, "form.error").props.text, "add.error_comment")

-- the protocol choice through the real shell: one active box at every step
local function panelChoice(want)
  for _, id in ipairs({ "both", "tcp", "udp" }) do
    local box = findKey(rendered, "form.box." .. id)
    local tag = "panel: " .. want .. " selected, " .. id
    eq(tag .. " border", box.props.border, id == want and "primary" or "#00000000")
    eq(tag .. " opacity", box.props.opacity, 1)
    eq(tag .. " clickable", findKey(rendered, "form.proto." .. id) ~= nil, id ~= want)
  end
end
panelChoice("both")
findKey(rendered, "form.proto.tcp").props.onClick()
panelChoice("tcp")
findKey(rendered, "form.proto.udp").props.onClick()
panelChoice("udp")
findKey(rendered, "form.proto.both").props.onClick()
panelChoice("both")

-- valid add
inputKey("add.comment").props.onChange("dev box")
findKey(rendered, "form.proto.tcp").props.onClick()
findKey(rendered, "form.proto.udp").props.onClick()
panelChoice("udp")
findKey(rendered, "btn.add").props.onClick()
eq("panel: valid add sends stage_add", got[1] and got[1].action, "stage_add")
eq("panel: stage_add port", got[1] and got[1].port, "40007")
eq("panel: stage_add proto", got[1] and got[1].proto, "udp")
eq("panel: stage_add comment", got[1] and got[1].comment, "dev box")
check("panel: no form error after a valid add", findKey(rendered, "form.error") == nil)
local before = inputKey("add.port").props.key
-- the service accepts it: the inputs mount empty again
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 2, pending = { { id = "1", kind = "add", port = 40007, proto = "udp" } } }))
check("panel: accepted add re-keys the inputs", inputKey("add.port").props.key ~= before)
eq("panel: accepted add clears the port", inputKey("add.port").props.value, "")
eq("panel: proto choice resets to both", findKey(rendered, "form.box.both").props.border, "primary")
-- a newer publish with an unrelated lingering error is not the add's answer
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 2, pending = { { id = "1", kind = "add", port = 40007, proto = "udp" } } }))
inputKey("add.port").props.onChange("40008")
findKey(rendered, "btn.add").props.onClick()
local waiting = inputKey("add.port").props.key
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 3, lastError = { key = "error.timeout" },
  pending = { { id = "1", kind = "add", port = 40007, proto = "udp" } } }))
eq("panel: an unrelated error keeps waiting", inputKey("add.port").props.key, waiting)
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 4, lastError = { key = "error.timeout" },
  pending = { { id = "1", kind = "add", port = 40007, proto = "udp" }, { id = "2", kind = "add", port = 40008, proto = "both" } } }))
check("panel: the add's real answer still clears the form", inputKey("add.port").props.key ~= waiting)
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 2 }))
-- a refused add keeps the text
inputKey("add.port").props.onChange("22")
findKey(rendered, "btn.add").props.onClick()
before = inputKey("add.port").props.key
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 3, lastError = { key = "add.error_exists" } }))
eq("panel: refused add keeps the inputs", inputKey("add.port").props.key, before)
eq("panel: refused add shows the service error", findKey(rendered, "form.error").props.text, "add.error_exists")

-- the other callbacks become requests
local n0 = #got
local s = snap({ requestSeq = 4, enabled = false, pending = { ADD_OP }, polkitFallback = { ["for"] = "enable" } })
fake.noctalia.state.set("ufw.state", s)
findKey(rendered, "btn.turn_on").props.onClick()
eq("panel: turn on sends enable", got[n0 + 1] and got[n0 + 1].action, "enable")
findKey(rendered, "hdr.toggle").props.onChange("true")
eq("panel: toggle on sends enable", got[n0 + 2] and got[n0 + 2].action, "enable")
findKey(rendered, "btn.save").props.onClick()
eq("panel: save sends save", got[n0 + 3] and got[n0 + 3].action, "save")
findKey(rendered, "btn.discard").props.onClick()
eq("panel: discard sends discard", got[n0 + 4] and got[n0 + 4].action, "discard")
findKey(rendered, "op.7.remove").props.onClick()
eq("panel: unstage sends unstage", got[n0 + 5] and got[n0 + 5].action, "unstage")
eq("panel: unstage id", got[n0 + 5] and got[n0 + 5].id, "7")
findKey(rendered, "btn.run_in_terminal").props.onClick()
eq("panel: terminal sends run_in_terminal", got[n0 + 6] and got[n0 + 6].action, "run_in_terminal")
eq("panel: terminal for the failed action", got[n0 + 6] and got[n0 + 6]["for"], "enable")
findKey(rendered, "btn.polkit_agent").props.onClick()
eq("panel: agent sends enable_polkit_agent", got[n0 + 7] and got[n0 + 7].action, "enable_polkit_agent")
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5 }))
-- turning off asks first
local box0 = "hdr.toggle_box#0"
check("panel: the switch sits in a keyed box", findKey(rendered, box0) ~= nil)
findKey(rendered, "hdr.toggle").props.onChange("false")
eq("panel: toggle-off sends nothing", #got, n0 + 7)
check("panel: toggle-off opens the confirmation", findKey(rendered, "box.confirm") ~= nil)
eq("panel: the switch still shows on", findKey(rendered, "hdr.toggle").props.checked, true)
check("panel: the switch is remounted", findKey(rendered, box0) == nil)
eq("panel: confirmation in error colour", findText(rendered, "confirm.turn_off") and findText(rendered, "confirm.turn_off").props.color, "error")
eq("panel: Cancel is ghost", findKey(rendered, "btn.cancel_off").props.variant, "ghost")
eq("panel: Turn off is destructive", findKey(rendered, "btn.confirm_off").props.variant, "destructive")
eq("panel: Turn off text", findKey(rendered, "btn.confirm_off").props.text, "action.turn_off")
eq("panel: confirmation adds no primary", #primaries(rendered), 0)
eq("panel: Turn off is the one strong button", #strong(rendered), 1)
local staleConfirm = findKey(rendered, "btn.confirm_off")
findKey(rendered, "btn.cancel_off").props.onClick()
eq("panel: Cancel sends nothing", #got, n0 + 7)
staleConfirm.props.onClick()
eq("panel: Turn off from a closed confirmation sends nothing", #got, n0 + 7)
check("panel: Cancel closes the confirmation", findKey(rendered, "box.confirm") == nil)
eq("panel: after Cancel the switch shows on", findKey(rendered, "hdr.toggle").props.checked, true)
findKey(rendered, "hdr.toggle").props.onChange("false")
findKey(rendered, "btn.confirm_off").props.onClick()
eq("panel: Turn off sends disable", got[n0 + 8] and got[n0 + 8].action, "disable")
eq("panel: Turn off sends it once", #got, n0 + 8)
check("panel: Turn off closes the confirmation", findKey(rendered, "box.confirm") == nil)
-- the confirmation goes away when the firewall is already off, or an action runs
findKey(rendered, "hdr.toggle").props.onChange("false")
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5, busy = true, busyAction = "disable" }))
check("panel: busy hides the confirmation", findKey(rendered, "box.confirm") == nil)
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5 }))
check("panel: it stays hidden after the action", findKey(rendered, "box.confirm") == nil)
findKey(rendered, "hdr.toggle").props.onChange("false")
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5, enabled = false }))
check("panel: off hides the confirmation", findKey(rendered, "box.confirm") == nil)
-- turning on needs no confirmation
findKey(rendered, "hdr.toggle").props.onChange("true")
eq("panel: toggle on sends enable at once", #got, n0 + 9)
eq("panel: toggle on is enable", got[n0 + 9] and got[n0 + 9].action, "enable")
check("panel: toggle on shows no confirmation", findKey(rendered, "box.confirm") == nil)
-- the enable did not happen (refused, cancelled, timed out): the switch is remounted
local function switchBox()
  local b = findKeyPrefix(rendered, "hdr.toggle_box#")
  return b and b.props.key
end
local flipped = switchBox()
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5, enabled = false }))
check("panel: an unapplied flip remounts the switch", switchBox() ~= flipped)
eq("panel: the remounted switch shows off", findKey(rendered, "hdr.toggle").props.checked, false)
local settled = switchBox()
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5, enabled = false }))
eq("panel: no remount without a flip or an action", switchBox(), settled)
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5, enabled = false, busy = true, busyAction = "enable" }))
local during = switchBox()
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5, enabled = false }))
check("panel: an action ending remounts the switch", switchBox() ~= during)
-- amber (failed): the switch shows off; flipping it on sends enable at once, no confirmation
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5, unit = { active = "failed", bootEnabled = true } }))
eq("panel: failed shows the switch off", findKey(rendered, "hdr.toggle").props.checked, false)
local nAmber = #got
findKey(rendered, "hdr.toggle").props.onChange("true")
eq("panel: failed toggle on sends enable", got[nAmber + 1] and got[nAmber + 1].action, "enable")
check("panel: failed toggle on shows no confirmation", findKey(rendered, "box.confirm") == nil)
eq("panel: failed toggle on sends one request", #got, nAmber + 1)
table.remove(got) -- keep the request numbering below
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 5 }))
findKey(rendered, rowId(BASE_RULES[1]) .. ".remove").props.onClick()
eq("panel: ✕ sends stage_remove", got[n0 + 10] and got[n0 + 10].action, "stage_remove")
eq("panel: stage_remove rule id", got[n0 + 10] and got[n0 + 10].rule, BASE_RULES[1].id)
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 6, unit = { active = "inactive" }, lastError = { key = "error.timeout" } }))
findKey(rendered, "btn.start_service").props.onClick()
eq("panel: start ufw sends start_service", got[n0 + 11] and got[n0 + 11].action, "start_service")
findKey(rendered, "btn.dismiss_error").props.onClick()
eq("panel: dismiss sends dismiss_error", got[n0 + 12] and got[n0 + 12].action, "dismiss_error")
eq("panel: dismiss_error key", got[n0 + 12] and got[n0 + 12].key, "error.timeout")
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 7, enabled = "unreadable", source = "none", rules = {} }))
findKey(rendered, "btn.load_rules").props.onClick()
eq("panel: load rules sends load_rules", got[n0 + 13] and got[n0 + 13].action, "load_rules")
fake.noctalia.state.set("ufw.state", snap({ requestSeq = 8, unit = { active = "active", bootEnabled = false } }))
findKey(rendered, "btn.start_at_boot").props.onClick()
eq("panel: start at boot sends enable_at_boot", got[n0 + 14] and got[n0 + 14].action, "enable_at_boot")

-- re-opening drops a half-typed field
inputKey("add.port").props.onChange("4")
before = inputKey("add.port").props.key
onOpen({})
check("panel: reopening re-keys the inputs", inputKey("add.port").props.key ~= before)

if current then current.uninstall() end
_G.ui, _G.panel = previousUi, previousPanel
