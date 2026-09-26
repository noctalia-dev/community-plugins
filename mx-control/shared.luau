--!nonstrict
-- Pure helpers for the service, widget and panel. Plain-Lua syntax only, so
-- tests/shared_test.lua can load this file under `lua`.

local M = {}

M.STATUS_KEY = "mx_status"
M.COMMAND_KEY = "mx_command"
M.APPS_KEY = "mx_apps"

-- serve stamps ts on every publish and heartbeats every 60 s.
local STALE_SEC = 150
local HELPER_RESTART_SEC = 90

-- A running serve, from any copy of the plugin; anchored so a shell or grep
-- that merely mentions it is never killed.
M.HELPER_PATTERN = "^python3 [^ ]*/mxctl\\.py serve$"

function M.helperNeedsStart(ts, nowSec)
    ts = tonumber(ts)
    return ts == nil or nowSec - ts > HELPER_RESTART_SEC
end

-- A choice list this long and evenly spaced is a numeric scale (DPI).
local SLIDER_MIN_CHOICES = 13

M.TABS = { "point", "buttons", "hosts", "profiles", "shortcuts" }

-- profiles and shortcuts hold no device settings, so they have no sections.
local TAB_SECTIONS = {
    point = { "pointer", "scroll", "thumb", "other" },
    buttons = { "buttons" },
    hosts = { "hosts" },
}

local SECTION_TAB = {}
for tab, sections in pairs(TAB_SECTIONS) do
    for _, section in ipairs(sections) do
        SECTION_TAB[section] = tab
    end
end

-- Column captions for the per-button groups; other key settings keep their label.
local CAPTION_KEYS = {
    ["reprogrammable-keys"] = "caption.action",
    ["divert-keys"] = "caption.mode",
}

function M.sectionsFor(tab)
    return TAB_SECTIONS[tab] or {}
end

function M.captionKey(settingName)
    return CAPTION_KEYS[settingName]
end

function M.sectionFor(name)
    name = tostring(name or "")
    if name == "change-host" then
        return "hosts"
    end
    if name == "dpi" or name:find("^dpi") or name:find("^pointer") then
        return "pointer"
    end
    if name:find("^thumb") then
        return "thumb"
    end
    if name:find("^hires") or name:find("^lowres") or name:find("^scroll") or name == "smart-shift" then
        return "scroll"
    end
    if name:find("key") or name:find("gesture") or name:find("button") then
        return "buttons"
    end
    return "other"
end

function M.tabFor(name)
    return SECTION_TAB[M.sectionFor(name)] or "point"
end

function M.pickDevice(status, preferred)
    if type(status) ~= "table" or type(status.devices) ~= "table" then
        return nil
    end
    local first, online
    for _, device in ipairs(status.devices) do
        if preferred and preferred ~= "" and device.id == preferred then
            return device
        end
        first = first or device
        if device.online and not online then
            online = device
        end
    end
    return online or first
end

-- jsonable() emits NamedInt values as {id, name}.
function M.valueId(value)
    if type(value) == "table" then
        if value.id ~= nil then
            return value.id
        end
        return value.name
    end
    return value
end

function M.choiceIndex(choices, value)
    local wanted = M.valueId(value)
    for i, choice in ipairs(choices or {}) do
        if choice.id == wanted or choice.name == wanted or tostring(choice.id) == tostring(wanted) then
            return i - 1
        end
    end
    return -1
end

