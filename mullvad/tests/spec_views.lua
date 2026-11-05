-- View builders (view_connect, view_advanced) and the panel shell, on stubs.ui.
local parse = loadModule("parse.luau")
local relays = loadModule("relays.luau")

local previousUi = _G.ui
_G.ui = stubs.ui

local view_connect = loadModule("view_connect.luau")
local view_advanced = loadModule("view_advanced.luau")

local RELAYS = relays.forState(relays.parse(fixture("relay-list.txt")))
local ROMANIA = { country = "Romania", latitude = 44.4, longitude = 26.1 }

local function indexOfCountry(code)
  for i, c in ipairs(RELAYS) do
    if c.code == code then return i end
  end
  return nil
end

local function snapshot(statusFixture, over)
  local s = {
    daemon = "running",
    bootEnabled = true,
    busy = false,
    tunnel = parse.status(json.decode(fixture(statusFixture))),
    relays = RELAYS,
    realLocation = ROMANIA,
    requestSeq = 1,
  }
  for k, v in pairs(over or {}) do s[k] = v end
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

local function recorder()
  local sent = {}
  return sent, function(request) sent[#sent + 1] = request end
end

-- A snapshot whose daemon relay location (settings.relay.location) is `location`,
-- as `relay get` prints it.
local function withRelay(statusFixture, location, over, names)
  local s = snapshot(statusFixture, over)
  s.settings = { relay = parse.relayConstraints("    Location:               " .. location .. "\n", names) }
  return s
end

local function uiState(over)
  local u = { tab = "connect", mode = "country" }
  for k, v in pairs(over or {}) do u[k] = v end
  return u
end

-- connect / disconnect buttons follow the tunnel
local _, send = recorder()
local tree = view_connect.build(snapshot("status-disconnected.json"), uiState(), send)
check("view: disconnected shows connect.button", findKey(tree, "connect.button") ~= nil)
check("view: disconnected has no disconnect.button", findKey(tree, "disconnect.button") == nil)

tree = view_connect.build(snapshot("status-connected.json"), uiState(), send)
check("view: connected shows disconnect.button", findKey(tree, "disconnect.button") ~= nil)
check("view: connected has no connect.button", findKey(tree, "connect.button") == nil)

-- my country without a real location
local noLocation = snapshot("status-connected.json")
noLocation.realLocation = nil
tree = view_connect.build(noLocation, uiState({ mode = "my_country" }), send)
local myCountry = findKey(tree, "mode.my_country")
eq("view: my_country disabled without a real location", myCountry and myCountry.props.enabled, false)
check("view: my_country explains why", findText(tree, "connect.my_country_unknown") ~= nil)
local disconnected = snapshot("status-disconnected.json")
disconnected.realLocation = nil
tree = view_connect.build(disconnected, uiState({ mode = "my_country" }), send)
eq("view: my_country without a location cannot connect", findKey(tree, "connect.button").props.enabled, false)
tree = view_connect.build(snapshot("status-disconnected.json"), uiState({ mode = "my_country" }), send)
myCountry = findKey(tree, "mode.my_country")
check("view: my_country enabled with a real location", myCountry and myCountry.props.enabled ~= false)
check("view: no my_country warning with a real location", findText(tree, "connect.my_country_unknown") == nil)

-- city select: "any city" first, then the selected country's cities
local se = indexOfCountry("se")
tree = view_connect.build(withRelay("status-disconnected.json", "country ro"), uiState({ countryCode = "se" }), send)
local citySelect = findKey(tree, "city.select")
local options = citySelect and citySelect.props.options or {}
eq("view: city options start with any city", options[1], "connect.any_city")
eq("view: city options list the country's cities", #options, #RELAYS[se].cities + 1)
eq("view: second city option is the first city", options[2], RELAYS[se].cities[1].name)
eq("view: any city selected", citySelect and citySelect.props.selectedIndex, 0)
local countrySelect = findKey(tree, "country.select")
eq("view: country select is 0-based", countrySelect and countrySelect.props.selectedIndex, se - 1)
eq("view: country options are the relay countries", countrySelect and #countrySelect.props.options, #RELAYS)

-- pressing connect in country mode
local sent
sent, send = recorder()
tree = view_connect.build(snapshot("status-disconnected.json"), uiState({ countryCode = "se" }), send)
findKey(tree, "connect.button").props.onClick()
eq("view: connect sends one request", #sent, 1)
local r = sent[1] or {}
eq("view: connect action", r.action, "connect")
eq("view: connect mode", r.mode, "country")
eq("view: connect country", r.country, "se")
eq("view: any city sends city=nil", r.city, nil)

sent, send = recorder()
tree = view_connect.build(snapshot("status-disconnected.json"), uiState({ countryCode = "se", cityCode = RELAYS[se].cities[1].code }), send)
findKey(tree, "connect.button").props.onClick()
eq("view: a picked city is sent", sent[1] and sent[1].city, RELAYS[se].cities[1].code)

sent, send = recorder()
tree = view_connect.build(snapshot("status-disconnected.json"), uiState({ mode = "random" }), send)
check("view: random mode hides the country select", findKey(tree, "country.select") == nil)
findKey(tree, "connect.button").props.onClick()
eq("view: random connect", sent[1] and sent[1].mode, "random")

sent, send = recorder()
tree = view_connect.build(snapshot("status-disconnected.json"), uiState({ mode = "my_country" }), send)
findKey(tree, "connect.button").props.onClick()
eq("view: my_country connect", sent[1] and sent[1].mode, "my_country")

sent, send = recorder()
tree = view_connect.build(snapshot("status-connected.json"), uiState(), send)
findKey(tree, "disconnect.button").props.onClick()
eq("view: disconnect sends disconnect", sent[1] and sent[1].action, "disconnect")

-- busy disables connect
tree = view_connect.build(snapshot("status-disconnected.json", { busy = true }), uiState(), send)
eq("view: busy disables connect.button", findKey(tree, "connect.button").props.enabled, false)
tree = view_connect.build(snapshot("status-disconnected.json"), uiState(), send)
check("view: idle connect.button enabled", findKey(tree, "connect.button").props.enabled ~= false)

-- default country: the daemon's relay setting (R32), connected or not
tree = view_connect.build(withRelay("status-connected.json", "country se"), uiState(), send)
eq("view: default country is the relay setting while connected",
  findKey(tree, "country.select").props.selectedIndex, indexOfCountry("se") - 1)

-- mode buttons and selects report through setUi (codes, never indices), never send
local patches = {}
sent, send = recorder()
tree = view_connect.build(withRelay("status-disconnected.json", "country ro"), uiState(), send, function(p) patches[#patches + 1] = p end)
eq("view: active mode is boxed in primary", findKey(tree, "mode.box.country").props.border, "primary")
findKey(tree, "mode.random").props.onClick()
eq("view: mode button patches ui_state", patches[1] and patches[1].mode, "random")
findKey(tree, "country.select").props.onChange("3", "Austria")
eq("view: country select patches the country code", patches[2] and patches[2].countryCode, RELAYS[4].code)
eq("view: picking a country resets the city", patches[2] and patches[2].cityCode, false)
eq("view: ui changes send nothing", #sent, 0)

-- picking a city pins its country too
patches = {}
local ro = indexOfCountry("ro")
tree = view_connect.build(withRelay("status-disconnected.json", "country ro"), uiState(), send, function(p) patches[#patches + 1] = p end)
eq("view: default country follows the relay setting", findKey(tree, "country.select").props.selectedIndex, ro - 1)
findKey(tree, "city.select").props.onChange("1", "Bucharest")
eq("view: city pick patches the city code", patches[1] and patches[1].cityCode, RELAYS[ro].cities[1].code)
eq("view: city pick pins the country", patches[1] and patches[1].countryCode, "ro")
local pinned = uiState({ countryCode = patches[1].countryCode, cityCode = patches[1].cityCode })
tree = view_connect.build(withRelay("status-connected.json", "country se"), pinned, send)
eq("view: pinned country survives a tunnel country change", findKey(tree, "country.select").props.selectedIndex, ro - 1)
eq("view: pinned city survives a tunnel country change", findKey(tree, "city.select").props.selectedIndex, 1)
findKey(tree, "city.select").props.onChange("0", "Any city")
tree = view_connect.build(withRelay("status-disconnected.json", "country ro"), uiState(), send, function(p) patches[#patches + 1] = p end)
findKey(tree, "city.select").props.onChange("0", "Any city")
eq("view: any city patches cityCode=false", patches[#patches] and patches[#patches].cityCode, false)

-- a re-read relay list in another order keeps the selection (by code)
local reordered = {}
for i = #RELAYS, 1, -1 do reordered[#reordered + 1] = RELAYS[i] end
table.insert(reordered, 1, { code = "zz", name = "Atlantis", cities = { { code = "atl", name = "Atlantis City" } } })
local gotState = uiState({ countryCode = "se", cityCode = "got" })
tree = view_connect.build(snapshot("status-disconnected.json"), gotState, send)
local before = findKey(tree, "country.select").props
local beforeName = before.options[before.selectedIndex + 1]
tree = view_connect.build(snapshot("status-disconnected.json", { relays = reordered }), gotState, send)
local after = findKey(tree, "country.select").props
eq("view: reordered relays keep the country", after.options[after.selectedIndex + 1], beforeName)
check("view: reordered list really moved the index", after.selectedIndex ~= before.selectedIndex)
local cityAfter = findKey(tree, "city.select").props
eq("view: reordered relays keep the city", cityAfter.options[cityAfter.selectedIndex + 1], "Gothenburg")

-- connected: Reconnect for the current location, Switch for another
sent, send = recorder()
tree = view_connect.build(snapshot("status-connected.json"), uiState(), send)
check("view: connected shows reconnect.button", findKey(tree, "reconnect.button") ~= nil)
check("view: unchanged selection has no switch.button", findKey(tree, "switch.button") == nil)
findKey(tree, "reconnect.button").props.onClick()
eq("view: reconnect sends reconnect", sent[1] and sent[1].action, "reconnect")
eq("view: reconnect sends only the action", sent[1] and sent[1].country, nil)

sent, send = recorder()
tree = view_connect.build(snapshot("status-connected.json"), uiState({ countryCode = "se", cityCode = "sto" }), send)
check("view: picking the current city is still reconnect", findKey(tree, "reconnect.button") ~= nil)

sent, send = recorder()
tree = view_connect.build(snapshot("status-connected.json"), uiState({ countryCode = "se", cityCode = "got" }), send)
check("view: another city shows switch.button", findKey(tree, "switch.button") ~= nil)
check("view: another city has no reconnect.button", findKey(tree, "reconnect.button") == nil)
findKey(tree, "switch.button").props.onClick()
eq("view: switch sends connect", sent[1] and sent[1].action, "connect")
eq("view: switch sends the picked country", sent[1] and sent[1].country, "se")
eq("view: switch sends the picked city", sent[1] and sent[1].city, "got")

sent, send = recorder()
tree = view_connect.build(snapshot("status-connected.json"), uiState({ countryCode = "ro" }), send)
findKey(tree, "switch.button").props.onClick()
eq("view: another country switches", sent[1] and sent[1].country, "ro")

tree = view_connect.build(snapshot("status-connected.json"), uiState({ mode = "random" }), send)
check("view: random while connected is a switch", findKey(tree, "switch.button") ~= nil)
tree = view_connect.build(snapshot("status-connected.json", { busy = true }), uiState({ countryCode = "ro" }), send)
eq("view: busy disables switch", findKey(tree, "switch.button").props.enabled, false)

-- R7: no Connect / Switch while the tunnel is on its way up or down
local function inState(name, statusFixture, over)
  local s = withRelay(statusFixture or "status-disconnected.json", "country ro", over)
  s.tunnel = { state = name }
  return s
end
tree = view_connect.build(inState("disconnecting"), uiState(), send)
eq("view: connect disabled while disconnecting", findKey(tree, "connect.button") and findKey(tree, "connect.button").props.enabled, false)
tree = view_connect.build(inState("disconnecting"), uiState({ mode = "random" }), send)
eq("view: random connect disabled while disconnecting", findKey(tree, "connect.button") and findKey(tree, "connect.button").props.enabled, false)
tree = view_connect.build(inState("connecting"), uiState({ countryCode = "se" }), send)
eq("view: switch disabled while connecting", findKey(tree, "switch.button") and findKey(tree, "switch.button").props.enabled, false)
eq("view: disconnect stays enabled while connecting", findKey(tree, "disconnect.button").props.enabled ~= false, true)
tree = view_connect.build(snapshot("status-connected.json"), uiState({ countryCode = "ro" }), send)
eq("view: switch enabled once connected", findKey(tree, "switch.button").props.enabled ~= false, true)

-- no relays yet
tree = view_connect.build(snapshot("status-disconnected.json", { relays = {} }), uiState(), send)
eq("view: no relays disables connect", findKey(tree, "connect.button").props.enabled, false)
check("view: no relays says so", findText(tree, "error.no_relays") ~= nil)

-- toggles (Task 7): lockdown, multihop + entry, auto-connect, all from settings
local function settingsWith(over)
  local st = {
    relay = parse.relayConstraints(fixture("relay-get-disconnected.txt")),
    lockdown = false,
    autoConnect = false,
  }
  for k, v in pairs(over or {}) do st[k] = v end
  return st
end
local multihopOn = parse.relayConstraints(fixture("relay-get-multihop-on.txt"))

tree = view_connect.build(snapshot("status-disconnected.json"), uiState(), send)
check("toggles: hidden until settings are read", findKey(tree, "toggle.lockdown") == nil
  and findKey(tree, "toggle.multihop") == nil and findKey(tree, "toggle.auto_connect") == nil)

tree = view_connect.build(snapshot("status-disconnected.json", { settings = settingsWith() }), uiState(), send)
eq("toggles: lockdown off", findKey(tree, "toggle.lockdown") and findKey(tree, "toggle.lockdown").props.checked, false)
eq("toggles: multihop off", findKey(tree, "toggle.multihop") and findKey(tree, "toggle.multihop").props.checked, false)
eq("toggles: auto-connect off", findKey(tree, "toggle.auto_connect") and findKey(tree, "toggle.auto_connect").props.checked, false)
check("toggles: no entry selects with multihop off",
  findKey(tree, "entry.country.select") == nil and findKey(tree, "entry.city.select") == nil)

local onSettings = settingsWith({ relay = multihopOn, lockdown = true, autoConnect = true })
tree = view_connect.build(snapshot("status-disconnected.json", { settings = onSettings }), uiState(), send)
eq("toggles: lockdown on", findKey(tree, "toggle.lockdown").props.checked, true)
eq("toggles: multihop on", findKey(tree, "toggle.multihop").props.checked, true)
eq("toggles: auto-connect on", findKey(tree, "toggle.auto_connect").props.checked, true)
local entryCountry = findKey(tree, "entry.country.select")
check("toggles: entry selects with multihop on", entryCountry ~= nil and findKey(tree, "entry.city.select") ~= nil)
-- options: a leading "any country" option, then the relay countries
eq("toggles: entry country is the daemon's", entryCountry and entryCountry.props.selectedIndex, se)
eq("toggles: entry country options are any + the relay countries", entryCountry and #entryCountry.props.options, #RELAYS + 1)
eq("toggles: entry leading option is any country", entryCountry and entryCountry.props.options[1], "connect.entry_any_option")
eq("toggles: entry options then list the countries", entryCountry and entryCountry.props.options[se + 1], RELAYS[se].name)
local entryCity = findKey(tree, "entry.city.select")
eq("toggles: entry city options start with any city", entryCity and entryCity.props.options[1], "connect.any_city")
eq("toggles: entry country-wide is any city", entryCity and entryCity.props.selectedIndex, 0)

-- a toggle (or an entry pick) sends the opposite of what the daemon reports, and never patches ui_state
patches = {}
sent, send = recorder()
local setUiRecorder = function(p) patches[#patches + 1] = p end
tree = view_connect.build(snapshot("status-disconnected.json", { settings = settingsWith() }), uiState(), send, setUiRecorder)
findKey(tree, "toggle.lockdown").props.onChange(true)
findKey(tree, "toggle.multihop").props.onChange(true)
findKey(tree, "toggle.auto_connect").props.onChange(true)
eq("toggles: lockdown sends set_lockdown on", sent[1] and sent[1].action .. "=" .. tostring(sent[1].on), "set_lockdown=true")
eq("toggles: multihop sends set_multihop on", sent[2] and sent[2].action .. "=" .. tostring(sent[2].on), "set_multihop=true")
eq("toggles: auto-connect sends set_auto_connect on", sent[3] and sent[3].action .. "=" .. tostring(sent[3].on), "set_auto_connect=true")
sent, send = recorder()
tree = view_connect.build(snapshot("status-disconnected.json", { settings = onSettings }), uiState(), send, setUiRecorder)
findKey(tree, "toggle.lockdown").props.onChange(false)
eq("toggles: lockdown on sends off", sent[1] and sent[1].on, false)

-- entry picks send set_entry at once
findKey(tree, "entry.country.select").props.onChange(tostring(ro), "Romania")
eq("entry: country pick sends set_entry", sent[2] and sent[2].action, "set_entry")
eq("entry: country pick sends the code", sent[2] and sent[2].country, "ro")
eq("entry: country pick is country-wide", sent[2] and sent[2].city, nil)
findKey(tree, "entry.country.select").props.onChange("0", "Any country")
eq("entry: leading option sends set_entry any", sent[3] and sent[3].action .. ":" .. tostring(sent[3].country), "set_entry:any")
findKey(tree, "entry.city.select").props.onChange("1", RELAYS[se].cities[1].name)
eq("entry: city pick sends country and city", sent[4] and (sent[4].country .. " " .. tostring(sent[4].city)),
  "se " .. RELAYS[se].cities[1].code)
findKey(tree, "entry.city.select").props.onChange("0", "Any city")
eq("entry: any city sends country only", sent[5] and sent[5].country .. ":" .. tostring(sent[5].city), "se:nil")
eq("entry: picks never patch ui_state", #patches, 0)

-- the selects show only the daemon's entry; a stale ui_state pick is ignored
local function entrySettings(entryText, names)
  return settingsWith({ relay = parse.relayConstraints("    Location:               country ro\n"
    .. "    Multihop state:         enabled\n    Multihop entry:         " .. entryText .. "\n", names) })
end
local gotEntry = entrySettings("city got, se")
tree = view_connect.build(snapshot("status-disconnected.json", { settings = gotEntry }),
  uiState({ entryCountryCode = "ro", entryCityCode = false }), send)
eq("entry: daemon entry country shown", findKey(tree, "entry.country.select").props.selectedIndex, se)
local gotCity = findKey(tree, "entry.city.select").props
eq("entry: daemon entry city shown", gotCity.options[gotCity.selectedIndex + 1], "Gothenburg")

local anyEntry = entrySettings("any")
tree = view_connect.build(snapshot("status-disconnected.json", { settings = anyEntry }),
  uiState({ entryCountryCode = "ro" }), send)
local anyProps = findKey(tree, "entry.country.select").props
eq("entry: any entry selects the leading option", anyProps.selectedIndex, 0)
eq("entry: any entry's leading option says any", anyProps.options[1], "connect.entry_any_option")
check("entry: any entry shows no city select", findKey(tree, "entry.city.select") == nil)

local listEntry = entrySettings("my list", { "my list" })
tree = view_connect.build(snapshot("status-disconnected.json", { settings = listEntry }), uiState(), send)
local listProps = findKey(tree, "entry.country.select").props
eq("entry: custom list selects the leading option", listProps.selectedIndex, 0)
eq("entry: custom list label", listProps.options[1], "connect.entry_list_option")
check("entry: custom list shows no city select", findKey(tree, "entry.city.select") == nil)
sent, send = recorder()
tree = view_connect.build(snapshot("status-disconnected.json", { settings = listEntry }), uiState(), send)
findKey(tree, "entry.country.select").props.onChange("0", "Custom list: my list")
eq("entry: leading option under a custom list sends any", sent[1] and sent[1].country, "any")

local unknownEntry = entrySettings("region nordics", {})
tree = view_connect.build(snapshot("status-disconnected.json", { settings = unknownEntry }), uiState(), send)
local unknownProps = findKey(tree, "entry.country.select").props
eq("entry: unknown selects no country", unknownProps.selectedIndex, 0)
eq("entry: unknown label", unknownProps.options[1], "connect.entry_unknown_option")
check("entry: unknown says it cannot show it", findText(tree, "connect.entry_unknown") ~= nil)
check("entry: unknown shows no city select", findKey(tree, "entry.city.select") == nil)
local unlisted = entrySettings("country zz")
tree = view_connect.build(snapshot("status-disconnected.json", { settings = unlisted }), uiState(), send)
eq("entry: a country not in the list selects nothing", findKey(tree, "entry.country.select").props.selectedIndex, 0)
check("entry: an unlisted country says so", findText(tree, "connect.entry_unknown") ~= nil)

-- busy disables the toggles and entry selects
tree = view_connect.build(snapshot("status-disconnected.json", { busy = true, settings = onSettings }), uiState(), send)
eq("toggles: busy disables lockdown", findKey(tree, "toggle.lockdown").props.enabled, false)
eq("toggles: busy disables multihop", findKey(tree, "toggle.multihop").props.enabled, false)
eq("toggles: busy disables auto-connect", findKey(tree, "toggle.auto_connect").props.enabled, false)
eq("toggles: busy disables entry country", findKey(tree, "entry.country.select").props.enabled, false)
eq("toggles: busy disables entry city", findKey(tree, "entry.city.select").props.enabled, false)

-- selectionIsCurrent follows the relay constraint when it is known
local function constrained(location, names)
  local relay = parse.relayConstraints("    Location:               " .. location .. "\n", names)
  return snapshot("status-connected.json", { settings = settingsWith({ relay = relay }) })
end
local isCurrent = view_connect.selectionIsCurrent
eq("current: city constraint, same city pick", isCurrent(constrained("city got, se"), uiState({ countryCode = "se", cityCode = "got" })), true)
eq("current: city constraint, country-wide pick", isCurrent(constrained("city got, se"), uiState({ countryCode = "se", cityCode = false })), false)
eq("current: country constraint, city pick", isCurrent(constrained("country se"), uiState({ countryCode = "se", cityCode = "sto" })), false)
eq("current: country constraint, country pick", isCurrent(constrained("country se"), uiState({ countryCode = "se" })), true)
eq("current: country constraint, other country", isCurrent(constrained("country ro"), uiState({ countryCode = "se" })), false)
eq("current: no pick is always current", isCurrent(constrained("country ro"), uiState()), true)
eq("current: hostname constraint vs its city", isCurrent(constrained("city sto, se, hostname se-sto-wg-011"),
  uiState({ countryCode = "se", cityCode = "sto" })), false)
eq("current: custom list constraint vs a country", isCurrent(constrained("my list", { "my list" }), uiState({ countryCode = "se" })), false)
eq("current: unknown constraint vs a country", isCurrent(constrained("region nordics"), uiState({ countryCode = "se" })), false)
eq("current: unknown constraint, my_country", isCurrent(constrained("region nordics"), uiState({ mode = "my_country" })), false)
eq("current: my_country follows the constraint", isCurrent(constrained("country ro"), uiState({ mode = "my_country" })), true)
eq("current: my_country, other constraint", isCurrent(constrained("country se"), uiState({ mode = "my_country" })), false)
eq("current: tunnel fallback without settings", isCurrent(snapshot("status-connected.json"), uiState({ countryCode = "se", cityCode = "sto" })), true)
tree = view_connect.build(constrained("city got, se"), uiState({ countryCode = "se", cityCode = "got" }), send)
check("current: constraint match shows reconnect", findKey(tree, "reconnect.button") ~= nil)

-- R32: with no pick, Connect follows the daemon's relay setting and never
-- replaces it with another country (the tunnel's, the real location's).
local gotIndex = nil
for i, ci in ipairs(RELAYS[se].cities) do
  if ci.code == "got" then gotIndex = i end
end
sent, send = recorder()
tree = view_connect.build(withRelay("status-disconnected.json", "city got, se"), uiState(), send)
local cs = findKey(tree, "country.select").props
eq("setting: city setting selects its country", cs.selectedIndex, se - 1)
eq("setting: a listed setting adds no leading option", #cs.options, #RELAYS)
eq("setting: city setting selects its city", findKey(tree, "city.select").props.selectedIndex, gotIndex)
findKey(tree, "connect.button").props.onClick()
eq("setting: connect sends the setting's country", sent[1] and sent[1].country, "se")
eq("setting: connect sends the setting's city", sent[1] and sent[1].city, "got")
eq("setting: connect in country mode", sent[1] and sent[1].mode, "country")

sent, send = recorder()
tree = view_connect.build(withRelay("status-disconnected.json", "country se"), uiState(), send)
findKey(tree, "connect.button").props.onClick()
eq("setting: country setting sends that country", sent[1] and sent[1].country, "se")
eq("setting: country setting sends any city", sent[1] and sent[1].city, nil)

local function leadCase(name, location, names, wantLead)
  local prev = _G.noctalia
  _G.noctalia = { tr = function(key, subst) return key .. (subst and subst.name and ("{" .. subst.name .. "}") or "") end }
  local sentHere, sendHere = recorder()
  local t = view_connect.build(withRelay("status-disconnected.json", location, nil, names), uiState(), sendHere)
  _G.noctalia = prev
  local props = findKey(t, "country.select").props
  eq("setting: " .. name .. " leads with the current setting", props.options[1], wantLead)
  eq("setting: " .. name .. " lists every country after it", #props.options, #RELAYS + 1)
  eq("setting: " .. name .. " selects the current setting", props.selectedIndex, 0)
  eq("setting: " .. name .. " has no city to pick", findKey(t, "city.select").props.enabled, false)
  findKey(t, "connect.button").props.onClick()
  eq("setting: " .. name .. " connects under the current setting", sentHere[1] and sentHere[1].mode, "current")
  eq("setting: " .. name .. " sends no location", sentHere[1] and (sentHere[1].country or sentHere[1].city), nil)
end
leadCase("any", "any", nil, "connect.current_setting_named{connect.entry_any_option}")
leadCase("a custom list", "my list", { "my list" }, "connect.current_setting_named{my list}")
leadCase("a hostname", "city sto, se, hostname se-sto-wg-011", nil, "connect.current_setting_named{se-sto-wg-011}")
leadCase("an unknown setting", "region nordics", nil, "connect.current_setting_named{region nordics}")
leadCase("an unlisted country", "country xx", nil, "connect.current_setting_named{xx}")

sent, send = recorder()
tree = view_connect.build(snapshot("status-disconnected.json"), uiState(), send)
eq("setting: unread settings lead with the plain current setting", findKey(tree, "country.select").props.options[1], "connect.current_setting")
findKey(tree, "connect.button").props.onClick()
eq("setting: unread settings connect under the current setting", sent[1] and sent[1].mode, "current")

-- the leading option shifts the countries by one; picking it goes back to the setting
patches = {}
tree = view_connect.build(withRelay("status-disconnected.json", "any"), uiState(), send, function(p) patches[#patches + 1] = p end)
findKey(tree, "country.select").props.onChange("1", RELAYS[1].name)
eq("setting: after the lead, option 1 is the first country", patches[1] and patches[1].countryCode, RELAYS[1].code)
findKey(tree, "country.select").props.onChange("0", "connect.current_setting")
eq("setting: picking the lead drops the country pick", patches[2] and patches[2].countryCode, false)
eq("setting: picking the lead drops the city pick", patches[2] and patches[2].cityCode, false)
tree = view_connect.build(withRelay("status-disconnected.json", "any"), uiState({ countryCode = "se" }), send)
eq("setting: a pick under the lead selects that country", findKey(tree, "country.select").props.selectedIndex, se)
sent, send = recorder()
tree = view_connect.build(withRelay("status-disconnected.json", "any"), uiState({ countryCode = false, cityCode = false }), send)
eq("setting: lead picked again is selected", findKey(tree, "country.select").props.selectedIndex, 0)
findKey(tree, "connect.button").props.onClick()
eq("setting: lead picked again connects under the setting", sent[1] and sent[1].mode, "current")

-- connected: unchanged, no pick is Reconnect whatever the setting
sent, send = recorder()
tree = view_connect.build(withRelay("status-connected.json", "any"), uiState(), send)
check("setting: connected with any setting shows reconnect", findKey(tree, "reconnect.button") ~= nil)
findKey(tree, "reconnect.button").props.onClick()
eq("setting: connected with any setting reconnects", sent[1] and sent[1].action, "reconnect")
tree = view_connect.build(withRelay("status-connected.json", "any"), uiState({ countryCode = false, cityCode = false }), send)
check("setting: connected, lead picked is still reconnect", findKey(tree, "reconnect.button") ~= nil)

-- advanced (v1)
sent, send = recorder()
tree = view_advanced.build(snapshot("status-disconnected.json"), uiState({ tab = "advanced" }), send, true)
check("advanced: explains settings live in the app", findText(tree, "advanced.in_app") ~= nil)
local openApp = findKey(tree, "advanced.open_app")
check("advanced: open app button with the app", openApp ~= nil)
openApp.props.onClick()
eq("advanced: open app sends open_app", sent[1] and sent[1].action, "open_app")
tree = view_advanced.build(snapshot("status-disconnected.json"), uiState({ tab = "advanced" }), send, false)
check("advanced: no open app button without the app", findKey(tree, "advanced.open_app") == nil)
check("advanced: still explains without the app", findText(tree, "advanced.in_app") ~= nil)

-- account tab (Task 13) and the shared confirm row
local view_account = loadModule("view_account.luau")
local view_common = loadModule("view_common.luau")
local SIXTEEN_DIGITS = string.rep("%d", 16)
local LOGGED_IN = {
  loggedIn = true, masked = "•••• •••• •••• 0000", expiresAt = "2030-01-01 00:00:00 +00:00", expiry = "ok",
  deviceName = "Test Device", devices = { "Test Device", "Other Device 1" },
}
local function keyTr(key) return key end
local function withAccount(account, over)
  local s = snapshot("status-disconnected.json", over)
  s.account = account
  return s
end
local function anyStringMatches(tree, pattern)
  if type(tree) ~= "table" then return false end
  for _, v in pairs(tree.props or {}) do
    if type(v) == "string" and v:find(pattern) then return true end
  end
  for _, child in ipairs(tree.children or {}) do
    if anyStringMatches(child, pattern) then return true end
  end
  return false
end

local yes, no = 0, 0
eq("confirmRow: nothing unless that action is being confirmed",
  view_common.confirmRow(keyTr, { confirm = "revoke.x" }, "logout", function() end, function() end), nil)
local row = view_common.confirmRow(keyTr, { confirm = "logout" }, "logout",
  function() yes = yes + 1 end, function() no = no + 1 end)
check("confirmRow: asks", row ~= nil and findText(row, "confirm.prompt") ~= nil)
findKey(row, "confirm.yes").props.onClick()
eq("confirmRow: yes runs onYes", yes, 1)
findKey(row, "confirm.no").props.onClick()
eq("confirmRow: no runs onNo", no, 1)
eq("confirmRow: yes is destructive", findKey(row, "confirm.yes").props.variant, "destructive")

eq("confirmRow: no is ghost", findKey(row, "confirm.no").props.variant, "ghost")

-- three button types: the main action is the only primary-filled button in the Connect body
local function countPrimary(node)
  if type(node) ~= "table" then return 0 end
  local n = (node.props and node.props.variant == "primary") and 1 or 0
  for _, c in ipairs(node.children or {}) do n = n + countPrimary(c) end
  return n
end
do
  local _, s2 = recorder()
  local t = view_connect.build(snapshot("status-disconnected.json"), uiState(), s2)
  local b = findKey(t, "connect.button").props
  eq("main: connect is primary", b.variant, "primary")
  eq("main: connect is large", b.controlSize, "lg")
  eq("main: connect glyph", b.glyph, "shield-check")
  eq("main: one primary when disconnected", countPrimary(t), 1)
  t = view_connect.build(snapshot("status-connected.json"), uiState(), s2)
  b = findKey(t, "reconnect.button").props
  eq("main: reconnect is primary", b.variant, "primary")
  eq("main: reconnect is large", b.controlSize, "lg")
  eq("main: reconnect glyph", b.glyph, "shield-check")
  eq("main: disconnect is destructive", findKey(t, "disconnect.button").props.variant, "destructive")
  eq("main: one primary when connected, unchanged", countPrimary(t), 1)
  t = view_connect.build(snapshot("status-connected.json"), uiState({ mode = "random" }), s2)
  b = findKey(t, "switch.button").props
  eq("main: switch is primary", b.variant, "primary")
  eq("main: switch is large", b.controlSize, "lg")
  eq("main: switch glyph", b.glyph, "shield-check")
  eq("main: one primary when connected, changed", countPrimary(t), 1)
end

-- logged out: only the login form
local patches = {}
local function setUi(p) patches[#patches + 1] = p end
sent, send = recorder()
tree = view_account.build(withAccount({ loggedIn = false }), uiState({ tab = "account" }), send, setUi)
local input = findKey(tree, "account.input")
check("account: logged out shows account.input", input ~= nil)
eq("account: the input is a password field", input and input.props.password, true)
eq("account: the input has no value prop", input and input.props.value, nil)
check("account: logged out shows account.login", findKey(tree, "account.login") ~= nil)
for _, key in ipairs({ "account.logout", "account.expiry", "voucher.input", "voucher.redeem", "device.Test Device.revoke" }) do
  check("account: logged out has no " .. key, findKey(tree, key) == nil)
end
eq("account: login disabled while the field is empty", findKey(tree, "account.login").props.enabled, false)
input.props.onChange("1234")
eq("account: typing patches ui_state", patches[1] and patches[1].accountInput, "1234")

tree = view_account.build(withAccount({ loggedIn = false }), uiState({ accountInput = "1234" }), send, setUi)
eq("account: login disabled for a bad number", findKey(tree, "account.login").props.enabled, false)
check("account: a bad number explains itself", findText(tree, "error.invalid_account") ~= nil)

patches = {}
tree = view_account.build(withAccount({ loggedIn = false }), uiState({ accountInput = "1234 5678-9012 3456", loginSeq = 4 }), send, setUi)
check("account: the form is keyed by loginSeq", findKey(tree, "account.form.4") ~= nil)
check("account: the typed number is never rendered", not anyStringMatches(tree, SIXTEEN_DIGITS))
eq("account: login enabled for 16 digits", findKey(tree, "account.login").props.enabled, true)
findKey(tree, "account.login").props.onClick()
eq("account: login sends login", sent[1] and sent[1].action, "login")
eq("account: login sends the normalised number", sent[1] and sent[1].number, "1234567890123456")
eq("account: login clears the input from ui_state", patches[1] and patches[1].accountInput, false)
eq("account: login re-keys the form (clears the field)", patches[1] and patches[1].loginSeq, 5)
sent, send = recorder()
tree = view_account.build(withAccount({ loggedIn = false }), uiState(), send, setUi)
findKey(tree, "account.input").props.onSubmit("1234567890123456")
eq("account: Enter in the field logs in", sent[1] and sent[1].number, "1234567890123456")
sent, send = recorder()
tree = view_account.build(withAccount({ loggedIn = false }), uiState(), send, setUi)
findKey(tree, "account.input").props.onSubmit("12")
eq("account: Enter with a bad number sends nothing", #sent, 0)
tree = view_account.build(withAccount({ loggedIn = false }, { busy = true }), uiState({ accountInput = "1234567890123456" }), send, setUi)
eq("account: login disabled while busy", findKey(tree, "account.login").props.enabled, false)

tree = view_account.build(withAccount(nil), uiState(), send, setUi)
check("account: before the first read shows loading", findKey(tree, "account.loading") ~= nil)
check("account: no retry while the first read runs", findKey(tree, "account.retry") == nil)
-- R8: a failed read with nothing to show says so and offers a retry
sent, send = recorder()
tree = view_account.build(withAccount(nil, { accountReadFailed = true }), uiState(), send, setUi)
check("account: a failed read stops showing loading", findKey(tree, "account.loading") == nil)
check("account: a failed read says so", findText(tree, "account.read_failed") ~= nil)
local retry = findKey(tree, "account.retry")
check("account: a failed read offers retry", retry ~= nil)
if retry then retry.props.onClick() end
eq("account: retry sends refresh", sent[1] and sent[1].action, "refresh")
tree = view_account.build(withAccount(LOGGED_IN, { accountReadFailed = true }), uiState(), send, setUi)
check("account: a failed re-read keeps showing the last account", findKey(tree, "account.number") ~= nil and findKey(tree, "account.retry") == nil)
check("account: no form before the first read", findKey(tree, "account.input") == nil)

-- logged in: expiry, devices, voucher, logout
local previousNoctalia = _G.noctalia
_G.noctalia = { tr = function(key, subst)
  if subst == nil then return key end
  local parts = {}
  for k, v in pairs(subst) do parts[#parts + 1] = k .. "=" .. tostring(v) end
  table.sort(parts)
  return key .. "{" .. table.concat(parts, ",") .. "}"
end }
sent, send = recorder()
patches = {}
tree = view_account.build(withAccount(LOGGED_IN), uiState(), send, setUi)
check("account: logged in has no account.input", findKey(tree, "account.input") == nil)
check("account: logged in has no account.login", findKey(tree, "account.login") == nil)
eq("account: masked number shown", findKey(tree, "account.number") and findKey(tree, "account.number").props.text,
  "account.number{number=•••• •••• •••• 0000}")
local expiry = findKey(tree, "account.expiry")
eq("account: expiry shows the date", expiry and expiry.props.text, "account.expires{date=2030-01-01}")
check("account: ok expiry is not a warning", expiry and expiry.props.color ~= "error" and expiry.props.color ~= "primary")
check("account: this device named", findText(tree, "account.this_device{name=Test Device}") ~= nil)
check("account: other device has a revoke button", findKey(tree, "device.Other Device 1.revoke") ~= nil)
check("account: the current device has no revoke button", findKey(tree, "device.Test Device.revoke") == nil)
check("account: the current device is listed", findKey(tree, "device.Test Device") ~= nil)
check("account: logout shown", findKey(tree, "account.logout") ~= nil)
check("account: voucher input shown", findKey(tree, "voucher.input") ~= nil)
check("account: voucher redeem shown", findKey(tree, "voucher.redeem") ~= nil)
eq("account: redeem disabled while empty", findKey(tree, "voucher.redeem").props.enabled, false)

tree = view_account.build(withAccount(LOGGED_IN), uiState(), send, setUi)
local warnAccount = {}
for k, v in pairs(LOGGED_IN) do warnAccount[k] = v end
warnAccount.expiry = "warn"
eq("account: under 7 days is the warning colour",
  findKey(view_account.build(withAccount(warnAccount), uiState(), send, setUi), "account.expiry").props.color, "primary")
warnAccount.expiry = "expired"
local expiredAccount = warnAccount
local expiredTree = view_account.build(withAccount(warnAccount), uiState(), send, setUi)
eq("account: expired is the error colour", findKey(expiredTree, "account.expiry").props.color, "error")
eq("account: expired says so", findKey(expiredTree, "account.expiry").props.text, "account.expired_on{date=2030-01-01}")

-- logout and revoke ask first (view_common.confirmRow)
findKey(tree, "account.logout").props.onClick()
eq("account: logout asks first", patches[#patches] and patches[#patches].confirm, "logout")
eq("account: logout sends nothing yet", #sent, 0)
tree = view_account.build(withAccount(LOGGED_IN), uiState({ confirm = "logout" }), send, setUi)
check("account: confirming hides the logout button", findKey(tree, "account.logout") == nil)
eq("account: logout confirm yes is destructive", findKey(tree, "confirm.yes").props.variant, "destructive")
findKey(tree, "confirm.yes").props.onClick()
eq("account: confirmed logout sends logout", sent[1] and sent[1].action, "logout")
eq("account: confirmed logout closes the question", patches[#patches] and patches[#patches].confirm, false)
tree = view_account.build(withAccount(LOGGED_IN), uiState({ confirm = "logout" }), send, setUi)
findKey(tree, "confirm.no").props.onClick()
eq("account: cancel closes the question", patches[#patches] and patches[#patches].confirm, false)
eq("account: cancel sends nothing", #sent, 1)

sent, send = recorder()
tree = view_account.build(withAccount(LOGGED_IN), uiState(), send, setUi)
findKey(tree, "device.Other Device 1.revoke").props.onClick()
eq("account: revoke asks first", patches[#patches] and patches[#patches].confirm, "revoke.Other Device 1")
eq("account: revoke sends nothing yet", #sent, 0)
tree = view_account.build(withAccount(LOGGED_IN), uiState({ confirm = "revoke.Other Device 1" }), send, setUi)
check("account: confirming hides that revoke button", findKey(tree, "device.Other Device 1.revoke") == nil)
check("account: logout stays while a revoke is asked", findKey(tree, "account.logout") ~= nil)
eq("account: revoke confirm yes is destructive", findKey(tree, "confirm.yes").props.variant, "destructive")
findKey(tree, "confirm.yes").props.onClick()
eq("account: confirmed revoke sends revoke_device", sent[1] and sent[1].action, "revoke_device")
eq("account: confirmed revoke names the device", sent[1] and sent[1].name, "Other Device 1")

-- voucher
sent, send = recorder()
patches = {}
tree = view_account.build(withAccount(LOGGED_IN), uiState({ voucherInput = "ABCD-1234", voucherSeq = 2 }), send, setUi)
check("account: the voucher form is keyed by voucherSeq", findKey(tree, "voucher.form.2") ~= nil)
eq("account: redeem enabled with a code", findKey(tree, "voucher.redeem").props.enabled, true)
findKey(tree, "voucher.redeem").props.onClick()
eq("account: redeem sends the code", sent[1] and sent[1].voucher, "ABCD1234")
eq("account: redeem clears the field", patches[1] and patches[1].voucherSeq, 3)
findKey(tree, "voucher.input").props.onChange("XY")
eq("account: voucher typing patches ui_state", patches[#patches] and patches[#patches].voucherInput, "XY")
tree = view_account.build(withAccount(LOGGED_IN, { busy = true }), uiState({ voucherInput = "ABCD" }), send, setUi)
eq("account: redeem disabled while busy", findKey(tree, "voucher.redeem").props.enabled, false)
eq("account: logout disabled while busy", findKey(tree, "account.logout").props.enabled, false)
eq("account: revoke disabled while busy", findKey(tree, "device.Other Device 1.revoke").props.enabled, false)
-- fix round 1: Yes is disabled while busy; the account page button
row = view_common.confirmRow(keyTr, { confirm = "logout" }, "logout", function() end, function() end, true)
eq("confirmRow: yes disabled while busy", findKey(row, "confirm.yes").props.enabled, false)
eq("confirmRow: cancel stays enabled while busy", findKey(row, "confirm.no").props.enabled ~= false, true)
row = view_common.confirmRow(keyTr, { confirm = "logout" }, "logout", function() end, function() end)
eq("confirmRow: yes enabled when not busy", findKey(row, "confirm.yes").props.enabled ~= false, true)
tree = view_account.build(withAccount(LOGGED_IN, { busy = true }), uiState({ confirm = "logout" }), send, setUi)
eq("account: confirm yes disabled while busy", findKey(tree, "confirm.yes").props.enabled, false)

sent, send = recorder()
tree = view_account.build(withAccount(LOGGED_IN), uiState(), send, setUi)
local openPage = findKey(tree, "account.open_page")
check("account: logged in offers the account page", openPage ~= nil)
if openPage then openPage.props.onClick() end
eq("account: account page sends open_account_page", sent[1] and sent[1].action, "open_account_page")
check("account: expired offers the account page",
  findKey(view_account.build(withAccount(expiredAccount), uiState(), send, setUi), "account.open_page") ~= nil)
check("account: logged out has no account page button",
  findKey(view_account.build(withAccount({ loggedIn = false }), uiState(), send, setUi), "account.open_page") == nil)
check("account: too many devices offers the account page", findKey(view_account.build(
  withAccount({ loggedIn = false }, { lastError = { key = "error.too_many_devices" } }), uiState(), send, setUi),
  "account.open_page") ~= nil)

_G.noctalia = previousNoctalia

-- mode selector: unfilled segmented buttons, active one boxed in primary, with a label
do
  local t = view_connect.build(snapshot("status-disconnected.json"), uiState(), send)
  for _, id in ipairs({ "country", "my_country", "random" }) do
    local variant = findKey(t, "mode." .. id).props.variant
    check("mode: " .. id .. " is not the filled variant", variant ~= "primary" and variant ~= "default" and variant ~= "secondary")
  end
  check("mode: no button is selected (selected paints a fill)", findKey(t, "mode.country").props.selected == nil)
  eq("mode: inactive is ghost", findKey(t, "mode.random").props.variant, "ghost")
  eq("mode: active box has a primary border", findKey(t, "mode.box.country").props.border, "primary")
  eq("mode: inactive box has no border", findKey(t, "mode.box.random").props.border, nil)
  eq("mode: label above the row", findKey(t, "mode.label") and findKey(t, "mode.label").props.text, "connect.mode_label")
end

-- hint texts carry the flag (show_flags)
do
  local prev = _G.noctalia
  _G.noctalia = { tr = function(key, subst) return key .. "{" .. tostring(subst and subst.country) .. "}" end }
  local mc = uiState({ mode = "my_country" })
  local on = view_connect.build(snapshot("status-disconnected.json"), mc, send, nil, true)
  local off = view_connect.build(snapshot("status-disconnected.json"), mc, send, nil, false)
  check("hint: my-country hint has the flag", findText(on, "connect.my_country_hint{🇷🇴 Romania}") ~= nil)
  check("hint: flag off leaves the plain name", findText(off, "connect.my_country_hint{Romania}") ~= nil)
  _G.noctalia = prev
end

-- country flags in the selects (view_connect takes showFlags)
local FLAG_SE = "🇸🇪"
do
  local flagged = view_connect.build(snapshot("status-disconnected.json",
    { settings = settingsWith({ relay = multihopOn }) }), uiState(), send, nil, true)
  local plain = view_connect.build(snapshot("status-disconnected.json",
    { settings = settingsWith({ relay = multihopOn }) }), uiState(), send, nil, false)
  local fo = findKey(flagged, "country.select").props.options
  local po = findKey(plain, "country.select").props.options
  eq("flags: country option starts with the flag", fo[se], FLAG_SE .. " " .. RELAYS[se].name)
  eq("flags: off leaves the plain name", po[se], RELAYS[se].name)
  local fe = findKey(flagged, "entry.country.select").props.options
  local pe = findKey(plain, "entry.country.select").props.options
  eq("flags: entry country option starts with the flag", fe[se + 1], FLAG_SE .. " " .. RELAYS[se].name)
  eq("flags: entry leading option has no flag", fe[1], "connect.entry_any_option")
  eq("flags: entry off leaves the plain name", pe[se + 1], RELAYS[se].name)
end

-- panel shell
local current
local rendered
local closed
local wantsTicks
local function bootPanel(state, setup)
  if current then current.uninstall() end
  local fake = stubs.newNoctalia()
  if setup then setup(fake) end
  fake.state["mullvad.state"] = state
  fake.install()
  rendered = nil
  closed = false
  wantsTicks = nil
  _G.panel = {
    render = function(t) rendered = t end,
    close = function() closed = true end,
    setWantsSecondTicks = function(on) wantsTicks = on end,
  }
  loadFresh("panel.luau")
  current = fake
  onOpen({})
  return fake
end

-- Every send is a state.set; the stub keeps only the last value, so watch it.
local function watchRequests(fake)
  local out = {}
  fake.noctalia.state.watch("mullvad.request", function(v) out[#out + 1] = v end)
  return out
end

local fake = bootPanel(snapshot("status-disconnected.json"))
eq("panel: opening asks for a refresh", fake.state["mullvad.request"] and fake.state["mullvad.request"].action, "refresh")
check("panel: renders a header", findKey(rendered, "header") ~= nil)
for _, id in ipairs({ "connect", "advanced", "account" }) do
  check("panel: tab." .. id .. " exists", findKey(rendered, "tab." .. id) ~= nil)
end
eq("panel: connect tab active by default", findKey(rendered, "tab.connect").props.variant, "secondary")
check("panel: active tab is not host-selected (that paints it primary)", findKey(rendered, "tab.connect").props.selected ~= true)
eq("panel: inactive tab is ghost", findKey(rendered, "tab.advanced").props.variant, "ghost")
check("panel: connect tab body shown", findKey(rendered, "connect.button") ~= nil)
check("panel: tab row sits in a bordered container", findKey(rendered, "tabs") ~= nil and findKey(rendered, "tabs").props.border ~= nil)
eq("panel: tab container border is a live colour role", findKey(rendered, "tabs").props.border, "outline_variant")
for id, glyph in pairs({ connect = "plug-connected", advanced = "adjustments", account = "user-circle" }) do
  eq("panel: tab." .. id .. " carries its glyph", findKey(rendered, "tab." .. id).props.glyph, glyph)
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
local scroller = findType(rendered, "scroll")
eq("panel: the tab body scrolls and grows to the cap", scroller and scroller.props.flexGrow, 1)

local got = watchRequests(fake)
findKey(rendered, "connect.button").props.onClick()
eq("panel: connect button sends mullvad.request", got[1] and got[1].action, "connect")

findKey(rendered, "mode.random").props.onClick()
eq("panel: mode change re-renders", findKey(rendered, "mode.box.random").props.border, "primary")
check("panel: random mode hides the country select", findKey(rendered, "country.select") == nil)

findKey(rendered, "tab.advanced").props.onClick()
eq("panel: advanced tab active", findKey(rendered, "tab.advanced").props.variant, "secondary")
check("panel: advanced body shown", findText(rendered, "advanced.in_app") ~= nil)
check("panel: connect body hidden on advanced", findKey(rendered, "connect.button") == nil)
check("panel: no open-app button when mullvad-vpn is missing", findKey(rendered, "advanced.open_app") == nil)

findKey(rendered, "tab.account").props.onClick()
check("panel: account tab shows view_account", findKey(rendered, "account.tab") ~= nil)

fake = bootPanel(snapshot("status-disconnected.json"), function(f)
  f.noctalia.commandExists = function(name) return name == "mullvad-vpn" end
end)
findKey(rendered, "tab.advanced").props.onClick()
check("panel: open-app button when mullvad-vpn exists", findKey(rendered, "advanced.open_app") ~= nil)

-- daemon down: the header replaces the body, its button sends start_service
fake = bootPanel({ daemon = "down", busy = false, relays = {}, requestSeq = 1 })
check("panel: daemon down hides the tabs", findKey(rendered, "tab.connect") == nil)
check("panel: daemon down hides the body", findKey(rendered, "connect.button") == nil)
local startButton = findKey(rendered, "header.start_service")
check("panel: daemon down offers start service", startButton ~= nil)
got = watchRequests(fake)
if startButton then startButton.props.onClick() end
eq("panel: start service sends start_service", got[1] and got[1].action, "start_service")

-- boot disabled: enable_service in the header
fake = bootPanel(snapshot("status-disconnected.json", { bootEnabled = false }))
got = watchRequests(fake)
local enable = findKey(rendered, "header.enable_service")
check("panel: boot disabled offers start at boot", enable ~= nil)
if enable then enable.props.onClick() end
eq("panel: enable sends enable_service", got[1] and got[1].action, "enable_service")

-- open_account_tab is local: it switches the tab
fake = bootPanel(snapshot("status-disconnected.json", { account = { loggedIn = false } }))
got = watchRequests(fake)
local toAccount = findKey(rendered, "header.open_account_tab")
check("panel: logged out offers the account tab", toAccount ~= nil)
if toAccount then toAccount.props.onClick() end
eq("panel: open_account_tab switches tab", findKey(rendered, "tab.account").props.variant, "secondary")
eq("panel: open_account_tab sends nothing", #got, 0)

-- header connect (lockdown blocking) follows the same rule as connect.button
local blocked = snapshot("synthetic-status-blocked-lockdown.json")
fake = bootPanel(blocked)
got = watchRequests(fake)
local headerConnect = findKey(rendered, "header.connect")
check("panel: lockdown blocking offers connect", headerConnect ~= nil)
check("panel: header connect enabled with a selection", headerConnect and headerConnect.props.enabled ~= false)
if headerConnect then headerConnect.props.onClick() end
eq("panel: header connect sends the selection", got[1] and got[1].action, "connect")
eq("panel: header connect without settings keeps the daemon's setting", got[1] and got[1].mode, "current")
eq("panel: header connect never sets the real location's country", got[1] and got[1].country, nil)
fake = bootPanel(withRelay("synthetic-status-blocked-lockdown.json", "city got, se"))
got = watchRequests(fake)
findKey(rendered, "header.connect").props.onClick()
eq("panel: header connect follows the relay setting's country", got[1] and got[1].country, "se")
eq("panel: header connect follows the relay setting's city", got[1] and got[1].city, "got")
local blockedNoLocation = snapshot("synthetic-status-blocked-lockdown.json")
blockedNoLocation.realLocation = nil
fake = bootPanel(blockedNoLocation)
findKey(rendered, "mode.my_country").props.onClick()
headerConnect = findKey(rendered, "header.connect")
eq("panel: header connect disabled in my_country without a location", headerConnect and headerConnect.props.enabled, false)
eq("panel: connect.button disabled the same way", findKey(rendered, "connect.button").props.enabled, false)

-- header: the visible location while not connected, only when the daemon reports one
local function substituting(f)
  f.noctalia.tr = function(key, subst)
    if subst == nil then return key end
    local parts = {}
    for k, v in pairs(subst) do parts[#parts + 1] = k .. "=" .. tostring(v) end
    table.sort(parts)
    return key .. "{" .. table.concat(parts, ",") .. "}"
  end
end
fake = bootPanel(snapshot("status-disconnected.json"), substituting)
local where = findKey(rendered, "header.location")
check("panel: disconnected header shows the visible location", where ~= nil)
eq("panel: visible location names city and country", where and where.props.text,
  "header.visible_location{location=header.place_flag{city=Testville,country=🇷🇴 Romania}}")
fake = bootPanel(snapshot("status-disconnected.json"), function(f) substituting(f); f.config.show_flags = false end)
eq("panel: show_flags off drops the flag from the location", findKey(rendered, "header.location").props.text,
  "header.visible_location{location=header.place{city=Testville,country=Romania}}")
fake = bootPanel(snapshot("status-disconnected-nolocation.json"), substituting)
check("panel: no location reported, none shown", findKey(rendered, "header.location") == nil)
local function hasTextPrefix(node, prefix)
  if type(node) ~= "table" then return false end
  local text = node.props and node.props.text
  if type(text) == "string" and text:sub(1, #prefix) == prefix then return true end
  for _, child in ipairs(node.children or {}) do
    if hasTextPrefix(child, prefix) then return true end
  end
  return false
end
check("panel: no location still shows the state", hasTextPrefix(findKey(rendered, "header"), "header.disconnected{"))
fake = bootPanel(snapshot("status-connected.json"), substituting)
check("panel: connected header does not repeat the location", findKey(rendered, "header.location") == nil)

-- lastError notice, dismissable
fake = bootPanel(snapshot("status-disconnected.json", { lastError = { key = "error.busy" } }))
local notice = findKey(rendered, "error.notice")
check("panel: lastError shows a notice", notice ~= nil)
check("panel: notice shows the error text", notice and findText(notice, "error.busy") ~= nil)
findKey(rendered, "error.dismiss").props.onClick()
check("panel: dismissed notice is gone", findKey(rendered, "error.notice") == nil)
fake.noctalia.state.set("mullvad.state", snapshot("status-disconnected.json", { lastError = { key = "error.busy" }, requestSeq = 2 }))
check("panel: same error stays dismissed on re-publish", findKey(rendered, "error.notice") == nil)
fake.noctalia.state.set("mullvad.state", snapshot("status-disconnected.json", { lastError = { key = "error.timeout" }, requestSeq = 3 }))
check("panel: a new error shows again", findKey(rendered, "error.notice") ~= nil)

-- no_polkit_agent notice offers both fallbacks
fake = bootPanel(snapshot("status-disconnected.json", { lastError = { key = "error.no_polkit_agent", action = "restart_service" } }))
local terminalBtn = findKey(rendered, "error.run_in_terminal")
local agentBtn = findKey(rendered, "error.enable_polkit_agent")
check("panel: no_polkit_agent shows both buttons", terminalBtn ~= nil and agentBtn ~= nil)
if terminalBtn and agentBtn then
  local sent = {}
  fake.noctalia.state.watch("mullvad.request", function(v) sent[#sent + 1] = v end)
  terminalBtn.props.onClick()
  eq("panel: terminal button sends run_in_terminal", sent[1] and sent[1].action, "run_in_terminal")
  eq("panel: terminal button names the failed action", sent[1] and sent[1]["for"], "restart_service")
  agentBtn.props.onClick()
  eq("panel: agent button sends enable_polkit_agent", sent[2] and sent[2].action, "enable_polkit_agent")
end
fake = bootPanel(snapshot("status-disconnected.json", { lastError = { key = "error.busy" } }))
check("panel: busy error has no polkit buttons", findKey(rendered, "error.run_in_terminal") == nil)

-- re-render from published snapshots
fake = bootPanel(snapshot("status-disconnected.json"))
fake.noctalia.state.set("mullvad.state", snapshot("status-connected.json"))
check("panel: re-renders the connected state", findKey(rendered, "disconnect.button") ~= nil)

-- no snapshot yet
fake = bootPanel(nil)
check("panel: renders without a snapshot", rendered ~= nil and findKey(rendered, "header") ~= nil)

-- login through the panel: the number goes into one request, then out of the panel
fake = bootPanel(snapshot("status-disconnected.json", { account = { loggedIn = false } }))
got = watchRequests(fake)
findKey(rendered, "tab.account").props.onClick()
check("panel: logged out account tab has the form", findKey(rendered, "account.form.1") ~= nil)
findKey(rendered, "account.input").props.onChange("1234 5678 9012 3456")
eq("panel: typing enables login", findKey(rendered, "account.login").props.enabled, true)
findKey(rendered, "account.login").props.onClick()
eq("panel: login sends one request", #got, 1)
eq("panel: login request carries the number", got[1] and got[1].number, "1234567890123456")
check("panel: the form is re-keyed after login (field cleared)", findKey(rendered, "account.form.2") ~= nil)
eq("panel: login disabled again (input dropped from ui_state)", findKey(rendered, "account.login").props.enabled, false)
check("panel: no rendered string holds the number", not anyStringMatches(rendered, SIXTEEN_DIGITS))
findKey(rendered, "account.input").props.onChange("1234")
onOpen({})
eq("panel: reopening drops a half-typed number", findKey(rendered, "account.login").props.enabled, false)
-- R9: closing drops it too, not only reopening
findKey(rendered, "account.input").props.onChange("1234 5678 9012 3456")
eq("panel: a full number enables login", findKey(rendered, "account.login").props.enabled, true)
onClose()
fake.noctalia.state.set("mullvad.state", snapshot("status-disconnected.json", { account = { loggedIn = false }, requestSeq = 9 }))
eq("panel: closing drops the typed number", findKey(rendered, "account.login").props.enabled, false)

-- a login request nobody consumed (service not running) is wiped from the channel
fake = bootPanel(snapshot("status-disconnected.json", { account = { loggedIn = false } }))
findKey(rendered, "tab.account").props.onClick()
findKey(rendered, "account.input").props.onChange("1234567890123456")
findKey(rendered, "account.login").props.onClick()
eq("panel: login asks for second ticks", wantsTicks, true)
fake.advance(2000)
update()
eq("panel: the login request stays for a moment", fake.state["mullvad.request"] and fake.state["mullvad.request"].action, "login")
fake.advance(1500)
update()
eq("panel: an unconsumed login request is wiped after 3 s", fake.state["mullvad.request"], nil)
eq("panel: ticks off again", wantsTicks, false)
findKey(rendered, "account.input").props.onChange("1234567890123456")
findKey(rendered, "account.login").props.onClick()
findKey(rendered, "panel.refresh").props.onClick()
fake.advance(3500)
update()
eq("panel: a newer request is never wiped", fake.state["mullvad.request"] and fake.state["mullvad.request"].action, "refresh")
findKey(rendered, "account.input").props.onChange("1234567890123456")
findKey(rendered, "account.login").props.onClick()
onClose()
eq("panel: closing wipes a pending login at once", fake.state["mullvad.request"], nil)

-- dismissing the notice also clears the error in the service
fake = bootPanel(snapshot("status-disconnected.json", { lastError = { key = "error.unknown_device" } }))
got = watchRequests(fake)
findKey(rendered, "error.dismiss").props.onClick()
eq("panel: dismiss sends dismiss_error", got[1] and got[1].action, "dismiss_error")
eq("panel: dismiss names the error", got[1] and got[1].key, "error.unknown_device")
check("panel: dismissed notice hidden at once", findKey(rendered, "error.notice") == nil)

-- the confirm question does not survive closing the panel
fake = bootPanel(snapshot("status-disconnected.json", { account = LOGGED_IN }))
findKey(rendered, "tab.account").props.onClick()
findKey(rendered, "account.logout").props.onClick()
check("panel: logout asks", findKey(rendered, "confirm.yes") ~= nil)
onOpen({})
check("panel: reopening drops the question", findKey(rendered, "confirm.yes") == nil and findKey(rendered, "account.logout") ~= nil)

-- every translation key the views and panel render exists in en.json
local file = io.open("mullvad/translations/en.json", "r")
local en = file and json.decode(file:read("*a"))
if file then file:close() end
local function hasKey(key)
  local node = en
  for part in key:gmatch("[^.]+") do
    node = type(node) == "table" and node[part] or nil
  end
  return type(node) == "string"
end
local seen = {}
local function collect(node)
  if type(node) ~= "table" then return end
  local props = node.props or {}
  local texts = {}
  for _, field in ipairs({ "text", "tooltip", "placeholder" }) do texts[#texts + 1] = props[field] end
  for _, option in ipairs(props.options or {}) do texts[#texts + 1] = option end
  for _, text in pairs(texts) do
    if type(text) == "string" and text:match("^[%l_]+%.[%l_.]+$") then seen[text] = true end
  end
  for _, child in ipairs(node.children or {}) do collect(child) end
end
local trees = {}
local function grab(t) trees[#trees + 1] = t end
fake = bootPanel(snapshot("status-connected.json"), function(f)
  f.noctalia.commandExists = function() return true end
end)
grab(rendered)
for _, id in ipairs({ "my_country", "random" }) do
  findKey(rendered, "mode." .. id).props.onClick()
  grab(rendered)
end
for _, id in ipairs({ "advanced", "account" }) do
  findKey(rendered, "tab." .. id).props.onClick()
  grab(rendered)
end
-- the account tab in each state (it stays the active tab for these)
for _, s in ipairs({
  snapshot("status-connected.json", { account = { loggedIn = false } }),
  snapshot("status-connected.json", { account = LOGGED_IN }),
  snapshot("status-connected.json", { account = expiredAccount }),
  snapshot("status-connected.json"),
  snapshot("status-connected.json", { account = { loggedIn = false }, lastError = { key = "error.too_many_devices" } }),
}) do
  fake.noctalia.state.set("mullvad.state", s)
  grab(rendered)
end
grab(view_account.build(snapshot("status-connected.json", { account = { loggedIn = false } }), uiState({ accountInput = "12" }), send))
grab(view_account.build(snapshot("status-connected.json", { account = LOGGED_IN }), uiState({ confirm = "logout" }), send))
findKey(rendered, "tab.connect").props.onClick() -- the snapshots below render the connect tab
for _, s in ipairs({
  { daemon = "down", relays = {} },
  snapshot("status-disconnected.json", { bootEnabled = false, busy = true, lastError = { key = "error.command_failed", detail = "x" } }),
  snapshot("status-disconnected.json", { relays = {} }),
  snapshot("status-disconnected.json", { account = { loggedIn = false } }),
  snapshot("status-disconnected.json", { account = { expiry = "expired" } }),
  snapshot("status-disconnected.json", { settings = onSettings }),
  snapshot("status-disconnected.json", { settings = anyEntry }),
  snapshot("status-disconnected.json", { settings = listEntry }),
  snapshot("status-disconnected.json", { settings = unknownEntry }),
}) do
  fake.noctalia.state.set("mullvad.state", s)
  grab(rendered)
end
fake = bootPanel(nil)
grab(rendered)
for _, t in ipairs(trees) do collect(t) end
local missing = {}
for key in pairs(seen) do
  if not hasKey(key) then missing[#missing + 1] = key end
end
table.sort(missing)
eq("views: every rendered key is in en.json", table.concat(missing, ", "), "")
check("views: the coverage scan saw keys", seen["tab.connect"] and seen["advanced.in_app"] and seen["header.action.start_service"])
check("views: the coverage scan saw the account tab", seen["account.login"] and seen["account.input_placeholder"]
  and seen["account.expires"] and seen["account.expired_on"] and seen["confirm.yes"] and seen["error.invalid_account"]
  and seen["account.loading"] and seen["voucher.redeem"] and seen["account.open_page"])
check("views: the coverage scan saw the toggles", seen["connect.lockdown"] and seen["connect.entry_any_option"]
  and seen["connect.entry_list_option"] and seen["connect.entry_unknown_option"] and seen["connect.entry_unknown"])

current.uninstall()
_G.panel = nil
_G.ui = previousUi
