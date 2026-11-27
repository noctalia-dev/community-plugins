--!nonstrict
-- Guide topics are local UI state; switching a topic does not read the phone.
local palette = require("./palette.luau")
local M = {}
local topics = {
  { "panel", "home", {
    { "widget", "device-mobile" }, { "home", "home" }, { "settings", "settings" }, { "device", "devices" },
  } },
  { "sections", "apps", {
    { "messages", "message" }, { "calls", "phone" }, { "photos", "photo" }, { "deck", "puzzle" },
  } },
  { "help", "info-circle", {
    { "connection", "wifi" }, { "history", "message" }, { "unconfirmed", "info-circle" }, { "preview", "photo" },
  } },
  { "cache", "clock", {
    { "navigation", "history" }, { "refresh", "refresh" }, { "reload", "info-circle" }, { "search", "search" },
  } },
  { "compatibility", "device-mobile", {
    { "fork", "device-mobile" }, { "niri", "info-circle" }, { "checks", "settings" }, { "theme", "palette" },
  } },
}

function M.render(model, components, actions, width)
  local railWidth, gap, padding = 220, 10, 10
  local noteWidth = width - railWidth - gap
  -- Four short notes use the space without making the topic rail grow.
  local noteHeight, railHeight = 98, 314
  local topic = topics[model.guideTopic][3]
  local height = #topic * noteHeight + (#topic - 1) * gap
  local tabWidth = railWidth - 2 * padding
  local tabs = { components.label(noctalia.tr("guide.topics"), 12, "on_surface_variant", true, tabWidth) }
  for index, topic in ipairs(topics) do
    tabs[#tabs + 1] = ui.button({
      key = "guide-tab-" .. index,
      text = noctalia.tr("guide." .. topic[1]),
      glyph = topic[2],
      glyphSize = 17,
      width = tabWidth,
      height = 36,
      contentAlign = "start",
      variant = model.guideTopic == index and "primary" or "ghost",
      onClick = function()
        model.guideTopic = index
        actions.render()
      end,
    })
  end
  tabs[#tabs + 1] = ui.box({ width = tabWidth, height = 1, fill = palette("muted_border", 0.55) })
  tabs[#tabs + 1] = ui.button({
    key = "help-fork", glyph = "external-link", glyphSize = 16,
    text = noctalia.tr("setup.instructions"), tooltip = noctalia.tr("common.fork_help"),
    width = tabWidth, height = 36, variant = "ghost", contentAlign = "start",
    onClick = function()
      actions.send("open_fork")
    end,
  })
  local notes = {}
  for _, definition in ipairs(topic) do
    local note, glyph = definition[1], definition[2]
    local key = "guide." .. note
    notes[#notes + 1] = components.pageNote(
      noctalia.tr(key .. ".title"), noctalia.tr(key .. ".body"), glyph,
      noteWidth, noteHeight, nil, "guide-note-" .. note
    )
  end
  return ui.row({ key = "guide-layout", width = width, height = height, gap = gap, align = "start" }, {
    ui.column({
      key = "guide-topics", width = railWidth, height = railHeight, padding = padding, gap = 8,
      align = "start", radius = 12, fill = palette("raised", 0.72),
    }, tabs),
    ui.column({ key = "guide-notes", width = noteWidth, height = height, gap = gap }, notes),
  })
end

return M
