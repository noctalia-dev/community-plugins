--!nonstrict
-- panel.luau — main VPN UI. Multi-view single panel:
--   view = "main" | "editor" | "rules" | "logs"
-- Value-driven: every render reads current state; controls report changes
-- through named global callbacks. ui.input is uncontrolled (value seeds once,
-- edits flow through onChange into the module-level `form` table).

local MAX_ROWS  = 20          -- clickable server rows
local MAX_PRE   = 8           -- preset toggles
local MAX_RULE  = 20          -- custom rule rows
local MAX_SUB   = 12          -- subscription rows
local nonce     = 0

local view      = "main"
local slotIds   = {}          -- server row slot -> id
local presetKeys = {}         -- preset slot -> key
local ruleIds   = {}          -- rule slot -> id

-- editor form
local form      = {}
local formProto = "ssh"
local editingId = nil
local formRev   = 0           -- bumps to reset ui.input identity on open

-- add-rule form
local ruleForm  = { pattern = "", type = "force-proxy" }
local ruleRev   = 0

-- subscriptions
local subUrls   = {}          -- sub slot -> url
local subForm   = { url = "", name = "" }
local subRev    = 0

local resetArmed = false      -- "Reset all servers" waits for a second click

local PROTOS = { "ssh", "vless", "vmess", "shadowsocks", "socks5" }
local TRANSPORTS = { "tcp", "ws", "grpc", "http" }
local SECURITIES = { "none", "tls", "reality" }
local RULE_TYPES = { "force-proxy", "direct", "block" }

-- ── design tokens ───────────────────────────────────────────────
-- The fixed olive/chartreuse palette gives the plugin its own visual identity.
local T = {
  bg         = "#1b1c17",
  card       = "#26271f",
  cardHi     = "#2e2f25",
  cardActive = "#34362a",
  border     = "#33342a",
  borderSoft = "#2a2b22",
  accent     = "#cfe04e",
  accentText = "#1b1c17",
  text       = "#e8e7df",
  textDim    = "#a3a497",
  muted      = "#7d7e71",
  success    = "#9bd17a",
  danger     = "#d68a7a",
  pingGood   = "#9bd17a",
  pingMid    = "#e0c84e",
  pingBad    = "#d68a7a",
}

