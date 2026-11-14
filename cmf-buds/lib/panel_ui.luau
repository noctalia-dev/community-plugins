--!nonstrict
-- Control panel for the CMF Buds Pro 2 (shared implementation).
-- A single panel with 4 internal tabs; smooth "bubble" transition.

local C = require("./common.luau")

local M = {}

local statePath = nil
local socketPath = nil
local logPath = nil
local pluginPath = noctalia.pluginDir() or ""

local st = nil
local tab = "sound"
local panelId = "faminec/cmf-buds:panel"
local panelHeight = 0

local ctrlGroup = "left"
local lastRaw = nil
local loading = true
local connecting = false
local errorText = ""
local customDirty = false
local localRules = {}
local localLast = {}
local localAction = {}
local localMods = {}
local localModsOk = false
local localDevices = {}
-- The rules whose command was typed but not saved yet. They are saved
-- when the panel is closed: the text is not stored anywhere else.
local pendingCommands = {}
-- The panel is closed: the answers that arrive afterwards must not
-- touch the UI anymore.
local closed = false

local dragUntil = 0
local pendingVolume = nil
local pendingEq = nil
local refreshElapsedMs = 0
local refreshIntervalMs = 500
local autoRefreshInFlight = false
local autoRefreshAt = 0
local autoRefreshSeq = 0
local rpcSeq = 0
local lastStateSeq = 0

-- ── guards against the reconciler echo ──────────────────────────────────────
-- Noctalia applies a slider's `value` prop through slider->setValue(), and
-- setValue() fires onChange (see Noctalia's slider.cpp and reconciler.cpp).
-- Without these guards, every re-render with a different value looks like a
-- user drag: the panel rewrites the value and the volume "snaps back".
-- We keep the value we pushed into the tree to tell the echo (an external
-- change that only needs reflecting) apart from a real user change.
local pushedVolume = nil
local pushedEq = {}

-- The user's local value while they are editing (drag in progress or a
-- write pending confirmation). State coming from the daemon does not
-- overwrite it until the daemon confirms that same value: otherwise a
-- `status` arriving mid-drag leaves the old value behind and releasing the
-- mouse rewrites that old value (the "snap back" the user saw).
local localVolume = nil
local localVolumeAt = 0
local localEq = nil
local localEqAt = 0
local LOCAL_TTL = 3

-- os.clock() in Luau returns the process CPU time, not wall-clock time.
-- With the panel open almost no CPU is consumed, so a "0.8 s" window
-- stretched to tens of seconds: the automatic refresh stalled (and live
-- sync never arrived). Time windows use os.time(), which is a wall clock.
local function nowSec()
  return os.time()
end


local dot = nil
local render

local function ensurePaths()
  local dir = noctalia.pluginDataDir()
  if dir ~= nil then
    statePath = dir .. "/state.json"
    socketPath = dir .. "/daemon.sock"
    logPath = dir .. "/daemon.log"
  end
end

local function loadFonts()
  if dot == nil then
    dot = noctalia.loadFont("fonts/Doto.ttf")
  end
end

local function tr(key, args)
  return C.tr(key, args)
end

local function truthy(value)
  return value == true or value == "true"
end

local function syncCustom()
  if st == nil or customDirty then
    return
  end
  local c = st.eq and st.eq.custom or {}
  st.eq = st.eq or {}
  st.eq.custom = {
    bass = tonumber(c.bass) or 0,
    mid = tonumber(c.mid) or 0,
    treble = tonumber(c.treble) or 0,
  }
end

local function syncLocal()
  if st == nil then
    return
  end
  local actions = st.local_actions
  if actions == nil then
    return
  end
  if actions.rules ~= nil then
    localRules = actions.rules
  end
  if actions.last_event ~= nil then
    localLast = actions.last_event
  end
  if actions.last_action ~= nil then
    localAction = actions.last_action
  end
  if actions.modifiers ~= nil then
    localMods = actions.modifiers
  end
  if actions.modifiers_available ~= nil then
    localModsOk = actions.modifiers_available
  end
end

-- The user has the last word until the daemon confirms their value.
-- Meanwhile, incoming state (a `status` arriving mid-drag, for instance)
-- does not overwrite the volume or the EQ the user is moving: if it did,
-- releasing the mouse would rewrite the old value.
local function applyLocalOverrides()
  if st == nil then
    return
  end
  local now = nowSec()
  if localVolume ~= nil then
    local real = tonumber(st.volume and st.volume.percent)
    if real ~= nil and math.abs(real - localVolume) <= 1 then
      -- The daemon already has the value: from here on, state wins.
      localVolume = nil
    elseif now - localVolumeAt > LOCAL_TTL then
      -- The daemon did not confirm (error, sink changed...): release it.
      localVolume = nil
    else
      st.volume = st.volume or {}
      st.volume.percent = localVolume
      st.volume.muted = false
    end
  end
  if localEq ~= nil then
    local real = st.eq and st.eq.custom or {}
    local matches = true
    for key, value in pairs(localEq) do
      if tonumber(real[key] or 0) ~= tonumber(value or 0) then
        matches = false
      end
    end
    if matches then
      localEq = nil
      customDirty = false
    elseif now - localEqAt > LOCAL_TTL then
      localEq = nil
      customDirty = false
    else
      st.eq = st.eq or {}
      st.eq.custom = st.eq.custom or {}
      for key, value in pairs(localEq) do
        st.eq.custom[key] = value
      end
    end
  end
end

local function readState()
  if statePath == nil then
    ensurePaths()
  end
  if statePath == nil then
    return false
  end
  local raw = noctalia.readFile(statePath)
  if raw == nil or raw == lastRaw then
    return false
  end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return false
  end
  lastRaw = raw
  st = data
  syncCustom()
  syncLocal()
  applyLocalOverrides()
  if data.devices ~= nil then
    localDevices = data.devices
  end
  return true
end

-- The daemon can take a while: a full query of the earbuds is about 15 s
-- and a reconnection up to a minute (the Bluetooth connect plus the wait
-- for BlueZ). The host clamps the timeout to 60 s, so the request is not
-- killed in the middle and the real answer is not lost.
local RPC_TIMEOUT_MS = 60000

