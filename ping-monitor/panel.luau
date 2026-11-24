--!nonstrict
-- Ping Monitor panel: devices (sound, interval, remove), add form, per-device activity graph.
local shared = require("./shared.luau")
local store = require("./store.luau")

local newName, newIp = "", ""

local function fmt(epoch)
  if not epoch or epoch == 0 then return "—" end
  return noctalia.formatTime("%d.%m %H:%M:%S", epoch)
end

local function changed(cfg)
  store.saveConfig(cfg)
  noctalia.state.set("cfg_rev", noctalia.nowMs())
end

local draw

local function deviceCard(s, d, index)
  local color = shared.color(d.status)
  local intervalOptions = {}
  for _, v in store.INTERVALS do
    table.insert(intervalOptions, v .. " " .. noctalia.tr("panel.sec"))
  end

  local bars = {}
  local now = math.floor(noctalia.nowMs() / 1000)
  for i = s.days - 1, 0, -1 do
    local t = now - i * 86400
    local online = d.history[noctalia.formatTime("%Y-%m-%d", t)] == true
    table.insert(bars, ui.column({ gap = 2, align = "center", width = 14 }, {
      ui.box({ fill = online and "primary" or "outline_variant", radius = 2, width = 11, height = online and 18 or 5 }),
      ui.label({ text = noctalia.formatTime("%-d", t), color = "on_surface_variant", fontSize = 7 }),
    }))
  end

  return ui.column({ key = "dev-" .. d.ip, gap = 6, padding = 10, fill = "surface_container", radius = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.box({ fill = color, radius = 5, width = 9, height = 9 }),
      ui.label({ text = shared.label(d), fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = noctalia.tr(d.status == "up" and "status.up" or (d.status == "down" and "status.down" or "status.checking")), color = color, fontSize = 12 }),
      ui.button({
        glyph = d.sound == false and "bell-off" or "bell", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("panel.device_sound"),
        onClick = function()
          local cfg = store.loadConfig()
          local dev = cfg.devices[index]
          if dev then dev.sound = (dev.sound == false) end
          changed(cfg)
          draw()
        end,
      }),
      ui.button({
        glyph = "trash", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.remove"),
        onClick = function()
          local cfg = store.loadConfig()
          table.remove(cfg.devices, index)
          changed(cfg)
          draw()
        end,
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("panel.interval"), color = "on_surface_variant", fontSize = 12, flexGrow = 1 }),
      ui.select({
        options = intervalOptions, selectedIndex = store.intervalIndex(d.interval) - 1, controlSize = "sm", width = 130,
        onChange = function(i)
          local cfg = store.loadConfig()
          local dev = cfg.devices[index]
          if dev then dev.interval = store.INTERVALS[(tonumber(i) or 2) + 1] or 15 end
          changed(cfg)
        end,
      }),
    }),
    ui.label({ text = noctalia.tr("panel.last_ping") .. " " .. fmt(d.lastPing), color = "on_surface_variant", fontSize = 11 }),
    ui.row({ gap = 2, justify = "start" }, bars),
  })
end

draw = function()
  local s = shared.snapshot()
  local cards = {}
  for i, d in s.devices do
    table.insert(cards, deviceCard(s, d, i))
  end

  panel.render(ui.column({ gap = 10, padding = 16 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "server", size = 18, color = shared.color(shared.overall(s.devices)) }),
      ui.label({ text = "Ping Monitor", fontWeight = "bold", fontSize = 15, flexGrow = 1 }),
      ui.label({ text = noctalia.tr("panel.sound"), color = "on_surface_variant", fontSize = 12 }),
      ui.toggle({
        checked = not s.muted,
        onChange = function(on)
          local cfg = store.loadConfig()
          cfg.muted = not (on == "true" or on == true)
          changed(cfg)
          draw()
        end,
      }),
    }),
    ui.scroll(#cards > 2 and { gap = 8, height = 380 } or { gap = 8 }, cards),
    ui.separator({}),
    ui.label({ text = noctalia.tr("panel.add"), color = "on_surface_variant", fontSize = 12 }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = "new-name", placeholder = noctalia.tr("panel.name"), value = newName, controlSize = "sm", flexGrow = 1, onChange = function(v) newName = v end }),
      ui.input({ key = "new-ip", placeholder = "IP / host", value = newIp, controlSize = "sm", flexGrow = 1, onChange = function(v) newIp = v end }),
      ui.button({
        glyph = "plus", variant = "primary", controlSize = "sm", tooltip = noctalia.tr("panel.add_button"),
        onClick = function()
          local ip = string.gsub(newIp or "", "%s", "")
          if ip == "" then return end
          local cfg = store.loadConfig()
          table.insert(cfg.devices, { name = newName or "", ip = ip, interval = 15, sound = true })
          newName, newIp = "", ""
          changed(cfg)
          draw()
        end,
      }),
    }),
  }))
end

function onOpen()
  draw()
end

noctalia.state.watch("snap", function() draw() end)
