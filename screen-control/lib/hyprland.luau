--!nonstrict
-- The screens' layout on Hyprland (DESIGN.md, sections 10.3 and 10.9). Reads the screens with
-- `hyprctl monitors all -j` and applies a layout with `hyprctl eval 'hl.monitor({…})'`
-- while Noctalia runs, never in Hyprland's config. A Hyprland with the older config takes
-- `hyprctl --batch` with `keyword monitor` instead.

local Hyprland = {}

local lua = nil -- whether Hyprland takes Lua; nil until the first apply tells
local vrrNow = {} -- screen id -> the VRR Hyprland reported last

local function quoted(value)
  return string.format("%q", tostring(value))
end

-- "1920x1080@279.99Hz" -> "1920x1080@279.99"
local function modeOf(text)
  return (text:gsub("Hz$", ""))
end

-- One screen as Hyprland reports it, in the plugin's own terms.
local function screenOf(monitor)
  local hardware = monitor.hardwareDetails or {}
  local modes = {}
  for _, mode in ipairs(monitor.availableModes or {}) do
    table.insert(modes, modeOf(mode))
  end
  return {
    id = monitor.description,
    name = monitor.name,
    model = monitor.model ~= "" and monitor.model or monitor.name,
    pixelWidth = monitor.width,
    pixelHeight = monitor.height,
    mode = string.format("%dx%d@%.2f", monitor.width, monitor.height, monitor.refreshRate),
    modes = modes,
    x = monitor.x,
    y = monitor.y,
    scale = monitor.scale,
    transform = monitor.transform % 4,
    enabled = not monitor.disabled,
    vrrCapable = hardware.vrrCapable == true,
    vrr = monitor.vrr and 1 or 0,
    hdrCapable = hardware.hdr == true,
    hdr = monitor.colorManagementPreset == "hdr" or monitor.colorManagementPreset == "hdredid",
    sdrBrightness = monitor.sdrBrightness or 1,
    tenBit = (monitor.currentFormat or ""):find("2101010", 1, true) ~= nil,
    mirrorOf = monitor.mirrorOf ~= "none" and monitor.mirrorOf or nil,
    workspaces = "",
  }
end

-- Calls back with the screens, in Hyprland's order, or nil and an error.
function Hyprland.read(callback)
  noctalia.runAsync({ "hyprctl", "monitors", "all", "-j" }, function(result)
    if result.exitCode ~= 0 then
      callback(nil, result.stderr ~= "" and result.stderr or result.stdout)
      return
    end
    local monitors = noctalia.json.decode(result.stdout)
    if type(monitors) ~= "table" then
      callback(nil, "hyprctl monitors: no JSON")
      return
    end
    local screens = {}
    for _, monitor in ipairs(monitors) do
      local screen = screenOf(monitor)
      vrrNow[screen.id] = screen.vrr
      table.insert(screens, screen)
    end
    -- A mirror names its source by connector; the layout names it by screen.
    local byName = {}
    for _, screen in ipairs(screens) do
      byName[screen.name] = screen.id
    end
    for _, screen in ipairs(screens) do
      screen.mirror = screen.mirrorOf and byName[screen.mirrorOf] or ""
      screen.mirrorOf = nil
    end
    callback(screens)
  end, 5000)
end

-- "1-3, 5" -> { 1, 2, 3, 5 }; nil when the text is not a list of workspaces.
function Hyprland.workspaceIds(text)
  local ids = {}
  for part in (text or ""):gmatch("[^,%s]+") do
    local from, to = part:match("^(%d+)%-(%d+)$")
    from = tonumber(from or part:match("^(%d+)$"))
    to = tonumber(to) or from
    if not from or to < from or to - from > 99 then
      return nil
    end
    for id = from, to do
      table.insert(ids, id)
    end
  end
  return ids
end

local function connector(screens, id)
  for _, screen in ipairs(screens) do
    if screen.id == id then
      return screen.name
    end
  end
  return nil