local function rpc(req, cb)
  ensurePaths()
  if statePath == nil then
    errorText = tr("error.daemon")
    loading = false
    render()
    if cb ~= nil then
      cb(nil)
    end
    return false
  end
  local encoded = noctalia.json.encode(req)
  if encoded == nil then
    noctalia.log("cmf-buds: could not serialize the request")
    errorText = C.error_text("generic")
    loading = false
    if cb ~= nil then
      cb(nil)
    end
    render()
    return false
  end
  local argv = {
    "python3",
    pluginPath .. "/bin/budsctl.py",
    "rpc",
    encoded,
    "--socket",
    socketPath,
    "--state",
    statePath,
    "--log",
    logPath,
    "--poll",
    tostring(C.poll_seconds()),
    "--device-mac",
    noctalia.getConfig("device_mac") or "",
    "--device-name",
    noctalia.getConfig("device_name") or "",
  }
  rpcSeq = rpcSeq + 1
  local seq = rpcSeq
  if req.cmd ~= "status" then
    -- A new action replaces the error of the previous one. The status poll
    -- must not clear it: it runs every 500 ms and the error of an action
    -- would disappear before the user could read it.
    errorText = ""
  end
  local launched = noctalia.runAsync(argv, function(result)
    loading = false
    local ok, data = pcall(noctalia.json.decode, result.stdout or "")
    if not ok or type(data) ~= "table" then
      -- The answer of the daemon is not JSON: the raw output goes as the
      -- detail of the generic message (it is technical text).
      local detail = ""
      if result.timedOut then
        detail = "timeout"
      else
        detail = (result.stderr or ""):gsub("%s+$", "")
      end
      errorText = C.error_text("daemon_failed", detail)
    else
      if data.state ~= nil then
        if seq >= lastStateSeq then
          lastStateSeq = seq
          st = data.state
          lastRaw = nil
          syncCustom()
          syncLocal()
          applyLocalOverrides()
        end
      end
      if data.local_actions ~= nil then
        if data.local_actions.rules ~= nil then
          localRules = data.local_actions.rules
        end
        if data.local_actions.last_event ~= nil then
          localLast = data.local_actions.last_event
        end
        if data.local_actions.last_action ~= nil then
          localAction = data.local_actions.last_action
        end
        if data.local_actions.modifiers ~= nil then
          localMods = data.local_actions.modifiers
        end
        if data.local_actions.modifiers_available ~= nil then
          localModsOk = data.local_actions.modifiers_available
        end
      end
      if data.devices ~= nil then
        localDevices = data.devices
      end
      if data.ok ~= true then
        -- The daemon sends a stable code and the technical detail apart:
        -- the text is resolved here, in the language of the user.
        errorText = C.error_text(data.error, data.error_detail)
      elseif req.cmd ~= "status" then
        errorText = ""
      end
    end
    if cb ~= nil then
      cb(data)
    end
    render()
  end, RPC_TIMEOUT_MS)
  if not launched then
    -- The host did not start the process and never calls the callback: the
    -- failure has to be reported here or the panel would wait forever.
    loading = false
    errorText = C.error_text("daemon_failed")
    if cb ~= nil then
      cb(nil)
    end
    render()
    return false
  end
  return true
end

local function refresh()
  loading = st == nil
  render()
  rpc({ cmd = "status" })
end

local function fullRefresh()
  loading = st == nil
  render()
  rpc({ cmd = "refresh" })
end

-- ── UI pieces ────────────────────────────────────────────────────────────────

local function section(titleKey, glyphName, hint, small)
  local titleSize = small and 15 or 19
  local glyphSize = small and 12 or 15
  local children = {
    ui.glyph({ name = glyphName or "circle", size = glyphSize, color = "primary" }),
    ui.label({
      text = tr(titleKey),
      fontFamily = dot,
      fontSize = titleSize,
      color = "on_surface",
      flexGrow = 1,
    }),
  }
  local row = ui.row({ align = "center", gap = 8 }, children)
  if hint ~= nil then
    return ui.column({ gap = 2 }, {
      row,
      ui.label({ text = hint, fontSize = 10, color = "on_surface_variant" }),
    })
  end
  return row
end

local function card(children, extra)
  local props = {
    gap = 8,
    padding = 11,
    radius = 14,
    fill = "surface_container/0.35",
    align = "stretch",
  }
  if extra ~= nil then
    for k, v in pairs(extra) do
      props[k] = v
    end
  end
  return ui.column(props, children)
end

local function chip(text, selected, onClick, opts)
  local props = {
    text = text,
    variant = selected and "primary" or "secondary",
    controlSize = "sm",
    selected = selected,
    flexGrow = 1,
    onClick = onClick,
  }
  if opts ~= nil then
    for k, v in pairs(opts) do
      props[k] = v
    end
  end
  return ui.button(props)
end

local function batteryChip(label, value, charging)
  local rowChildren = {
    ui.label({
      text = value ~= nil and (tostring(value) .. "%") or "—",
      fontFamily = dot,
      fontSize = 15,
      color = value ~= nil and "on_surface" or "on_surface_variant",
    }),
  }
  if charging then
    table.insert(rowChildren, ui.glyph({ name = "bolt", size = 11, color = "primary" }))
  end
  return ui.column({
    flexGrow = 1,
    gap = 0,
    padding = 6,
    radius = 8,
    fill = "surface_container/0.4",
    align = "center",
  }, {
    ui.label({ text = label, fontSize = 9, color = "on_surface_variant" }),
    ui.row({ gap = 3, align = "center" }, rowChildren),
  })
end

local function bigValue(text)
  return ui.label({
    text = text,
    fontFamily = dot,
    fontSize = 38,
    color = "on_surface",
  })
end

-- ── header ───────────────────────────────────────────────────────────────────

