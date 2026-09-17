--!nonstrict
-- Keeps the arrangement honest across hotplug.
--
-- Being off outlives the cable, so a disabled panel plus an unplugged monitor
-- leaves a session with something connected and nothing drawing on it. A
-- display that returns is the mirror of that: it takes the position its section
-- still holds, which the displays that stayed have since been packed into, and
-- the two land on one rectangle looking like a frozen clone.
--
-- Both are the same fix: wake something if the session is dark, then lay the
-- arrangement out again. Umbriel advertises a disabled output as a head, so the
-- survivor is visible here. It also runs at start, for a config already dark.

local displays = require("./outputs.luau")

-- The internal panel is the safest one to wake: it is the only output that
-- cannot be unplugged out from under the session again.
local function preferred(candidate, current)
  if current == nil then
    return true
  end
  local candidateIsPanel = string.match(candidate.name, "^eDP") ~= nil
  local currentIsPanel = string.match(current.name, "^eDP") ~= nil
  if candidateIsPanel ~= currentIsPanel then
    return candidateIsPanel
  end
  return candidate.name < current.name
end

-- Nothing was reported, so there is no output to match a section against. The
-- blunt recovery is to drop every `enabled = false` in the file and let Umbriel
-- light whatever is attached.
local function enableEverything()
  local sections = displays.read()
  local changed = false
  for _, fields in pairs(sections) do
    if fields.enabled ~= nil then
      fields.enabled = nil
      changed = true
    end
  end
  if changed then
    displays.write(sections, function() end)
  end
  return changed
end

-- Output events arrive in bursts while a display settles, and each query is a
-- process. One in flight is enough: the last event's answer is the current one.
local querying = false

local function reconcile()
  if querying then
    return
  end
  querying = true

  displays.query(function(outputs)
    querying = false
    if outputs == nil then
      return
    end

    if #outputs == 0 then
      if enableEverything() then
        noctalia.notifyError(noctalia.tr("rescue.title"), noctalia.tr("rescue.blind"))
      end
      return
    end

    local woken = nil
    local lit = false
    for _, output in ipairs(outputs) do
      lit = lit or output.enabled
    end
    if not lit then
      for _, output in ipairs(outputs) do
        if preferred(output, woken) then
          woken = output
        end
      end
      woken.enabled = true
    end

    -- Only write when the file would actually change: this runs on every output
    -- event, and a write is another reload is another event.
    local sections, changed = displays.apply(outputs, displays.rows(outputs))
    if not changed then
      return
    end

    displays.write(sections, function(ok, err)
      if not ok then
        noctalia.log("umbriel-displays: cannot rewrite the arrangement: " .. tostring(err))
      elseif woken ~= nil then
        noctalia.notify(noctalia.tr("rescue.title"), noctalia.tr("rescue.body", { name = woken.name }))
      end
    end)
  end)
end

function onOutputsChanged()
  reconcile()
end

reconcile()
