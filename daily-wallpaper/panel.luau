--!nonstrict
-- Daily Wallpaper panel — today's full caption, credit, and a "learn more"
-- link out to the source's own page for it (Bing's quiz page, or NASA's full
-- article). Opens on a bar-widget click, or via
-- `noctalia msg panel-toggle nzlov/daily-wallpaper:panel`. Pure subscriber of
-- daily_wallpaper.luau's "today"/"status" state; the refresh button just asks
-- the service to re-check now (onIpc "refresh").

local function tr(key, args) return noctalia.tr(key, args) end

local WRAP = 380

local SOURCE_LABEL = { bing = "Bing", nasa = "NASA" }

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function render()
  local today = noctalia.state.get("today")
  local status = noctalia.state.get("status")

  local rows = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
  }

  if type(today) ~= "table" or type(today.title) ~= "string" or today.title == "" then
    local msg = (type(status) == "table" and status.state == "error")
        and (status.message or tr("panel.error"))
        or tr("panel.loading")
    rows[#rows + 1] = ui.label({ text = msg, maxWidth = WRAP, opacity = 0.7 })
  else
    rows[#rows + 1] = ui.label({ text = today.title, fontSize = 15, fontWeight = "medium", maxWidth = WRAP })
    if today.credit and today.credit ~= "" then
      rows[#rows + 1] = ui.label({ text = today.credit, maxWidth = WRAP, opacity = 0.7 })
    end
    local sourceLabel = SOURCE_LABEL[today.source] or today.source or "?"
    rows[#rows + 1] = ui.label({
      text = tr("panel.date", { source = sourceLabel, date = today.date }),
      maxWidth = WRAP, fontSize = 12, opacity = 0.6,
    })
    if today.link and today.link ~= "" then
      rows[#rows + 1] = ui.button({ text = tr("panel.learn_more"), variant = "ghost", onClick = "onOpenLink" })
    end
  end

  panel.render(ui.column({ padding = 14, gap = 10, flexGrow = 1 }, rows))
end

function onOpen(_context)
  render()
end

function onCloseClicked()
  panel.close()
end

function onRefresh()
  noctalia.runAsync("noctalia msg plugin 'nzlov/daily-wallpaper:service' all refresh")
end

function onOpenLink()
  local today = noctalia.state.get("today")
  if type(today) == "table" and type(today.link) == "string" and today.link ~= "" then
    noctalia.runAsync("xdg-open " .. shellQuote(today.link) .. " >/dev/null 2>&1")
  end
end

noctalia.state.watch("today", render)
noctalia.state.watch("status", render)
