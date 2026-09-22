--!nonstrict
-- Misr Quran Radio panel - live toggle plus today's programme schedule.
--
-- Every change becomes one "misr_quran.request" on the plugin's shared state:
-- the service fetches the schedule and owns the mpv process, then answers
-- with a fresh "misr_quran.state" snapshot. The panel owns no network calls.

local snapshot = { available = false, playing = false, schedule = {} }

local canOpenSite = noctalia.commandExists("xdg-open")

-- Forward declaration, before anything that re-renders: the button callbacks
-- call render(), and a `local function render` further down would leave them
-- calling a nil global instead.
local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function request(value)
  noctalia.state.set("misr_quran.request", value)
end

function onCloseClicked()
  panel.close()
end

function onPlayToggle()
  if snapshot.playing == true then
    request({ action = "stop" })
  else
    request({ action = "play" })
  end
end

function onRefresh()
  request({ action = "refresh" })
end

function onCopyUrl()
  local url = snapshot.stream_url
  if type(url) == "string" and url ~= "" then
    noctalia.copyToClipboard(url, "text/plain")
    noctalia.notify(tr("title"), tr("panel.copied"))
  end
end

function onOpenSite()
  if not canOpenSite then
    noctalia.notify(tr("title"), tr("panel.site_unavailable"))
    return
  end
  noctalia.runAsync("xdg-open https://misrquran.gov.eg/home")
end

local function statusText()
  if snapshot.available == false then
    return tr("panel.unavailable")
  end
  if snapshot.busy == true then
    return tr("panel.busy")
  end
  if snapshot.playing == true then
    return tr("panel.playing")
  end
  return tr("panel.stopped")
end

local function currentBlock()
  local cur = snapshot.current
  if type(cur) ~= "table" or type(cur.title) ~= "string" then
    return nil
  end
  local when = ""
  if type(cur.fromTime) == "string" then
    when = cur.fromTime
    if type(cur.toTime) == "string" then
      when = when .. " - " .. cur.toTime
    end
  end
  local rows = {
    ui.label({ text = tr("panel.now"), fontWeight = "medium", color = "on_surface_variant", textAlign = "end" }),
    ui.label({ text = cur.title, fontWeight = "bold", color = "on_surface", textAlign = "end" }),
  }
  if when ~= "" then
    table.insert(rows, ui.label({ text = when, color = "on_surface_variant", textAlign = "end" }))
  end
  if type(cur.description) == "string" and cur.description ~= "" and cur.description ~= "null" then
    table.insert(rows, ui.label({ text = cur.description, color = "on_surface_variant", textAlign = "end" }))
  end
  return ui.column({ gap = 4 }, rows)
end

local function scheduleList()
  local items = {}
  if type(snapshot.schedule) == "table" then
    items = snapshot.schedule
  end
  if #items == 0 then
    return ui.label({ text = tr("panel.empty"), color = "on_surface_variant" })
  end
  local rows = {}
  for i, item in ipairs(items) do
    if type(item) == "table" and type(item.title) == "string" then
      local when = ""
      if type(item.fromTime) == "string" then
        when = item.fromTime
        if type(item.toTime) == "string" then
          when = when .. " - " .. item.toTime
        end
      end
      local isCurrent = snapshot.current ~= nil and snapshot.current.title == item.title and snapshot.current.fromTime == item.fromTime
      local weight = "normal"
      local color = "on_surface"
      if isCurrent then
        weight = "bold"
        color = "primary"
      end
      table.insert(rows, ui.column({ key = "sched:" .. tostring(i), gap = 2 }, {
        ui.label({ text = item.title, fontWeight = weight, color = color, textAlign = "end" }),
        ui.label({ text = when, color = "on_surface_variant", textAlign = "end" }),
      }))
    end
  end
  return ui.column({ gap = 12 }, rows)
end

function render()
  local playGlyph = "player-play"
  local playLabel = tr("panel.play")
  if snapshot.playing == true then
    playGlyph = "player-stop"
    playLabel = tr("panel.stop")
  end
  local playEnabled = snapshot.available ~= false and snapshot.busy ~= true

  local controls = {
    ui.row({ gap = 12, align = "center", justify = "end" }, {
      ui.button({ glyph = playGlyph, text = playLabel, variant = "primary", onClick = onPlayToggle, enabled = playEnabled }),
      ui.button({ glyph = "refresh", onClick = onRefresh, tooltip = tr("panel.refresh") }),
    }),
    ui.label({ text = statusText(), color = "on_surface_variant", textAlign = "end" }),
  }

  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(controls, ui.label({ text = snapshot.error, color = "error", textAlign = "end" }))
  end

  local cur = currentBlock()
  if cur ~= nil then
    table.insert(controls, ui.separator({ spacing = 4 }))
    table.insert(controls, cur)
  end

  panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.button({ glyph = "x", onClick = "onCloseClicked" }),
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1, textAlign = "end" }),
    }),
    ui.column({ gap = 8 }, controls),
    ui.scroll({ flexGrow = 1, gap = 12 }, {
      ui.label({ text = tr("panel.schedule"), fontWeight = "medium", color = "on_surface_variant", textAlign = "end" }),
      scheduleList(),
    }),
    ui.row({ gap = 12, align = "center", justify = "end" }, {
      ui.button({ glyph = "link", text = tr("panel.site"), onClick = onOpenSite, enabled = canOpenSite }),
      ui.button({ glyph = "copy", text = tr("panel.copy"), onClick = onCopyUrl }),
    }),
  }))
end

function onOpen(_context)
  request({ action = "refresh" })
  render()
end

noctalia.state.watch("misr_quran.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()
