--!nonstrict
-- Keyboard service: one list of the languages you type in, from the compositor's keyboard
-- layouts and fcitx5's input methods, and switching between them.
--
-- A layout comes from Hyprland's main keyboard. An fcitx5 input method joins the list when
-- it is more than a plain keyboard, such as Hangul, or a keyboard layout the compositor does
-- not have. Picking a layout switches every keyboard to it and puts fcitx5 back on plain
-- typing; picking an input method switches fcitx5 to it.
--
-- The active one is read every second; the lists and their names when the service starts,
-- every 30 seconds, and when the panel asks.
--
-- The on-screen keyboard is the "osk" layer, shown, hidden and placed here.
--
-- The panel adds and removes layouts and input methods. Once the owner changes the layouts
-- here, the plugin keeps its own list in its data folder and sets it in Hyprland while
-- Noctalia runs, also after Hyprland reloads its config; it never writes Hyprland's config.
-- "Use Hyprland's layouts" gives the config's list back. Input methods are added to and
-- removed from fcitx5's group through fcitx5, which saves them in its own configuration.
--
-- Publishes "keyboard.model" and takes commands on "keyboard.command".

local Keybind = require("./lib/keybind.luau")

local POLL_MS = 1000
local REFRESH_MS = 30000
local IPC = "noctalia msg plugin omerfuyar/keyboard:service all "
local keys = { Keybind.new("keybind", IPC .. "next"), Keybind.new("osk_key", IPC .. "osk") }
-- Settings change with each typed letter, so the keys are checked once typing stops.
local KEYS_DELAY_MS = 1500
local keysDueMs = nil

-- xkb's list of layouts and their names.
local XKB_LIST = "/usr/share/X11/xkb/rules/evdev.lst"
local onHyprland = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil and noctalia.commandExists("hyprctl")
local hasFcitx = noctalia.commandExists("fcitx5-remote")
local FCITX = { "gdbus", "call", "--session", "--dest", "org.fcitx.Fcitx5", "--object-path", "/controller", "--method" }

local OSK = "osk"
-- The keyboard's gap to the screen edges it sits at, in pixels.
local MARGIN = 12
-- The edges each place is anchored to; "center" has none.
local SPOT_ANCHORS = {
  top_left = { "top", "left" }, top = { "top" }, top_right = { "top", "right" },
  left = { "left" }, center = {}, right = { "right" },
  bottom_left = { "bottom", "left" }, bottom = { "bottom" }, bottom_right = { "bottom", "right" },
}
-- wtype types the on-screen keyboard's keys; each system installs it its own way.
local WTYPE_INSTALLERS = {
  { manager = "pacman", command = "sudo pacman -S --needed wtype" },
  { manager = "apt", command = "sudo apt install wtype" },
  { manager = "dnf", command = "sudo dnf install wtype" },
  { manager = "zypper", command = "sudo zypper install wtype" },
}

local oskOpen = false
local oskPicking = false -- the keyboard shows its nine places instead of its keys
local oskSpot = "bottom"
local hasWtype = noctalia.commandExists("wtype")

local dataDir = noctalia.pluginDataDir() or ""
local layoutsFile = dataDir .. "/layouts.json"
local oskFile = dataDir .. "/osk.json"

local model = { ready = false, entries = {}, current = nil, fcitx = false }
-- The plugin's own layouts, once the owner changed them here: { layouts = { { code, variant } },
-- original = { layout, variant } }, the config's list to give back. nil follows Hyprland's config.
local stored = nil
local mainLayout, mainVariant = nil, nil -- the main keyboard's layouts as Hyprland has them now
local lastApplyMs = 0
local groupName = nil -- fcitx5's current group
local groupItems = {} -- its input methods with their layouts: { id, layout }
local wantCatalog = false -- read the catalog once the running refresh is done
local catalog = nil -- what the panel can add: { layouts = { { code, name } }, ims = { { id, name } } }
local layouts = {} -- { code, variant } of the compositor, in order
local activeLayout = 0 -- index into layouts, from 0 as Hyprland counts
local layoutNames = nil -- code -> "Turkish", every layout xkb knows, read once
local layoutLangs = {} -- code -> "en", from fcitx5's keyboard input methods
local groupLayout = nil -- the layout fcitx5's group types its input methods on, such as "us"
local inputMethods = {} -- in the group's order: { id, name, label, lang, layout }
local currentIm = nil
local lastPollMs = 0
local lastRefreshMs = nil
local polling = false
local refreshing = false

