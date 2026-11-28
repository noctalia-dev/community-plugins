local open = false

local function emit(action)
  local seq = tonumber(noctalia.state.get("carousel.seq")) or 0
  noctalia.state.set("carousel.action", action)
  noctalia.state.set("carousel.seq", seq + 1)
end

-- The panel is an invisible keyboard-capture surface; its position setting drives
-- where the visual carousel layer is placed on screen.
local function publishPosition()
  local ok, position = pcall(noctalia.getSetting, "plugin_settings.type3demo/wallpaper-carousel.keys_position")
  if not ok or type(position) ~= "string" or position == "" then
    position = noctalia.getConfig("keys_position")
  end
  if type(position) == "string" and position ~= "" then
    noctalia.state.set("carousel.position", position)
  end
end

local function requestHide()
  noctalia.state.set("carousel.visible", false)
  -- Ask the layer entry to slide out and hide itself; hiding the surface here
  -- would cut the exit animation off on its first frame.
  local seq = tonumber(noctalia.state.get("carousel.hideSeq")) or 0
  noctalia.state.set("carousel.hideSeq", seq + 1)
end

function onOpen(_context)
  open = true
  noctalia.state.set("carousel.visible", true)
  publishPosition()
  pcall(noctalia.layer.show, "carousel")
  panel.render(ui.box({ width = 2, height = 2 }))
end

function onClose()
  open = false
  requestHide()
end

-- Closing through panel-toggle waits for the panel's own close animation before
-- onClose fires, which is what made the shortcut feel late. This entry point is
-- bound to the shortcut instead: it starts the slide-out first and closes the
-- panel right after, so the two overlap.
function onIpc(event, _payload)
  if event == "toggle" then
    if open then
      requestHide()
      panel.close()
    else
      noctalia.togglePanel("type3demo/wallpaper-carousel:keys")
    end
    return
  end

  -- Same actions the keys emit, so the carousel can be driven from the shell.
  if event == "prev" or event == "next" or event == "apply" or event == "random" or event == "delete" then
    emit(event)
  end
end

function onKey(chord, pressed)
  if not pressed then return end
  local key = chord:lower()

  if chord == "Left" or chord == "Up" then
    emit("prev")
  elseif chord == "Right" or chord == "Down" then
    emit("next")
  elseif chord == "Return" then
    emit("apply")
  elseif chord == "Space" then
    emit("random")
  elseif key == "alt+d" then
    emit("delete")
  end
end

local lastClose = tonumber(noctalia.state.get("carousel.closeSeq")) or 0

noctalia.state.watch("carousel.closeSeq", function(value)
  local seq = tonumber(value) or 0
  if seq == lastClose then return end
  lastClose = seq
  panel.close()
end)
