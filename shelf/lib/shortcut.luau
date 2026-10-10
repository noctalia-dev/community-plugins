--!nonstrict
-- Keyboard shortcut for the drop window. On Wayland the compositor owns the
-- keyboard, so a plugin cannot grab a global key itself. This module turns
-- the shortcut setting into the bind line for the running compositor, and
-- can add that line to the compositor's config file (backing it up first).
--
-- Every line it writes sits under a marker comment, so adding again replaces
-- the old line and removing finds it.

local M = {}

M.COMMAND = "noctalia msg plugin alok-debnath/shelf:service all toggle"
M.MARKER = "noctalia-shelf: drop window shortcut"
M.DEFAULT = "Super+Shift+D"

M.NAMES = {
  hyprland = "Hyprland",
  niri = "niri",
  sway = "Sway",
  scroll = "Scroll",
  umbriel = "Umbriel",
  labwc = "labwc",
  mango = "Mango",
  kde = "KDE Plasma",
  gnome = "GNOME",
}

local MOD_ALIASES = {
  super = "super", mod = "super", mod4 = "super", win = "super", meta = "super", logo = "super",
  shift = "shift",
  ctrl = "ctrl", control = "ctrl",
  alt = "alt", mod1 = "alt",
}
local MOD_ORDER = { "super", "ctrl", "alt", "shift" }

-- Parses "Super+Shift+D" into { mods = { super = true, ... }, key = "D" }.
-- Returns nil and a reason when the text is not a usable shortcut.
function M.parse(text)
  if type(text) ~= "string" then
    return nil, "empty"
  end
  local parts = {}
  for part in string.gmatch(text, "[^+]+") do
    part = noctalia.string.trim(part)
    if part ~= "" then
      table.insert(parts, part)
    end
  end
  if #parts == 0 then
    return nil, "empty"
  end
  local mods, key = {}, nil
  for i, part in ipairs(parts) do
    local mod = MOD_ALIASES[string.lower(part)]
    if mod ~= nil and i < #parts then
      mods[mod] = true
    elseif i == #parts and mod == nil then
      key = part
    else
      return nil, "bad"
    end
  end
  if key == nil or not string.match(key, "^[%w_]+$") then
    return nil, "bad"
  end
  if #key == 1 then
    key = string.upper(key)
  end
  return { mods = mods, key = key }
end

local function modList(combo, names)
  local out = {}
  for _, mod in ipairs(MOD_ORDER) do
    if combo.mods[mod] then
      table.insert(out, names[mod])
    end
  end
  return out
end

local function lowerKey(combo)
  return #combo.key == 1 and string.lower(combo.key) or combo.key
end

function M.display(combo)
  local out = modList(combo, { super = "Super", ctrl = "Ctrl", alt = "Alt", shift = "Shift" })
  table.insert(out, combo.key)
  return table.concat(out, "+")
end

-- Which compositor this session runs, from the environment.
function M.detect()
  local env = noctalia.getenv
  local desktop = string.lower(env("XDG_CURRENT_DESKTOP") or "")
  if env("HYPRLAND_INSTANCE_SIGNATURE") then
    return "hyprland"
  elseif env("NIRI_SOCKET") then
    return "niri"
  elseif string.find(desktop, "umbriel", 1, true) then
    return "umbriel"
  elseif string.find(desktop, "scroll", 1, true) then
    return "scroll"
  elseif env("SWAYSOCK") then
    return "sway"
  elseif env("LABWC_PID") or string.find(desktop, "labwc", 1, true) then
    return "labwc"
  elseif string.find(desktop, "mango", 1, true) then
    return "mango"
  elseif string.find(desktop, "kde", 1, true) then
    return "kde"
  elseif string.find(desktop, "gnome", 1, true) then
    return "gnome"
  end
  return nil
end

local function configHome()
  local xdg = noctalia.getenv("XDG_CONFIG_HOME")
  if xdg ~= nil and xdg ~= "" then
    return xdg
  end
  return (noctalia.getenv("HOME") or "") .. "/.config"