-- Colour props take a role token or a plain hex. Flatten alpha against the
-- backdrop because alpha suffixes are only legal on theme roles.
local function mix(fg, bg, a)
  local function ch(h, i) return tonumber(h:sub(i, i + 1), 16) end
  local r = ch(bg, 2) + (ch(fg, 2) - ch(bg, 2)) * a
  local g = ch(bg, 4) + (ch(fg, 4) - ch(bg, 4)) * a
  local b = ch(bg, 6) + (ch(fg, 6) - ch(bg, 6)) * a
  return string.format("#%02x%02x%02x", math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
end

-- Protocol pill colours, alpha pre-flattened.
local PROTO_TAG = {
  SSH    = { fg = "#9ab7d1", a = 0.12 },
  VLESS  = { fg = "#cfe04e", a = 0.14 },
  VMess  = { fg = "#c18cd9", a = 0.14 },
  SS     = { fg = "#d99967", a = 0.14 },
  SOCKS5 = { fg = "#d99967", a = 0.14 },
}

local PROTO_LABEL = {
  ssh = "SSH", vless = "VLESS", vmess = "VMess",
  shadowsocks = "SS", socks5 = "SOCKS5",
}

-- ── command channel ─────────────────────────────────────────────
local function send(method, args)
  nonce = nonce + 1
  noctalia.state.set("cmd", {
    method = method, args = args or {},
    nonce = tostring(nonce) .. ":" .. tostring(os.time()),
  })
end

-- ── helpers ─────────────────────────────────────────────────────
local function indexOf(list, val, dflt)
  for i, v in ipairs(list) do if v == val then return i - 1 end end
  return dflt or 0
end

local function pingColor(ms)
  ms = tonumber(ms)
  if not ms or ms < 0 then return T.muted end
  if ms < 60 then return T.pingGood end
  if ms < 150 then return T.pingMid end
  return T.pingBad
end

-- Uppercase protocol pill.
local function protoTag(proto)
  local label = PROTO_LABEL[(proto or ""):lower()]
  if not label then return nil end
  local tag = PROTO_TAG[label]
  return ui.row({ fill = mix(tag.fg, T.card, tag.a), radius = 4, paddingH = 6, align = "center" }, {
    ui.label({ text = label:upper(), color = tag.fg, fontSize = 10, fontWeight = "bold" }),
  })
end

-- Coloured latency dot and milliseconds.
local function pingBadge(ms)
  return ui.row({ gap = 5, align = "center" }, {
    ui.box({ width = 6, height = 6, radius = 3, fill = pingColor(ms) }),
    ui.label({ text = tostring(ms) .. "ms", color = T.textDim, fontSize = 11 }),
  })
end

-- ISO-3166 alpha-2 to regional indicator pair.
local function flagFor(country)
  if type(country) ~= "string" or #country ~= 2 then return nil end
  local cc, out = country:upper(), ""
  for i = 1, 2 do
    local b = cc:byte(i)
    if b < 65 or b > 90 then return nil end
    out = out .. utf8.char(0x1F1E6 + b - 65)
  end
  return out
end

local function activeName(servers, id)
  for _, s in ipairs(servers) do if s.id == id then return s.name or s.id end end
  return nil
end

local function num(v, dflt) return tonumber(v) or dflt end

-- Leaving the view disarms the reset confirm; it must never survive a round trip.
local function navigate(v) view = v; resetArmed = false; render() end   -- render is assigned below

-- ── declared forward ────────────────────────────────────────────
render = nil

-- ================================================================
-- MAIN VIEW
-- ================================================================
-- Server row: status, flag, name, protocol, endpoint, latency and actions.
-- Row and column nodes do not accept onClick, so the name button and status
-- dot are the click targets.
local function serverRows(servers, status, running, health)
  local rows = {}
  slotIds = {}
  for i, s in ipairs(servers) do
    local slot = i - 1
    if slot >= MAX_ROWS then break end
    slotIds[slot] = s.id
    local isSelected = s.id == status.activeServerId
    local isActive   = isSelected and running

    local dot = (isActive and T.success) or (isSelected and mix(T.accent, T.bg, 0.7)) or T.border
    -- Keep idle rows transparent instead of painting over the panel.
    local fill = (isActive and T.cardActive) or (isSelected and mix(T.accent, T.bg, 0.05)) or nil
    local edge = (isActive and T.border) or (isSelected and mix(T.accent, T.bg, 0.4)) or nil

    local pick = "onServer" .. tostring(slot)
    local title = { ui.button({ text = s.name or s.id or noctalia.tr("panel.fallback-server-name"),
                                variant = "ghost", contentAlign = "start", onClick = pick }) }
    local tag = protoTag(s.protocol)
    if tag then title[#title + 1] = tag end

    local cells = { ui.box({ width = 7, height = 7, radius = 4, fill = dot, onClick = pick }) }
    local flag = flagFor(s.country)
    if flag then cells[#cells + 1] = ui.label({ text = flag, fontSize = 16 }) end
    cells[#cells + 1] = ui.column({ gap = 2, flexGrow = 1 }, {
      ui.row({ gap = 6, align = "center" }, title),
      -- Indent to clear the name button's own inner padding so the endpoint
      -- lines up under the name rather than under the button's edge.
      ui.row({ paddingH = 15 }, {
        ui.label({ text = s.host or s.address or "", color = T.muted, fontSize = 11, maxLines = 1 }),
      }),
    })
    if isActive and health.latency_ms and health.latency_ms > 0 then
      cells[#cells + 1] = pingBadge(health.latency_ms)
    end
    cells[#cells + 1] = ui.button({ glyph = "pencil", glyphSize = 13, variant = "ghost",
                                    onClick = "onEdit" .. tostring(slot) })
    cells[#cells + 1] = ui.button({ glyph = "trash", glyphSize = 13, variant = "ghost",
                                    onClick = "onDel" .. tostring(slot) })

    rows[#rows + 1] = ui.row({ gap = 10, align = "center", fill = fill, radius = 10,
                               border = edge, borderWidth = edge and 1 or nil,
                               paddingH = 12, paddingV = 10 }, cells)
  end
  if #rows == 0 then
    rows[1] = ui.row({ paddingH = 12, paddingV = 10 }, {
      ui.label({ text = noctalia.tr("panel.no-servers"), color = T.muted }),
    })
  end
  return rows
end

local function hero(status, backend, running)
  if not backend.ready then return "shield-off", T.muted end
  local level = status.statusLevel
  if running and (level == "error" or level == "failed") then return "alert-triangle", T.danger end
  if running and level == "degraded" then return "alert-circle", T.pingMid end
  if running then return "shield-check", T.success end
  return "shield-off", T.muted
end