local function header()
  local dev = st and st.device or {}
  local connected = st ~= nil and st.connected == true
  local name = (dev.name ~= nil and dev.name ~= "") and dev.name or "CMF Buds Pro 2"
  local statusText = connected and tr("status.connected") or ((connecting or loading) and tr("status.connecting") or tr("status.disconnected"))
  local statusColor = connected and "primary" or ((connecting or loading) and "on_surface_variant" or "error")

  local titleRow = ui.row({ align = "center", gap = 10 }, {
    ui.row({
      width = 36,
      height = 36,
      radius = 18,
      fill = "primary/0.14",
      align = "center",
      justify = "center",
    }, {
      ui.glyph({ name = "headphones", size = 20, color = "primary" }),
    }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({
        text = string.upper(name),
        fontFamily = dot,
        fontSize = 21,
        color = "on_surface",
        maxLines = 1,
      }),
      ui.row({ gap = 5, align = "center" }, {
        ui.glyph({ name = "circle-filled", size = 7, color = statusColor }),
        ui.label({ text = statusText, fontSize = 10, color = statusColor }),
        ui.label({ text = "·", fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = tr("subtitle"), fontSize = 8, color = "on_surface_variant" }),
      }),
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      glyphSize = 16,
      tooltip = tr("button.refresh"),
      onClick = function()
        -- A full refresh: the status only returns the cached values, so
        -- the battery, the ANC or the EQ would stay stale until the next
        -- poll of the daemon (up to five minutes).
        fullRefresh()
      end,
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      controlSize = "sm",
      glyphSize = 16,
      tooltip = tr("button.settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    }),
    ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      glyphSize = 16,
      tooltip = tr("button.close"),
      onClick = function()
        panel.close()
      end,
    }),
  })

  local b = st and st.battery or {}
  local ch = b.charging or {}
  local batteryRow = ui.row({ gap = 6 }, {
    batteryChip(tr("battery.left"), b.left, ch.left == true),
    batteryChip(tr("battery.right"), b.right, ch.right == true),
    batteryChip(tr("battery.case"), b.case, ch.case == true),
  })

  return ui.column({ gap = 8 }, { titleRow, batteryRow })
end

local function tabBar()
  local function tabBtn(key, label)
    local selected = tab == key
    return ui.button({
      text = label,
      variant = selected and "primary" or "ghost",
      controlSize = "sm",
      selected = selected,
      flexGrow = 1,
      onClick = function()
        M.switchTab(key)
      end,
    })
  end
  return ui.row({ gap = 6 }, {
    tabBtn("sound", tr("tab.sound")),
    tabBtn("controls", tr("tab.controls")),
    tabBtn("actions", tr("tab.actions")),
    tabBtn("system", tr("tab.system")),
  })
end

-- ── Sound tab ────────────────────────────────────────────────────────────────

local function ancCard()
  local anc = st and st.anc or {}
  local mode = anc.mode or "unknown"
  local level = anc.level or "high"

  local modes = ui.row({ gap = 6 }, {
    chip(tr("anc.off"), mode == "off", function()
      rpc({ cmd = "anc", mode = "off" })
    end),
    chip(tr("anc.transparency"), mode == "transparency", function()
      rpc({ cmd = "anc", mode = "transparency" })
    end),
    chip(tr("anc.cancel"), mode == "anc", function()
      rpc({ cmd = "anc", mode = "anc", level = level })
    end),
  })

  local children = { modes }
  if mode == "anc" then
    local levels = ui.row({ gap = 6 }, {
      chip(tr("anc.adaptive"), level == "adaptive", function()
        rpc({ cmd = "anc", mode = "anc", level = "adaptive" })
      end),
      chip(tr("anc.high"), level == "high", function()
        rpc({ cmd = "anc", mode = "anc", level = "high" })
      end),
      chip(tr("anc.mid"), level == "mid", function()
        rpc({ cmd = "anc", mode = "anc", level = "mid" })
      end),
      chip(tr("anc.low"), level == "low", function()
        rpc({ cmd = "anc", mode = "anc", level = "low" })
      end),
    })
    table.insert(children, levels)
  end
  table.insert(children, ui.label({
    text = tr("anc.hint"),
    fontSize = 10,
    color = "on_surface_variant",
  }))
  return card(children)
end

local function volumeCard()
  local v = st and st.volume or {}
  -- While the user is moving the slider, their value wins until the daemon
  -- confirms it (otherwise a `status` arriving mid-drag overwrites it).
  local percent = localVolume or tonumber(v.percent) or 0
  local muted = v.muted == true
  local sink = v.description ~= nil and v.description ~= "" and v.description or v.sink or "—"

  local top = ui.row({ align = "center", gap = 10 }, {
    bigValue(tostring(percent) .. "%"),
    ui.label({
      text = muted and tr("volume.mute") or "",
      fontSize = 10,
      color = "error",
      flexGrow = 1,
    }),
    ui.button({
      glyph = muted and "volume-off" or "volume",
      text = muted and tr("volume.unmute") or tr("volume.mute"),
      variant = "secondary",
      controlSize = "sm",
      onClick = function()
        rpc({ cmd = "volume", mute = "toggle" })
      end,
    }),
  })

  local slider = ui.slider({
    min = 0,
    max = 100,
    step = 1,
    value = percent,
    flexGrow = 1,
    onChange = function(value)
      local v = tonumber(value) or percent
      -- Echo: the reconciler just applied the value we ourselves pushed
      -- into the tree (setValue fires onChange). It is not a user change:
      -- it is only reflected, never rewritten.
      if pushedVolume ~= nil and v == pushedVolume then
        return
      end
      if localVolume == nil then
        local current = tonumber(st and st.volume and st.volume.percent)
        if current ~= nil and v == current then
          return
        end
      end
      dragUntil = nowSec() + 1
      localVolume = v
      localVolumeAt = nowSec()
      if st ~= nil then
        st.volume = st.volume or {}
        st.volume.percent = v
        st.volume.muted = false
      end
      pendingVolume = v
      render()
    end,
    onDragEnd = function()
      dragUntil = 0
      -- The user's local value is used: the daemon state may be older (the
      -- `status` is requested every 500 ms and can arrive mid-drag).
      local target = localVolume or tonumber(st and st.volume and st.volume.percent) or percent
      pendingVolume = nil
      rpc({ cmd = "volume", percent = target, mute = "off" })
    end,
  })
  -- The value we just pushed into the tree: used to recognize the echo.
  pushedVolume = percent

  return card({
    top,
    slider,
    ui.label({
      text = tr("volume.system", { sink = sink }),
      fontSize = 9,
      color = "on_surface_variant",
      maxLines = 1,
    }),
  })
end

