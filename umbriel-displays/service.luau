--!nonstrict
-- Emergency enablement is session state, not a change to saved display policy.
local displays = require("./outputs.luau")

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

local busy = false
local pending = false
local sleeping = false
local generation = 0
local reconcile

local function finish()
  busy = false
  if pending then
    pending = false
    reconcile()
  end
end

reconcile = function()
  if sleeping then
    return
  end
  if busy then
    pending = true
    return
  end
  busy = true
  local queriedGeneration = generation

  displays.query(function(outputs)
    -- KVM switching also removes every output, without a suspend callback.
    if sleeping or generation ~= queriedGeneration or outputs == nil or #outputs == 0 then
      finish()
      return
    end

    local woken = nil
    for _, output in ipairs(outputs) do
      if output.enabled then
        finish()
        return
      end
      if preferred(output, woken) then
        woken = output
      end
    end

    local sent = noctalia.umbriel.action({ action = "output-enable", output = woken.name }, function(ok, err)
      if not ok then
        noctalia.log("umbriel-displays: output-enable failed: " .. tostring(err))
      elseif not sleeping and generation == queriedGeneration then
        noctalia.notify(noctalia.tr("rescue.title"), noctalia.tr("rescue.body", { name = woken.name }))
      end
      finish()
    end)
    if not sent then
      noctalia.log("umbriel-displays: cannot send output-enable")
      finish()
    end
  end)
end

function onOutputsChanged()
  reconcile()
end

function onSuspend()
  sleeping = true
  generation = generation + 1
  pending = false
end

function onResume()
  sleeping = false
  generation = generation + 1
  reconcile()
end

reconcile()
