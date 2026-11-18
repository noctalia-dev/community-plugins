--!nonstrict
-- Bar widget: "<web UIs> / <total containers>" next to an icon.

local PANEL_ID = "davinci13/containers:panel"
local KEY_SNAPSHOT = "snapshot"
local KEY_REFRESH_NONCE = "refresh"

local glyph = "container"
local showLabel = true
local hideWhenEmpty = false
local labelFormat = "web_and_total"
local snapshot = nil
local refreshNonce = 0

local function runtimeSummary(info)
  if not info.available then return noctalia.tr("panel.runtime.missing") end
  if info.errorKey ~= "" then return noctalia.tr(info.errorKey) end
  if info.count == 0 then return noctalia.tr(info.emptyKey ~= "" and info.emptyKey or "panel.empty.title") end
  local text = string.format("%d %s", info.count, noctalia.trp("panel.unit", info.count))
  if info.webCount > 0 then
    text = text .. ", " .. string.format("%d %s", info.webCount, noctalia.trp("panel.unit_web", info.webCount))
  end
  return text
end

local function tooltipRows()
  if snapshot == nil then
    return { { key = noctalia.tr("title"), value = noctalia.tr("widget.loading") } }
  end
  local rows = {
    { key = noctalia.tr("widget.web"), value = tostring(snapshot.web) },
    { key = noctalia.tr("widget.total"), value = tostring(snapshot.total) },
  }
  for _, info in ipairs(snapshot.runtimes) do
    rows[#rows + 1] = { key = info.label, value = runtimeSummary(info) }
  end
  rows[#rows + 1] = { key = noctalia.tr("widget.hint_key"), value = noctalia.tr("widget.hint") }
  return rows
end

local function render()
  local web = snapshot ~= nil and snapshot.web or 0
  local total = snapshot ~= nil and snapshot.total or 0

  barWidget.setGlyph(glyph)
  barWidget.setTooltip(tooltipRows())

  if showLabel then
    if snapshot == nil then
      barWidget.setText("...")
    elseif labelFormat == "web_only" then
      barWidget.setText(tostring(web))
    elseif labelFormat == "total_only" then
      barWidget.setText(tostring(total))
    else
      barWidget.setText(tostring(web) .. " / " .. tostring(total))
    end
  else
    barWidget.setText("")
  end

  barWidget.setVisible(not (hideWhenEmpty and total == 0))
end

local function loadConfig()
  local g = noctalia.getConfig("glyph")
  glyph = (type(g) == "string" and g ~= "") and g or "container"
  showLabel = noctalia.getConfig("show_label") ~= false
  hideWhenEmpty = noctalia.getConfig("hide_when_empty") == true
  local lf = noctalia.getConfig("label_format")
  labelFormat = (type(lf) == "string" and lf ~= "") and lf or "web_and_total"
end

loadConfig()
snapshot = noctalia.state.get(KEY_SNAPSHOT)
noctalia.state.watch(KEY_SNAPSHOT, function(value)
  snapshot = value
  render()
end)

function update() render() end
function onConfigChanged() loadConfig(); render() end
function onClick() noctalia.togglePanel(PANEL_ID) end
function onRightClick()
  refreshNonce = refreshNonce + 1
  noctalia.state.set(KEY_REFRESH_NONCE, refreshNonce)
end

render()
