--!nonstrict
-- Social Block panel: master switch, timers, focus stats, and one toggle per
-- service. Toggling a service OFF allows it (for example Slack or Discord at
-- work) without turning the whole block off. All colours are palette roles.

local PLUGIN = "treeonlinux/social-block"
local SERVICE = PLUGIN .. ":service"

local blocked = noctalia.state.get("blocked") == true
local untilMs = noctalia.state.get("untilMs") or 0
local remaining = noctalia.state.get("remaining") or 0
local since = noctalia.state.get("since") or 0
local todayMinutes = noctalia.state.get("todayMinutes") or 0
local streakDays = noctalia.state.get("streak") or 0
local graph = noctalia.state.get("graph") or { 0, 0, 0, 0, 0, 0, 0 }
local services = noctalia.state.get("services") or {}
local servicesLoaded = noctalia.state.get("servicesLoaded") == true
local setupRequired = noctalia.state.get("setupRequired") == true
local helperError = noctalia.state.get("helperError") or ""

local busy = false
local render
local onServiceToggle

local TOOL_FILE = "/etc/social-block/tool"

local function preferredTool()
  local raw = noctalia.readFile(TOOL_FILE)
  if raw then
    local t = (string.gsub(raw, "%s+", ""))
    if t == "sudo" and noctalia.commandExists("sudo") then return "sudo" end
    if t == "doas" and noctalia.commandExists("doas") then return "doas" end
  end
  return noctalia.commandExists("sudo") and "sudo" or "doas"
end

local function setupCommand(extra)
  local priv = preferredTool()
  local flag = (priv == "doas") and " --doas" or " --sudo"
  return [[bash -c 'installer="$(find -L "${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/plugins" "$HOME/.local/share/noctalia/plugins" -maxdepth 5 -name install-helper.sh -path "*social-block*" 2>/dev/null | head -n1)"; if [ -z "$installer" ]; then echo "Enable Social Block first, then re-run this command."; else cd "$(dirname "$installer")" && ]] .. priv .. [[ bash install-helper.sh]] .. flag .. (extra or "") .. [[; fi']]
end


local glyphs = {
  youtube = "brand-youtube", netflix = "brand-netflix", twitch = "brand-twitch",
  hulu = "device-tv", disneyplus = "device-tv", primevideo = "movie",
  max = "movie", peacock = "device-tv", paramountplus = "device-tv",
  crunchyroll = "movie", kick = "device-tv", rumble = "device-tv",
  vimeo = "movie", dailymotion = "movie", pluto = "device-tv",
  tubi = "device-tv", bilibili = "device-tv", iqiyi = "device-tv",
  youku = "device-tv",
  facebook = "brand-facebook", instagram = "brand-instagram", threads = "at",
  tiktok = "brand-tiktok", x = "brand-x", reddit = "brand-reddit",
  discord = "brand-discord", slack = "brand-slack", snapchat = "brand-snapchat",
  pinterest = "brand-pinterest", tumblr = "brand-tumblr",
  linkedin = "brand-linkedin", bluesky = "cloud", mastodon = "brand-mastodon",
  telegram = "brand-telegram", whatsapp = "brand-whatsapp", vk = "brand-vk",
  okru = "world", weibo = "world", douyin = "brand-tiktok",
  quora = "help-circle", ["9gag"] = "messages", ["4chan"] = "messages",
  lemmy = "world",
  tinder = "flame", bumble = "hexagon", hinge = "heart", okcupid = "heart",
  match = "heart", badoo = "heart",
  amazon = "brand-amazon", ebay = "brand-ebay", temu = "shopping-bag",
  aliexpress = "shopping-bag", shein = "shopping-bag", etsy = "shopping-bag",
  doh = "shield-lock",
}

local categoryRole = {
  Streaming = "error",
  Social = "primary",
  Forums = "secondary",
  Dating = "tertiary",
  Shopping = "on_surface_variant",
  Network = "error",
  Other = "on_surface_variant",
}