end

-- The config file a bind goes into, and its syntax ("hyprlang" or
-- "hyprlua" for Hyprland). nil when the compositor is set up through its own
-- settings app instead.
function M.target(compositor)
  local home = configHome()
  if compositor == "hyprland" then
    local lua = home .. "/hypr/hyprland.lua"
    if noctalia.fileExists(lua) then
      return lua, "hyprlua"
    end
    return home .. "/hypr/hyprland.conf", "hyprlang"
  elseif compositor == "niri" then
    return home .. "/niri/config.kdl", "kdl"
  elseif compositor == "sway" then
    return home .. "/sway/config", "sway"
  elseif compositor == "scroll" then
    return home .. "/scroll/config", "sway"
  elseif compositor == "umbriel" then
    return home .. "/umbriel/config.toml", "toml"
  elseif compositor == "labwc" then
    return home .. "/labwc/rc.xml", "labwc"
  elseif compositor == "mango" then
    return home .. "/mango/config.conf", "mango"
  end
  return nil, nil
end

local function comment(syntax, text)
  if syntax == "hyprlua" then
    return "-- " .. text
  elseif syntax == "kdl" then
    return "// " .. text
  elseif syntax == "labwc" then
    return "<!-- " .. text .. " -->"
  end
  return "# " .. text
end

-- The bind line for a syntax.
function M.line(syntax, combo)
  local cmd = M.COMMAND
  if syntax == "hyprlang" then
    local mods = modList(combo, { super = "SUPER", ctrl = "CTRL", alt = "ALT", shift = "SHIFT" })
    return string.format("bind = %s, %s, exec, %s", table.concat(mods, " "), combo.key, cmd)
  elseif syntax == "hyprlua" then
    local keys = modList(combo, { super = "SUPER", ctrl = "CTRL", alt = "ALT", shift = "SHIFT" })
    table.insert(keys, combo.key)
    return string.format('hl.bind("%s", hl.dsp.exec_cmd("%s"))', table.concat(keys, "+"), cmd)
  elseif syntax == "kdl" then
    local keys = modList(combo, { super = "Super", ctrl = "Ctrl", alt = "Alt", shift = "Shift" })
    table.insert(keys, combo.key)
    return string.format('%s { spawn-sh "%s"; }', table.concat(keys, "+"), cmd)
  elseif syntax == "sway" then
    local keys = modList(combo, { super = "Mod4", ctrl = "Ctrl", alt = "Mod1", shift = "Shift" })
    table.insert(keys, lowerKey(combo))
    return string.format("bindsym %s exec %s", table.concat(keys, "+"), cmd)
  elseif syntax == "toml" then
    return string.format('"%s" = { action = "spawn:%s", repeat = false }', M.display(combo), cmd)
  elseif syntax == "labwc" then
    local keys = modList(combo, { super = "W", ctrl = "C", alt = "A", shift = "S" })
    table.insert(keys, lowerKey(combo))
    return string.format('<keybind key="%s"><action name="Execute"><command>%s</command></action></keybind>',
      table.concat(keys, "-"), cmd)
  elseif syntax == "mango" then
    local mods = modList(combo, { super = "SUPER", ctrl = "CTRL", alt = "ALT", shift = "SHIFT" })
    return string.format("bind=%s,%s,spawn,%s", table.concat(mods, "+"), lowerKey(combo), cmd)
  end
  return nil
end

local function splitLines(text)
  local lines = {}
  for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
    table.insert(lines, line)
  end
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