end

-- A workspace rule as Lua, from its JSON in `hyprctl workspacerules -j`, on <monitor> when
-- given. The fields a rule keeps while this plugin moves it to another screen.
local RULE_FIELDS = { default = "default", persistent = "persistent", layout = "layout",
  defaultName = "default_name", borderSize = "border_size" }

local function workspaceRule(id, rule, monitor)
  local fields = { "workspace = " .. quoted(id) }
  monitor = monitor or (rule and rule.monitor)
  if monitor and monitor ~= "" then
    table.insert(fields, "monitor = " .. quoted(monitor))
  end
  for json, field in pairs(RULE_FIELDS) do
    local value = rule and rule[json]
    if type(value) == "boolean" or type(value) == "number" then
      table.insert(fields, `{field} = {tostring(value)}`)
    elseif type(value) == "string" and value ~= "" then
      table.insert(fields, `{field} = {quoted(value)}`)
    end
  end
  return "hl.workspace_rule({ " .. table.concat(fields, ", ") .. " })"
end

-- The Lua for <layout>. <ruled> maps each workspace id this plugin moved to the rule it had
-- before, or false; <current> maps ids to their rules now. A workspace that no screen asks
-- for any more gets its rule back. Returns the Lua and the new <ruled>.
local function luaRules(layout, ruled, current)
  local lines, kept = {}, {}
  for _, screen in ipairs(layout) do
    local output = quoted("desc:" .. screen.id)
    if not screen.enabled then
      table.insert(lines, string.format("hl.monitor({ output = %s, disabled = true })", output))
    else
      local mirror = screen.mirror ~= "" and connector(layout, screen.mirror) or ""
      table.insert(lines, string.format(
        "hl.monitor({ output = %s, disabled = false, mode = %s, position = %s, scale = %s, transform = %d,"
          .. " vrr = %d, mirror = %s, bitdepth = %d, cm = %s, sdrbrightness = %s })",
        output, quoted(screen.mode), quoted(`{screen.x}x{screen.y}`), quoted(screen.scale), screen.transform,
        screen.vrr, quoted(mirror), (screen.hdr or screen.tenBit) and 10 or 8,
        quoted(screen.hdr and "hdr" or "srgb"), quoted(screen.sdrBrightness)))
      for _, number in ipairs(Hyprland.workspaceIds(screen.workspaces) or {}) do
        local id = tostring(number)
        if ruled[id] == nil then
          kept[id] = current[id] or false
        else
          kept[id] = ruled[id]
        end
        table.insert(lines, workspaceRule(id, kept[id] or nil, "desc:" .. screen.id))
        table.insert(lines, string.format(
          "pcall(function() hl.dispatch(hl.dsp.workspace.move({ workspace = %s, monitor = %s })) end)",
          quoted(id), quoted(screen.name)))
      end
    end
  end
  -- Hyprland merges a rule into the one it has and cannot remove one while it runs, so a
  -- workspace gets back the fields its rule had, and keeps the screen until Hyprland
  -- reloads its config when its rule named none.
  for id, rule in pairs(ruled) do
    if kept[id] == nil and rule then
      table.insert(lines, workspaceRule(id, rule))
    end
  end
  return table.concat(lines, "\n"), kept
end

-- Hyprland leaves VRR out when it compares a monitor rule with the one in use, so a rule
-- that changes only VRR does not apply. A rule that also changes another value, the
-- brightness of normal content here, comes first; the real rule then applies VRR.
local function vrrRules(layout)
  local lines = {}
  for _, screen in ipairs(layout) do
    if screen.enabled and vrrNow[screen.id] ~= nil and screen.vrr ~= vrrNow[screen.id] then
      table.insert(lines, string.format("hl.monitor({ output = %s, vrr = %d, sdrbrightness = %s })",
        quoted("desc:" .. screen.id), screen.vrr, quoted((tonumber(screen.sdrBrightness) or 1) + 0.01)))
    end
  end
  return table.concat(lines, "\n")
