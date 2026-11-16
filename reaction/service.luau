--[[
Reaction trigger service.

Keeps the sticker ready for the whole session and owns the trigger path:

* Warms the GIF frame cache for every configured candidate, so both the
  transparent overlay process and the panel fallback know the sticker's
  duration from the first trigger on.
* Routes `trigger` through the shared sticker module (lib/sticker.luau): the
  transparent overlay when its dependencies are present, the panel otherwise.
  A second trigger while the sticker is on screen restarts it instead of
  closing it.

Callers are external: a keybind, a script, or another plugin (miixz/game-clip
routes its trigger here when no game is focused):

    noctalia msg plugin miixz/reaction:service all trigger

The bar tile does not come through here: it calls the same shared module in
process, so a click works even in the moment this service is still starting.
]]

local Sticker = require("./lib/sticker.luau")

local function setting(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function show()
  noctalia.log("reaction: trigger")
  Sticker.show()
end

local function hide()
  noctalia.log("reaction: hide")
  Sticker.hide()
end

function update()
  -- Keep every candidate warm in the background. Extraction is cheap after the
  -- first pass, so this settles into a no-op quickly.
  Sticker.warm()
  Sticker.tick()
end

function onIpc(event, _payload)
  if event == "trigger" or event == "show" then
    show()
  elseif event == "hide" or event == "close" then
    hide()
  elseif event == "status" then
    local candidates = Sticker.candidates()
    local currentPath = noctalia.state.get("current_path") or ""
    local total = #candidates
    local state = "idle"

    if total == 0 then
      state = "no candidates"
    elseif currentPath ~= "" then
      local ready = Sticker.isReady(currentPath)
      state = string.format("%d candidate%s, current %s",
        total,
        total == 1 and "" or "s",
        ready and "ready" or "extracting")
    else
      state = string.format("%d candidate%s, not yet triggered",
        total,
        total == 1 and "" or "s")
    end

    noctalia.notify(
      noctalia.tr("notify.status.title"),
      noctalia.tr("notify.status.body", {
        sticker = currentPath == "" and noctalia.tr("status.unset") or currentPath,
        state = state,
      })
    )
  end
end

noctalia.setUpdateInterval(2000)