local function mainView()
  local status  = noctalia.state.get("status") or {}
  local servers = noctalia.state.get("servers") or {}
  local health  = noctalia.state.get("health") or {}
  local backend = noctalia.state.get("backend") or {}
  local sp      = noctalia.state.get("speedtest") or {}
  local running = status.running == true

  local down = (sp.down_mbps and sp.down_mbps > 0) and sp.down_mbps or health.down_mbps
  local up   = (sp.up_mbps and sp.up_mbps > 0) and sp.up_mbps or health.up_mbps
  -- A finished test reports its own latency; prefer it over the background probe.
  local ping = (sp.ping_ms and sp.ping_ms > 0) and sp.ping_ms or health.latency_ms

  local heroGlyph, heroColor = hero(status, backend, running)

  local heroTitle
  if not backend.ready then
    heroTitle = noctalia.tr("panel.starting")
  elseif running then
    heroTitle = noctalia.tr("panel.connected")
  else
    heroTitle = noctalia.tr("panel.disconnected")
  end

  -- Active server subtitle.
  local heroSub = running and activeName(servers, status.activeServerId) or nil

  -- Telemetry line.
  local line2
  if not backend.ready then
    line2 = backend.error and ("backend: " .. backend.error) or ""
  elseif running and ping and ping > 0 then
    line2 = tostring(ping) .. " ms"
    if down and down > 0 then
      line2 = line2 .. "   ↓" .. string.format("%.1f", down)
              .. " ↑" .. string.format("%.1f", up or 0) .. " Mbps"
    end
  else
    line2 = ""
  end

  local heroHead = {
    ui.box({ width = 7, height = 7, radius = 4, fill = heroColor }),
    ui.label({ text = heroTitle, color = T.text, fontSize = 15, fontWeight = "semibold" }),
  }
  if heroSub then
    heroHead[#heroHead + 1] = ui.label({ text = "· " .. heroSub, color = T.muted,
                                         fontSize = 14, maxLines = 1, flexGrow = 1 })
  end

  local heroBody = { ui.row({ gap = 8, align = "center" }, heroHead) }
  if line2 ~= "" then
    heroBody[#heroBody + 1] = ui.label({ text = line2, color = T.textDim, fontSize = 12, maxLines = 1 })
  end

  -- No width here: the column fills the panel declared in plugin.toml, so the
  -- content uses the whole window instead of sitting in a 380px strip.
  return ui.column({ gap = 0, flexGrow = 1 }, {
    -- ── header ──────────────────────────────────────────────────
    ui.row({ gap = 8, align = "center", paddingH = 16, paddingV = 14 }, {
      ui.label({ text = noctalia.tr("title"), color = T.text, fontSize = 16,
                 fontWeight = "semibold", flexGrow = 1 }),
      ui.toggle({ checked = running, onChange = "onMaster" }),
      ui.button({ glyph = "cloud-download", glyphSize = 15, variant = "ghost", onClick = "onOpenSubs" }),
      ui.button({ glyph = "file-text", glyphSize = 15, variant = "ghost", onClick = "onOpenLogs" }),
      ui.button({ glyph = "settings", glyphSize = 15, variant = "ghost", onClick = "onOpenRules" }),
      ui.button({ glyph = "x", glyphSize = 15, variant = "ghost", onClick = "onClosePanel" }),
    }),
    ui.separator({}),

    ui.column({ gap = 14, paddingH = 16, paddingV = 14, flexGrow = 1 }, {
      -- ── status hero card ──────────────────────────────────────
      ui.row({ gap = 14, align = "center", fill = T.card, radius = 14,
               border = T.borderSoft, borderWidth = 1, paddingH = 16, paddingV = 14 }, {
        ui.row({ fill = mix(heroColor, T.card, 0.14), radius = 12,
                 border = mix(heroColor, T.card, 0.28), borderWidth = 1,
                 paddingH = 10, paddingV = 10, align = "center" }, {
          ui.glyph({ name = heroGlyph, size = 22, color = heroColor }),
        }),
        ui.column({ gap = 3, flexGrow = 1 }, heroBody),
        -- Single test button, in the hero's right corner: it drives both
        -- numbers shown to its left (latency and throughput).
        ui.button({ text = noctalia.tr("action.run-test"), glyph = "gauge", glyphSize = 14,
                    variant = "outline", onClick = "onRunTest", enabled = backend.ready == true }),
      }),

      -- ── mode chips ────────────────────────────────────────────
      ui.row({ gap = 10 }, {
        ui.column({ gap = 4, flexGrow = 1 }, {
          ui.label({ text = noctalia.tr("panel.routing"), fontSize = 11, color = T.muted }),
          ui.select({ selectedIndex = (status.mode == "global") and 1 or 0,
                      options = { "rules", "global" }, onChange = "onMode", flexGrow = 1 }),
        }),
        ui.column({ gap = 4, flexGrow = 1 }, {
          ui.label({ text = noctalia.tr("panel.via"), fontSize = 11, color = T.muted }),
          ui.select({ selectedIndex = (status.proxyMode == "tun") and 1 or 0,
                      options = { "system", "tun" }, onChange = "onVia", flexGrow = 1 }),
        }),
      }),

      -- ── servers ───────────────────────────────────────────────
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = noctalia.tr("panel.servers") .. " (" .. tostring(#servers) .. ")",
                   fontSize = 12, color = T.muted, flexGrow = 1 }),
        ui.button({ glyph = "clipboard", glyphSize = 14, variant = "ghost", onClick = "onImportClip" }),
        ui.button({ text = noctalia.tr("action.add"), glyph = "plus", glyphSize = 14,
                    variant = "primary", onClick = "onAddServer" }),
      }),
      -- flexGrow, not a fixed height: the list takes whatever vertical space
      -- is left so the panel has no dead area at the bottom.
      ui.scroll({ flexGrow = 1, gap = 4 }, { ui.column({ gap = 4 }, serverRows(servers, status, running, health)) }),
    }),
  })
end

-- ================================================================
-- EDITOR VIEW
-- ================================================================
local function field(key, labelKey, placeholder)
  return ui.column({ gap = 2 }, {
    ui.label({ text = noctalia.tr(labelKey), fontSize = 11, color = T.muted }),
    ui.input({ key = "fld-" .. key .. "-" .. formRev, value = tostring(form[key] or ""),
               placeholder = placeholder or "", onChange = "onFld_" .. key, flexGrow = 1 }),
  })
