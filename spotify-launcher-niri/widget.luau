-- Spotify toggle for niri.
-- niri has no minimize, so "hiding" parks the window on a named workspace
-- (declared in the niri config) and "showing" pulls it onto the focused one.

local APP_IDS = { spotify = true, Spotify = true } -- native Wayland vs xwayland-satellite
local SCRATCH = "spotify-scratch"                  -- needs `workspace "spotify-scratch"` in niri config
local SPOTIFY = "~/.local/share/spotify-launcher/install/usr/share/spotify/spotify"
-- Native Wayland gives the window app-id "spotify" (lowercase); a normal spotify-launcher
-- start runs under XWayland as "Spotify". A case-sensitive niri rule on ^spotify$ can
-- therefore float only the windows this widget launches.
local WAYLAND = { "--enable-features=UseOzonePlatform", "--ozone-platform=wayland" }

local running = false

local function action(args, onDone)
  local argv = { "niri", "msg", "action" }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  noctalia.runAsync(argv, function(res)
    if res.exitCode ~= 0 then
      noctalia.notifyError("Spotify widget", "niri msg action failed: " .. (res.stderr or ""))
    elseif onDone then
      onDone()
    end
  end)
end

-- Runs `niri msg -j <what>` and passes the decoded JSON to cb (nil on failure).
local function query(what, cb)
  noctalia.runAsync({ "niri", "msg", "-j", what }, function(res)
    if res.exitCode ~= 0 then
      cb(nil)
      return
    end
    cb(noctalia.json.decode(res.stdout))
  end)
end

local function findSpotify(windows)
  for _, w in ipairs(windows or {}) do
    if APP_IDS[w.app_id] then
      return w
    end
  end
  return nil
end

-- Lets spotify-launcher install/update as usual, then starts Spotify itself so it can
-- pass the Wayland flags. Falls back to a plain spotify-launcher start (not floating).
local function launch()
  noctalia.runAsync({ "spotify-launcher", "--no-exec" }, function(res)
    local bin = noctalia.expandPath(SPOTIFY)
    if res.exitCode ~= 0 or res.timedOut or not noctalia.fileExists(bin) then
      noctalia.runAsync({ "spotify-launcher" })
      return
    end
    local argv = { bin }
    for _, a in ipairs(WAYLAND) do
      table.insert(argv, a)
    end
    noctalia.runAsync(argv)
  end)
end

local function render()
  barWidget.setGlyph("brand-spotify")
  barWidget.setColor(running and "primary" or "on_surface")
  barWidget.setTooltip(running and "Left: show/hide · Right: close" or "Left: launch Spotify")
end

function update()
  noctalia.setUpdateInterval(2000)
  render()
  query("windows", function(windows)
    local w = findSpotify(windows)
    running = w ~= nil
    render()
  end)
end

function onClick()
  query("windows", function(windows)
    local w = findSpotify(windows)
    if not w then
      launch()
      return
    end

    if w.is_focused then
      action({ "move-window-to-workspace", "--window-id", tostring(w.id), "--focus", "false", SCRATCH })
      return
    end

    query("workspaces", function(workspaces)
      for _, ws in ipairs(workspaces or {}) do
        if ws.is_focused then
          action({ "move-window-to-workspace", "--window-id", tostring(w.id), "--focus", "false", tostring(ws.idx) }, function()
            action({ "focus-window", "--id", tostring(w.id) })
          end)
          return
        end
      end
    end)
  end)
end

function onRightClick()
  query("windows", function(windows)
    local w = findSpotify(windows)
    if w then
      action({ "close-window", "--id", tostring(w.id) })
      running = false
      render()
    end
  end)
end
