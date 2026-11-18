--!nonstrict
-- Monitor Control control-center tile - the display glyph captioned with the
-- focused output's resolution, one click from the panel.
--
-- A thin client like the bar widget: it watches the service's "monitor.state"
-- snapshot for availability and opens the panel on click, so every compositor
-- call stays in the service. Add it in
-- Settings -> Control Center -> Shortcuts.

local snapshot = { available = false, outputs = {} }

local function outputByName(name)
  for _, output in ipairs(snapshot.outputs or {}) do
    if output.name == name then
      return output
    end
  end
  return nil
end

-- "2560x1440" for the output's current mode; nil when it has no active mode.
local function resolutionText(output)
  if output == nil then
    return nil
  end
  for _, mode in ipairs(output.modes or {}) do
    if mode.current == true then
      return `{mode.width}x{mode.height}`
    end
  end
  return nil
end

-- The focused output, or - with nothing focused - the first enabled output with
-- an active mode: the same pick the bar widget makes.
local function subjectOutput()
  local output = outputByName(snapshot.focused)
  if output ~= nil then
    return output
  end
  for _, candidate in ipairs(snapshot.outputs or {}) do
    if candidate.enabled == true and resolutionText(candidate) ~= nil then
      return candidate
    end
  end
  return nil
end

local function render()
  shortcut.setIcon("device-desktop")

  if snapshot.available ~= true then
    shortcut.setLabel(noctalia.tr("shortcut.unavailable"))
    shortcut.setActive(false)
    shortcut.setEnabled(false)
    return
  end

  -- The caption is the resolution, and the resolution only: the tile is one
  -- short line next to the glyph, while the bar widget carries the refresh
  -- rate and the panel both halves. A single space when there is no active
  -- mode to name - an *empty* label makes the shell substitute the entry id.
  local resolution = resolutionText(subjectOutput())
  shortcut.setLabel(resolution ~= nil and resolution or " ")

  -- A way into the panel, not a state of its own - and the shell renders every
  -- plugin shortcut as a toggle tile, so this one never lights up.
  shortcut.setActive(false)
  shortcut.setEnabled(true)
end

function onClick()
  noctalia.togglePanel("muhammadessam/umbriel-monitor-control:panel")
end

noctalia.state.watch("monitor.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

-- watch does not replay an old value to a freshly loaded entry, and the service
-- may have last published before this tile was added: ask for a snapshot,
-- exactly as the bar widget does.
noctalia.state.set("monitor.request", { action = "refresh" })