end

local function protoFields()
  local p = formProto
  -- GetServers strips secrets, so an edited server's password/uuid arrive
  -- empty; the backend keeps the stored value when they stay empty on save.
  local keep = editingId and noctalia.tr("editor.keep") or nil
  local f = {}
  if p == "ssh" then
    f = { field("host", "editor.host", "1.2.3.4"), field("port", "editor.port", "22"),
          field("user", "editor.user", "root"), field("password", "editor.password", keep),
          field("keyFile", "editor.keyfile", "~/.ssh/id_ed25519") }
  elseif p == "vless" then
    f = { field("address", "editor.address"), field("port", "editor.port"),
          field("uuid", "editor.uuid", keep),
          ui.column({ gap = 2 }, { ui.label({ text = noctalia.tr("editor.transport"), fontSize = 11, color = T.muted }),
            ui.select({ selectedIndex = indexOf(TRANSPORTS, form.transport, 0), options = TRANSPORTS, onChange = "onFldTransport", flexGrow = 1 }) }),
          ui.column({ gap = 2 }, { ui.label({ text = noctalia.tr("editor.security"), fontSize = 11, color = T.muted }),
            ui.select({ selectedIndex = indexOf(SECURITIES, form.security, 0), options = SECURITIES, onChange = "onFldSecurity", flexGrow = 1 }) }),
          field("sni", "editor.sni"), field("flow", "editor.flow"),
          field("pbk", "editor.pbk"), field("sid", "editor.sid"), field("fp", "editor.fp"),
          field("path", "editor.path"), field("host", "editor.wshost") }
  elseif p == "vmess" then
    f = { field("address", "editor.address"), field("port", "editor.port"),
          field("uuid", "editor.uuid", keep), field("alterId", "editor.alterid", "0"),
          ui.column({ gap = 2 }, { ui.label({ text = noctalia.tr("editor.transport"), fontSize = 11, color = T.muted }),
            ui.select({ selectedIndex = indexOf(TRANSPORTS, form.transport, 0), options = TRANSPORTS, onChange = "onFldTransport", flexGrow = 1 }) }),
          field("sni", "editor.sni"), field("path", "editor.path"), field("host", "editor.wshost") }
  elseif p == "shadowsocks" then
    f = { field("address", "editor.address"), field("port", "editor.port"),
          field("method", "editor.method", "aes-256-gcm"), field("password", "editor.password", keep) }
  elseif p == "socks5" then
    f = { field("host", "editor.host"), field("port", "editor.port"),
          field("username", "editor.user"), field("password", "editor.password", keep) }
  end
  return f
end

local function editorView()
  local children = {
    ui.column({ gap = 2 }, {
      ui.label({ text = noctalia.tr("editor.protocol"), fontSize = 11, color = T.muted }),
      ui.select({ selectedIndex = indexOf(PROTOS, formProto, 0), options = PROTOS,
                  onChange = "onFldProto", flexGrow = 1, enabled = editingId == nil }),
    }),
    field("name", "editor.name", "my server"),
    -- The flag in the server row comes from here. Nothing in the backend ever
    -- derives a country (the models have no such field; they just accept extra
    -- keys), so without this input flagFor() had no data and the flag could
    -- never render.
    field("country", "editor.country", "fi"),
  }
  for _, f in ipairs(protoFields()) do children[#children + 1] = f end
  children[#children + 1] = ui.separator({})
  children[#children + 1] = ui.row({ gap = 8 }, {
    ui.button({ text = noctalia.tr("action.save"), glyph = "check", variant = "primary", onClick = "onSave" }),
    ui.spacer({}),
    editingId and ui.button({ text = noctalia.tr("action.delete"), glyph = "trash", glyphSize = 13,
                              variant = "outline", onClick = "onDelete" }) or ui.spacer({}),
  })
  -- Header outside the scroll, scroll on flexGrow: a fixed scroll height
  -- overflowed the panel instead of clipping, leaving Save unreachable.
  return ui.column({ gap = 10, padding = 16, flexGrow = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", onClick = "onBack" }),
      ui.label({ text = editingId and noctalia.tr("editor.edit") or noctalia.tr("editor.new"),
                 fontWeight = "bold", fontSize = 15, flexGrow = 1 }),
    }),
    ui.scroll({ flexGrow = 1 }, { ui.column({ gap = 10 }, children) }),
  })
end

