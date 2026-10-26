--!nonstrict
-- LOQ RGB: control panel.
-- Header (on/off) / mode tabs / live preview of every zone / editor of the current mode / brightness.
-- Every change is sent to the service (noctalia.state); the preview eases toward the new colours on
-- panel frame ticks, which run only while a transition is in progress.
local P = require("./lib/profile.luau")

local function T(key, subst)
  return noctalia.tr(key, subst)
end

local PREVIEW_TAU_MS = 75      -- preview easing time constant
local SWATCHES = { "#ef4444", "#f97316", "#eab308", "#22c55e", "#06b6d4", "#3b82f6", "#8b5cf6", "#ec4899" }
local TAB_GLYPHS = { palette = "palette", gradient = "color-swatch", custom = "layout-grid", static = "bulb", firmware = "sparkles" }

local profile = P.defaults()
local status = { state = "starting" }
local selZone = 0              -- selected zone (0-based) in "Zones" mode
local gradStop = "a"           -- gradient point being edited: "a" start | "m" middle | "b" end
local lastCommitMs = -100000
local counter = 0
local panelOpen = false
local autoPrompted = false

local shown = nil              -- preview colours currently drawn ({r,g,b} floats per zone)
local target = nil             -- preview colours we are easing toward
local animating = false
local acc = 0

local ed = { key = nil, h = 0, s = 1, v = 1 }   -- colour editor state (keeps the hue through grey/black)
local hexRev = 0                                 -- bumped when the colour changes outside the hex field

local render
local draw

local function pick(cond, a, b)
  if cond then
    return a
  end
  return b
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

local function zoneCount()
  if type(status.zones) == "number" and status.zones >= 1 then
    return status.zones
  end
  return 24
end

local function rgbHex(c)
  return string.format("#%02x%02x%02x", math.floor(c[1] + 0.5), math.floor(c[2] + 0.5), math.floor(c[3] + 0.5))
end

-- ---------------------------------------------------------------- talking to the service
local function commit()
  counter = counter + 1
  lastCommitMs = noctalia.nowMs()
  noctalia.state.set("kb_req_profile", { profile = profile, id = counter })
end

local function change(fn)
  fn()
  commit()
  render()
end

-- ---------------------------------------------------------------- preview animation
local function goalColors()
  local n = zoneCount()
  local cols = P.colors(profile, n)
  local out = {}
  for i = 1, n do
    local r, g, b = 58, 58, 58
    if cols then
      r, g, b = P.toRgb(cols[i])
    end
    out[i] = { r, g, b }
  end
  return out
end

local function sameColors(a, b)
  if a == nil or b == nil or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] or a[i][3] ~= b[i][3] then
      return false
    end
  end
  return true
end

local function syncTarget()
  local goal = goalColors()
  if shown == nil or #shown ~= #goal then
    shown = {}
    for i, c in ipairs(goal) do
      shown[i] = { c[1], c[2], c[3] }
    end
    target = goal
    animating = false
    return
  end
  if not sameColors(goal, target) then
    target = goal
    if not animating then
      animating = true
      acc = 0
      panel.setNeedsFrameTick(true)
    end
  end
end

function onFrameTick(deltaMs)
  if not animating or shown == nil or target == nil then
    return
  end
  acc = acc + (tonumber(deltaMs) or 16)
  if acc < 30 then            -- ~30 redraws per second is plenty for an ease
    return
  end
  local k = 1 - math.exp(-acc / PREVIEW_TAU_MS)
  acc = 0
  local done = true
  for i = 1, #shown do
    for c = 1, 3 do
      local d = target[i][c] - shown[i][c]
      if math.abs(d) > 0.8 then
        shown[i][c] = shown[i][c] + d * k
        done = false
      else
        shown[i][c] = target[i][c]
      end
    end
  end
  if done then
    animating = false
    panel.setNeedsFrameTick(false)
  end
  draw()
end

-- ---------------------------------------------------------------- access setup / diagnostics
local function hexOnly(s)
  if type(s) == "string" and string.match(s, "^%x+$") then
    return s
  end
  return ""
end

