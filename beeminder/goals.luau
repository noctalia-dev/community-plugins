--!nonstrict
local shared = require("./shared.luau")

local isOpen = false

local function openAndClose(url)
  shared.openUrl(url)
  panel.close()
end

local function header(report)
  local subtitle = nil
  if report ~= nil and report.fetchedAt ~= nil then
    subtitle = noctalia.tr("panel.updated", { age = shared.formatAge(report.fetchedAt) })
  end
  return ui.row({ align = "center", gap = 8 }, {
    ui.image({ path = "icons/bee-gray.svg", width = 22, height = 22 }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = subtitle or "", fontSize = 11, color = "on_surface_variant", visible = subtitle ~= nil }),
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      tooltip = noctalia.tr("panel.refresh"),
      onClick = shared.requestRefresh,
    }),
    ui.button({ glyph = "x", variant = "ghost", onClick = function() panel.close() end }),
  })
end

local function errorBanner(report)
  local action
  if report.status == "no_token" or report.status == "unauthorized" then
    action = ui.button({
      text = noctalia.tr("panel.open_settings"),
      variant = "primary",
      onClick = function()
        noctalia.openSettings()
        panel.close()
      end,
    })
  else
    action = ui.button({ text = noctalia.tr("panel.retry"), onClick = shared.requestRefresh })
  end
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = "error/0.15" }, {
    ui.image({ path = shared.ICON_ERROR, width = 28, height = 28 }),
    ui.label({ text = shared.errorMessage(report), color = "on_surface", flexGrow = 1, maxLines = 3 }),
    action,
  })
end

local function goalRow(report, goal)
  local due = goal.safebuf <= 0
  local right = { ui.label({ text = shared.formatCountdown(goal.losedate), fontWeight = "medium", color = due and "error" or "on_surface", textAlign = "end" }) }
  if goal.pledge > 0 then
    table.insert(right, ui.label({ text = shared.formatMoney(goal.pledge), fontSize = 11, color = "on_surface_variant", textAlign = "end" }))
  end

  local canOpen = report.username ~= nil
  return ui.row({
    key = goal.slug,
    gap = 10,
    align = "center",
    paddingH = 8,
    paddingV = 6,
    radius = 8,
    opacity = shared.isInactive(goal) and 0.5 or 1,
    onClick = canOpen and function()
      openAndClose(shared.goalUrl(report.username, goal.slug))
    end or nil,
  }, {
    ui.image({ path = shared.iconFor(goal.colorkey), width = 24, height = 24 }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = goal.title, fontWeight = "medium", color = "on_surface", maxLines = 1 }),
      ui.label({ text = goal.limsum, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.column({ gap = 2, align = "end" }, right),
  })
end

local function render()
  if not isOpen then
    return
  end
  local report = shared.report()
  local children = { header(report) }

  if report == nil then
    table.insert(children, ui.label({ text = noctalia.tr("bar.loading"), color = "on_surface_variant" }))
  else
    if report.status ~= "ok" then
      table.insert(children, errorBanner(report))
    end
    local goals = report.goals or {}
    if #goals == 0 and report.status == "ok" then
      table.insert(children, ui.label({ text = noctalia.tr("bar.no_goals"), color = "on_surface_variant" }))
    elseif #goals > 0 then
      local rows = {}
      for _, goal in ipairs(goals) do
        table.insert(rows, goalRow(report, goal))
      end
      table.insert(children, ui.scroll({ flexGrow = 1, gap = 2 }, rows))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, children))
end

noctalia.state.watch("report", function(_)
  render()
end)

function update()
  render()
end

function onOpen(_context)
  isOpen = true
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  isOpen = false
  panel.setWantsSecondTicks(false)
end