local function presetRow(names)
  local buttons = {}
  for _, name in ipairs(names) do
    table.insert(buttons, chip(tr("eq.preset." .. name), st ~= nil and st.eq and st.eq.preset == name, function()
      rpc({ cmd = "eq", preset = name })
    end))
  end
  return ui.row({ gap = 6 }, buttons)
end

local function customSlider(labelKey, key)
  local custom = st and st.eq and st.eq.custom or {}
  local value = tonumber(custom[key]) or 0
  local slider = ui.slider({
    min = -6,
    max = 6,
    step = 1,
    value = value,
    flexGrow = 1,
    onChange = function(newValue)
      local nv = tonumber(newValue) or value
      -- Reconciler echo (setValue fires onChange): not from the user.
      if pushedEq[key] ~= nil and nv == pushedEq[key] then
        return
      end
      dragUntil = nowSec() + 1
      customDirty = true
      local c = st and st.eq and st.eq.custom or {}
      local updated = {
        bass = tonumber(c.bass) or 0,
        mid = tonumber(c.mid) or 0,
        treble = tonumber(c.treble) or 0,
      }
      updated[key] = nv
      localEq = updated
      localEqAt = nowSec()
      if st ~= nil then
        st.eq = st.eq or {}
        st.eq.custom = updated
      end
      pendingEq = updated
      render()
    end,
    onDragEnd = function()
      dragUntil = 0
      local c = localEq or (st and st.eq and st.eq.custom) or {}
      pendingEq = nil
      rpc({
        cmd = "custom_eq",
        bass = tonumber(c.bass) or 0,
        mid = tonumber(c.mid) or 0,
        treble = tonumber(c.treble) or 0,
      })
    end,
  })
  -- The value we just pushed into the tree: used to recognize the echo.
  pushedEq[key] = value
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = tr(labelKey), width = 52, fontSize = 11, color = "on_surface_variant" }),
    slider,
    ui.label({
      text = string.format("%+d", math.floor(value + 0.5)),
      width = 34,
      fontSize = 11,
      color = "on_surface",
      textAlign = "end",
    }),
  })
end

local function eqCard()
  local bass = st and st.bass or {}
  local level = tonumber(bass.level) or 1
  local enabled = bass.enabled == true

  local levelChips = {}
  for i = 1, 5 do
    table.insert(levelChips, chip(tostring(i), enabled and level == i, function()
      rpc({ cmd = "bass", enabled = true, level = i })
    end, { flexGrow = 1 }))
  end

  return card({
    presetRow({ "balanced", "rock", "electronic", "pop" }),
    presetRow({ "vocal", "classical", "custom" }),
    ui.separator({ thickness = 1, color = "outline_variant/0.25", spacing = 6 }),
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "wave-sine", size = 14, color = "primary" }),
      ui.label({
        text = tr("eq.ultra"),
        fontSize = 11,
        color = "on_surface",
        flexGrow = 1,
      }),
      ui.toggle({
        checked = enabled,
        onChange = function(value)
          rpc({ cmd = "bass", enabled = truthy(value), level = level })
        end,
      }),
    }),
    ui.row({ gap = 6 }, levelChips),
    ui.separator({ thickness = 1, color = "outline_variant/0.25", spacing = 6 }),
    ui.label({
      text = tr("eq.custom"),
      fontFamily = dot,
      fontSize = 16,
      color = "on_surface",
    }),
    customSlider("eq.bass", "bass"),
    customSlider("eq.mid", "mid"),
    customSlider("eq.treble", "treble"),
    ui.label({
      text = tr("eq.hint"),
      fontSize = 9,
      color = "on_surface_variant",
    }),
  })
end

local function soundTab()
  return {
    section("anc.title", "wave-sine"),
    ancCard(),
    section("volume.title", "volume"),
    volumeCard(),
    section("eq.title", "adjustments"),
    eqCard(),
  }
end

-- ── Controls tab ─────────────────────────────────────────────────────────────

local function controlsTab()
  local rows = {
    section("controls." .. ctrlGroup, ctrlGroup == "case" and "dialpad" or "hand-click"),
  }

  local groupRow = ui.row({ gap = 6 }, {
    chip(tr("controls.left"), ctrlGroup == "left", function()
      ctrlGroup = "left"
      render()
    end),
    chip(tr("controls.right"), ctrlGroup == "right", function()
      ctrlGroup = "right"
      render()
    end),
    chip(tr("controls.case"), ctrlGroup == "case", function()
      ctrlGroup = "case"
      render()
    end),
  })
  table.insert(rows, groupRow)

  if ctrlGroup == "case" then
    table.insert(rows, ui.label({
      text = tr("controls.case_hint"),
      fontSize = 10,
      color = "on_surface_variant",
    }))
  end

  local items = {}
  for _, gesture in ipairs(C.gesture_types(ctrlGroup)) do
    local keys = C.action_keys(ctrlGroup, gesture)
    local current = st and st.gestures and st.gestures[ctrlGroup .. "." .. gesture] or "no_action"
    local selected = 0
    for i, key in ipairs(keys) do
      if key == current then
        selected = i - 1
        break
      end
    end
    table.insert(items, ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = C.gesture_label(gesture),
        width = 136,
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.select({
        options = C.action_labels(keys),
        selectedIndex = selected,
        flexGrow = 1,
        controlSize = "sm",
        onChange = function(value)
          local idx = (tonumber(value) or 0) + 1
          local action = keys[idx] or "no_action"
          rpc({ cmd = "gesture", group = ctrlGroup, gesture = gesture, action = action })
        end,
      }),
    }))
  end
  table.insert(rows, card(items))

  local ring = st and st.ring or {}
  table.insert(rows, section("ring.title", "bell"))
  table.insert(rows, card({
    ui.row({ gap = 8 }, {
      ui.button({
        text = ring.left and tr("ring.stop") or tr("ring.left"),
        glyph = ring.left and "player-stop" or "volume",
        variant = ring.left and "destructive" or "secondary",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          rpc({ cmd = "ring", side = "left", on = not (ring.left == true) })
        end,
      }),
      ui.button({
        text = ring.right and tr("ring.stop") or tr("ring.right"),
        glyph = ring.right and "player-stop" or "volume",
        variant = ring.right and "destructive" or "secondary",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          rpc({ cmd = "ring", side = "right", on = not (ring.right == true) })
        end,
      }),
    }),
  }))
  return rows
