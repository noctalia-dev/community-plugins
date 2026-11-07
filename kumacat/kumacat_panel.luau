--!nonstrict
-- KumaCat Telemetry HUD Panel: interactive popout showing hardware telemetry,
-- runner status, and live gauges synced with the bar widget.

local catFont = noctalia.loadFont("fonts/kumacat.otf")

local snapshot = nil
local petCount = 0

local function gaugeBar(label, pct, detail, color)
  local safePct = math.clamp(pct or 0, 0, 100)
  return ui.column({ gap = 3, align = "stretch" }, {
    ui.row({ align = "center" }, {
      ui.label({ text = label, fontSize = 12, fontWeight = "medium" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = detail or `{safePct}%`, fontSize = 12, fontWeight = "bold", color = color or "primary" }),
    }),
    ui.progress({
      progress = safePct / 100,
      fill = color or "primary",
      track = "surface_container",
      height = 5,
      radius = 2,
    }),
  })
end

local function render()
  local glyph = snapshot and snapshot.glyph or "a"
  local color = snapshot and snapshot.color or "secondary"
  local pace = snapshot and snapshot.pace or "sleep"
  local cpu = snapshot and snapshot.cpuPercent or 0
  local cpuTemp = snapshot and snapshot.cpuTemp
  local memPct = snapshot and snapshot.memPercent or 0
  local memUsed = snapshot and snapshot.memUsedGiB or 0
  local memTotal = snapshot and snapshot.memTotalGiB or 0
  local gpu = snapshot and snapshot.gpuPercent or 0
  local gpuTemp = snapshot and snapshot.gpuTemp

  local paceBadge = "Idle Sleep"
  if pace == "walk" then
    paceBadge = "Walking"
  elseif pace == "sprint" then
    paceBadge = "Sprinting"
  end

  local cpuDetail = `{cpu}%`
  if cpuTemp then
    cpuDetail ..= ` ({math.floor(cpuTemp)}°C)`
  end

  local memDetail = string.format("%.1f/%.1f GiB", memUsed, memTotal)
  local gpuDetail = `{gpu}%`
  if gpuTemp then
    gpuDetail ..= ` ({math.floor(gpuTemp)}°C)`
  end

  local children = {
    -- Header Row: Runner glyph + Pace status
    ui.row({ align = "center", gap = 12 }, {
      ui.label({
        text = glyph,
        fontFamily = catFont,
        baseline = "inkCentered",
        fontSize = 56,
        color = color,
      }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = "KumaCat", fontSize = 16, fontWeight = "bold" }),
        ui.row({ gap = 6, align = "center" }, {
          ui.box({
            width = 8,
            height = 8,
            radius = 4,
            fill = pace == "sleep" and "on_surface_variant" or color,
          }),
          ui.label({
            text = paceBadge,
            fontSize = 12,
            color = pace == "sleep" and "on_surface_variant" or color,
          }),
        }),
        petCount > 0 and ui.label({
          text = `Petted {petCount} time{petCount == 1 and "" or "s"}`,
          fontSize = 11,
          color = "secondary",
        }) or nil,
      }),
    }),

    -- Hardware Telemetry Cards
    ui.column({ gap = 8, align = "stretch", padding = 8, radius = 8, fill = "surface_container_low" }, {
      gaugeBar("CPU", cpu, cpuDetail, color),
      gaugeBar("Memory", memPct, memDetail, "primary"),
      (gpu > 0 or gpuTemp ~= nil) and gaugeBar("GPU", gpu, gpuDetail, "tertiary") or nil,
    }),

    -- Quick Action: Pet button
    ui.row({ align = "center", justify = "center" }, {
      ui.button({
        text = "Pet Kuma",
        glyph = "heart",
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          petCount += 1
          render()
        end,
      }),
    }),
  }

  panel.render(ui.column({ gap = 12, padding = 14, align = "stretch" }, children))
end

noctalia.state.watch("kumacat", function(value)
  snapshot = value
  render()
end)

function onOpen()
  snapshot = noctalia.state.get("kumacat")
  render()
end
