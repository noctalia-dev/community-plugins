--!nonstrict
-- Controls shared by settings rows: the slider gesture, number parsing, and the compound controls (tables,
-- display modes, Browse…, lists, opacity). One row per field: fields.luau.
local kit = require("./kit.luau")
local format = require("./format.luau")
local displays = require("../lib/displays.luau")
local files = require("../pages/files.luau")

local M = {}

local EDITOR_WIDTH = 320
local ACTIONS_WIDTH = 64  -- two small icon buttons: undo, help
local NO_COLOR = "#000000FF"  -- what color controls show for an unset color

local function parseNumber(text, integer)
  local number = format.parseNumber(text)
  if number == nil then return nil end
  if integer then
    if number ~= math.floor(number) then return nil end
  end
  return number
end

-- Sliders commit on onDragEnd, not on every onChange.
-- props: key, min, max, step, value, ...; preview(number) runs on every change; commit(number) once at the end.
-- Noctalia also calls onChange when a render moves the slider (Slider::setValue reports every new value), and it
-- calls the previous render's handler. Without a gesture, a value at the one rendered last is that echo: taking it
-- for a drag would rebuild the number box next to it while someone types there.
local function slider(ctx, props, preview, commit)
  local view, key = ctx.view, props.key
  view.sliding = view.sliding or {}
  view.sliderShown = view.sliderShown or {}
  view.sliderShown[key] = props.value
  props.key = key .. ":" .. ctx.gen(key)
  props.onChange = function(text)
    local number = tonumber(text)
    if number == nil then return end
    local gesture = view.sliding[key]
    local rendered = view.sliderShown[key]
    if not gesture and rendered ~= nil and math.abs(number - rendered) <= (props.step or 0) / 2 + 1e-9 then return end
    if not gesture then
      gesture = {}
      view.sliding[key] = gesture
    end
    gesture.value = number
    if preview then preview(number) end
    ctx.renderSoon()
  end
  props.onDragEnd = function(text)
    local gesture = view.sliding[key]
    view.sliding[key] = nil
    if not gesture then return end
    commit(tonumber(text) or gesture.value)  -- the app passes the final value along
    ctx.render()
  end
  return ui.slider(props)
end

-- The value a slider gesture is previewing, if one is running.
local function sliding(ctx, key)
  local gesture = ctx.view.sliding and ctx.view.sliding[key]
  return gesture and gesture.value
end

local function tableControl(ctx, spec, effective)
  local field, key = spec.field, spec.key
  local defaults = type(field.default) == "table" and field.default
    or type(field.initial) == "table" and field.initial or {}
  -- Unset tables show the starting values as hints; typing one part fills the others from them.
  local current = (spec.set and type(effective) == "table") and effective or nil
  local controls = {}
  for _, sub in ipairs(field.keys or {}) do
    local numeric = type(defaults[sub]) == "number"
    table.insert(controls, ui.column({ key = key .. ":" .. sub, gap = 2, flexGrow = 1 }, {
      kit.muted(sub, { fontSize = kit.FONT.tiny }),
      ui.input({
        key = key .. ":" .. sub .. ":" .. ctx.gen(key), controlSize = "sm",
        value = (current and current[sub] ~= nil) and format.number(current[sub]) or "",
        placeholder = defaults[sub] ~= nil and format.number(defaults[sub]) or "",
        onChange = function(text)
          local next = {}
          for _, other in ipairs(field.keys) do
            if current and current[other] ~= nil then next[other] = current[other] else next[other] = defaults[other] end
          end
          local trimmed = noctalia.string.trim(text)
          if trimmed == "" then
            -- an emptied box is not an error: unset stays unset, a set value falls back to the hint
            ctx.view.invalid[key] = nil
            if not current then ctx.render(); return end
            next[sub] = defaults[sub]
          elseif numeric then
            local number = format.parseNumber(trimmed)
            if number == nil then ctx.view.invalid[key] = sub .. ": enter a number"; ctx.render(); return end
            next[sub] = number
          else
            next[sub] = text
          end
          ctx.view.invalid[key] = nil
          spec.onSet(next)
          ctx.render()
        end,
      }),
    }))
  end
  return controls