end

-- ── Local shortcuts tab ──────────────────────────────────────────────────────

local function infoRow(labelKey, value)
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = tr(labelKey), width = 82, fontSize = 10, color = "on_surface_variant" }),
    ui.label({
      text = (value ~= nil and tostring(value) ~= "") and tostring(value) or "—",
      fontSize = 10,
      color = "on_surface",
      flexGrow = 1,
      maxLines = 2,
    }),
  })
end

local TRIGGERS = { "volume_up", "volume_down", "knob_press" }
local TRIGGER_NAMES = { volume_up = "dial_up", volume_down = "dial_down", knob_press = "knob" }

local function triggerName(trigger)
  return TRIGGER_NAMES[tostring(trigger)] or tostring(trigger)
end

local MODIFIERS = { "none", "super", "ctrl", "alt", "shift", "no_super" }

local function modifierRequire(mod)
  if mod == "super" or mod == "ctrl" or mod == "alt" or mod == "shift" then
    return { mod }
  end
  return {}
end

local function modifierForbid(mod)
  if mod == "no_super" then
    return { "super" }
  end
  return {}
end

local function ruleIndexById(id)
  for i, rule in ipairs(localRules) do
    if tostring(rule.id) == tostring(id) then
      return i
    end
  end
  return nil
end

local ruleCounter = 0

local function saveRule(rule)
  -- The constraints of a rule are the authoritative ones: the engine only
  -- looks at 'require' and 'forbid'. They are not rebuilt here, because a
  -- rule written by hand can require a combination of modifiers that the
  -- panel cannot express (ctrl+shift, for example) and saving it would
  -- silently remove the restriction. They are only set when the rule is
  -- new (newRule) or when the user changes the modifier in the panel.
  --
  -- The empty tables are sent as nil: JSON encodes them as an object
  -- instead of an array, and the engine expects a list.
  if rule.require ~= nil and next(rule.require) == nil then
    rule.require = nil
  end
  if rule.forbid ~= nil and next(rule.forbid) == nil then
    rule.forbid = nil
  end
  pendingCommands[tostring(rule.id)] = nil
  rpc({ cmd = "local_rule_set", rule = rule })
end

-- Save the commands that were typed but not submitted: the text is not
-- stored anywhere else and it would be lost when the panel is closed.
local function flushPendingCommands()
  local pending = pendingCommands
  pendingCommands = {}
  for _id, rule in pairs(pending) do
    saveRule(rule)
  end
end

local function removeRule(id)
  local idx = ruleIndexById(id)
  if idx ~= nil then
    table.remove(localRules, idx)
  end
  -- The rule is gone: it must not be saved again when the panel is closed
  -- (the pending command of a deleted rule would come back).
  pendingCommands[tostring(id)] = nil
  rpc({ cmd = "local_rule_delete", id = id })
end

local function newRule()
  ruleCounter = ruleCounter + 1
  return {
    id = "r" .. tostring(ruleCounter) .. "-" .. tostring(math.floor(math.random(100000))),
    trigger = "volume_up",
    presses = 0,
    modifier = "super",
    command = "",
    enabled = true,
    notify = true,
    restore_volume = false,
    -- The constraints of a new rule come from its modifier: the engine
    -- only looks at 'require' and 'forbid'.
    require = modifierRequire("super"),
    forbid = modifierForbid("super"),
  }
end

local function selectRow(label, options, selected, onChange)
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = label, width = 92, fontSize = 11, color = "on_surface_variant" }),
    ui.select({
      options = options,
      selectedIndex = selected,
      flexGrow = 1,
      controlSize = "sm",
      onChange = onChange,
    }),
  })
end

local function ruleCard(rule)
  -- ui.select is 0-based: the first option is the index 0. A trigger or a
  -- modifier that is not in the lists (a hand written rule, or one added by
  -- a newer daemon) must show the first option, not the second one.
  local triggerIdx = 0
  for i, name in ipairs(TRIGGERS) do
    if name == rule.trigger then
      triggerIdx = i - 1
      break
    end
  end
  local modIdx = 0
  for i, name in ipairs(MODIFIERS) do
    if name == rule.modifier then
      modIdx = i - 1
      break
    end
  end

  -- The daemon accepts any number of presses. A rule with more than five
  -- (written by hand) is shown with its own number instead of being
  -- displayed as "any", which would say the opposite of what it does.
  local pressOptions = {
    tr("shortcut.presses.any"),
    "1",
    "2",
    "3",
    "4",
    "5",
  }
  local pressCount = tonumber(rule.presses) or 0
  local pressIdx = pressCount
  if pressCount > 5 then
    table.insert(pressOptions, tostring(pressCount))
    pressIdx = #pressOptions - 1
  end

  local header = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "command", size = 15, color = "primary" }),
    ui.label({
      text = tr("shortcut.rule_title", {
        trigger = C.trOr("shortcut.gesture." .. triggerName(rule.trigger), triggerName(rule.trigger)),
        modifier = C.trOr("shortcut.modifier." .. tostring(rule.modifier or "none"), tostring(rule.modifier or "none")),
      }),
      fontSize = 12,
      color = "on_surface",
      flexGrow = 1,
    }),
    ui.toggle({
      checked = rule.enabled ~= false,
      onChange = function(value)
        rule.enabled = truthy(value)
        saveRule(rule)
      end,
    }),
    ui.button({
      glyph = "trash",
      variant = "ghost",
      controlSize = "sm",
      glyphSize = 15,
      tooltip = tr("shortcut.delete"),
      onClick = function()
        removeRule(rule.id)
      end,
    }),
  })

  local children = {
    header,
    selectRow(tr("shortcut.gesture_label"), {
      tr("shortcut.gesture.dial_up"),
      tr("shortcut.gesture.dial_down"),
      tr("shortcut.gesture.knob"),
    }, triggerIdx, function(value)
      rule.trigger = TRIGGERS[(tonumber(value) or 0) + 1] or "volume_up"
      saveRule(rule)
    end),
    selectRow(tr("shortcut.presses_label"), pressOptions, pressIdx, function(value)
      rule.presses = tonumber(value) or 0
      saveRule(rule)
    end),
    selectRow(tr("shortcut.modifier_label"), {
      tr("shortcut.modifier.none"),
      tr("shortcut.modifier.super"),
      tr("shortcut.modifier.ctrl"),
      tr("shortcut.modifier.alt"),
      tr("shortcut.modifier.shift"),
      tr("shortcut.modifier.no_super"),
    }, modIdx, function(value)
      rule.modifier = MODIFIERS[(tonumber(value) or 0) + 1] or "none"
      rule.require = modifierRequire(rule.modifier)
      rule.forbid = modifierForbid(rule.modifier)
      saveRule(rule)
    end),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("shortcut.command_label"), width = 92, fontSize = 11, color = "on_surface_variant" }),
      ui.input({
        key = "cmd-" .. tostring(rule.id),
        value = rule.command or "",
        placeholder = tr("shortcut.command_placeholder"),
        flexGrow = 1,
        onChange = function(value)
          rule.command = value
          -- The text is not saved yet: it is saved when the panel is
          -- closed (or when the rule is saved for another reason).
          pendingCommands[tostring(rule.id)] = rule
        end,
        onSubmit = function(value)
          rule.command = value
          saveRule(rule)
        end,
      }),
    }),
    ui.row({ gap = 10, align = "center" }, {
      ui.toggle({
        checked = rule.notify ~= false,
        onChange = function(value)
          rule.notify = truthy(value)
          saveRule(rule)
        end,
      }),
      ui.label({ text = tr("shortcut.notify"), fontSize = 10, color = "on_surface_variant" }),
      ui.toggle({
        checked = rule.restore_volume == true,
        onChange = function(value)
          rule.restore_volume = truthy(value)
          saveRule(rule)
        end,
      }),
      ui.label({ text = tr("shortcut.restore"), fontSize = 10, color = "on_surface_variant" }),
      ui.button({
        text = tr("shortcut.test"),
        glyph = "player-play",
        variant = "secondary",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          -- The rule is saved before it is tested: the text the user
          -- just typed is not stored anywhere else and it would be lost
          -- when the panel is closed.
          saveRule(rule)
          if (rule.command or "") ~= "" then
            rpc({ cmd = "local_test", command = rule.command })
          end
        end,
      }),
    }),
  }
  return card(children)
