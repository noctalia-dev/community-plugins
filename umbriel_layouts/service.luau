--!nonstrict
-- The one watcher. Reads every output's current layout, publishes them on
-- noctalia.state for the capsules to draw, and announces a change.
--
-- HOW IT NOTICES CHANGES
-- Umbriel's IPC has no `workspaces` or `layout` event, but it does have
-- `windows`, and that event is scheduled from Workspace::arrange(). Everything
-- this plugin cares about goes through an arrange:
--
--   * switching workspace          -> arrange -> windows event
--   * focusing another output      -> arrange/focus path -> windows event
--   * workspace-set-layout:<mode>  -> overrideLayoutMode -> applyLayoutConfig
--                                     -> new Layout + re-insert -> arrange
--
-- So subscribing to `windows` covers every trigger, including a layout change
-- made from a keybind. The event payload carries the window list rather than the
-- layout, so a hit still costs one `umbriel workspaces --json`; the point is
-- that it only happens when something actually moved.
--
-- The stream is coalesced rather than acted on directly: `windows` also fires
-- per frame during a drag or resize, and a read per frame would be worse than
-- the polling this replaces. A tick drains a dirty flag instead, so a burst of
-- events costs exactly one read.
--
-- `fallback_poll_s` is the safety net for when there is no stream at all.

local shared = require("./shared.luau")
local LAYOUTS = shared.LAYOUTS

-- Cheap enough to run when nothing changed: it only tests a boolean.
local TICK_MS = 200

-- The trailing `sleep` is load-bearing, and not for waiting. socat closes the
-- connection and exits once its stdin reaches EOF, so a bare
-- `printf ... | socat -` sends the subscribe, prints the first snapshot and dies
-- about a second later -- which looks like a working stream just long enough to
-- be believed. A process that never exits holds the pipe's write end open, so
-- socat never sees EOF.
--
-- 2147483647 rather than `infinity`: POSIX only requires sleep to accept an
-- integer, and busybox rejects `infinity`. That would reopen exactly the silent
-- failure above on any musl/busybox system.
local SUBSCRIBE =
    [[{ printf '{"cmd":"subscribe","events":["windows"]}\n'; sleep 2147483647; } | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock"]]

local function fallbackMs(): number
    local raw = tonumber(noctalia.getConfig("fallback_poll_s")) or 10
    return math.max(2, math.min(120, raw)) * 1000
end

local function notifyEnabled(): boolean
    return noctalia.getConfig("notifications") ~= false
end

local inFlight = false
local dirty = true
local streaming = false
local sinceRefreshMs = 0
-- nil until the first successful read. Distinguishing "not read yet" from "read
-- as scrolling" is what stops an announcement firing for the layout that was
-- already on screen when the shell started.
-- Keyed by WORKSPACE id, not by output. Keying by output means switching from a
-- dwindle workspace to a master one on the same monitor reads as a layout
-- change, because the layout active on that connector did change -- but nothing
-- was relayouted, the user just moved. A workspace's own layout only changes
-- when it is actually changed.
--
-- nil until the first successful read, so the layouts already on screen when the
-- shell started are not announced.
local lastByWorkspace: { [string]: string }? = nil

-- `byOutput` maps a connector to the layout of the workspace currently active on
-- it, so a capsule on eDP-1 keeps reporting eDP-1 while focus sits on HDMI-A-1.
local function publish(byOutput, byWorkspace, focusedLayout: string, focusedOutput: string)
    noctalia.state.set("layouts", byOutput)
    noctalia.state.set("layout", focusedLayout)
    noctalia.state.set("focused_output", focusedOutput)

    -- Announce a LAYOUT change and nothing else. Two things that are not one:
    --   * moving focus between monitors holding different layouts
    --   * switching to another workspace on the same monitor
    -- Both change which layout is on screen while relayouting nothing, and both
    -- announced when this diffed by output. Diffing by workspace id means an
    -- entry only moves when that workspace was actually given a new layout.
    if lastByWorkspace ~= nil and notifyEnabled() then
        for id, layout in pairs(byWorkspace) do
            local previous = lastByWorkspace[id]
            if previous ~= nil and previous ~= layout then
                local label = if LAYOUTS[layout] ~= nil
                    then noctalia.tr("name_" .. layout)
                    else layout
                -- Flat key on purpose: tr() treats a dot as a nested lookup, so
                -- "osd.changed" would resolve against d["osd"]["changed"].
                noctalia.notify(noctalia.tr("osd_changed", { layout = label }))
            end
        end
    end
    lastByWorkspace = byWorkspace
end

local function refresh()
    if inFlight then return end
    inFlight = true
    sinceRefreshMs = 0

    noctalia.runAsync("umbriel workspaces --json", function(result)
        inFlight = false
        if result == nil or result.exitCode ~= 0 then
            noctalia.state.set("error", true)
            return
        end

        local ok, decoded = pcall(function()
            return noctalia.json.decode(result.stdout or "")
        end)
        if not ok or type(decoded) ~= "table" then
            noctalia.state.set("error", true)
            return
        end

        local byOutput = {}
        local byWorkspace = {}
        local focusedLayout = ""
        local focusedOutput = ""

        for _, ws in ipairs(decoded) do
            if type(ws) == "table" then
                local output = tostring(ws.output or "")
                local layout = tostring(ws.layout or "")
                local id = tostring(ws.id or "")

                -- Every workspace, not just the visible ones: change detection
                -- needs a stable key per workspace.
                if id ~= "" then
                    byWorkspace[id] = layout
                end
                -- `active` is the workspace currently shown on that output;
                -- `focused` is the single one holding keyboard focus.
                if ws.active == true and output ~= "" then
                    byOutput[output] = layout
                end
                if ws.focused == true then
                    focusedLayout = layout
                    focusedOutput = output
                end
            end
        end

        noctalia.state.set("error", false)
        publish(byOutput, byWorkspace, focusedLayout, focusedOutput)
    end)
end

local function startStream()
    if streaming then return end
    if not noctalia.commandExists("socat") then
        -- No stream: the tick becomes a plain poll at fallback_poll_s.
        noctalia.log("socat not found; falling back to interval polling")
        return
    end

    local rc = noctalia.runStream(SUBSCRIBE, function(line)
        if line == nil or line == "" then return end
        -- Every line is a windows event; which one does not matter, only that
        -- the compositor rearranged something.
        dirty = true
    end)
    -- Only an explicit true means it launched; nil must not be read as success,
    -- or a rejected command silently disables the retry.
    streaming = rc == true
end

function update()
    sinceRefreshMs += TICK_MS

    if dirty then
        dirty = false
        refresh()
        return
    end

    -- Safety net: the stream may never have started, or may have died with the
    -- socket when the compositor restarted.
    if sinceRefreshMs >= fallbackMs() then
        if not streaming then startStream() end
        refresh()
    end
end

function onConfigChanged()
    refresh()
end

-- `noctalia msg plugin soheil7799/umbriel_layouts:poller all refresh` forces a
-- read, for a keybind that wants to be certain rather than wait for the tick.
function onIpc(event, payload)
    if event == "refresh" then
        dirty = false
        refresh()
    end
end

noctalia.setUpdateInterval(TICK_MS)
startStream()
refresh()
