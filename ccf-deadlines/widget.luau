--!nonstrict
-- CCF Deadlines bar widget: the next deadline and its countdown.
--
-- Left click:  open/close the panel
-- Right click: refresh the data now
--
-- Pure renderer over "ccfddl.state"; the countdown ticks locally.

local Common = require("./lib/common.luau")

local TOOLTIP_ROWS = 6

local snapshot = nil

local function nextItem()
  if snapshot == nil or type(snapshot.items) ~= "table" then
    return nil
  end
  local now = Common.nowSec()
  local first = nil
  local preferStarred = noctalia.getConfig("prefer_starred") ~= false
  for _, item in ipairs(snapshot.items) do
    if item.due > now then
      if first == nil then
        first = item
      end
      if not preferStarred or item.starred then
        return item
      end
    end
  end
  return first
end

local function tooltip(now)
  local rows = {}
  if snapshot == nil or snapshot.phase == "loading" then
    table.insert(rows, { key = noctalia.tr("title"), value = noctalia.tr("status.loading") })
    return rows
  end
  if snapshot.phase == "error" then
    table.insert(rows, { key = noctalia.tr("title"), value = snapshot.error or noctalia.tr("status.error") })
    return rows
  end
  local shown = 0
  for _, item in ipairs(snapshot.items or {}) do
    if item.due > now then
      shown += 1
      local star = if item.starred then "★ " else ""
      local kind = if item.kind == "abstract" then ` ({noctalia.tr("kind.abstract_short")})` else ""
      table.insert(rows, {
        key = `{star}{Common.itemTitle(item)}{kind}`,
        value = `{Common.countdown(item.due - now)} · {noctalia.formatTime("%m-%d %H:%M", item.due)}`,
      })
      if shown >= TOOLTIP_ROWS then
        break
      end
    end
  end
  if shown == 0 then
    table.insert(rows, { key = noctalia.tr("title"), value = noctalia.tr("status.none") })
  end
  table.insert(rows, { key = "", value = noctalia.tr("tooltip.hints") })
  return rows
end

local function render()
  local now = Common.nowSec()
  local item = nextItem()
  local display = noctalia.getConfig("display") or "name_countdown"
  local urgentDays = tonumber(noctalia.getConfig("urgent_days")) or 3

  barWidget.setGlyph(noctalia.getConfig("glyph") or "calendar-due")
  if snapshot ~= nil and snapshot.phase == "error" then
    barWidget.setGlyphColor("error")
  elseif item ~= nil then
    barWidget.setGlyphColor(Common.urgencyColor(item.due - now, urgentDays))
  else
    barWidget.setGlyphColor("on_surface")
  end

  if item == nil or display == "icon" or noctalia.getConfig("show_text") == false then
    barWidget.setText("")
  elseif display == "countdown" then
    barWidget.setText(Common.countdown(item.due - now))
  else
    barWidget.setText(`{item.title} {Common.countdown(item.due - now)}`)
  end
  barWidget.setTooltip(tooltip(now))
end

noctalia.state.watch(Common.STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel(Common.PANEL_ID)
end

function onRightClick()
  Common.request("refresh")
end

noctalia.setUpdateInterval(1000)
snapshot = noctalia.state.get(Common.STATE_KEY)
if snapshot == nil then
  Common.request("ping")
end
render()