end

local function shortcutsTab()
  local rows = {
    section("shortcut.title", "command"),
    ui.label({
      text = tr("shortcut.hint"),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 3,
    }),
  }

  for _, rule in ipairs(localRules) do
    table.insert(rows, ruleCard(rule))
  end

  table.insert(rows, ui.button({
    text = tr("shortcut.add"),
    glyph = "plus",
    variant = "secondary",
    controlSize = "sm",
    onClick = function()
      local rule = newRule()
      table.insert(localRules, rule)
      saveRule(rule)
    end,
  }))

  local function modsText(list)
    if list == nil or #list == 0 then
      return ""
    end
    local names = {}
    for _, m in ipairs(list) do
      table.insert(names, m:upper())
    end
    return " + " .. table.concat(names, "+")
  end

  local lastText = tr("shortcut.none")
  if localLast ~= nil and localLast.trigger ~= nil then
    local tname = triggerName(tostring(localLast.trigger))
    lastText = tr("shortcut.last", {
      trigger = C.trOr("shortcut.gesture." .. tname, tname),
      presses = tostring(localLast.presses or 1),
      modifiers = modsText(localLast.modifiers),
    })
  end

  local actionText = tr("shortcut.none")
  if localAction ~= nil and localAction.command ~= nil and localAction.command ~= "" then
    actionText = tostring(localAction.command)
    if localAction.modifiers ~= nil and #localAction.modifiers > 0 then
      actionText = actionText .. " (" .. table.concat(localAction.modifiers, "+") .. ")"
    end
  end

  local modsText = localModsOk and (tr("shortcut.mods_held", { mods = (#localMods > 0) and table.concat(localMods, "+") or "—" })) or tr("shortcut.mods_unavailable")

  table.insert(rows, card({
    infoRow("shortcut.last_label", lastText),
    infoRow("shortcut.last_action_label", actionText),
    infoRow("shortcut.mods_label", modsText),
    ui.label({
      text = tr("shortcut.note"),
      fontSize = 9,
      color = "on_surface_variant",
      maxLines = 3,
    }),
  }))

  return rows
end

-- ── System tab ───────────────────────────────────────────────────────────────

local function toggleRow(glyphName, titleKey, descKey, key, current)
  return ui.row({ align = "center", gap = 10 }, {
    ui.row({
      width = 32,
      height = 32,
      radius = 10,
      fill = "primary/0.10",
      align = "center",
      justify = "center",
    }, {
      ui.glyph({ name = glyphName, size = 15, color = "primary" }),
    }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = tr(titleKey), fontSize = 12, color = "on_surface" }),
      ui.label({ text = tr(descKey), fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.toggle({
      checked = current == true,
      onChange = function(value)
        rpc({ cmd = "toggle", key = key, value = truthy(value) })
      end,
    }),
  })
end

local function fitCard()
  local fit = st and st.fit_test or {}
  local running = fit.running == true
  local err = fit.error or ""
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({
        text = tr("fit.title"),
        fontFamily = dot,
        fontSize = 18,
        color = "on_surface",
        flexGrow = 1,
      }),
      ui.button({
        text = running and tr("fit.stop") or tr("fit.start"),
        glyph = running and "player-stop" or "ear",
        variant = running and "destructive" or "secondary",
        controlSize = "sm",
        onClick = function()
          rpc({ cmd = "fit_test", start = not running })
        end,
      }),
    }),
    -- Summary on a single line: it used to be two blocks with a description
    -- and a duplicated "start" button that pushed the rest of the panel down.
    ui.label({
      text = tr("fit.intro_audio") .. " · " .. tr("fit.intro_anc"),
      fontSize = 9,
      color = "on_surface_variant",
      maxLines = 1,
    }),
  }

  if running then
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "loader", size = 13, color = "primary" }),
      ui.label({ text = tr("fit.running"), fontSize = 10, color = "on_surface_variant" }),
    }))
  elseif err ~= "" then
    table.insert(children, ui.row({
      gap = 6,
      padding = 8,
      radius = 8,
      fill = "error/0.12",
      align = "center",
    }, {
      ui.glyph({ name = "alert-triangle", size = 13, color = "error" }),
      ui.label({ text = tr("fit.not_worn"), fontSize = 9, color = "error", flexGrow = 1, maxLines = 2 }),
    }))
  else
    local function resultChip(labelKey, value)
      return ui.column({
        flexGrow = 1,
        gap = 2,
        padding = 5,
        radius = 8,
        fill = "surface_container/0.4",
        align = "center",
      }, {
        ui.label({ text = tr(labelKey), fontSize = 9, color = "on_surface_variant" }),
        ui.label({
          text = C.fit_label(value),
          fontSize = 11,
          color = value == 0 and "primary" or (value == 1 and "error" or "on_surface_variant"),
        }),
      })
    end
    table.insert(children, ui.row({ gap = 6 }, {
      resultChip("fit.left", fit.left),
      resultChip("fit.right", fit.right),
    }))
  end

  table.insert(children, ui.label({
    text = tr("fit.hint"),
    fontSize = 9,
    color = "on_surface_variant",
  }))
  return card(children)