-- ================================================================
-- RULES VIEW
-- ================================================================
local function rulesView()
  local presets = noctalia.state.get("presets") or {}
  local rules   = noctalia.state.get("rules") or {}
  local kill    = noctalia.state.get("killswitch") or {}
  local dns     = noctalia.state.get("dnsleak")

  local dnsText, dnsColor
  if dns == nil then
    dnsText, dnsColor = noctalia.tr("rules.dns-hint"), T.muted
  elseif dns.leaking then
    dnsText, dnsColor = noctalia.tr("rules.dns-leak") .. " — " .. (dns.reason or ""), T.danger
  else
    dnsText, dnsColor = noctalia.tr("rules.dns-ok") .. " — " .. (dns.reason or ""), T.success
  end

  local presetRows = {}
  presetKeys = {}
  for i, p in ipairs(presets) do
    local slot = i - 1
    if slot >= MAX_PRE then break end
    presetKeys[slot] = p.key
    presetRows[#presetRows + 1] = ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = (p.flag or "") .. " " .. (p.name or p.key), flexGrow = 1 }),
      ui.toggle({ checked = p.enabled == true, onChange = "onPreset" .. tostring(slot) }),
    })
  end

  local ruleRows = {}
  ruleIds = {}
  for i, r in ipairs(rules) do
    local slot = i - 1
    if slot >= MAX_RULE then break end
    ruleIds[slot] = r.id
    ruleRows[#ruleRows + 1] = ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = r.type == "block" and "ban" or (r.type == "direct" and "arrow-right" or "shield"),
                 color = r.type == "block" and T.danger or T.muted }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = r.pattern or "", fontSize = 13 }),
        ui.label({ text = r.type or "", fontSize = 10, color = T.muted }),
      }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onRuleDel" .. tostring(slot) }),
    })
  end
  if #ruleRows == 0 then
    ruleRows[1] = ui.row({ paddingH = 6, paddingV = 6 }, {
      ui.label({ text = noctalia.tr("rules.none"), color = T.muted }),
    })
  end

  -- Header outside the scroll, scroll on flexGrow (same fix as editorView):
  -- a fixed scroll height overflowed the panel instead of clipping.
  return ui.column({ gap = 12, padding = 16, flexGrow = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", onClick = "onBack" }),
      ui.label({ text = noctalia.tr("rules.title"), fontWeight = "bold", fontSize = 15, flexGrow = 1 }),
    }),

    ui.scroll({ flexGrow = 1 }, { ui.column({ gap = 12 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "shield-x", color = kill.enabled and T.danger or T.muted }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("rules.killswitch") }),
        ui.label({ text = noctalia.tr("rules.killswitch-desc"), fontSize = 10, color = T.muted }),
      }),
      ui.toggle({ checked = kill.enabled == true, onChange = "onKill" }),
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "world-search", color = dnsColor }),
      ui.label({ text = dnsText, fontSize = 11, color = dnsColor, flexGrow = 1 }),
      ui.button({ text = noctalia.tr("rules.dns-check"), variant = "outline", onClick = "onDnsCheck" }),
    }),

    ui.separator({}),
    ui.label({ text = noctalia.tr("rules.presets"), fontSize = 12, color = T.muted }),
    ui.column({ gap = 6 }, presetRows),

    ui.separator({}),
    ui.label({ text = noctalia.tr("rules.custom"), fontSize = 12, color = T.muted }),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({ key = "rule-pat-" .. ruleRev, value = ruleForm.pattern, placeholder = "*.example.com | 10.0.0.0/8",
                 onChange = "onRulePattern", flexGrow = 1 }),
      ui.select({ selectedIndex = indexOf(RULE_TYPES, ruleForm.type, 0), options = RULE_TYPES, onChange = "onRuleType" }),
      ui.button({ glyph = "plus", variant = "primary", onClick = "onRuleAdd" }),
    }),
    ui.column({ gap = 6 }, ruleRows),

    -- Two-step reset because there is no undo or backend bulk-clear command.
    ui.separator({}),
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "trash", size = 15, color = resetArmed and T.danger or T.muted }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("rules.reset-servers"), color = resetArmed and T.danger or T.text }),
        ui.label({ text = noctalia.tr("rules.reset-servers-desc"), fontSize = 10, color = T.muted }),
      }),
      ui.button({ text = resetArmed and noctalia.tr("action.confirm") or noctalia.tr("action.reset"),
                  variant = "outline", onClick = "onResetServers" }),
    }),
    }) }),
  })
end

-- ================================================================
-- LOGS VIEW
-- ================================================================
local function logsView()
  local logs = noctalia.state.get("logs") or {}
  local rows = {}
  local startI = math.max(1, #logs - 150)
  for i = startI, #logs do
    local e = logs[i]
    local lvl = (e and e.level) or "info"
    rows[#rows + 1] = ui.label({
      text = (e and e.message) or "",
      fontSize = 11,
      color = (lvl == "error" and T.danger) or (lvl == "warn" and T.pingMid) or T.muted,
    })
  end
  if #rows == 0 then rows[1] = ui.label({ text = noctalia.tr("logs.empty"), color = T.muted }) end
  return ui.column({ gap = 10, padding = 16, flexGrow = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", onClick = "onBack" }),
      ui.label({ text = noctalia.tr("logs.title"), fontWeight = "bold", fontSize = 15, flexGrow = 1 }),
    }),
    ui.scroll({ flexGrow = 1, stickToBottom = true }, { ui.column({ gap = 3 }, rows) }),
  })
end

