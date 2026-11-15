--!nonstrict
-- XWayland Indicator service - the only entry that talks to the compositor.
--
--   noctalia.runStream(cmd, onLine)   long-lived child, one callback per line
--   noctalia.state.set("umbriel.state", snapshot)     one snapshot, one re-render

local RECONNECT_INTERVAL_MS = 1000
-- runStream has no exit callback. Report termination on stdout so the next
-- retry can reconnect, including when the child starts but cannot connect.
local STREAM_COMMAND =
    [[umbriel subscribe workspaces,windows; printf '\n{"event":"xwayland-indicator-disconnected"}\n']]

local available = false
local streaming = false
local workspaces = {}
local windows = {}
local streamError = nil

-- A shell started by systemd can inherit WAYLAND_DISPLAY without UMBRIEL_SOCKET.
-- Follow the CLI's fallback, scoped to this display rather than another session.
local function socketPath()
    local explicit = noctalia.getenv("UMBRIEL_SOCKET")
    if explicit ~= nil and explicit ~= "" then
        return explicit
    end
    local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
    local display = noctalia.getenv("WAYLAND_DISPLAY")
    if runtimeDir ~= nil and runtimeDir ~= "" and display ~= nil and display ~= "" then
        return `{runtimeDir}/umbriel-{display}.sock`
    end
    return nil
end

-- A window's `focused` flag is per workspace. `active` would name the one window
-- holding keyboard focus, but the open panel takes that, so the target is the
-- focused window of the focused workspace.
local function findFocusedWindow(workspace)
    for _, window in ipairs(windows) do
        if window.focused == true and window.workspace == workspace.id then
            return {
                xwayland = window.xwayland,
                title = window.title,
                app_id = window.app_id,
            }
        end
    end
    return nil
end

local function findXWaylandWindows()
    local ret = {}
    for _, window in ipairs(windows) do
        if window.xwayland == true then
            table.insert(ret, {
                xwayland = window.xwayland,
                title = window.title,
                app_id = window.app_id,
            })
        end
    end
    return ret
end

local function publish()
    local focused = nil
    for _, workspace in ipairs(workspaces) do
        if workspace.focused == true then
            focused = workspace
            break
        end
    end

    noctalia.state.set("umbriel.state", {
        available = available,
        xwayland_windows = findXWaylandWindows(),
        focused_window = focused ~= nil and findFocusedWindow(focused) or nil,
        error = streamError,
    })
end

local function onLine(line)
    local decoded = noctalia.json.decode(line)
    if type(decoded) ~= "table" then
        return
    end
    if decoded.event == "xwayland-indicator-disconnected" then
        streaming = false
        available = false
        workspaces = {}
        windows = {}
        streamError = noctalia.tr("error.stream_closed")
        publish()
        return
    end
    -- The stream reports its own rejection on the first line and then closes;
    -- every other line is one subscribed state snapshot.
    if type(decoded.err) == "string" then
        streamError = decoded.err
        publish()
        return
    end
    if decoded.event == "workspaces" and type(decoded.data) == "table" then
        workspaces = decoded.data
    elseif decoded.event == "windows" and type(decoded.data) == "table" then
        windows = decoded.data
    else
        return
    end
    available = true
    streamError = nil
    publish()
end

local function startStream()
    if streaming then
        return
    end
    local path = socketPath()
    if path == nil or not noctalia.fileExists(path) or not noctalia.commandExists("umbriel") then
        return
    end
    streaming = noctalia.runStream(STREAM_COMMAND, onLine)
    if not streaming then
        streamError = noctalia.tr("error.stream_failed")
        publish()
    end
end

function update()
    startStream()
end

noctalia.setUpdateInterval(RECONNECT_INTERVAL_MS)
publish()
startStream()
