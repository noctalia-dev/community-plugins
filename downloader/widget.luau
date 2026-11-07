--!nonstrict
-- Downloader bar widget: a download glyph, and the running download's progress.
-- Renders "downloader.model" from service.luau; a click opens the panel.

local PANEL = "omerfuyar/downloader:panel"

local model = nil

local function counts(jobs)
  local running, queued = nil, 0
  for _, job in ipairs(jobs) do
    if job.status == "running" then
      running = job
    elseif job.status == "queued" then
      queued += 1
    end
  end
  return running, queued
end

-- color nil keeps the bar's own color.
local function show(glyph, color, text)
  local children = { ui.glyph({ name = glyph, color = color }) }
  if text and not barWidget.isVertical() then
    table.insert(children, ui.label({ text = text, color = color }))
  end
  barWidget.render(ui.row({ gap = 4, align = "center" }, children))
end

local function render()
  if model == nil then
    return
  end

  if not model.ready then
    show("alert-triangle", "error")
    barWidget.setTooltip(noctalia.tr("widget.setup", { list = table.concat(model.missing, ", ") }))
    return
  end

  local running, queued = counts(model.jobs)
  if running == nil then
    show("download")
    barWidget.setTooltip(noctalia.tr("widget.idle"))
    return
  end

  local percent = `{math.floor(running.progress * 100)}%`
  show("download", "primary", percent)

  local rows = {
    { key = noctalia.tr("widget.tooltip.file"), value = running.title or running.url },
    { key = noctalia.tr("widget.tooltip.progress"), value = percent },
  }
  if running.speed then
    table.insert(rows, { key = noctalia.tr("widget.tooltip.speed"), value = running.speed })
  end
  if running.eta then
    table.insert(rows, { key = noctalia.tr("widget.tooltip.eta"), value = running.eta })
  end
  if queued > 0 then
    table.insert(rows, { key = noctalia.tr("widget.tooltip.queued"), value = tostring(queued) })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("downloader.model", function(value)
  model = value
  render()
end)

function update()
  noctalia.setUpdateInterval(60000)
  model = model or noctalia.state.get("downloader.model")
  render()
end

function onClick()
  noctalia.togglePanel(PANEL)
end

-- Right click downloads the link on the clipboard, as video or audio like the last download.
function onRightClick()
  noctalia.state.set("downloader.command", { action = "clipboard", n = noctalia.nowMs() })
end