local function runSetup()
  local dir = noctalia.pluginDir()
  if not noctalia.runInTerminal or not dir then
    noctalia.notifyError(T("setup.noterminal"))
    return
  end
  local cmd = "sh " .. P.shellQuote(dir .. "/scripts/setup-access.sh") .. " "
    .. hexOnly(status.vid) .. " " .. hexOnly(status.pid) .. " " .. hexOnly(status.iface)
  noctalia.runInTerminal(cmd)
end

local function copyDiagnostics()
  local lines = { "loq-rgb diagnostics", "state: " .. tostring(status.state) }
  for _, d in ipairs(status.hid or {}) do
    table.insert(lines, string.format("%s  %s:%s  lampArray=%s", tostring(d.name), tostring(d.vid), tostring(d.pid), tostring(d.lamparray)))
  end
  noctalia.copyToClipboard(table.concat(lines, "\n"), "text/plain")
  noctalia.notify(T("banner.none.copied"))
end

-- ---------------------------------------------------------------- colour editor
local function syncEditor(key, hex)
  if ed.key ~= key or P.hsvToHex(ed.h, ed.s, ed.v) ~= hex then
    ed.key = key
    ed.h, ed.s, ed.v = P.hexToHsv(hex)
  end
end

local function colorEditor(key, hex, onColor)
  syncEditor(key, hex)

  local function setHsv(h, s, v)
    ed.h, ed.s, ed.v = h, s, v
    hexRev = hexRev + 1
    onColor(P.hsvToHex(h, s, v))
  end

  local activeSeg = math.floor(ed.h / 15 + 0.5) % 24
  local hues = {}
  for i = 0, 23 do
    local hh = i * 15
    table.insert(hues, ui.box({
      key = "hue" .. i,
      fill = "#" .. P.hsvToHex(hh, 1, 1),
      height = 24,
      flexGrow = 1,
      radius = 2,
      border = "on_surface",
      borderWidth = pick(i == activeSeg and ed.s > 0, 2, 0),
      onClick = function()
        local s, v = ed.s, ed.v
        if s == 0 then s = 1 end
        if v == 0 then v = 1 end
        setHsv(hh, s, v)
      end,
    }))
  end

  local swatches = {}
  for i, sw in ipairs(SWATCHES) do
    local sh = P.normHex(sw)
    table.insert(swatches, ui.box({
      key = "sw" .. i,
      fill = sw,
      height = 22,
      flexGrow = 1,
      radius = 4,
      onClick = function()
        ed.h, ed.s, ed.v = P.hexToHsv(sh)
        hexRev = hexRev + 1
        onColor(sh)
      end,
    }))
  end

  local function sliderRow(label, value, onValue)
    return ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = label, fontSize = 12, minWidth = 78, maxLines = 1 }),
      ui.slider({
        min = 0, max = 100, step = 1, value = value, controlSize = "sm", flexGrow = 1,
        onChange = function(x)
          local n = tonumber(x)
          if n then
            onValue(math.max(0, math.min(100, n)) / 100)
          end
        end,
      }),
      ui.label({ text = tostring(value), fontSize = 12, minWidth = 28 }),
    })
  end

  local top = {
    ui.box({ fill = "#" .. hex, width = 40, height = 40, radius = 8, border = "on_surface/0.3", borderWidth = 1 }),
    ui.label({ text = "#", fontSize = 14, color = "on_surface/0.6" }),
    ui.input({
      key = "hex-" .. key .. "-" .. hexRev,
      value = hex,
      placeholder = "rrggbb",
      controlSize = "sm",
      width = 100,
      onChange = function(t)
        local h = P.normHex(t)
        if h then
          ed.h, ed.s, ed.v = P.hexToHsv(h)
          onColor(h)
        end
      end,
    }),
  }
  if noctalia.openColorPicker then
    table.insert(top, ui.button({
      key = "advanced",
      glyph = "color-picker",
      variant = "outline",
      controlSize = "sm",
      tooltip = T("color.advanced"),
      onClick = function()
        noctalia.openColorPicker("#" .. hex, function(c)
          local h = P.normHex(c)
          if h then
            ed.h, ed.s, ed.v = P.hexToHsv(h)
            hexRev = hexRev + 1
            onColor(h)
          end
        end)
      end,
    }))
  end

  return ui.column({ gap = 8, key = "ced-" .. key }, {
    ui.row({ gap = 10, align = "center" }, top),
    ui.row({ gap = 1 }, hues),
    sliderRow(T("color.saturation"), math.floor(ed.s * 100 + 0.5), function(x) setHsv(ed.h, x, ed.v) end),
    sliderRow(T("color.value"), math.floor(ed.v * 100 + 0.5), function(x) setHsv(ed.h, ed.s, x) end),
    ui.row({ gap = 4 }, swatches),
  })