end

local function infoCard()
  local dev = st and st.device or {}
  return card({
    infoRow("info.model", dev.model),
    infoRow("info.firmware", dev.firmware),
    infoRow("info.serial", dev.serial),
    infoRow("info.address", dev.mac),
    infoRow("info.battery", C.battery_detail(st)),
  })
end

local function connectionCard()
  local connected = st ~= nil and st.connected == true
  local statusKey = connected and "status.connected" or (connecting and "status.connecting" or "status.disconnected")
  local statusColor = connected and "primary" or (connecting and "on_surface_variant" or "error")
  local buttonKey = connecting and "status.connecting" or (connected and "button.reconnect" or "button.connect")
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = connected and "bluetooth" or "bluetooth-off", size = 16, color = statusColor }),
      ui.label({
        text = tr(statusKey),
        fontSize = 12,
        color = statusColor,
        flexGrow = 1,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        glyphSize = 16,
        tooltip = tr("button.settings"),
        onClick = function()
          noctalia.openSettings()
        end,
      }),
      ui.button({
        text = tr(buttonKey),
        variant = "secondary",
        controlSize = "sm",
        onClick = function()
          if connecting then
            return
          end
          connecting = true
          errorText = ""
          render()
          -- The reconnect command closes the link and opens it again: the
          -- connect command does nothing while the link is alive, and a
          -- half-open one can only be recovered this way. It also
          -- re-establishes the Bluetooth link when the serial channel is
          -- refused, so it is the right command in both cases.
          rpc({ cmd = "reconnect" }, function()
            connecting = false
          end)
        end,
      }),
    }),
  }
  -- The error of the last action (a code translated here) has priority; if
  -- there is none, the error the daemon left in the state is shown (the
  -- earbuds are not paired, the link was lost...).
  local message = errorText
  if message == "" and st ~= nil and st.error ~= nil and st.error ~= "" then
    message = C.error_text(st.error, st.error_detail)
  end
  if message ~= "" then
    table.insert(children, ui.row({
      gap = 6,
      padding = 8,
      radius = 8,
      fill = "error/0.12",
      align = "center",
    }, {
      ui.glyph({ name = "alert-triangle", size = 13, color = "error" }),
      ui.label({ text = message, fontSize = 9, color = "error", flexGrow = 1, maxLines = 3 }),
    }))
  end
  table.insert(children, ui.label({
    text = tr("hint.phone"),
    fontSize = 9,
    color = "on_surface_variant",
    maxLines = 2,
  }))
  return card(children)
end

local function systemTab()
  local dualPending = st ~= nil and st.dual_restart_pending == true
  local dualChildren = {
    toggleRow("devices", "system.dual", "system.dual_desc", "dual_connection", st and st.dual_connection),
    ui.label({
      text = tr("system.dual_note"),
      fontSize = 9,
      color = "on_surface_variant",
      maxLines = 3,
    }),
  }
  if dualPending then
    table.insert(dualChildren, ui.row({
      gap = 6,
      padding = 8,
      radius = 8,
      fill = "warning/0.12",
      align = "center",
    }, {
      ui.glyph({ name = "alert-triangle", size = 13, color = "warning" }),
      ui.label({ text = tr("system.dual_restart"), fontSize = 9, color = "warning", flexGrow = 1, maxLines = 3 }),
      ui.button({
        text = tr("system.dual_restart_ack"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          rpc({ cmd = "dual_ack" })
        end,
      }),
    }))
  end

  -- Device panel: list of paired Nothing/CMF devices (max. 2)
  local deviceRows = {}
  local shownDevices = {}
  for i = 1, math.min(2, #localDevices) do
    table.insert(shownDevices, localDevices[i])
  end
  for _, dev in ipairs(shownDevices) do
    table.insert(deviceRows, ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = dev.connected and "bluetooth" or "bluetooth-off", size = 13, color = dev.connected and "primary" or "on_surface_variant" }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = tostring(dev.name or dev.mac), fontSize = 10, color = "on_surface", maxLines = 1 }),
        ui.label({ text = tostring(dev.mac), fontSize = 8, color = "on_surface_variant", maxLines = 1 }),
      }),
      ui.button({
        text = dev.connected and tr("button.disconnect") or tr("button.connect"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          if dev.connected then
            rpc({ cmd = "device_disconnect", mac = dev.mac }, function() rpc({ cmd = "devices" }) end)
          else
            rpc({ cmd = "device_connect", mac = dev.mac }, function() rpc({ cmd = "devices" }) end)
          end
        end,
      }),
    }))
  end
  if #deviceRows == 0 then
    table.insert(deviceRows, ui.label({ text = tr("system.devices_none"), fontSize = 9, color = "on_surface_variant" }))
  end
  table.insert(deviceRows, ui.label({ text = tr("system.devices_note"), fontSize = 9, color = "on_surface_variant", maxLines = 3 }))

  return {
    section("system.title", "adjustments", nil, true),
    card({
      toggleRow("sparkles", "system.spatial", "system.spatial_desc", "spatial", st and st.spatial),
      ui.separator({ thickness = 1, color = "outline_variant/0.25", spacing = 4 }),
      toggleRow("ear", "system.in_ear", "system.in_ear_desc", "in_ear", st and st.in_ear),
      ui.separator({ thickness = 1, color = "outline_variant/0.25", spacing = 4 }),
      toggleRow("bolt", "system.low_latency", "system.low_latency_desc", "low_latency", st and st.low_latency),
    }),
    card(dualChildren),
    card(deviceRows),
    fitCard(),
    connectionCard(),
    section("info.title", "info-circle", nil, true),
    infoCard(),
  }
