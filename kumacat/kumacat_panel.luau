--!nonstrict
-- KumaCat HUD panel: mirrors the bar runner from shared state so both surfaces
-- stay frame-synchronized without running a second timer in the panel runtime.

local catFont = noctalia.loadFont("fonts/kumacat.otf")

local STYLE_NAMES = {
  ["flash-cat"] = "Flash Cat",
  ["cat-tail"] = "Cat's Tail",
  ["classic-cat"] = "Classic Cat",
}

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
  local runnerStyle = snapshot and snapshot.runnerStyle or "flash-cat"
  local glyph = snapshot and snapshot.glyph or "a"
  local imagePath = snapshot and snapshot.imagePath or (snapshot == nil and "runners/sleep.png" or nil)
  local imageAspect = snapshot and snapshot.imageAspect or 1
  local color = snapshot and snapshot.color or "secondary"
  local pace = snapshot and snapshot.pace or "sleep"
  local cpu = snapshot and snapshot.cpuPercent or 0
  local cpuTemp = snapshot and snapshot.cpuTemp
  local ramPct = snapshot and snapshot.ramPercent or 0
  local ramUsed = snapshot and snapshot.ramUsedGiB or 0
  local ramTotal = snapshot and snapshot.ramTotalGiB or 0
  local gpu = snapshot and snapshot.gpuPercent or 0
  local gpuTemp = snapshot and snapshot.gpuTemp

  local paceBadge = "Idle Sleep (0 FPS)"
  if pace == "walk" then
    paceBadge = "Active Pace"
  elseif pace == "sprint" then
    paceBadge = "Turbo Sprint"
  end

  local cpuDetail = `{cpu}%`
  if cpuTemp then
    cpuDetail ..= ` ({math.floor(cpuTemp)}°C)`
  end

  local ramDetail = ramTotal > 0 and string.format("%.1f / %.1f GiB", ramUsed, ramTotal) or `{ramPct}%`
  local gpuDetail = `{gpu}%`
  if gpuTemp then
    gpuDetail ..= ` ({math.floor(gpuTemp)}°C)`
  end

  local previewNode
  if imagePath then
    local h = 42
    previewNode = ui.image({
      path = imagePath,
      width = math.max(42, math.floor(h * imageAspect + 0.5)),
      height = h,
      fit = "contain",
    })
  else
    previewNode = ui.label({
      text = glyph,
      fontFamily = catFont,
      baseline = "inkCentered",
      fontSize = 52,
      color = color,
    })
  end

  local titleText = STYLE_NAMES[runnerStyle] or "KumaCat"
  local children = {
    ui.row({ align = "center", gap = 12 }, {
      previewNode,
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = titleText, fontSize = 15, fontWeight = "bold" }),
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

    ui.column({ gap = 8, align = "stretch", padding = 10, radius = 8, fill = "surface_container_low" }, {
      gaugeBar("CPU", cpu, cpuDetail, color),
      gaugeBar("Memory", ramPct, ramDetail, "primary"),
      (gpu > 0 or gpuTemp ~= nil) and gaugeBar("GPU", gpu, gpuDetail, "tertiary") or nil,
    }),

    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
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
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Plugin Settings",
        onClick = function()
          noctalia.openSettings()
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

-- Request GPU sampling only while the HUD is open, and release on close (API 46).
function onOpen()
  if noctalia.setGpuMonitoring ~= nil then
    noctalia.setGpuMonitoring(true)
  end
  snapshot = noctalia.state.get("kumacat")
  render()
end

function onClose()
  if noctalia.setGpuMonitoring ~= nil then
    noctalia.setGpuMonitoring(false)
  end
end