end

local function keywordRules(layout)
  local lines = {}
  for _, screen in ipairs(layout) do
    local output = "desc:" .. screen.id
    if not screen.enabled then
      table.insert(lines, `keyword monitor {output},disable`)
    else
      local rule = string.format("%s,%s,%dx%d,%s,transform,%d,vrr,%d,bitdepth,%d,cm,%s,sdrbrightness,%s",
        output, screen.mode, screen.x, screen.y, tostring(screen.scale), screen.transform, screen.vrr,
        (screen.hdr or screen.tenBit) and 10 or 8, screen.hdr and "hdr" or "srgb", tostring(screen.sdrBrightness))
      local mirror = screen.mirror ~= "" and connector(layout, screen.mirror)
      if mirror then
        rule ..= ",mirror," .. mirror
      end
      table.insert(lines, "keyword monitor " .. rule)
      for _, id in ipairs(Hyprland.workspaceIds(screen.workspaces) or {}) do
        table.insert(lines, `keyword workspace {id},monitor:{output}`)
        table.insert(lines, `dispatch moveworkspacetomonitor {id} {screen.name}`)
      end
    end
  end
  return table.concat(lines, " ; ")
end

local function ordered(layout)
  local list = {}
  for _, screen in ipairs(layout) do
    if screen.enabled then
      table.insert(list, screen)
    end
  end
  for _, screen in ipairs(layout) do
    if not screen.enabled then
      table.insert(list, screen)
    end
  end
  return list
end

-- Applies <layout>, a list of screens. <ruled> is what luaRules takes. Screens that stay on
-- come first, so the last screen is never turned off before another one is on. Calls back
-- with whether Hyprland took it, its message, and the new <ruled>.
function Hyprland.apply(layout, ruled, callback)
  layout = ordered(layout)
  local function older()
    noctalia.runAsync({ "hyprctl", "--batch", keywordRules(layout) }, function(result)
      callback(result.exitCode == 0, result.stdout, ruled)
    end, 10000)
  end
  if lua == false then
    older()
    return
  end
  noctalia.runAsync({ "hyprctl", "workspacerules", "-j" }, function(rules)
    local current = {}
    for _, rule in ipairs(rules.exitCode == 0 and noctalia.json.decode(rules.stdout) or {}) do
      if type(rule) == "table" and rule.workspaceString then
        current[rule.workspaceString] = rule
      end
    end
    local text, kept = luaRules(layout, ruled, current)
    local function run()
      -- A Hyprland without Lua answers "unknown request". A Lua error exits with an error; a
      -- warning, such as a workspace that does not exist yet, does not.
      noctalia.runAsync({ "hyprctl", "eval", text }, function(result)
        if result.exitCode == 0 and not result.stdout:find("unknown request", 1, true) then
          lua = true
          callback(true, nil, kept)
        elseif lua == nil and result.exitCode == 0 then
          lua = false
          older()
        else
          callback(false, noctalia.string.trim(result.stdout .. result.stderr), ruled)
        end
      end, 10000)
    end
    local first = lua ~= false and vrrRules(layout) or ""
    if first == "" then
      run()
    else
      noctalia.runAsync({ "hyprctl", "eval", first }, run, 10000)
    end
  end, 5000)
end

-- Applies <layout> and gives every workspace in <ruled> its rule back, without waiting, as
-- the plugin is turned off.
function Hyprland.applyNow(layout, ruled)
  layout = ordered(layout)
  for _, screen in ipairs(layout) do
    screen.workspaces = ""
  end
  if lua == false then
    noctalia.runAsync({ "hyprctl", "--batch", keywordRules(layout) })
    return
  end
  local first = vrrRules(layout)
  if first ~= "" then
    noctalia.runAsync({ "hyprctl", "eval", first })
  end
  noctalia.runAsync({ "hyprctl", "eval", (luaRules(layout, ruled, {})) })
end

return Hyprland