end

-- ── Module API ───────────────────────────────────────────────────────────────

function M.setup(defaultTab, ownPanelId, height)
  tab = defaultTab or "sound"
  panelId = ownPanelId or panelId
  panelHeight = tonumber(height) or 0
  C.set_last_tab(tab)
end

function M.switchTab(key)
  if key ~= "sound" and key ~= "controls" and key ~= "actions" and key ~= "system" then
    return
  end
  if tab == key then
    return
  end
  tab = key
  C.set_last_tab(key)
  render()
end

-- ── render ────────────────────────────────────────────────────────────────────

render = function()
  if closed then
    -- The panel is closed: an answer that arrives late must not touch
    -- the UI anymore.
    return
  end
  if statePath == nil then
    ensurePaths()
  end

  local body
  if st == nil then
    -- The daemon did not answer yet (or could not be started). The error is
    -- shown here too: otherwise the panel would show a spinner forever with
    -- no clue about what went wrong.
    local waiting = {
      ui.glyph({ name = "headphones", size = 34, color = "primary" }),
      ui.label({ text = tr("loading"), fontFamily = dot, fontSize = 18, color = "on_surface" }),
      ui.label({ text = tr("hint.phone"), fontSize = 9, color = "on_surface_variant", maxLines = 2 }),
    }
    if errorText ~= "" then
      table.insert(waiting, ui.label({
        text = errorText,
        fontSize = 10,
        color = "error",
        maxLines = 3,
      }))
    end
    body = ui.column({ gap = 10, align = "center", justify = "center" }, waiting)
  else
    local rows
    if tab == "controls" then
      rows = controlsTab()
    elseif tab == "actions" then
      rows = shortcutsTab()
    elseif tab == "system" then
      rows = systemTab()
    else
      rows = soundTab()
    end
    -- The layout distributes the scroll height through flexGrow: the header
    -- and the tab bar size themselves and the scroll gets exactly what is
    -- left. Setting "height" by hand (panelHeight - 200) also pinned
    -- min/maxHeight on the scroll, which cancels the flexGrow distribution
    -- and pushes the viewport outside the root's inner box.
    local scrollProps = { gap = 8, align = "stretch", flexGrow = 1 }
    body = ui.scroll(scrollProps, rows)
  end

  -- Fixed height: the panel does not grow with the content and the scroll
  -- clips whatever does not fit (plugin.toml declares a 1000 px height).
  local rootProps = { gap = 10, padding = 14, align = "stretch" }
  if panelHeight > 0 then
    rootProps.height = panelHeight - 28
  end
  panel.render(ui.column(rootProps, {
    header(),
    tabBar(),
    body,
  }))
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

function M.onOpen(_context)
  closed = false
  M.setup(tab, panelId, panelHeight)
  ensurePaths()
  loadFonts()
  C.loadTranslations()
  panel.setWantsSecondTicks(false)
  panel.setNeedsFrameTick(true)
  refreshElapsedMs = 0
  autoRefreshInFlight = false
  loading = true
  connecting = false
  errorText = ""
  readState()
  render()
  rpc({ cmd = "status" })
  rpc({ cmd = "configure", poll = C.poll_seconds(), device_mac = noctalia.getConfig("device_mac") or "", device_name = noctalia.getConfig("device_name") or "" })
  rpc({ cmd = "devices" })
end

function M.onClose()
  closed = true
  panel.setNeedsFrameTick(false)
  -- The command that was typed but not submitted is saved: otherwise it
  -- would be lost when the panel is closed.
  flushPendingCommands()
end

local function tickRefresh()
  local now = nowSec()
  if now < dragUntil then
    return
  end
  if pendingVolume ~= nil then
    local target = pendingVolume
    pendingVolume = nil
    rpc({ cmd = "volume", percent = target, mute = "off" })
  end
  if pendingEq ~= nil then
    local c = pendingEq
    pendingEq = nil
    rpc({ cmd = "custom_eq", bass = c.bass, mid = c.mid, treble = c.treble })
  end
  if autoRefreshInFlight then
    -- The request is released when its answer arrives. If the daemon
    -- does not answer at all, it is released when the timeout of the
    -- request is reached: otherwise the panel would never refresh
    -- again.
    if now - autoRefreshAt <= RPC_TIMEOUT_MS / 1000 then
      return
    end
    autoRefreshInFlight = false
  end
  autoRefreshInFlight = true
  autoRefreshAt = now
  autoRefreshSeq = autoRefreshSeq + 1
  local seq = autoRefreshSeq
  rpc({ cmd = "status" }, function(_data)
    -- Only the answer of the request in flight releases the guard: an
    -- old answer must not release a newer request.
    if seq == autoRefreshSeq then
      autoRefreshInFlight = false
    end
  end)
end

function M.update()
  tickRefresh()
end

function M.onConfigChanged()
  ensurePaths()
  loadFonts()
  C.loadTranslations()
  readState()
  render()
  refresh()
  rpc({ cmd = "configure", poll = C.poll_seconds(), device_mac = noctalia.getConfig("device_mac") or "", device_name = noctalia.getConfig("device_name") or "" })
end

function M.onIpc(event, payload)
  if event == "refresh" then
    refresh()
  elseif event == "tab" then
    if payload == "sound" or payload == "controls" or payload == "actions" or payload == "system" then
      M.switchTab(payload)
    end
  end
end

function M.onFrameTick(deltaMs)
  refreshElapsedMs = refreshElapsedMs + (tonumber(deltaMs) or 16)
  if refreshElapsedMs >= refreshIntervalMs then
    refreshElapsedMs = 0
    tickRefresh()
  end
  -- Keep frame ticks running while the panel is open.
  panel.setNeedsFrameTick(true)
end

ensurePaths()
loadFonts()
C.loadTranslations()

return M