-- Drops our marker comment, the bind line under it, and the blank line we
-- put before an appended block. The line under the marker goes only when it
-- runs our command: if the user deleted the bind by hand, the next line is
-- theirs (in niri it can be the closing brace of binds).
local function withoutOurs(lines)
  local out, skip = {}, false
  for _, line in ipairs(lines) do
    if skip and string.find(line, M.COMMAND, 1, true) then
      skip = false
    elseif string.find(line, M.MARKER, 1, true) then
      skip = true
      if out[#out] == "" then
        table.remove(out)
      end
    else
      skip = false
      table.insert(out, line)
    end
  end
  return out
end

-- Is the bind for combo already there, under our marker?
function M.installed(path, syntax, combo)
  local text = path and noctalia.fileExists(path) and noctalia.readFile(path)
  if type(text) ~= "string" then
    return false
  end
  local want = M.line(syntax, combo)
  local lines = splitLines(text)
  for i, line in ipairs(lines) do
    if string.find(line, M.MARKER, 1, true) and lines[i + 1] ~= nil
      and noctalia.string.trim(lines[i + 1]) == want then
      return true
    end
  end
  return false
end

-- Clash detection ----------------------------------------------------------
-- Each bind line is read back into a set of modifiers and a key, with the
-- file's variables ($mainMod, $mod, local mainMod) resolved, so a clash is
-- found however it is written: another modifier order, a variable, a bind
-- flavour like bindd, or Mod standing for the configured modifier.

local MOD_TOKENS = {
  super = "super", mod4 = "super", win = "super", logo = "super", meta = "super", w = "super",
  shift = "shift", s = "shift",
  ctrl = "ctrl", control = "ctrl", c = "ctrl",
  alt = "alt", mod1 = "alt", a = "alt",
}

-- "alt,ctrl|d": modifiers sorted, key lower-cased.
local function canonical(mods, key)
  local list = {}
  for mod in pairs(mods) do
    table.insert(list, mod)
  end
  table.sort(list)
  return table.concat(list, ",") .. "|" .. string.lower(key)
end

-- Splits "SUPER SHIFT" / "Mod+Shift" / "W-S" into a modifier set. Returns
-- nil when a token is not a modifier.
local function modSet(text, seps, modKey)
  local mods = {}
  for token in string.gmatch(text, "[^" .. seps .. "]+") do
    local t = string.lower(token)
    if t == "mod" then
      t = modKey
    end
    local mod = MOD_TOKENS[t]
    if mod == nil then
      if t ~= "none" then
        return nil
      end
    else
      mods[mod] = true
    end
  end
  return mods
end

-- "Super+Shift+D" (any separator set): modifiers and the last token as key.
local function splitCombo(text, seps, modKey)
  local tokens = {}
  for token in string.gmatch(text, "[^" .. seps .. "]+") do
    table.insert(tokens, token)
  end
  if #tokens == 0 then
    return nil
  end
  local key = table.remove(tokens)
  local mods = modSet(table.concat(tokens, "+"), "+", modKey)
  if mods == nil then
    return nil
  end
  return canonical(mods, key)
end

local function substitute(text, vars, prefix)
  return (string.gsub(text, prefix .. "([%w_]+)", function(name)
    return vars[name] or (prefix == "%$" and "$" .. name or name)
  end))
end

-- Lua: evaluates a string expression like mainMod .. "+Space".
local function luaString(expr, vars)
  local out = {}
  for piece in string.gmatch(expr .. "..", "(.-)%.%.") do
    piece = noctalia.string.trim(piece)
    local literal = string.match(piece, '^"(.*)"$') or string.match(piece, "^'(.*)'$")
    if literal ~= nil then
      table.insert(out, literal)
    elseif vars[piece] ~= nil then
      table.insert(out, vars[piece])
    else
      return nil
    end
  end
  return table.concat(out)
end

local function isComment(line)
  local t = noctalia.string.trim(line)
  return string.sub(t, 1, 1) == "#" or string.sub(t, 1, 2) == "//" or string.sub(t, 1, 2) == "--"
    or string.sub(t, 1, 4) == "<!--"
end

-- Every bind in the file as { combo = canonical, line = text }.
local function binds(lines, syntax)
  local out = {}
  local function add(combo, line)
    if combo ~= nil then
      table.insert(out, { combo = combo, line = noctalia.string.trim(line) })
    end
  end
  local vars = {}
  if syntax == "hyprlang" then
    for _, line in ipairs(lines) do
      local name, value = string.match(line, "^%s*%$([%w_]+)%s*=%s*(.-)%s*$")
      if name ~= nil then
        vars[name] = value
      end
    end
    for _, line in ipairs(lines) do
      local mods, key = string.match(line, "^%s*bind%a*%s*=%s*([^,]*),%s*([^,]-)%s*,")
      if mods ~= nil and not isComment(line) then
        local set = modSet(substitute(mods, vars, "%$"), "%s_+", "super")
        if set ~= nil and key ~= "" then
          add(canonical(set, key), line)
        end
      end
    end
  elseif syntax == "hyprlua" then
    for _, line in ipairs(lines) do
      local name, value = string.match(line, '^%s*local%s+([%w_]+)%s*=%s*"([^"]*)"')
      if name ~= nil then
        vars[name] = value
      end
    end
    for _, line in ipairs(lines) do
      local expr = string.match(line, "hl%.bind%(%s*(.-)%s*,")
      if expr ~= nil and not isComment(line) then
        local text = luaString(expr, vars)
        if text ~= nil then
          add(splitCombo(text, "%s+", "super"), line)
        end
      end
    end
  elseif syntax == "kdl" then
    local depth, inBinds = 0, false
    for _, line in ipairs(lines) do
      if not isComment(line) then
        if depth == 0 and string.match(line, "^%s*binds%s*{") then
          inBinds = true
        elseif inBinds and depth == 1 then
          local combo = string.match(line, "^%s*([%w_+]+)[%s{]")
          if combo ~= nil then
            add(splitCombo(combo, "+", "super"), line)
          end
        end
        local _, opens = string.gsub(line, "{", "")
        local _, closes = string.gsub(line, "}", "")
        depth = depth + opens - closes
        if depth <= 0 then
          depth, inBinds = 0, false
        end
      end
    end
  elseif syntax == "sway" then
    for _, line in ipairs(lines) do
      local name, value = string.match(line, "^%s*set%s+%$([%w_]+)%s+(%S+)")
      if name ~= nil then
        vars[name] = value
      end
    end
    for _, line in ipairs(lines) do
      local rest = string.match(line, "^%s*bindsym%s+(.*)$")
      if rest ~= nil and not isComment(line) then
        -- Skip flags such as --release or --locked.
        while string.sub(rest, 1, 2) == "--" do
          rest = string.gsub(rest, "^%-%-%S+%s*", "")
        end
        local combo = string.match(rest, "^(%S+)")
        if combo ~= nil then
          add(splitCombo(substitute(combo, vars, "%$"), "+", "super"), line)
        end
      end
    end
  elseif syntax == "toml" then
    local modKey, section = "super", nil
    for _, line in ipairs(lines) do
      local value = string.match(line, '^%s*mod_key%s*=%s*"(%w+)"')
      if value ~= nil then
        modKey = string.lower(value)
      end
    end
    for _, line in ipairs(lines) do
      local header = string.match(line, "^%s*%[([^%]]+)%]%s*$")
      if header ~= nil then
        section = header
      elseif section == "keybinds" and not isComment(line) then
        local combo = string.match(line, '^%s*"([^"]+)"%s*=')
        if combo ~= nil then
          add(splitCombo(combo, "+", modKey), line)
        end
      end
    end
  elseif syntax == "labwc" then
    for _, line in ipairs(lines) do
      for combo in string.gmatch(line, '<keybind[^>]-key="([^"]+)"') do
        add(splitCombo(combo, "-", "super"), line)
      end
    end
  elseif syntax == "mango" then
    for _, line in ipairs(lines) do
      local mods, key = string.match(line, "^%s*bind%a*%s*=%s*([^,]*),%s*([^,]-)%s*,")
      if mods ~= nil and not isComment(line) then
        local set = modSet(mods, "+%s", "super")
        if set ~= nil and key ~= "" then
          add(canonical(set, key), line)
        end
      end
    end
  end
  return out
end

-- A line, not ours, that already binds the same keys, or nil.
local function conflict(lines, syntax, combo)
  local want = canonical(combo.mods, combo.key)
  for _, bind in ipairs(binds(lines, syntax)) do
    if bind.combo == want then
      return bind.line
    end
  end
  return nil
end

local function insertAfter(lines, pattern, newLines, indent)
  for i, line in ipairs(lines) do
    if string.find(line, pattern) then
      for j, l in ipairs(newLines) do
        table.insert(lines, i + j, (indent or "") .. l)
      end
      return true
    end
  end
  return false
end

-- Writes in place rather than renaming a temporary file over the config:
-- configs are often symlinks into a dotfiles repo, and a rename would
-- replace the link with a plain file. The backup covers a failed write.
local function write(path, lines)
  return noctalia.writeFile(path, table.concat(lines, "\n") .. "\n")
end

-- Adds (or replaces) the bind in the config at path. Backs the file up to
-- path .. ".shelf-backup" first. Returns true, or nil and a message.
function M.install(path, syntax, combo)
  -- Never create a config: one that is missing may live somewhere else,
  -- and a new file could replace the compositor's built-in defaults.
  if not noctalia.fileExists(path) then
    return nil, path .. " does not exist"
  end
  local text, err = noctalia.readFile(path)
  if text == nil then
    return nil, "cannot read " .. path .. ": " .. tostring(err)
  end
  -- Back up the file as the user had it. When it already holds our line
  -- (the shortcut is being changed), keep the earlier backup instead.
  if not string.find(text, M.MARKER, 1, true) or not noctalia.fileExists(path .. ".shelf-backup") then
    local ok, werr = noctalia.writeFile(path .. ".shelf-backup", text)
    if not ok then
      return nil, "cannot back up " .. path .. ": " .. tostring(werr)
    end
  end
  local lines = withoutOurs(splitLines(text))
  local clash = conflict(lines, syntax, combo)
  if clash ~= nil then
    return nil, "already bound: " .. clash
  end
  local block = { comment(syntax, M.MARKER), M.line(syntax, combo) }
  if syntax == "toml" then
    -- TOML forbids a second [keybinds] table, so go inside the existing one.
    if not insertAfter(lines, "^%s*%[keybinds%]%s*$", block) then
      table.insert(lines, "")
      table.insert(lines, "[keybinds]")
      table.insert(lines, block[1])
      table.insert(lines, block[2])
    end
  elseif syntax == "kdl" then
    if not insertAfter(lines, "^%s*binds%s*{", block, "    ") then
      return nil, "no binds { } section in " .. path
    end
  elseif syntax == "labwc" then
    if not insertAfter(lines, "<keyboard>", block, "    ") then
      return nil, "no <keyboard> section in " .. path
    end
  else
    table.insert(lines, "")
    table.insert(lines, block[1])
    table.insert(lines, block[2])
  end
  local ok, err = write(path, lines)
  if not ok then
    return nil, "cannot write " .. path .. ": " .. tostring(err)
  end
  return true
end

-- Removes our bind from the config at path.
function M.uninstall(path)
  if not noctalia.fileExists(path) then
    return true
  end
  local raw, err = noctalia.readFile(path)
  if raw == nil then
    return nil, "cannot read " .. path .. ": " .. tostring(err)
  end
  local lines = splitLines(raw)
  local kept = withoutOurs(lines)
  if #kept == #lines then
    return true
  end
  local ok, werr = write(path, kept)
  if not ok then
    return nil, "cannot write " .. path .. ": " .. tostring(werr)
  end
  return true
end

-- Command that makes the compositor pick up the change, when it does not
-- watch its config file itself.
function M.reloadCommand(compositor)
  if compositor == "sway" then
    return { "swaymsg", "reload" }
  elseif compositor == "scroll" then
    return { "scrollmsg", "reload" }
  elseif compositor == "labwc" then
    return { "labwc", "--reconfigure" }
  end
  return nil
end

return M
