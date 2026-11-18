--!nonstrict
-- Control Center tile: today's Jalali date, opens the calendar panel.
--
-- Shortcut entries cannot declare their own settings, so this reads the
-- plugin-level ones.

local host = require("./host.luau")
local fmt = require("./fmt.luau")

local opts = host.normalize({
  language = noctalia.getConfig("language"),
  digits = noctalia.getConfig("digits"),
  week_start = noctalia.getConfig("week_start"),
  show_hijri = noctalia.getConfig("show_hijri"),
  show_gregorian = noctalia.getConfig("show_gregorian"),
  show_holidays = noctalia.getConfig("show_holidays"),
  events_national = noctalia.getConfig("events_national"),
  events_ancient = noctalia.getConfig("events_ancient"),
  events_religious = noctalia.getConfig("events_religious"),
  events_afghan = noctalia.getConfig("events_afghan"),
})

local function render()
  local today = host.today()
  shortcut.setLabel(`{fmt.digits(today.jd, opts.digits)} {fmt.monthName(today.jm, opts.lang)}`)
  shortcut.setIcon("calendar")
  shortcut.setActive(false)
  shortcut.setEnabled(true)
end

render()

function onClick()
  noctalia.togglePanel(host.PANEL_ID)
  -- The date can have rolled over since the tile was last drawn.
  render()
end