end

local function chip(key, label, hex, selected, onClick)
  return ui.row({
    key = key, gap = 6, align = "center", paddingH = 8, paddingV = 6, radius = 8, flexGrow = 1,
    fill = pick(selected, "primary/0.18", "on_surface/0.06"),
    border = pick(selected, "primary", "on_surface/0.15"),
    borderWidth = 1,
    onClick = onClick,
  }, {
    ui.box({ fill = "#" .. hex, radius = 4, width = 18, height = 18 }),
    ui.label({ text = label, fontSize = 12, maxLines = 1, maxWidth = 130 }),
  })
end

local function toZonesButton()
  return ui.button({
    key = "to-zones",
    text = T("editor.to-zones"),
    glyph = "adjustments",
    variant = "outline",
    controlSize = "sm",
    onClick = function()
      local n = zoneCount()
      local cols = P.colors(profile, n)
      if cols then
        change(function()
          profile.custom = cols
          profile.mode = "custom"
        end)
      end
    end,
  })
end

-- ---------------------------------------------------------------- mode editors
local function paletteEditor()
  local chips = {}
  for _, role in ipairs(P.ROLE_CANDIDATES) do
    local c = P.normHex(noctalia.getColor(role))
    if c then
      table.insert(chips, chip("role-" .. role, role, c, contains(profile.roles, role), function()
        change(function()
          if contains(profile.roles, role) then
            if #profile.roles > 1 then
              local t = {}
              for _, r in ipairs(profile.roles) do
                if r ~= role then table.insert(t, r) end
              end
              profile.roles = t
            end
          else
            local want = {}
            for _, r in ipairs(profile.roles) do want[r] = true end
            want[role] = true
            local t = {}
            for _, r in ipairs(P.ROLE_CANDIDATES) do
              if want[r] then
                table.insert(t, r)
                want[r] = nil
              end
            end
            for _, r in ipairs(profile.roles) do
              if want[r] then table.insert(t, r) end
            end
            profile.roles = t
          end
        end)
      end))
    end
  end
  local rows = {}
  for i = 1, #chips, 2 do
    local pair = { chips[i] }
    if chips[i + 1] then
      table.insert(pair, chips[i + 1])
    else
      table.insert(pair, ui.spacer({ flexGrow = 1 }))
    end
    table.insert(rows, ui.row({ gap = 6, key = "role-row-" .. i }, pair))
  end
  return ui.column({ gap = 8 }, {
    ui.label({ text = T("palette.roles"), fontSize = 12, color = "on_surface/0.7" }),
    ui.column({ gap = 6 }, rows),
    ui.row({ gap = 8, align = "center" }, {
      ui.toggle({ checked = profile.smooth, onChange = function(v) change(function() profile.smooth = (v == "true") end) end }),
      ui.label({ text = T("palette.smooth"), fontSize = 12, flexGrow = 1 }),
    }),
    toZonesButton(),
  })
end

