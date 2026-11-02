local osdEnabled = noctalia.getConfig("enable_osd");

local function onEvent(payload)
  local decoded = noctalia.json.decode(payload)
  if type(decoded) ~= "table" or decoded.event ~= "submap" then
    return
  end

  noctalia.state.set("umbriel_submap", { current = decoded.data })

  if osdEnabled then
    noctalia.osd.show("keyboard", decoded.data or "reset")
  end
end

function onConfigChanged()
  osdEnabled = noctalia.getConfig("enable_osd")
end

noctalia.runStream("umbriel subscribe submap", onEvent)