end

-- Mode of a connected output (meta `picker = "mode"`): Resolution and Refresh rate from the modes Umbriel
-- reports. nil (a text box instead) when the entry's output isn't connected or reports no modes.
local function modeControl(ctx, spec)
  local entry = spec.entry
  if not entry or entry.editor ~= "output" then return nil end
  local item = ctx.store.entryItems("output")[entry.index]
  local display = item and displays.forEntry(displays.list(ctx.connectedOutputs().outputs, {}), item.name)
  if not display then return nil end
  local resolutions = displays.modes(display.live)
  if #resolutions == 0 then return nil end
  local key, value = spec.key, spec.set and spec.value or nil
  local w, h, rate = displays.parseMode(value)
  local resOptions = { "Preferred" }
  local chosen = nil
  for i, res in ipairs(resolutions) do
    table.insert(resOptions, res.label)
    if w and res.width == w and res.height == h then chosen = i end
  end
  local resIndex = 0
  if chosen then
    resIndex = chosen
  elseif value ~= nil then
    table.insert(resOptions, tostring(value) .. " (not reported)")
    resIndex = #resOptions - 1
  end
  local function write(res, text)
    spec.onSet(res.width .. "x" .. res.height .. (text and ("@" .. text) or ""))
    ctx.render()
  end
  local resSelect = ui.select({ key = key .. ":resolution", options = resOptions, selectedIndex = resIndex,
    flexGrow = 1, controlSize = "sm", onChange = function(text)
      local i = tonumber(text) or 0
      if i == 0 then
        if spec.onUnset then spec.onUnset(); ctx.render() end
      elseif resolutions[i] then
        write(resolutions[i], resolutions[i].rates[1].text)
      end
    end })
  local res = chosen and resolutions[chosen] or nil
  local rateOptions, rateIndex, offset = {}, 0, 0
  if res then
    if rate == nil then table.insert(rateOptions, "Highest"); offset = 1 end
    local found = nil
    for i, r in ipairs(res.rates) do
      table.insert(rateOptions, r.text .. " Hz" .. (r.preferred and " (preferred)" or ""))
      if rate and math.abs(r.mhz / 1000 - rate) < 0.0005 then found = i end
    end
    if found then rateIndex = found - 1 + offset
    elseif rate then
      table.insert(rateOptions, string.format("%g Hz (not reported)", rate))
      rateIndex = #rateOptions - 1
    end
  else  -- unset: Umbriel uses the preferred mode
    local _, _, preferredRate = displays.parseMode(displays.preferredText(display.live))
    rateOptions = { preferredRate and string.format("%g Hz", preferredRate) or "Refresh rate" }
  end
  local rateSelect = ui.select({ key = key .. ":rate", options = rateOptions, selectedIndex = rateIndex,
    enabled = res ~= nil, flexGrow = 1, controlSize = "sm", onChange = function(text)
      local i = (tonumber(text) or 0) + 1 - offset
      if not res then return end
      if i == 0 then write(res, nil)
      elseif res.rates[i] then write(res, res.rates[i].text) end
    end })
  return { resSelect, rateSelect }
end

-- Browse… for path fields (meta `picker = "file"`): `onChosen(value)` gets the chosen file; a `command` field
-- (autostart) first lists the installed apps, like the default apps.
local function browseButton(ctx, spec, onChosen)
  local field, view = spec.field, ctx.view
  local options = field.file or {}
  return ui.button({ key = spec.key .. ":browse", text = "Browse…", glyph = "folder-open", controlSize = "sm",
    variant = "outline", tooltip = options.command and "Choose an app" or options.title,
    onClick = function()
      if options.command then
        view.pick, view.appQuery = { options = options, onChosen = onChosen }, ""
        ctx.go({ name = "appPicker", kind = "command", target = field.label })
      else
        files.open(ctx, options, onChosen)
      end
    end })
end

local function copyList(items)
  local copy = {}
  for i, old in ipairs(items) do copy[i] = old end
  return copy
end

