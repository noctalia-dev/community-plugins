-- Coordinates wl-svg-bg, an external WebKitGTK layer-shell renderer, with
-- noctalia: yields noctalia's Background surface on the outputs the renderer
-- owns, and drives the renderer's systemd user unit.
--
-- The renderer cannot live in here: it needs WebKit to run the SVG's CSS
-- animation live, which a sandboxed Luau plugin cannot host.

local BIN = "wl-svg-bg"
local UNIT = BIN .. ".service"
local ENV_DIR = "~/.local/state/wl-svg-bg"
local ENV_FILE = ENV_DIR .. "/env"
local TITLE = "Animated SVG wallpaper"

-- Connectors we have told noctalia to yield, so onOutputsChanged only claims
-- what is new. noctalia's own managed set is runtime-only and clears on restart,
-- which is why the script body re-claims rather than relying on onEnable.
local owned = {}

local function claimOutputs()
    for _, output in ipairs(noctalia.outputs()) do
        if not owned[output.name] then
            noctalia.setWallpaperEnabled(output.name, false)
            owned[output.name] = true
        end
    end
end

local function releaseOutputs()
    for name in pairs(owned) do
        noctalia.setWallpaperEnabled(name, true)
    end
    owned = {}
end

-- Start the renderer without a declared unit, which is every install that is
-- not home-manager's: nothing else on Arch or Fedora writes wl-svg-bg.service,
-- and without this branch the plugin can only ever fail there.
--
-- A transient unit rather than a written one: `systemd-run` spawns and forgets,
-- where generating ~/.config/systemd/user/ + daemon-reload would have the plugin
-- installing units behind the user's back. --unit takes UNIT itself, so the
-- transient unit and the declarative one cannot drift apart and `stop` reaches
-- either; --collect frees the name again once the renderer exits, so the next
-- start can reclaim it.
--
-- The SVG path travels in EnvironmentFile, never on the command line, so a
-- wallpaper under "~/Pictures/My Wallpapers/" survives whatever splitting the
-- host applies to the command string. wallpaper.py reads WL_SVG_BG_SVG when
-- --svg is absent, which is what makes that possible.
local function runTransient(cause)
    if not noctalia.commandExists(BIN) then
        noctalia.notifyError(TITLE, BIN .. " is not installed, or not on PATH. "
            .. "Install it, then pick the SVG again.")
        releaseOutputs()
        return
    end
    -- Stop first: a transient unit cannot be restarted in place, and the name
    -- has to be free before systemd-run can claim it. Its result is deliberately
    -- ignored — "not running" is the expected case here, not an error.
    noctalia.runAsync("systemctl --user stop " .. UNIT, function()
        -- Restart=on-failure mirrors the declarative unit. Without it a renderer
        -- crash is terminal, and since the outputs are already yielded that
        -- means a black screen until the user touches the settings again.
        noctalia.runAsync("systemd-run --user --collect --unit=" .. UNIT
            .. " -p Restart=on-failure"
            .. " -p EnvironmentFile=" .. noctalia.expandPath(ENV_FILE)
            .. " " .. BIN, function(result)
            if result.exitCode ~= 0 then
                -- Report the declarative unit's failure too. This path is also
                -- taken when a unit exists but is genuinely broken, and naming
                -- only the fallback's error would bury the real cause.
                noctalia.notifyError(TITLE, "Could not start the renderer ("
                    .. tostring(result.exitCode) .. "): " .. tostring(result.stderr)
                    .. " — the declared unit first failed with: " .. cause)
                releaseOutputs()
            end
        end)
    end)
end

-- `detached` runs without a result callback, for use during teardown: onExit
-- side effects are discarded, but runAsync spawns immediately.
--
-- The outputs are claimed before the unit is asked to run, so a start that
-- fails outright — a deleted SVG, or no renderer installed at all — would
-- otherwise leave noctalia's Background surface torn down with nothing drawing
-- in its place: bare compositor, forever. Failing to a static wallpaper beats
-- failing to black, so every path that cannot start hands the outputs back.
-- A failed "stop" is not a reason to re-claim.