local function gradientEditor()
  local n = zoneCount()
  local mid = P.midIndex(profile, n)
  local hasMid = profile.gmid and mid ~= nil
  if gradStop == "m" and not hasMid then
    gradStop = "a"
  end

  local stops = { chip("stop-a", T("gradient.start"), profile.ga, gradStop == "a", function() gradStop = "a"; render() end) }
  if hasMid then
    table.insert(stops, chip("stop-m", T("gradient.zone", { n = tostring(mid + 1) }), profile.gm, gradStop == "m", function() gradStop = "m"; render() end))
  end
  table.insert(stops, chip("stop-b", T("gradient.end"), profile.gb, gradStop == "b", function() gradStop = "b"; render() end))

  local hex = profile.ga
  if gradStop == "m" then
    hex = profile.gm
  elseif gradStop == "b" then
    hex = profile.gb
  end

  local children = {
    ui.row({ gap = 6 }, stops),
    colorEditor("grad-" .. gradStop, hex, function(h)
      change(function()
        if gradStop == "a" then profile.ga = h
        elseif gradStop == "m" then profile.gm = h
        else profile.gb = h end
      end)
    end),
  }

  if n >= 3 then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.toggle({
        checked = hasMid,
        onChange = function(v)
          change(function()
            if v == "true" then
              if not profile.gmid then
                local cols = P.colors(profile, n)
                local at = P.midIndex(profile, n)
                if cols and at then profile.gm = cols[at + 1] end
              end
              profile.gmid = true
              gradStop = "m"
            else
              profile.gmid = false
              if gradStop == "m" then gradStop = "a" end
            end
          end)
        end,
      }),
      ui.label({ text = T("gradient.mid"), fontSize = 12, flexGrow = 1 }),
    }))
  end
  if hasMid and n > 3 then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = T("gradient.mid-zone"), fontSize = 12, maxLines = 1 }),
      ui.slider({
        min = 1, max = n - 2, step = 1, value = mid, controlSize = "sm", flexGrow = 1,
        onChange = function(x)
          local i = tonumber(x)
          if i then
            change(function() profile.gzf = math.max(1, math.min(n - 2, math.floor(i + 0.5))) / (n - 1) end)
          end
        end,
      }),
      ui.label({ text = tostring(mid + 1), fontSize = 12 }),
    }))
  end
  table.insert(children, toZonesButton())
  return ui.column({ gap = 10 }, children)
end

local function customEditor()
  local n = zoneCount()
  local list = P.fitCustom(profile, n)
  local function setZone(i, hex)
    change(function()
      profile.custom = P.fitCustom(profile, n)
      profile.custom[i + 1] = hex
    end)
  end
  return ui.column({ gap = 10 }, {
    ui.label({ text = T("custom.title", { n = tostring(selZone + 1) }), fontSize = 12, color = "on_surface/0.7" }),
    colorEditor("zone-" .. selZone, list[selZone + 1], function(h) setZone(selZone, h) end),
    ui.row({ gap = 6 }, {
      ui.button({
        key = "fill-all", text = T("custom.fill-all"), glyph = "color-swatch", variant = "outline", controlSize = "sm", flexGrow = 1,
        onClick = function()
          change(function()
            local c = P.fitCustom(profile, n)[selZone + 1]
            profile.custom = {}
            for i = 1, n do profile.custom[i] = c end
          end)
        end,
      }),
      ui.button({
        key = "mirror", text = T("custom.mirror.label"), glyph = "flip-horizontal", variant = "outline", controlSize = "sm", flexGrow = 1,
        tooltip = T("custom.mirror.tip"),
        onClick = function()
          change(function()
            profile.custom = P.fitCustom(profile, n)
            for i = 1, math.floor(n / 2) do profile.custom[n + 1 - i] = profile.custom[i] end
          end)
        end,
      }),
      ui.button({
        key = "reset", text = T("custom.reset.label"), glyph = "refresh", variant = "outline", controlSize = "sm", flexGrow = 1,
        tooltip = T("custom.reset.tip"),
        onClick = function() change(function() profile.custom = { "ffffff" } end) end,
      }),
    }),
  })
end

local function staticEditor()
  return ui.column({ gap = 10 }, {
    colorEditor("static", profile.static, function(h) change(function() profile.static = h end) end),
    toZonesButton(),
  })
end

local function editor()
  local body
  if profile.mode == "palette" then
    body = paletteEditor()
  elseif profile.mode == "gradient" then
    body = gradientEditor()
  elseif profile.mode == "custom" then
    body = customEditor()
  elseif profile.mode == "static" then
    body = staticEditor()
  else
    body = ui.label({ text = T("firmware.note"), fontSize = 12, color = "on_surface/0.7", maxLines = 3 })
  end
  return ui.column({ gap = 8 }, {
    ui.label({ text = T("hint." .. profile.mode), fontSize = 11, color = "on_surface/0.6", maxLines = 3 }),
    body,
  })
end