-- ================================================================
-- SUBSCRIPTIONS VIEW
-- ================================================================
local function subsView()
  local subs = noctalia.state.get("subscriptions") or {}
  local rows = {}
  subUrls = {}
  for i, sub in ipairs(subs) do
    local slot = i - 1
    if slot >= MAX_SUB then break end
    subUrls[slot] = sub.url
    rows[#rows + 1] = ui.row({ gap = 6, align = "center" }, {
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = (sub.name and sub.name ~= "") and sub.name or (sub.url or ""), fontSize = 13 }),
        ui.label({ text = sub.url or "", fontSize = 10, color = T.muted }),
      }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onSubUpd" .. tostring(slot) }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onSubDel" .. tostring(slot) }),
    })
  end
  if #rows == 0 then
    rows[1] = ui.row({ paddingH = 6, paddingV = 6 }, {
      ui.label({ text = noctalia.tr("subs.none"), color = T.muted }),
    })
  end

  return ui.column({ gap = 12, padding = 16, flexGrow = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", onClick = "onBack" }),
      ui.label({ text = noctalia.tr("subs.title"), fontWeight = "bold", fontSize = 15, flexGrow = 1 }),
    }),
    ui.column({ gap = 6 }, {
      ui.input({ key = "sub-url-" .. subRev, value = subForm.url, placeholder = "https://…/sub",
                 onChange = "onSubUrl", flexGrow = 1 }),
      ui.row({ gap = 6, align = "center" }, {
        ui.input({ key = "sub-name-" .. subRev, value = subForm.name, placeholder = noctalia.tr("subs.name"),
                   onChange = "onSubName", flexGrow = 1 }),
        ui.button({ text = noctalia.tr("action.add"), glyph = "plus", variant = "primary", onClick = "onSubAdd" }),
      }),
    }),
    ui.separator({}),
    ui.scroll({ flexGrow = 1 }, { ui.column({ gap = 8 }, rows) }),
  })
end

-- ── dispatch ────────────────────────────────────────────────────
render = function()
  local tree
  if view == "editor" then tree = editorView()
  elseif view == "rules" then tree = rulesView()
  elseif view == "logs" then tree = logsView()
  elseif view == "subs" then tree = subsView()
  else tree = mainView() end
  panel.render(tree)
end

-- ── lifecycle ───────────────────────────────────────────────────
function onOpen()
  for _, k in ipairs({ "status", "servers", "health", "backend", "presets", "rules",
                       "killswitch", "logs", "subscriptions", "speedtest", "dnsleak" }) do
    noctalia.state.watch(k, function(_) render() end)
  end
  render()
end
function onClose() end

-- ── main handlers ───────────────────────────────────────────────
function onToggle()
  local s = noctalia.state.get("status") or {}
  if s.running then send("StopProxy", {})
  elseif s.activeServerId and s.activeServerId ~= "" then
    send("StartProxy", { s.activeServerId, s.mode or "rules", s.proxyMode or "system" })
  else noctalia.notifyError("VPN", noctalia.tr("error.no-server")) end
end
-- The toggle reports the desired value; onToggle derives the action from state.
function onMaster(_) onToggle() end
function onClosePanel() panel.close() end

function onMode(_, label) send("SetMode", { label }) end
function onVia(_, label)
  if label == "tun" then noctalia.notify("VPN", noctalia.tr("notice.tun")) end
  send("SetProxyMode", { label })
end
-- RunSpeedTest reports latency and throughput in one command.
function onRunTest()
  local s = noctalia.state.get("status") or {}
  if not s.activeServerId or s.activeServerId == "" then
    noctalia.notifyError("VPN", noctalia.tr("error.no-server"))
    return
  end
  send("RunSpeedTest", {})
end
function onOpenRules() navigate("rules") end
function onOpenLogs() navigate("logs") end
function onOpenSubs() navigate("subs") end
function onBack() navigate("main") end

function onImportClip()
  local txt = noctalia.clipboardText()
  if txt and txt ~= "" then send("ParseShareLink", { txt })
  else noctalia.notifyError("VPN", noctalia.tr("error.clipboard")) end
end
function onDnsCheck() send("CheckDnsLeak", {}) end

-- ── editor open/save ────────────────────────────────────────────
local function openEditor(server)
  form = {}
  formRev = formRev + 1
  if server then
    editingId = server.id
    formProto = server.protocol or "ssh"
    for k, v in pairs(server) do form[k] = v end
  else
    editingId = nil
    formProto = "ssh"
    form.port = "22"
  end
  navigate("editor")
end

function onAddServer() openEditor(nil) end