local function systemctl(verb, detached)
    local command = "systemctl --user " .. verb .. " " .. UNIT
    if detached then
        noctalia.runAsync(command)
        return
    end
    if not noctalia.commandExists("systemctl") then
        noctalia.notifyError(TITLE, "systemctl not found; cannot manage " .. UNIT)
        if verb ~= "stop" then
            releaseOutputs()
        end
        return
    end
    noctalia.runAsync(command, function(result)
        if result.exitCode == 0 then
            return
        end
        -- A failed start is not yet a failure: on any non-Nix install it just
        -- means no unit was ever declared. Try a transient one before handing
        -- the outputs back, and stay quiet until that fails too — notifying here
        -- would fire on every healthy Arch session.
        if verb ~= "stop" then
            runTransient(tostring(result.exitCode) .. " " .. tostring(result.stderr))
            return
        end
        noctalia.notifyError(TITLE, "systemctl " .. verb .. " failed ("
            .. tostring(result.exitCode) .. "): " .. tostring(result.stderr))
    end)
end

-- Publish the chosen SVG where the unit's EnvironmentFile picks it up, and
-- report whether that changed anything.
--
-- The comparison is what makes a declarative SVG change take effect without a
-- relogin. EnvironmentFile always beats Environment, so once this file exists
-- the unit's declarative `Environment=` is shadowed for good; a rebuild that
-- changes the SVG restarts noctalia and the renderer in unspecified order, and
-- if the renderer goes first it re-reads the *old* file. Only a restart fixes
-- that, and only a restart when the content actually differs keeps a plain
-- noctalia restart from reloading the wallpaper — the property systemd was
-- chosen for over runStream.
--
-- A missing or unreadable file is not a differing file: on first boot nothing is
-- running yet, and `start` is what is wanted.
local function writeEnv(svg)
    local body = "WL_SVG_BG_SVG=" .. svg .. "\n"
    local previous = noctalia.readFile(ENV_FILE)
    local changed = type(previous) == "string" and previous ~= "" and previous ~= body

    noctalia.mkdirAll(ENV_DIR)
    local ok, err = noctalia.writeFile(ENV_FILE, body)
    if not ok then
        noctalia.notifyError(TITLE, "Cannot write " .. ENV_FILE .. ": " .. tostring(err))
        return false
    end
    return true, changed
end

-- Clearing the SVG is the supported off-switch: it releases the outputs and
-- stops the renderer.
local function activate()
    local svg = noctalia.getConfig("svg")
    if svg == nil or svg == "" then
        if next(owned) ~= nil then
            releaseOutputs()
            systemctl("stop")
        else
            -- Naming the bundled file matters: almost nobody owns an animated
            -- SVG, so "choose one" alone sends a first-time user to an empty
            -- file dialog and an uninstall.
            noctalia.notifyError(TITLE, "No SVG selected. Choose one in the plugin "
                .. "settings — this plugin ships an example, see its README.")
        end
        return
    end
    local ok, changed = writeEnv(svg)
    if not ok then
        return
    end
    claimOutputs()
    systemctl(changed and "restart" or "start")
end

activate()

function onEnable()
    activate()
end

function onOutputsChanged()
    -- Keyed on the SVG, not on `owned`. An empty `owned` is also what a load with
    -- every output asleep looks like — lid shut on an external-only setup, or
    -- noctalia restarting mid-reconfiguration — and gating on it there would
    -- disarm this hook for the session: the renderer self-heals via its own
    -- hotplug resync while noctalia never yields, which is the two-surface
    -- overlap this plugin exists to remove.
    local svg = noctalia.getConfig("svg")
    if svg ~= nil and svg ~= "" then
        claimOutputs()
    end
end

function onConfigChanged()
    activate()
end

function onExit(_, reason)
    -- "reload" is a script edit and "shutdown" is the session ending; the
    -- renderer should survive both.
    --
    -- Deliberately no releaseOutputs() here. setWallpaperEnabled queues a side
    -- effect, and the host's Stop path discards onExit's side effects entirely
    -- (script_runtime.cpp:527-537), so it would be dead code. Disabling the
    -- plugin therefore leaves the outputs yielded until noctalia restarts, which
    -- clears the runtime-only managed set. Clearing the SVG setting is the clean
    -- off-switch.
    if reason == "disable" or reason == "uninstall" then
        systemctl("stop", true)
    end
end
