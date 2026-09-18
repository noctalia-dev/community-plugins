--!nonstrict
-- Reading List bar widget — unread count and panel launcher.

local items = {}

local function unreadCount()
  local count = 0
  for _, item in ipairs(items) do
    if item.status == "unread" then count += 1 end
  end
  return count
end

local function render()
  barWidget.setGlyph("bookmarks")
  if noctalia.getConfig("show_unread_count") ~= false then
    local count = unreadCount()
    barWidget.setText(count > 0 and tostring(count) or "")
    barWidget.setTooltip(noctalia.tr("bar.unread", { count = count }))
  else
    barWidget.setText("")
    barWidget.setTooltip(noctalia.tr("panel.title"))
  end
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("ahmedhossamdev/reading-list:panel")
end

noctalia.state.watch("reading_list.items", function(value)
  items = type(value) == "table" and value or {}
  render()
end)

render()