-- ---------------------------------------------------------------- preview strip
local function onZone(i, n)
  if profile.mode == "custom" then
    selZone = i
    render()
  elseif profile.mode == "gradient" then
    if i == 0 then
      gradStop = "a"
      render()
    elseif i == n - 1 then
      gradStop = "b"
      render()
    else
      change(function()
        if not profile.gmid then
          local cols = P.colors(profile, n)
          if cols then profile.gm = cols[i + 1] end
          profile.gmid = true
        end
        profile.gzf = i / (n - 1)
        gradStop = "m"
      end)
    end
  end
end

local function zoneBorder(i, n)
  if profile.mode == "custom" then
    if i == selZone then
      return "primary", 2
    end
  elseif profile.mode == "gradient" then
    local mid = nil
    if profile.gmid then mid = P.midIndex(profile, n) end
    local isA, isB, isM = (i == 0), (i == n - 1), (mid ~= nil and i == mid)
    if (gradStop == "a" and isA) or (gradStop == "b" and isB) or (gradStop == "m" and isM) then
      return "primary", 2
    end
    if isA or isB or isM then
      return "on_surface", 2
    end
  end
  return "on_surface/0.2", 1
end

local function strip()
  local n = zoneCount()
  local boxes = {}
  for i = 0, n - 1 do
    local c = (shown and shown[i + 1]) or { 58, 58, 58 }
    local border, bw = zoneBorder(i, n)
    table.insert(boxes, ui.box({
      key = "z" .. i,
      fill = rgbHex(c),
      radius = 3,
      height = 38,
      flexGrow = 1,
      opacity = pick(profile.on, 1, 0.35),
      border = border,
      borderWidth = bw,
      tooltip = T("strip.zone", { n = tostring(i + 1) }),
      onClick = function() onZone(i, n) end,
    }))
  end

  local caption = ""
  if not profile.on then
    caption = T("strip.off")
  elseif profile.mode == "custom" then
    caption = T("strip.selected", { n = tostring(selZone + 1) })
  elseif profile.mode == "gradient" and n >= 3 then
    caption = T("strip.gradient-hint")
  elseif profile.mode == "palette" and #P.roleColors(profile.roles) == 0 then
    caption = T("strip.nopalette")
  end

  return ui.column({ gap = 6 }, {
    ui.row({ gap = pick(n > 24, 1, 2) }, boxes),
    ui.row({ justify = "space_between", gap = 8 }, {
      ui.label({ text = T("strip.left"), fontSize = 10, color = "on_surface/0.45" }),
      ui.label({ text = caption, fontSize = 11, color = "on_surface/0.7", maxLines = 2, textAlign = "center", flexGrow = 1 }),
      ui.label({ text = T("strip.right"), fontSize = 10, color = "on_surface/0.45" }),
    }),
  })
end

