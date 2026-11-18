--!nonstrict
-- Control-center tile: opens the picker panel, and lights up while animations are enabled.
--
--   shortcut.setLabel(text)
--   shortcut.setIcon(on [, off])
--   shortcut.setActive(bool)
--   shortcut.setEnabled(bool)

-- target_file is declared as a root-level [[setting]], which seeds every entry. Shortcuts do
-- NOT receive entry-level ([[panel.setting]]) values, so keeping the fallback here is what
-- makes this file survive someone moving that setting back under an entry.
local TARGET = noctalia.getConfig("target_file") or "~/.config/niri/animations.kdl"

local function animationsOn(): boolean
  local text = noctalia.readFile(TARGET)
  if text == nil then return true end
  return string.match(text, "\n%s*off%s*[\n\r]") == nil
end

local function render()
  local on = animationsOn()
  shortcut.setLabel(noctalia.tr("shortcut_label"))
  shortcut.setIcon("movie")
  shortcut.setActive(on)
  shortcut.setEnabled(true)
end

render()

-- The tile opens the ATTACHED variant: it is pressed from the control center, which already
-- sits against the bar, so a panel floating in the middle of the screen would feel detached.
-- Bind the `picker` entry to a key for the floating one.
function onClick()
  noctalia.runAsync("noctalia msg panel-toggle imjustdoingmypart/niri-animations:docked")
  render()
end