local function send(event, payload)
  if busy then return end
  busy = true
  local args = { "noctalia", "msg", "plugin", SERVICE, "all", event }
  if payload then args[#args + 1] = payload end
  local accepted = noctalia.runAsync(args, function()
    busy = false
    if render then render() end
  end)
  if not accepted then
    busy = false
    noctalia.notifyError("Social Block", "Could not reach the Social Block service.")
    if render then render() end
  end
end

onServiceToggle = function(id, shouldBlock)
  if busy then return end
  send(shouldBlock and "block" or "allow", id)
end

local function fmtMinutes(m)
  m = math.floor(m or 0)
  if m >= 60 then
    return string.format("%dh %02dm", m // 60, m % 60)
  end
  return m .. "m"
end

local function blockedCount()
  local n = 0
  for _, s in ipairs(services) do
    if s.blocked and (s.count or 0) > 0 then n = n + 1 end
  end
  return n
end

local function statusText()
  if not blocked then
    return "Off · one tap to shut the noise off"
  end
  if untilMs > 0 then
    return "Blocking · " .. remaining .. "m left"
  end
  if since and since > 0 then
    return "Blocking since " .. noctalia.formatTime("%H:%M", since // 1000)
  end
  return "Blocking until you turn it off"
end

local function serviceRow(s)
  local glyph = glyphs[s.id] or "world"
  local role = categoryRole[s.category] or "on_surface_variant"
  return ui.row({
    key = "svc-" .. s.id,
    fill = "surface_container",
    radius = 10,
    paddingH = 12,
    paddingV = 8,
    align = "center",
    gap = 10,
  }, {
    ui.glyph({ name = glyph, size = 16, color = role }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = s.name, color = "on_surface", fontSize = 13 }),
      ui.label({
        text = tostring(s.count or 0) .. " domain" .. ((s.count or 0) == 1 and "" or "s"),
        fontSize = 10,
        color = "on_surface_variant",
      }),
    }),
    ui.label({
      text = s.blocked and "blocked" or "allowed",
      fontSize = 10,
      fontWeight = "medium",
      color = s.blocked and "error" or "on_surface_variant",
    }),
    ui.toggle({
      key = "toggle-" .. s.id,
      checked = s.blocked == true,
      enabled = not busy,
      onChange = function(value)
        onServiceToggle(s.id, value == "true")
      end,
    }),
  })
end

local function setupCard()
  return ui.column({
    fill = "error/0.12",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 6,
  }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "tool", size = 16, color = "error" }),
      ui.label({ text = "Finish setup", fontWeight = "bold", color = "on_surface" }),
    }),
    ui.label({
      text = "Install the root helper once. Run this in a terminal, then press Re-check:",
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 3,
    }),
    ui.label({
      text = helperError ~= "" and helperError or "The helper or its privilege rule is missing.",
      fontSize = 10,
      color = "error",
      maxLines = 3,
    }),
    ui.label({
      text = setupCommand(""),
      fontSize = 9,
      color = "on_surface_variant",
      maxLines = 4,
    }),
    ui.row({ gap = 8 }, {
      ui.button({
        text = "Copy command",
        glyph = "copy",
        variant = "outline",
        controlSize = "sm",
        onClick = "onCopySetup",
      }),
      ui.button({
        text = "Re-check",
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        onClick = "onRecheck",
      }),
    }),
  })
end

local function errorCard()
  return ui.column({
    fill = "error/0.12",
    radius = 12,
    paddingH = 14,
    paddingV = 10,
    gap = 5,
  }, {
    ui.label({ text = "Helper problem", fontSize = 12, fontWeight = "bold", color = "error" }),
    ui.label({ text = helperError, fontSize = 10, color = "on_surface_variant", maxLines = 4 }),
    ui.row({ gap = 8 }, {
      ui.button({
        text = "Copy update command",
        glyph = "copy",
        variant = "outline",
        controlSize = "sm",
        onClick = "onCopyUpdate",
      }),
      ui.button({
        text = "Re-check",
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        onClick = "onRecheck",
      }),
    }),
  })
end