function M.evenScale(choices)
    if type(choices) ~= "table" or #choices < SLIDER_MIN_CHOICES then
        return nil
    end
    local step = nil
    for i, choice in ipairs(choices) do
        if type(choice.id) ~= "number" then
            return nil
        end
        if i > 1 then
            local diff = choice.id - choices[i - 1].id
            if diff <= 0 or (step and diff ~= step) then
                return nil
            end
            step = diff
        end
    end
    return choices[1].id, choices[#choices].id, step
end

function M.displayText(value)
    if value == nil then
        return "--"
    end
    if type(value) == "table" then
        if value.name ~= nil then
            return tostring(value.name)
        end
        return "…"
    end
    return tostring(value)
end

local function names(choices)
    local out = {}
    for i, choice in ipairs(choices or {}) do
        out[i] = tostring(choice.name)
    end
    return out
end

function M.controlFor(setting)
    local kind = setting.kind
    if kind == "toggle" then
        return { type = "toggle", value = setting.value == true }
    end
    if kind == "range" and tonumber(setting.min) and tonumber(setting.max) then
        local lo = tonumber(setting.min)
        return {
            type = "slider", min = lo, max = tonumber(setting.max), step = 1,
            value = tonumber(M.valueId(setting.value)) or lo,
        }
    end
    if kind == "choice" then
        if setting.name == "change-host" then
            return { type = "hosts" }
        end
        local lo, hi, step = M.evenScale(setting.choices)
        if lo then
            return {
                type = "slider", min = lo, max = hi, step = step, snap = true,
                value = tonumber(M.valueId(setting.value)) or lo,
            }
        end
        return { type = "select", options = names(setting.choices), index = M.choiceIndex(setting.choices, setting.value) }
    end
    if kind == "map_choice" or kind == "map_range" or kind == "multiple_toggle" then
        local entries = {}
        for _, entry in ipairs(setting.keys or {}) do
            local control = M.controlFor({
                kind = entry.kind, value = entry.value, min = entry.min, max = entry.max, choices = entry.choices,
            })
            if control.type ~= "readonly" then
                entries[#entries + 1] = { key = entry.key, label = entry.label, control = control, choices = entry.choices }
            end
        end
        if #entries > 0 then
            return { type = "map", entries = entries }
        end
    end
    local shown = setting.display
    if shown == nil then
        shown = setting.value
    end
    return { type = "readonly", text = M.displayText(shown) }
end

-- Turns a control's raw callback string into (value to send, value to show).
-- Choices are sent as a name or a digit string: Luau numbers are doubles, and
-- the helper's choice matcher rejects an encoded 1000.0.
function M.commandValue(control, choices, raw)
    if control.type == "toggle" then
        local on = raw == "true" or raw == true
        return on, on
    end
    local n = tonumber(raw)
    if n == nil then
        return nil
    end
    if control.type == "slider" then
        local steps = math.floor((n - control.min) / control.step + 0.5)
        local value = control.min + steps * control.step
        if value < control.min then
            value = control.min
        elseif value > control.max then
            value = control.max
        end
        value = math.floor(value)
        if control.snap then
            return string.format("%d", value), value
        end
        return value, value
    end
    if control.type == "select" then
        local choice = (choices or {})[math.floor(n) + 1]
        if choice == nil then
            return nil
        end
        return tostring(choice.name), choice.id ~= nil and choice.id or choice.name
    end
    return nil
end

function M.hostSwitchValue(index)
    return string.format("%d", math.floor(tonumber(index) or 0))
end

-- Nonces start with the sender's nowMs; a stored command replayed after a
-- reload is older than the window and must not be written again.
function M.isFreshNonce(nonce, nowMs, maxAgeMs)
    local ms = tonumber(tostring(nonce or ""):match("^(%d+)[%.%d]*%-"))
    if ms == nil then
        return false
    end
    return math.abs(nowMs - ms) <= maxAgeMs
end

-- Only settings keyed by button control id can share a per-button group.
function M.mergesByButton(settingName)
    return CAPTION_KEYS[settingName] ~= nil
end

function M.runtimeDirFrom(stdout, fallback)
    local path = tostring(stdout or ""):match("^%s*(.-)%s*$")
    if path:sub(1, 1) == "/" then
        return path
    end
    return fallback
end

function M.setCommand(deviceId, settingName, key, value)
    return { op = "set", device = deviceId, setting = settingName, key = key, value = value }
end

-- serve drains cmd-*.json sorted by name, so the name carries the write order.
function M.spoolName(ms, seq)
    return string.format("cmd-%013d%07d-noctalia.json", math.floor(ms), math.floor(seq) % 10000000)
end

function M.stateCode(status, nowSec)
    if type(status) ~= "table" then
        return "starting"
    end
    if status.installed == false then
        return "no_solaar"
    end
    local ts = tonumber(status.ts)
    if ts and nowSec and nowSec - ts > STALE_SEC then
        return "stale"
    end
    if status.accessible == false and status.permissionError and status.permissionError ~= "" then
        return "no_access"
    end
    if type(status.devices) ~= "table" or #status.devices == 0 then
        return "no_devices"
    end
    return nil
end

function M.batteryLevel(device)
    if type(device) ~= "table" or type(device.battery) ~= "table" then
        return nil
    end
    return tonumber(device.battery.level)
end

function M.batteryText(device)
    if type(device) ~= "table" or not device.online then
        return "--"
    end
    local level = M.batteryLevel(device)
    if level then
        return tostring(math.floor(level)) .. "%"
    end
    if type(device.battery) == "table" and device.battery.text and device.battery.text ~= "" then
        return tostring(device.battery.text)
    end
    return "--"
end

-- ── Shortcuts (mirrors mxactions.shortcut / sequence) ───────────────────────

local MODIFIERS = { CTRL = "CTRL", CONTROL = "CTRL", ALT = "ALT", SHIFT = "SHIFT", SUPER = "SUPER", META = "SUPER" }
local MAX_STEPS = 8

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.normalizeShortcut(text)
    if type(text) ~= "string" or #text > 100 then
        return nil, "shortcut.key"
    end
    local parts = {}
    for part in (text .. "+"):gmatch("(.-)%+") do
        parts[#parts + 1] = trim(part)
    end
    local key = parts[#parts] or ""
    if not key:match("^[A-Za-z0-9_]+$") or #key > 40 then
        return nil, "shortcut.key"
    end
    local mods, seen = {}, {}
    for i = 1, #parts - 1 do
        local mod = MODIFIERS[parts[i]:upper()]
        if not mod then
            return nil, "shortcut.modifier"
        end
        if not seen[mod] then
            seen[mod] = true
            mods[#mods + 1] = mod
        end
    end
    if MODIFIERS[key:upper()] then
        return nil, "shortcut.no_key"
    end
    if #key == 1 then
        key = key:lower()
    end
    mods[#mods + 1] = key
    return table.concat(mods, "+")
end

-- Steps are one per line, as the helper stores them; commas also separate,
-- since no valid key name contains one.
function M.normalizeSteps(text)
    local steps = {}
    for line in (tostring(text or ""):gsub(",", "\n") .. "\n"):gmatch("(.-)\n") do
        if trim(line) ~= "" then
            local step, err = M.normalizeShortcut(line)
            if not step then
                return nil, err
            end
            steps[#steps + 1] = step
        end
    end
    if #steps == 0 then
        return nil, "shortcut.empty"
    end
    if #steps > MAX_STEPS then
        return nil, "shortcut.too_many"
    end
    return table.concat(steps, "\n")
end

local function findSetting(device, name)
    for _, setting in ipairs((device or {}).settings or {}) do
        if setting.name == name then
            return setting
        end
    end
    return nil
end

-- Buttons that can run software actions are the divertable ones; "Mouse
-- Gestures" (id 2) among their modes means the button reports movement.
function M.actionControls(device)
    local divert = findSetting(device, "divert-keys")
    local out = {}
    for _, entry in ipairs((divert and divert.keys) or {}) do
        local gesture = false
        for _, choice in ipairs(entry.choices or {}) do
            if tonumber(choice.id) == 2 then
                gesture = true
            end
        end
        out[#out + 1] = {
            key = tostring(entry.key),
            label = entry.label or tostring(entry.key),
            gesture = gesture,
            divertMode = tonumber(M.valueId(entry.value)),
        }
    end
    return out
end

function M.bindingsFor(status, deviceId)
    local rows = {}
    for _, row in ipairs((type(status) == "table" and status.actions) or {}) do
        if row.device == deviceId then
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b)
        local ca, cb = tonumber(a.control) or 0, tonumber(b.control) or 0
        if ca ~= cb then
            return ca < cb
        end
        if (a.app or "") == "" or (b.app or "") == "" then
            return (a.app or "") == ""
        end
        return tostring(a.app):lower() < tostring(b.app):lower()
    end)
    return rows
end

function M.hasBinding(status, deviceId, key)
    for _, row in ipairs(M.bindingsFor(status, deviceId)) do
        if row.control == tostring(key) then
            return true
        end
    end
    return false
end

local function controlByKey(controls, key)
    for _, c in ipairs(controls or {}) do
        if c.key == tostring(key or "") then
            return c
        end
    end
    return nil
end

-- Checks a draft the way the helper will, so the panel can say why before sending.
function M.validateDraft(draft, controls, bindings)
    local control = controlByKey(controls, draft.control)
    if control == nil then
        return nil, "draft.no_control"
    end
    -- A bound button reads Diverted because the helper diverts it; only an
    -- unbound one must be Regular, as the helper checks before taking it over.
    local bound = false
    for _, row in ipairs(bindings or {}) do
        if row.control == control.key then
            bound = true
        end
    end
    if not bound and control.divertMode ~= nil and control.divertMode ~= 0 then
        return nil, "draft.not_regular"
    end
    local app = trim(draft.app)
    -- A blank "Another app" must not silently become the All apps action.
    if draft.appOther and app == "" then
        return nil, "draft.no_app"
    end
    if app ~= "" then
        local hasDefault = false
        for _, row in ipairs(bindings or {}) do
            if row.control == control.key and (row.app or "") == "" then
                hasDefault = true
            end
        end
        if not hasDefault then
            return nil, "draft.needs_default"
        end
    end
    local shortcut, err = M.normalizeSteps(draft.shortcut)
    if not shortcut then
        return nil, err
    end
    local mode = draft.mode == "gesture" and "gesture" or "shortcut"
    local gestures = {}
    if mode == "gesture" then
        if not control.gesture then
            return nil, "draft.no_gesture"
        end
        for _, dir in ipairs({ "up", "down", "left", "right" }) do
            local text = (draft.gestures or {})[dir]
            if text ~= nil and trim(text) ~= "" then
                local steps, stepErr = M.normalizeSteps(text)
                if not steps then
                    return nil, stepErr
                end
                gestures[dir] = steps
            else
                gestures[dir] = ""
            end
        end
    end
    return { control = control.key, app = app, mode = mode, shortcut = shortcut, gestures = gestures }
end

function M.actionSave(deviceId, draft)
    return {
        op = "action-save",
        device = deviceId,
        binding = {
            device = deviceId, control = draft.control, app = draft.app or "",
            mode = draft.mode, shortcut = draft.shortcut, gestures = draft.gestures or {},
        },
    }
end

function M.actionDelete(deviceId, binding)
    return {
        op = "action-delete",
        device = deviceId,
        binding = { device = deviceId, control = tostring(binding.control), app = binding.app or "" },
    }
end

-- ── Profiles and pointer ─────────────────────────────────────────────────────

function M.profileSave(deviceId, name)
    return { op = "profile-save", device = deviceId, name = name }
end

function M.profileApply(deviceId, name)
    return { op = "profile-apply", device = deviceId, name = name }
end

function M.profileDelete(name)
    return { op = "profile-delete", name = name }
end

function M.pointerSet(deviceId, mode)
    return { op = "pointer-set", device = deviceId, acceleration = mode }
end

function M.profilesFor(status, deviceId)
    local out = {}
    for _, profile in ipairs((type(status) == "table" and status.profiles) or {}) do
        if profile.deviceId == deviceId then
            out[#out + 1] = profile
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return out
end

-- Mirrors the helper's is_mouse_dev; pointer-set is refused for anything else.
local POINTER_KINDS = { mouse = true, trackball = true, touchpad = true }

function M.supportsAcceleration(device)
    return type(device) == "table" and POINTER_KINDS[tostring(device.kind or ""):lower()] == true
end

function M.accelMode(status, deviceId)
    local prefs = type(status) == "table" and type(status.pointer) == "table" and status.pointer[deviceId]
    if type(prefs) == "table" and prefs.acceleration == "mac" then
        return "mac"
    end
    return "system"
end

-- Mirrors the helper's sanitize_profile_name, so the name shown is the name saved.
function M.sanitizeProfileName(raw)
    local text = trim(tostring(raw or ""):gsub("%s+", " "):gsub("[<>]", ""))
    if text == "" then
        return nil
    end
    if #text > 40 then
        text = trim(text:sub(1, 40))
    end
    return text
end

-- Classes of open Hyprland windows (hyprctl -j clients), for the app picker.
function M.appClasses(clients)
    local seen, out = {}, {}
    for _, client in ipairs(type(clients) == "table" and clients or {}) do
        local class = type(client) == "table" and client.class or nil
        if type(class) == "string" and class ~= "" and not seen[class] then
            seen[class] = true
            out[#out + 1] = class
        end
    end
    table.sort(out, function(a, b)
        return a:lower() < b:lower()
    end)
    return out
end

function M.levelRole(level)
    level = tonumber(level)
    if level == nil then
        return nil
    end
    if level <= 15 then
        return "error"
    end
    if level <= 30 then
        return "secondary"
    end
    return nil
end

return M