function onSave()
  local p = { protocol = formProto, name = form.name or "" }
  -- Persisted via the models' extra="allow"; only the UI reads it.
  local cc = (form.country or ""):lower():gsub("%s", "")
  if #cc == 2 then p.country = cc end
  if editingId then p.id = editingId end
  if formProto == "ssh" then
    p.host = form.host; p.port = num(form.port, 22); p.user = form.user
    if form.password and form.password ~= "" then p.password = form.password end
    if form.keyFile and form.keyFile ~= "" then p.keyFile = form.keyFile end
  elseif formProto == "vless" then
    p.address = form.address; p.port = num(form.port, 443); p.uuid = form.uuid
    p.transport = form.transport or "tcp"; p.security = form.security or "none"
    for _, k in ipairs({ "sni", "flow", "pbk", "sid", "fp", "path", "host", "serviceName" }) do
      if form[k] and form[k] ~= "" then p[k] = form[k] end
    end
  elseif formProto == "vmess" then
    p.address = form.address; p.port = num(form.port, 443); p.uuid = form.uuid
    p.alterId = num(form.alterId, 0); p.transport = form.transport or "tcp"
    for _, k in ipairs({ "sni", "path", "host" }) do
      if form[k] and form[k] ~= "" then p[k] = form[k] end
    end
  elseif formProto == "shadowsocks" then
    p.address = form.address; p.port = num(form.port, 8388)
    p.method = form.method; p.password = form.password
  elseif formProto == "socks5" then
    p.host = form.host; p.port = num(form.port, 1080)
    if form.username and form.username ~= "" then p.username = form.username end
    if form.password and form.password ~= "" then p.password = form.password end
  end
  send(editingId and "UpdateServer" or "AddServer", { p })
  navigate("main")
end

function onDelete()
  if editingId then send("RemoveServer", { editingId }) end
  editingId = nil
  navigate("main")
end

-- editor field handlers (uncontrolled inputs → accumulate in form)
function onFld_name(v)       form.name = v end
function onFld_country(v)    form.country = v end
function onFld_host(v)       form.host = v end
function onFld_address(v)    form.address = v end
function onFld_port(v)       form.port = v end
function onFld_user(v)       form.user = v end
function onFld_password(v)   form.password = v end
function onFld_keyFile(v)    form.keyFile = v end
function onFld_uuid(v)       form.uuid = v end
function onFld_method(v)     form.method = v end
function onFld_sni(v)        form.sni = v end
function onFld_flow(v)       form.flow = v end
function onFld_fp(v)         form.fp = v end
function onFld_pbk(v)        form.pbk = v end
function onFld_sid(v)        form.sid = v end
function onFld_path(v)       form.path = v end
function onFld_serviceName(v) form.serviceName = v end
function onFld_username(v)   form.username = v end
function onFld_alterId(v)    form.alterId = v end
function onFldTransport(_, label) form.transport = label end
function onFldSecurity(_, label)  form.security = label end
function onFldProto(_, label)     formProto = label; formRev = formRev + 1; render() end

-- ── rules handlers ──────────────────────────────────────────────
function onKill(value) send("SetKillSwitch", { value == "true" }) end

-- Arms on the first click, fires on the second. Every state.set is delivered in
-- order (verified — the host queues them rather than collapsing to the last),
-- so fanning out one RemoveServer per id is safe.
function onResetServers()
  if not resetArmed then
    resetArmed = true
    render()
    return
  end
  resetArmed = false
  for _, s in ipairs(noctalia.state.get("servers") or {}) do
    send("RemoveServer", { s.id })
  end
  render()
end
function onRulePattern(v) ruleForm.pattern = v end
function onRuleType(_, label) ruleForm.type = label end
function onRuleAdd()
  if not ruleForm.pattern or ruleForm.pattern == "" then return end
  send("AddRoutingRule", { { pattern = ruleForm.pattern, type = ruleForm.type, enabled = true } })
  ruleForm.pattern = ""
  ruleRev = ruleRev + 1
  render()
end

local function onPresetAt(slot, value)
  local key = presetKeys[slot]; if key then send("TogglePreset", { key, value == "true" }) end
end
local function onRuleDelAt(slot)
  local id = ruleIds[slot]; if id then send("RemoveRoutingRule", { id }) end
end

-- ── subscription handlers ───────────────────────────────────────
function onSubUrl(v) subForm.url = v end
function onSubName(v) subForm.name = v end
function onSubAdd()
  if not subForm.url or subForm.url == "" then return end
  send("AddSubscription", { subForm.url, subForm.name or "" })
  subForm.url = ""; subForm.name = ""; subRev = subRev + 1; render()
end
local function onSubUpdAt(slot) local u = subUrls[slot]; if u then send("UpdateSubscription", { u }) end end
local function onSubDelAt(slot) local u = subUrls[slot]; if u then send("RemoveSubscription", { u }) end end

-- ── server row handlers ─────────────────────────────────────────
local function onServerAt(slot)
  local id = slotIds[slot]; if not id then return end
  local s = noctalia.state.get("status") or {}
  if s.running then send("SwitchServer", { id })
  else send("StartProxy", { id, s.mode or "rules", s.proxyMode or "system" }) end
end
local function onEditAt(slot)
  local id = slotIds[slot]; if not id then return end
  for _, sv in ipairs(noctalia.state.get("servers") or {}) do
    if sv.id == id then openEditor(sv); return end
  end
end
local function onDelAt(slot)
  local id = slotIds[slot]; if id then send("RemoveServer", { id }) end
end

-- ── fixed handler pools (host resolves onClick by global name) ───
function onServer0()  onServerAt(0)  end
function onServer1()  onServerAt(1)  end
function onServer2()  onServerAt(2)  end
function onServer3()  onServerAt(3)  end
function onServer4()  onServerAt(4)  end
function onServer5()  onServerAt(5)  end
function onServer6()  onServerAt(6)  end
function onServer7()  onServerAt(7)  end
function onServer8()  onServerAt(8)  end
function onServer9()  onServerAt(9)  end
function onServer10() onServerAt(10) end
function onServer11() onServerAt(11) end
function onServer12() onServerAt(12) end
function onServer13() onServerAt(13) end
function onServer14() onServerAt(14) end
function onServer15() onServerAt(15) end
function onServer16() onServerAt(16) end
function onServer17() onServerAt(17) end
function onServer18() onServerAt(18) end
function onServer19() onServerAt(19) end