render = function()
  local rows = {}
  local lastCategory = nil
  for _, s in ipairs(services) do
    if s.category ~= lastCategory then
      table.insert(rows, ui.label({
        text = s.category,
        fontSize = 11,
        fontWeight = "medium",
        color = "on_surface_variant",
      }))
      lastCategory = s.category
    end
    table.insert(rows, serviceRow(s))
  end

  local total = #services
  local active = blockedCount()
  local summary
  if total == 0 then
    summary = "No services loaded"
  elseif not blocked and active == 0 then
    summary = "Allow at least one service"
  elseif not blocked then
    summary = (active == total)
      and ("All " .. total .. " services selected")
      or (active .. " of " .. total .. " services selected")
  elseif active == total then
    summary = "All " .. total .. " services blocked"
  else
    summary = active .. " of " .. total .. " services blocked"
  end

  local children = {
    -- Header
    ui.row({ align = "center", gap = 12 }, {
      ui.row({
        fill = blocked and "error/0.16" or "primary/0.16",
        radius = 12,
        paddingH = 10,
        paddingV = 10,
        align = "center",
        justify = "center",
      }, {
        ui.glyph({
          name = blocked and "shield-lock" or "shield",
          size = 22,
          color = blocked and "error" or "primary",
        }),
      }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = "Social Block", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = statusText(), fontSize = 12, color = "on_surface_variant" }),
      }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onCloseClicked" }),
    }),

    -- Master switch
    ui.row({
      fill = "surface_container",
      radius = 12,
      paddingH = 14,
      paddingV = 12,
      align = "center",
      justify = "space_between",
    }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = "Block now", fontWeight = "medium", color = "on_surface" }),
        ui.label({ text = summary, fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.toggle({
        checked = blocked,
        enabled = not busy and (blocked or total == 0 or active > 0),
        onChange = "onToggle",
      }),
    }),

    -- Session timer
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = blocked and "Extend session" or "Session length", fontSize = 12, color = "on_surface_variant", fontWeight = "medium" }),
      ui.row({ gap = 6 }, {
        ui.button({ text = blocked and "+15m" or "15m", variant = "outline", controlSize = "sm", enabled = not busy, onClick = "onTimer15" }),
        ui.button({ text = blocked and "+30m" or "30m", variant = "outline", controlSize = "sm", enabled = not busy, onClick = "onTimer30" }),
        ui.button({ text = blocked and "+1h" or "1h", variant = "outline", controlSize = "sm", enabled = not busy, onClick = "onTimer60" }),
        ui.button({ text = "∞", variant = "outline", controlSize = "sm", enabled = not busy, onClick = "onForever" }),
      }),
    }),

    -- Today / streak / graph
    ui.row({
      fill = "surface_container",
      radius = 12,
      paddingH = 14,
      paddingV = 10,
      align = "center",
      gap = 12,
    }, {
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = "Today", fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = fmtMinutes(todayMinutes), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
        ui.label({
          text = streakDays > 0 and (streakDays .. " day streak") or "start a streak",
          fontSize = 11,
          color = streakDays > 0 and "primary" or "on_surface_variant",
        }),
      }),
      ui.graph({ values = graph, width = 120, height = 42, color = "primary", fillOpacity = 0.25 }),
    }),

    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Services", fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
      ui.label({
        text = "toggle off to allow",
        fontSize = 10,
        color = "on_surface_variant",
      }),
    }),
  }

  if setupRequired then
    table.insert(children, setupCard())
  elseif helperError ~= "" then
    table.insert(children, errorCard())
  end

  if not servicesLoaded and total == 0 then
    table.insert(children, ui.label({
      text = "Loading services…",
      fontSize = 11,
      color = "on_surface_variant",
    }))
  elseif servicesLoaded and total == 0 and not setupRequired then
    table.insert(children, ui.label({
      text = "No services found. Check /etc/social-block/domains and re-run install-helper.sh.",
      fontSize = 11,
      color = "error",
      maxLines = 3,
    }))
  end

  table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, rows))

  table.insert(children, ui.label({
    text = "Allowed services are skipped in /etc/hosts. DoT, hard-coded resolvers and proxies can still bypass hosts.",
    fontSize = 9,
    color = "outline_variant",
    maxLines = 3,
  }))

  table.insert(children, ui.row({ gap = 8, justify = "space_between" }, {
    ui.button({ text = "Settings", glyph = "settings", variant = "ghost", onClick = "onSettings" }),
    ui.button({
      text = blocked and "Turn off" or "Turn on",
      glyph = blocked and "shield-off" or "shield-lock",
      variant = blocked and "destructive" or "primary",
      enabled = not busy and (blocked or total == 0 or active > 0),
      onClick = "onToggleButton",
    }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 14 }, children))
end

function onToggle(value)
  local on
  if type(value) == "boolean" then
    on = value
  else
    on = tostring(value) == "true"
  end
  send(on and "on" or "off")
end

function onToggleButton()
  send(blocked and "off" or "on")
end

function onTimer15() send("timer", "15") end
function onTimer30() send("timer", "30") end
function onTimer60() send("timer", "60") end

function onForever()
  if blocked then
    send("forever")
  else
    send("on")
  end
end

function onCopySetup()
  noctalia.copyToClipboard(setupCommand(""), "text/plain")
  noctalia.notify("Social Block", "Install command copied. Run it in a terminal, then press Re-check.")
end

function onCopyUpdate()
  noctalia.copyToClipboard(setupCommand(" --update-domains"), "text/plain")
  noctalia.notify("Social Block", "Update command copied. Run it in a terminal, then press Re-check.")
end

function onRecheck()
  send("refresh")
end

function onSettings()
  noctalia.openSettings()
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  render()
  noctalia.runAsync({ "noctalia", "msg", "plugin", SERVICE, "all", "services" })
end

noctalia.state.watch("blocked", function(v) blocked = v == true; render() end)
noctalia.state.watch("remaining", function(v) remaining = v or 0; render() end)
noctalia.state.watch("untilMs", function(v) untilMs = v or 0; render() end)
noctalia.state.watch("since", function(v) since = v or 0; render() end)
noctalia.state.watch("todayMinutes", function(v) todayMinutes = v or 0; render() end)
noctalia.state.watch("streak", function(v) streakDays = v or 0; render() end)
noctalia.state.watch("graph", function(v) graph = v or graph; render() end)
noctalia.state.watch("services", function(v) services = v or {}; render() end)
noctalia.state.watch("servicesLoaded", function(v) servicesLoaded = v == true; render() end)
noctalia.state.watch("setupRequired", function(v) setupRequired = v == true; render() end)
noctalia.state.watch("helperError", function(v) helperError = v or ""; render() end)

render()
