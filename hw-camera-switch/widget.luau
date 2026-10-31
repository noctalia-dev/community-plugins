--!nonstrict

-- Hardware Camera Switch: shows the physical camera shutter state on the bar
-- and pops Noctalia's native OSD when it changes.
--
-- The state comes from one bit of one byte of the laptop's embedded
-- controller (EC). Which byte and bit depends on the laptop model, so they
-- are settings (see plugin.toml). Defaults are for the Lenovo LOQ 15IRX9.

-- ── Defaults for LOQ 15IRX9 (used when a setting is missing) ────────────────────────────────

local DEFAULT_PATH = "/sys/kernel/debug/ec/ec0/io"
local DEFAULT_OFFSET = 31
local DEFAULT_MASK = 64
local DEFAULT_POLL_MS = 500

-- ── Settings helpers ─────────────────────────────────────────────────────────

-- A number setting, or `default` if it is unset or not a number.
local function cfgNumber(key, default)
    local value = tonumber(noctalia.getConfig(key))
    if value == nil then
        return default
    end
    return value
end

-- A true/false setting, or `default` if it is unset.
local function cfgBool(key, default)
    local value = noctalia.getConfig(key)
    if value == nil then
        return default
    end
    return value == true or value == "true"
end

-- A text setting, or `default` if it is unset or empty.
local function cfgString(key, default)
    local value = noctalia.getConfig(key)
    if type(value) ~= "string" or value == "" then
        return default
    end
    return value
end

-- ── State ────────────────────────────────────────────────────────────────────

-- "on", "off", or nil when the switch cannot be read (startup, missing
-- permission, wrong path). nil is never treated as a change, so the OSD does
-- not pop at login.
local state = nil

-- True while a read is running, so two reads never overlap.
local polling = false

-- ── OSD ──────────────────────────────────────────────────────────────────────

local function showOsd(s)
    if not cfgBool("show_osd", true) then
        return
    end
    if s == "off" then
        noctalia.osd.show("camera-off", "Camera Disabled", { inactive = true })
    else
        noctalia.osd.show("camera", "Camera Enabled")
    end
end

-- ── Bar icon ─────────────────────────────────────────────────────────────────

local function render()
    barWidget.setText("")
    if state == "off" then
        barWidget.setGlyph("camera-off")
        barWidget.setGlyphColor("error")
        barWidget.setTooltip("Camera Hardware Switch: OFF (Closed)")
    elseif state == "on" then
        barWidget.setGlyph("camera")
        barWidget.setGlyphColor("on_surface")
        barWidget.setTooltip("Camera Hardware Switch: ON (Open)")
    else
        -- Cannot read the switch: dimmed icon, so it is obvious something
        -- is not set up instead of silently showing a wrong state.
        barWidget.setGlyph("camera")
        barWidget.setGlyphColor("on_surface_variant")
        barWidget.setTooltip("Camera switch: cannot read state (check the plugin README)")
    end
end

-- ── Reading the switch ───────────────────────────────────────────────────────

-- Reads one byte of the EC file with `od`, which prints it as a decimal
-- number, for example "98". The command runs in the background; the function
-- below is called when it finishes.
local function poll()
    if polling then
        return
    end
    polling = true

    -- Settings are read on every poll, so changes apply without a reload.
    local path = cfgString("ec_path", DEFAULT_PATH)
    local offset = cfgNumber("ec_offset", DEFAULT_OFFSET)
    local mask = cfgNumber("ec_mask", DEFAULT_MASK)
    local invert = cfgBool("ec_invert", false)

    noctalia.runAsync(
        { "od", "-An", "-tu1", "-j" .. tostring(offset), "-N1", path },
        function(result)
            polling = false

            local value = tonumber(string.match(result.stdout or "", "%d+"))
            if result.exitCode ~= 0 or value == nil or mask < 1 then
                state = nil
                render()
                return
            end

            -- Is the masked bit set? Divide by the mask, drop the fraction,
            -- and check if the result is odd. (Luau has no plain bit-and
            -- for this.) Example: 98 / 64 = 1.53 -> 1 -> odd -> set.
            local bitSet = (math.floor(value / mask) % 2 == 1)
            if invert then
                bitSet = not bitSet
            end
            local newState = bitSet and "on" or "off"

            local previous = state
            state = newState
            render()

            -- Only show the OSD for a real change, never for the first read
            -- or after an unreadable period.
            if previous ~= nil and previous ~= newState then
                showOsd(newState)
            end
        end,
        2000
    )
end

-- ── Entry points called by Noctalia ──────────────────────────────────────────

-- Called on the timer set below.
function update()
    poll()
end

-- Clicking the bar icon shows the current state as an OSD.
function onClick()
    if state ~= nil then
        showOsd(state)
    end
end

-- ── Startup ──────────────────────────────────────────────────────────────────

-- The interval is set once when the plugin loads. Changing "Check interval"
-- later needs a plugin reload.
local pollMs = cfgNumber("poll_ms", DEFAULT_POLL_MS)
if pollMs < 200 then
    pollMs = 200
end
noctalia.setUpdateInterval(pollMs)

render()
poll()