local function publish()
  noctalia.state.set("keyboard.model", model)
end

local function upper(text)
  return (text or ""):upper()
end

-- The on-screen keyboard's size: as tall as the setting says, three times as wide.
local function oskSize()
  local height = math.clamp(tonumber(noctalia.getConfig("osk_height")) or 220, 140, 400)
  return { width = height * 3, height = height }
end

-- fcitx5's keyboard input methods are "keyboard-<layout>" or "keyboard-<layout>-<variant>".
local function keyboardLayout(id)
  return id:match("^keyboard%-([%a]+)")
end

-- The one list, and which of it is active.
local function build()
  local entries, covered = {}, {}
  for index, layout in ipairs(layouts) do
    covered[layout.code] = true
    table.insert(entries, {
      key = "layout:" .. (index - 1),
      kind = "layout",
      index = index - 1,
      code = layout.code,
      short = upper(layoutLangs[layout.code] or layout.code),
      name = layoutNames and layoutNames[layout.code] or layout.code,
    })
  end
  for _, im in ipairs(inputMethods) do
    local code = keyboardLayout(im.id)
    if code == nil or not covered[code] then
      table.insert(entries, {
        key = "im:" .. im.id,
        kind = "im",
        id = im.id,
        short = upper(code or (im.lang ~= "" and im.lang) or im.label),
        name = im.name,
      })
    end
  end
  local current = nil
  local imCode = currentIm and keyboardLayout(currentIm)
  for _, entry in ipairs(entries) do
    if entry.kind == "im" and entry.id == currentIm then
      current = entry.key
    end
  end
  if current == nil and (currentIm == nil or imCode ~= nil) then
    for _, entry in ipairs(entries) do
      if entry.kind == "layout" and entry.index == activeLayout then
        current = entry.key
      end
    end
  end
  local removable = #entries > 1
  for _, entry in ipairs(entries) do
    entry.removable = removable and (entry.kind == "im" or #layouts > 1)
  end
  model = {
    ready = #entries > 0,
    entries = entries,
    current = current,
    fcitx = #inputMethods > 0,
    managed = stored ~= nil,
    catalog = catalog,
    osk = oskOpen,
    oskPicking = oskPicking,
    oskSpot = oskSpot,
    oskSize = oskSize(),
    oskKey = noctalia.string.trim(noctalia.getConfig("osk_key") or ""),
    wtype = hasWtype,
  }
  publish()
end

local function readDevices(text)
  local devices = noctalia.json.decode(text or "")
  layouts = {}
  if type(devices) ~= "table" or type(devices.keyboards) ~= "table" then
    return
  end
  for _, keyboard in ipairs(devices.keyboards) do
    if keyboard.main then
      local variants = string.split(keyboard.variant or "", ",")
      for index, code in ipairs(string.split(keyboard.layout or "", ",")) do
        code = noctalia.string.trim(code)
        if code ~= "" then
          table.insert(layouts, { code = code, variant = noctalia.string.trim(variants[index] or "") })
        end
      end
      activeLayout = tonumber(keyboard.active_layout_index) or 0
      mainLayout, mainVariant = keyboard.layout or "", keyboard.variant or ""
    end
  end
end

local function layoutCodes()
  local codes = {}
  for _, layout in ipairs(layouts) do
    table.insert(codes, layout.code)
  end
  return table.concat(codes, ",")
end

local function quoted(value)
  return string.format("%q", tostring(value))
end

-- "us,tr" and ",f" for a list of { code, variant }.
local function joined(list)
  local codes, variants = {}, {}
  for _, layout in ipairs(list) do
    table.insert(codes, layout.code)
    table.insert(variants, layout.variant or "")
  end
  return table.concat(codes, ","), table.concat(variants, ",")
end

-- Sets layouts and variants in Hyprland, with Lua first, as a Lua config takes only that.
local function setInHyprland(layout, variant)
  lastApplyMs = noctalia.nowMs()
  local lua = string.format("hl.config({ input = { kb_layout = %s, kb_variant = %s } })", quoted(layout), quoted(variant))
  noctalia.runAsync({ "hyprctl", "eval", lua }, function(result)
    if noctalia.string.trim(result.stdout or "") ~= "ok" then
      noctalia.runAsync({ "hyprctl", "keyword", "input:kb_variant", variant })
      noctalia.runAsync({ "hyprctl", "keyword", "input:kb_layout", layout })
    end
  end)
end

-- Keeps Hyprland on the plugin's own list; a config reload puts the config's back.
local function ensureApplied()
  if stored == nil or mainLayout == nil or noctalia.nowMs() - lastApplyMs < 3000 then
    return
  end
  local layout, variant = joined(stored.layouts)
  if layout ~= mainLayout or variant ~= mainVariant then
    setInHyprland(layout, variant)
  end
end

local function saveStored()
  noctalia.mkdirAll(dataDir)
  if stored then
    noctalia.writeFile(layoutsFile, noctalia.json.encode(stored) or "")
  else
    noctalia.removeFile(layoutsFile)
  end
end

-- Hyprland's keyboards, then fcitx5's input method.
local function poll()
  if polling then
    return
  end
  polling = true
  lastPollMs = noctalia.nowMs()
  local function readIm()
    if not hasFcitx then
      polling = false
      currentIm = nil
      ensureApplied()
      build()
      return
    end
    noctalia.runAsync({ "fcitx5-remote", "-n" }, function(result)
      polling = false
      local current = result.exitCode == 0 and noctalia.string.trim(result.stdout or "") or ""
      currentIm = current ~= "" and current or nil
      ensureApplied()
      build()
    end, 5000)
  end
  if not onHyprland then
    readIm()
    return
  end
  noctalia.runAsync({ "hyprctl", "-j", "devices" }, function(result)
    local before = layoutCodes()
    readDevices(result.stdout)
    -- New layouts need their names.
    if layoutCodes() ~= before then
      lastRefreshMs = nil
    end
    readIm()
  end, 5000)
end

-- Every layout xkb knows, as code -> name, from the "! layout" part of its list.
local function readLayoutNames(text)
  local names, inLayouts = {}, false
  for line in (text or ""):gmatch("[^\n]+") do
    if line:sub(1, 1) == "!" then
      inLayouts = line:match("^!%s*layout") ~= nil
    elseif inLayouts then
      local code, name = line:match("^%s*(%S+)%s+(.-)%s*$")
      if code then
        names[code] = name
      end
    end
  end
  return names
end

-- Calls a method of fcitx5's controller over D-Bus, and passes its answer to done.
local function fcitx(method, args, done)
  local argv = table.clone(FCITX)
  table.insert(argv, "org.fcitx.Fcitx.Controller1." .. method)
  for _, arg in ipairs(args) do
    table.insert(argv, arg)
  end
  noctalia.runAsync(argv, function(result)
    done(result.exitCode == 0 and result.stdout or nil)
  end, 10000)
end

-- What can be added: every layout, and the input methods fcitx5 has besides plain keyboards
-- and the ones in its group. For the panel's picker.
local function buildCatalog(available)
  local found = { layouts = {}, ims = {} }
  local inGroup = {}
  for _, item in ipairs(groupItems) do
    inGroup[item.id] = true
  end
  for code, name in pairs(layoutNames or {}) do
    -- "custom" is a placeholder for a layout file of one's own.
    if code ~= "custom" then
      table.insert(found.layouts, { code = code, name = name })
    end
  end
  table.sort(found.layouts, function(a, b)
    return a.name < b.name
  end)
  for _, im in ipairs(available) do
    if keyboardLayout(im.id) == nil and not inGroup[im.id] then
      table.insert(found.ims, { id = im.id, name = im.name })
    end
  end
  catalog = found
end

-- fcitx5's group and its input methods, then every input method fcitx5 has: each one is
-- (id, name, native name, icon, label, language, configurable). Names hold parentheses,
-- such as "English (US)", so the fields are matched as quoted strings.
local function readFcitx(done)
  fcitx("CurrentInputMethodGroup", {}, function(answer)
    local group = answer and answer:match("^%('(.*)',%)")
    if group == nil then
      done({})
      return
    end
    fcitx("InputMethodGroupInfo", { group }, function(info)
      groupName = group
      groupLayout = info and info:match("^%('([^']*)'")
      groupItems = {}
      for id, layout in ((info or ""):match("%[(.*)%]") or ""):gmatch("%('([^']*)', '([^']*)'%)") do
        table.insert(groupItems, { id = id, layout = layout })
      end
      fcitx("AvailableInputMethods", {}, function(list)
        local available = {}
        local pattern = "%('([^']*)', '([^']*)', '[^']*', '[^']*', '([^']*)', '([^']*)', %a+%)"
        for id, name, label, lang in (list or ""):gmatch(pattern) do
          table.insert(available, { id = id, name = name, label = label, lang = lang })
        end
        done(available)
      end)
    end)
  end)
end

local function refresh()
  if refreshing then
    return
  end
  refreshing = true
  lastRefreshMs = noctalia.nowMs()
  local function withNames()
    if not noctalia.commandExists("gdbus") then
      refreshing = false
      if wantCatalog then
        wantCatalog = false
        buildCatalog({})
      end
      build()
      return
    end
    readFcitx(function(available)
      refreshing = false
      local byId = {}
      for _, im in ipairs(available) do
        byId[im.id] = im
        local imLayout = keyboardLayout(im.id)
        if imLayout and im.lang ~= "" and im.id == "keyboard-" .. imLayout then
          layoutLangs[imLayout] = im.lang
        end
      end
      inputMethods = {}
      for _, item in ipairs(groupItems) do
        table.insert(inputMethods, byId[item.id] or { id = item.id, name = item.id, label = "", lang = "" })
      end
      if wantCatalog then
        wantCatalog = false
        buildCatalog(available)
      end
      build()
    end)
  end
  if layoutNames then
    withNames()
  else
    noctalia.readFileAsync(XKB_LIST, function(text)
      layoutNames = readLayoutNames(text)
      withNames()
    end)
  end
end

-- Switches to one entry of the list.
local function choose(key)
  for _, entry in ipairs(model.entries) do
    if entry.key == key then
      if entry.kind == "layout" then
        noctalia.runAsync({ "hyprctl", "switchxkblayout", "all", tostring(entry.index) }, function()
          poll()
        end)
        if model.fcitx then
          -- fcitx5 types plainly: with its keyboard of the same layout when it has one.
          local plain = nil
          for _, im in ipairs(inputMethods) do
            if keyboardLayout(im.id) == entry.code then
              plain = im.id
            end
          end
          noctalia.runAsync(plain and { "fcitx5-remote", "-s", plain } or { "fcitx5-remote", "-c" }, function()
            poll()
          end)
        end
      else
        -- An input method types on its group's layout, such as us for Hangul.
        for index, layout in ipairs(layouts) do
          if layout.code == groupLayout and index - 1 ~= activeLayout then
            noctalia.runAsync({ "hyprctl", "switchxkblayout", "all", tostring(index - 1) })
          end
        end
        noctalia.runAsync({ "fcitx5-remote", "-s", entry.id }, function()
          poll()
        end)
      end
      model.current = key
      publish()
      return
    end
  end
end

-- The layouts as they are now: the plugin's own, or Hyprland's.
local function currentLayouts()
  local list = {}
  for _, layout in ipairs(stored and stored.layouts or layouts) do
    table.insert(list, { code = layout.code, variant = layout.variant or "" })
  end
  return list
end

-- From now on the plugin keeps this list, and remembers the config's to give it back.
local function setLayouts(list)
  if #list == 0 then
    return
  end
  stored = { layouts = list, original = stored and stored.original or { layout = mainLayout or "", variant = mainVariant or "" } }
  saveStored()
  lastApplyMs = 0
  ensureApplied()
  lastRefreshMs = nil
end

local function addLayout(code)
  local list = currentLayouts()
  for _, layout in ipairs(list) do
    if layout.code == code then
      return
    end
  end
  table.insert(list, { code = code, variant = "" })
  setLayouts(list)
end

local function removeLayout(index)
  local list = currentLayouts()
  if #list > 1 and list[index + 1] then
    table.remove(list, index + 1)
    setLayouts(list)
  end
end

-- Hyprland's config decides the layouts again.
local function resetLayouts()
  if stored == nil then
    return
  end
  local original = stored.original
  stored = nil
  saveStored()
  if original and original.layout ~= "" then
    setInHyprland(original.layout, original.variant or "")
  end
  lastRefreshMs = nil
end

-- Sets fcitx5's group to these { id, layout } items, and has fcitx5 save it.
local function setGroup(items)
  if groupName == nil or #items == 0 then
    return
  end
  local parts = {}
  for _, item in ipairs(items) do
    -- Ids and layouts are plain words, such as hangul and us, so they need no escaping.
    table.insert(parts, string.format("('%s', '%s')", item.id, item.layout))
  end
  local list = "[" .. table.concat(parts, ", ") .. "]"
  local call = { "gdbus", "call", "--session", "--dest", "org.fcitx.Fcitx5", "--object-path", "/controller", "--method" }
  local set = table.clone(call)
  table.insert(set, "org.fcitx.Fcitx.Controller1.SetInputMethodGroupInfo")
  table.insert(set, groupName)
  table.insert(set, groupLayout or "")
  table.insert(set, list)
  noctalia.runAsync(set, function()
    local save = table.clone(call)
    table.insert(save, "org.fcitx.Fcitx.Controller1.Save")
    noctalia.runAsync(save, function()
      wantCatalog = true
      refresh()
    end)
  end)
end

local function addInputMethod(id)
  local items = {}
  for _, item in ipairs(groupItems) do
    if item.id == id then
      return
    end
    table.insert(items, item)
  end
  table.insert(items, { id = id, layout = "" })
  setGroup(items)
end

local function removeInputMethod(id)
  local items = {}
  for _, item in ipairs(groupItems) do
    if item.id ~= id then
      table.insert(items, item)
    end
  end
  -- fcitx5 needs a group to start with a plain keyboard.
  if #items > 0 and #items < #groupItems then
    setGroup(items)
  end
end

-- The on-screen keyboard, on the focused monitor, at its place: anchored to the edges the
-- place names, MARGIN from each. It floats above the windows and never moves them, and keeps
-- clear of the bar.
local function configureOsk()
  local size = oskSize()
  local margins = {}
  for _, edge in ipairs(SPOT_ANCHORS[oskSpot]) do
    margins[edge] = MARGIN
  end
  noctalia.layer.configure(OSK, {
    anchors = SPOT_ANCHORS[oskSpot],
    width = size.width,
    height = size.height,
    margins = margins,
    exclusiveZone = 0,
    output = "focused",
  })
end

local function setOsk(open)
  oskOpen = open
  oskPicking = false
  if open then
    configureOsk()
    noctalia.layer.show(OSK)
  else
    noctalia.layer.hide(OSK)
  end
  build()
end

-- Shows the nine places instead of the keys, or the keys again.
local function pickSpot()
  if oskOpen then
    oskPicking = not oskPicking
    build()
  end
end

-- Puts the keyboard at one of the nine places, and remembers it.
local function placeOsk(spot)
  if SPOT_ANCHORS[spot] == nil then
    return
  end
  oskSpot = spot
  oskPicking = false
  noctalia.mkdirAll(dataDir)
  noctalia.writeFile(oskFile, noctalia.json.encode({ spot = spot }) or "")
  if oskOpen then
    configureOsk()
  end
  build()
end

local function installWtype()
  for _, installer in ipairs(WTYPE_INSTALLERS) do
    if noctalia.commandExists(installer.manager) then
      noctalia.runInTerminal(installer.command)
      return
    end
  end
end

-- Moves along the list by <step>, round.
local function cycle(step)
  local entries = model.entries
  if #entries == 0 then
    return
  end
  local at = 1
  for index, entry in ipairs(entries) do
    if entry.key == model.current then
      at = index
    end
  end
  choose(entries[(at - 1 + step) % #entries + 1].key)
end

noctalia.state.watch("keyboard.command", function(command)
  if type(command) ~= "table" then
    return
  end
  if command.action == "choose" and type(command.key) == "string" then
    choose(command.key)
  elseif command.action == "next" then
    cycle(1)
  elseif command.action == "previous" then
    cycle(-1)
  elseif command.action == "refresh" then
    refresh()
  elseif command.action == "osk" then
    if type(command.open) == "boolean" then
      setOsk(command.open)
    else
      setOsk(not oskOpen)
    end
  elseif command.action == "osk_move" then
    pickSpot()
  elseif command.action == "osk_place" and type(command.spot) == "string" then
    placeOsk(command.spot)
  elseif command.action == "install_wtype" then
    installWtype()
  elseif command.action == "open" then
    hasWtype = noctalia.commandExists("wtype")
    wantCatalog = true
    refresh()
  elseif command.action == "add_layout" and type(command.code) == "string" then
    addLayout(command.code)
  elseif command.action == "remove_layout" and type(command.index) == "number" then
    removeLayout(command.index)
  elseif command.action == "reset_layouts" then
    resetLayouts()
  elseif command.action == "add_im" and type(command.id) == "string" then
    addInputMethod(command.id)
  elseif command.action == "remove_im" and type(command.id) == "string" then
    removeInputMethod(command.id)
  end
end)

-- noctalia msg plugin omerfuyar/keyboard:service all next|previous
-- noctalia msg plugin omerfuyar/keyboard:service all set <short name, such as TR>
-- noctalia msg plugin omerfuyar/keyboard:service all add-layout|remove-layout <code, such as de>
-- noctalia msg plugin omerfuyar/keyboard:service all add-im|remove-im <fcitx5 id, such as mozc>
-- noctalia msg plugin omerfuyar/keyboard:service all reset-layouts
-- noctalia msg plugin omerfuyar/keyboard:service all osk|osk-move
-- noctalia msg plugin omerfuyar/keyboard:service all osk-place <place, such as top_left>
function onIpc(event, payload)
  local value = payload and noctalia.string.trim(payload) or ""
  if event == "add-layout" and value ~= "" then
    addLayout(value)
  elseif event == "remove-layout" then
    for index, layout in ipairs(currentLayouts()) do
      if layout.code == value then
        removeLayout(index - 1)
      end
    end
  elseif event == "osk" then
    setOsk(not oskOpen)
  elseif event == "osk-move" then
    if not oskOpen then
      setOsk(true)
    end
    pickSpot()
  elseif event == "osk-place" then
    placeOsk(value)
  elseif event == "reset-layouts" then
    resetLayouts()
  elseif event == "add-im" and value ~= "" then
    addInputMethod(value)
  elseif event == "remove-im" and value ~= "" then
    removeInputMethod(value)
  elseif event == "next" then
    cycle(1)
  elseif event == "previous" then
    cycle(-1)
  elseif event == "set" and payload then
    for _, entry in ipairs(model.entries) do
      if entry.short == upper(noctalia.string.trim(payload)) then
        choose(entry.key)
        return
      end
    end
  end
end

function update()
  local now = noctalia.nowMs()
  if now - lastPollMs >= POLL_MS then
    poll()
  end
  if lastRefreshMs == nil or now - lastRefreshMs >= REFRESH_MS then
    refresh()
    for _, key in ipairs(keys) do
      key:check()
    end
  end
  if keysDueMs and now >= keysDueMs then
    keysDueMs = nil
    for _, key in ipairs(keys) do
      key:check()
    end
  end
end

function onConfigChanged()
  keysDueMs = noctalia.nowMs() + KEYS_DELAY_MS
  if oskOpen then
    configureOsk()
  end
  build()
end

function onExit()
  for _, key in ipairs(keys) do
    key:release()
  end
end

noctalia.setUpdateInterval(250)
noctalia.readFileAsync(oskFile, function(text)
  local saved = text and noctalia.json.decode(text)
  if type(saved) == "table" and SPOT_ANCHORS[saved.spot] then
    oskSpot = saved.spot
  end
end)
noctalia.readFileAsync(layoutsFile, function(text)
  local saved = text and noctalia.json.decode(text)
  if type(saved) == "table" and type(saved.layouts) == "table" and #saved.layouts > 0 then
    stored = saved
  end
  poll()
end)