-- ---------------------------------------------------------------- header, tabs, banner, footer
local function header()
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "keyboard", size = 18, color = "primary" }),
    ui.label({ text = T("panel.title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1, maxLines = 1 }),
    ui.toggle({ checked = profile.on, onChange = function(v) change(function() profile.on = (v == "true") end) end }),
    ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", tooltip = T("panel.close"), onClick = function() panel.close() end }),
  })
end

local function tabs()
  local items = {}
  for _, m in ipairs(P.MODES) do
    local sel = (profile.mode == m)
    local color = pick(sel, "primary", "on_surface")
    table.insert(items, ui.column({
      key = "tab-" .. m,
      flexGrow = 1,           -- the five tabs share the row equally: left and right margins always match
      align = "center",
      gap = 3,
      paddingV = 7,
      paddingH = 2,
      radius = 8,
      fill = pick(sel, "primary/0.18", "on_surface/0.06"),
      border = pick(sel, "primary", "on_surface/0.12"),
      borderWidth = 1,
      tooltip = T("tip." .. m),
      onClick = function() change(function() profile.mode = m end) end,
    }, {
      ui.glyph({ name = TAB_GLYPHS[m], size = 16, color = color }),
      -- same minimum width on every label so every tab starts from the same size
      ui.label({ text = T("mode." .. m), fontSize = 11, color = color, minWidth = 52, maxWidth = 78, maxLines = 1, textAlign = "center" }),
    }))
  end
  return ui.row({ gap = 4 }, items)
end

local function banner()
  local st = status.state
  if st == "ready" then
    return nil
  end
  local title, body, actions = "", "", {}
  local calm = (st == "starting")
  if st == "starting" then
    title = T("banner.starting")
  elseif st == "needs_python" then
    title, body = T("banner.python.title"), T("banner.python.body")
  elseif st == "needs_access" then
    title, body = T("banner.access.title"), T("banner.access.body", { name = tostring(status.name or "?") })
    table.insert(actions, ui.button({ key = "setup", text = T("banner.access.button"), glyph = "terminal-2", variant = "primary", controlSize = "sm", onClick = runSetup }))
  elseif st == "no_device" then
    title, body = T("banner.none.title"), T("banner.none.body")
    table.insert(actions, ui.button({ key = "diag", text = T("banner.none.button"), glyph = "copy", variant = "outline", controlSize = "sm", onClick = copyDiagnostics }))
  else
    title, body = T("banner.error.title"), tostring(status.message or "")
  end
  local children = { ui.label({ text = title, fontSize = 13, fontWeight = "bold", maxLines = 2 }) }
  if body ~= "" then
    table.insert(children, ui.label({ text = body, fontSize = 12, color = "on_surface/0.8", maxLines = 6 }))
  end
  if #actions > 0 then
    table.insert(children, ui.row({ gap = 6 }, actions))
  end
  return ui.column({
    gap = 8, padding = 12, radius = 10,
    fill = pick(calm, "on_surface/0.06", "#ff55551f"),
    border = pick(calm, "on_surface/0.12", "#ff555566"),
    borderWidth = 1,
  }, children)
end

local function brightnessRow()
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "sun", size = 16, color = "on_surface/0.7" }),
    ui.slider({
      min = 0, max = 100, step = 1, value = profile.br, controlSize = "sm", flexGrow = 1,
      onChange = function(v)
        local n = tonumber(v)
        if n then
          change(function() profile.br = math.floor(math.max(0, math.min(100, n)) + 0.5) end)
        end
      end,
    }),
    ui.label({ text = tostring(profile.br) .. " %", fontSize = 12, minWidth = 40 }),
  })
end

local function footer()
  if status.state ~= "ready" then
    return ui.spacer({})
  end
  local text = T("footer.device", { name = tostring(status.name), zones = tostring(status.zones) })
  if status.grouped then
    text = T("footer.grouped", { name = tostring(status.name), lamps = tostring(status.lamps), zones = tostring(status.zones) })
  end
  return ui.label({ text = text, fontSize = 11, color = "on_surface/0.5", maxLines = 2 })
end

-- ---------------------------------------------------------------- render
function draw()
  local children = { header() }
  local b = banner()
  if b then
    table.insert(children, b)
  end
  if status.state == "no_device" then
    table.insert(children, ui.spacer({ flexGrow = 1 }))
  else
    table.insert(children, tabs())
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 14 }, { strip(), editor() }))
    if profile.mode ~= "firmware" then
      table.insert(children, brightnessRow())
    end
    table.insert(children, footer())
  end
  panel.render(ui.column({ gap = 12, padding = 14, flexGrow = 1 }, children))
end

function render()
  local n = zoneCount()
  if selZone > n - 1 then
    selZone = n - 1
  end
  syncTarget()
  draw()
end

-- ---------------------------------------------------------------- lifecycle
noctalia.state.watch("kb_status", function(v)
  if type(v) ~= "table" then
    return
  end
  status = v
  if panelOpen then
    render()
    if status.state == "needs_access" and not autoPrompted then
      autoPrompted = true
      runSetup()
    end
  end
end)

-- Follow changes made elsewhere (bar widget), but never fight our own edits.
noctalia.state.watch("kb_profile", function(v)
  if type(v) == "table" and noctalia.nowMs() - lastCommitMs > 1500 then
    profile = P.sanitize(v)
    if panelOpen then
      render()
    end
  end
end)

function onOpen(_context)
  panelOpen = true
  local p = noctalia.state.get("kb_profile")
  if type(p) == "table" then
    profile = P.sanitize(p)
  end
  local s = noctalia.state.get("kb_status")
  if type(s) == "table" then
    status = s
  end
  shown = nil                 -- first frame snaps to the current colours: no fade on open
  render()
  if status.state == "needs_access" and not autoPrompted then
    autoPrompted = true       -- once per session; the banner button runs it again on demand
    runSetup()
  end
end

function onClose()
  panelOpen = false
  animating = false
end