function onEdit0()  onEditAt(0)  end
function onEdit1()  onEditAt(1)  end
function onEdit2()  onEditAt(2)  end
function onEdit3()  onEditAt(3)  end
function onEdit4()  onEditAt(4)  end
function onEdit5()  onEditAt(5)  end
function onEdit6()  onEditAt(6)  end
function onEdit7()  onEditAt(7)  end
function onEdit8()  onEditAt(8)  end
function onEdit9()  onEditAt(9)  end
function onEdit10() onEditAt(10) end
function onEdit11() onEditAt(11) end
function onEdit12() onEditAt(12) end
function onEdit13() onEditAt(13) end
function onEdit14() onEditAt(14) end
function onEdit15() onEditAt(15) end
function onEdit16() onEditAt(16) end
function onEdit17() onEditAt(17) end
function onEdit18() onEditAt(18) end
function onEdit19() onEditAt(19) end

function onDel0() onDelAt(0) end
function onDel1() onDelAt(1) end
function onDel2() onDelAt(2) end
function onDel3() onDelAt(3) end
function onDel4() onDelAt(4) end
function onDel5() onDelAt(5) end
function onDel6() onDelAt(6) end
function onDel7() onDelAt(7) end
function onDel8() onDelAt(8) end
function onDel9() onDelAt(9) end
function onDel10() onDelAt(10) end
function onDel11() onDelAt(11) end
function onDel12() onDelAt(12) end
function onDel13() onDelAt(13) end
function onDel14() onDelAt(14) end
function onDel15() onDelAt(15) end
function onDel16() onDelAt(16) end
function onDel17() onDelAt(17) end
function onDel18() onDelAt(18) end
function onDel19() onDelAt(19) end

function onPreset0(v) onPresetAt(0, v) end
function onPreset1(v) onPresetAt(1, v) end
function onPreset2(v) onPresetAt(2, v) end
function onPreset3(v) onPresetAt(3, v) end
function onPreset4(v) onPresetAt(4, v) end
function onPreset5(v) onPresetAt(5, v) end
function onPreset6(v) onPresetAt(6, v) end
function onPreset7(v) onPresetAt(7, v) end

function onRuleDel0()  onRuleDelAt(0)  end
function onRuleDel1()  onRuleDelAt(1)  end
function onRuleDel2()  onRuleDelAt(2)  end
function onRuleDel3()  onRuleDelAt(3)  end
function onRuleDel4()  onRuleDelAt(4)  end
function onRuleDel5()  onRuleDelAt(5)  end
function onRuleDel6()  onRuleDelAt(6)  end
function onRuleDel7()  onRuleDelAt(7)  end
function onRuleDel8()  onRuleDelAt(8)  end
function onRuleDel9()  onRuleDelAt(9)  end
function onRuleDel10() onRuleDelAt(10) end
function onRuleDel11() onRuleDelAt(11) end
function onRuleDel12() onRuleDelAt(12) end
function onRuleDel13() onRuleDelAt(13) end
function onRuleDel14() onRuleDelAt(14) end
function onRuleDel15() onRuleDelAt(15) end
function onRuleDel16() onRuleDelAt(16) end
function onRuleDel17() onRuleDelAt(17) end
function onRuleDel18() onRuleDelAt(18) end
function onRuleDel19() onRuleDelAt(19) end

function onSubUpd0()  onSubUpdAt(0)  end
function onSubUpd1()  onSubUpdAt(1)  end
function onSubUpd2()  onSubUpdAt(2)  end
function onSubUpd3()  onSubUpdAt(3)  end
function onSubUpd4()  onSubUpdAt(4)  end
function onSubUpd5()  onSubUpdAt(5)  end
function onSubUpd6()  onSubUpdAt(6)  end
function onSubUpd7()  onSubUpdAt(7)  end
function onSubUpd8()  onSubUpdAt(8)  end
function onSubUpd9()  onSubUpdAt(9)  end
function onSubUpd10() onSubUpdAt(10) end
function onSubUpd11() onSubUpdAt(11) end

function onSubDel0()  onSubDelAt(0)  end
function onSubDel1()  onSubDelAt(1)  end
function onSubDel2()  onSubDelAt(2)  end
function onSubDel3()  onSubDelAt(3)  end
function onSubDel4()  onSubDelAt(4)  end
function onSubDel5()  onSubDelAt(5)  end
function onSubDel6()  onSubDelAt(6)  end
function onSubDel7()  onSubDelAt(7)  end
function onSubDel8()  onSubDelAt(8)  end
function onSubDel9()  onSubDelAt(9)  end
function onSubDel10() onSubDelAt(10) end
function onSubDel11() onSubDelAt(11) end