-- Lists get one row per item below the label.
local function listRows(ctx, spec, effective)
  local key = spec.key
  local items = type(effective) == "table" and effective or {}
  local rows = {}
  local function swap(a, b)
    local next = copyList(items)
    next[a], next[b] = next[b], next[a]
    spec.onSet(next); ctx.bump(key); ctx.render()
  end
  for index, item in ipairs(items) do
    table.insert(rows, ui.row({ key = key .. ":item:" .. index, gap = 6, align = "center" }, {
      ui.input({ key = key .. ":item:" .. index .. ":" .. ctx.gen(key), value = tostring(item), flexGrow = 1,
                 controlSize = "sm",
                 onChange = function(text)
                   local next = copyList(items)
                   next[index] = text
                   spec.onSet(next)
                   ctx.render()
                 end }),
      kit.iconButton("arrow-up", "Move up", function() swap(index, index - 1) end, index > 1),
      kit.iconButton("arrow-down", "Move down", function() swap(index, index + 1) end, index < #items),
      kit.iconButton("trash", "Remove", function()
        local next = copyList(items)
        table.remove(next, index)
        spec.onSet(next); ctx.bump(key); ctx.render()
      end),
    }))
  end
  local function append(value)
    local next = copyList(items)
    table.insert(next, value)
    spec.onSet(next); ctx.bump(key)
  end
  local addRow = {
    ui.button({ text = "Add", glyph = "plus", controlSize = "sm", variant = "outline",
                onClick = function() append(""); ctx.render() end }),
  }
  if spec.field.picker == "file" then table.insert(addRow, browseButton(ctx, spec, append)) end
  table.insert(rows, ui.row({ key = key .. ":add", gap = 6 }, addRow))
  return rows
end

-- Opacity 0-1 for a #RRGGBB(AA) color, written back as its alpha byte (0.84 = D7).
local function opacityRow(ctx, spec, effective)
  local key, view = spec.key, ctx.view
  local follow = spec.follow
  local color = type(effective) == "string" and effective or spec.field.initial
  if follow then color = "#000000" .. follow.alpha end
  local rgb, alphaHex = string.match(type(color) == "string" and color or NO_COLOR, "^(#%x%x%x%x%x%x)(%x?%x?)$")
  if not rgb then return nil end
  alphaHex = string.upper(alphaHex ~= "" and alphaHex or "FF")
  local alpha = tonumber(alphaHex, 16) / 255
  local shown = sliding(ctx, key .. ":opacity-slider")  -- the value under a running drag
  local valueText = shown == nil and string.format("%.2f · %s", alpha, alphaHex)
                    or string.format("%.2f · ", shown) .. format.alphaByte(shown)
  return ui.row({ key = key .. ":opacity", gap = 12, align = "center" }, {
    ui.column({ flexGrow = 1 }, { kit.muted("Opacity") }),
    ui.row({ width = EDITOR_WIDTH, gap = 6, align = "center", opacity = (spec.set or follow) and 1 or 0.75,
             tooltip = "Opacity (alpha of the color)" }, {  -- sliders take no tooltip in Noctalia
      slider(ctx, { key = key .. ":opacity-slider", min = 0, max = 1, step = 0.01, value = alpha,
                    flexGrow = 1, controlSize = "sm" }, nil,
        function(number)
          number = math.max(0, math.min(1, number))
          if follow then
            spec.onFollow(follow.source, number)
          else
            spec.onSet(rgb .. format.alphaByte(number))
          end
          ctx.bump(key)
        end),
      ui.label({ text = valueText, fontSize = kit.FONT.small }),
    }),
    ui.row({ width = ACTIONS_WIDTH }, {}),
  })
end

M.EDITOR_WIDTH = EDITOR_WIDTH
M.ACTIONS_WIDTH = ACTIONS_WIDTH
M.NO_COLOR = NO_COLOR
M.parseNumber = parseNumber
M.slider = slider
M.sliding = sliding
M.tableControl = tableControl
M.modeControl = modeControl
M.browseButton = browseButton
M.listRows = listRows
M.opacityRow = opacityRow

return M
