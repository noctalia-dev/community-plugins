--!nonstrict
-- Pulsar Mouse quick controls - [[panel]]. Opened from the bar widget.
--
-- Unlike the battery read path (bar.luau/desktop.luau), this always talks
-- to the mouse directly via the CLI - none of DPI/polling/LED state lives
-- in the cached battery.json, and writes obviously can't be cached at all.
--
-- Sliders (DPI stage, polling rate, brightness, breathe speed) commit on
-- onDragEnd, not onChange - onChange only updates the live label as you
-- drag, so a drag gesture doesn't fire a USB write per pixel/step crossed.
-- DPI and polling rate are index-based sliders over their configured/
-- supported values (not a raw DPI/Hz range), so every position lands on
-- an actual valid value - equivalent to a slider with a notch per option.
--
-- Root is a ui.scroll, not a ui.column - the panel surface already insets
-- its own content (Style::panelPadding on the host side), so an outer
-- `padding` prop here would double up on that, and scrolling is a safety
-- net against the fixed panel height (declared in plugin.toml) not fitting
-- every combination of rows (the speed slider alone changes content height
-- depending on which LED effect is selected).
--
-- No native tabs control exists (checked noctalia.d.luau) - "Sensor" and
-- "Lighting" are two ui.button()s whose variant swaps between primary/
-- outline based on activeTab, same segmented-button pattern the DPI/polling
-- stage buttons used before they became sliders. Each section is just
-- conditionally included in the rendered tree rather than actually hidden.
--
--   panel.render(tree)          declarative UI tree
--   panel.close()                close the panel surface
--   noctalia.runAsync(cmd, cb)  CLI read/write
--   noctalia.json.decode(str)   status comes back as JSON on stdout

-- Which profile is targeted for --profile N reads/writes AND, in lockstep,
-- the mouse's actual active profile (this panel always keeps the two the
-- same - picking a profile in the UI calls --active-profile, not just a
-- local view change, so every field shown always belongs to one coherent
-- profile). Starts at 1 as a bootstrap placeholder only - the first
-- readStatus() call of each open corrects it to whatever's actually active
-- on the mouse (see profileSynced below), since a physical profile button
-- or Fusion on another OS could have left a different profile active than
-- this panel's default guess, or than whatever it was last left showing.
local profile = 1
-- Cleared by onOpen() on every open, not just once per process - see the
-- bootstrap block in readStatus().
local profileSynced = false
local numProfiles = 0
local pollingRate = nil
local pollingRates = {}
local dpiActive = nil
local dpiStages = {}
local dpiPreviewIndex = nil -- live drag preview, separate from the committed dpiActive
local pollPreviewIndex = nil
local ledEffects = {}
local ledEffect = nil
local brightnessPct = nil
local brightnessPreview = nil
local breatheSpeed = nil
local breatheSpeedPreview = nil
local wireless = false
local debounce = nil -- {value, min, max}
local debouncePreview = nil
local angleSnap = nil
local rippleControl = nil
local motionSync = nil
local lod = nil -- {value, min, max, step}
local lodPreview = nil
local powerSaving = nil -- {value, min, max}
local powerSavingPreview = nil
local lowPower = nil -- {value, min, max}
local lowPowerPreview = nil
local errorText = nil
local busy = false
local activeTab = "sensor" -- "sensor" | "advanced" | "lighting" | "power"

-- Forward-declared: sliderRow/toggleRow below build closures (onChange/
-- onDragEnd) that call render() before its definition is reached in the
-- file. A `local function render()` at that later point would create a
-- new local invisible to those already-defined closures, which would
-- instead close over the (nil) global - this forward declaration is what
-- lets them share the one local.
local render

-- Matches the GUI's own convention (see gui.py) for when breathe speed is
-- relevant: the device's last LED effect in its list, checked by position
-- rather than a literal string match, in case a future driver ever needs
-- a different name.
local function breatheSpeedRelevant()
  return breatheSpeed ~= nil and ledEffect == ledEffects[#ledEffects]
end

local function pollingRateIndex()
  for i, hz in ipairs(pollingRates) do
    if hz == pollingRate then
      return i
    end
  end
  return 1
end

-- Generic value slider (label + slider) for the four new global/per-profile
-- settings below - DPI/polling/brightness/breathe speed above predate this
-- and stay as they are (index-based lookups for the first two, already
-- working) rather than being retrofitted for the sake of it. get/setPreview
-- hold the live-drag value separately from the committed one, same
-- preview-then-commit-on-drag-end split as everywhere else in this file.
-- `key` gives this row's label/slider a stable identity across renders -
-- without it, Noctalia's UI reconciler matches purely by (type, position),
-- and this panel's row list shifts constantly (the error label appearing/
-- disappearing, tabs swapping which rows are present, the breathe-speed row
-- coming and going) - two different sliderRow() calls landing on the same
-- structural slot across renders can end up with one's onDragEnd bound to
-- the wrong control, so a drag on one setting silently writes another.
local function sliderRow(key, labelText, formatValue, min, max, step, get, getPreview, setPreview, buildCmd, onSuccess)
  local shown = getPreview() or get()
  return {
    ui.label({
      key = key .. "-label",
      text = `{labelText} — {formatValue(shown)}`,
      fontSize = 13,
      color = "on_surface_variant",
    }),
    ui.slider({
      key = key,
      min = min,
      max = max,
      step = step,
      value = shown,
      enabled = not busy,
      onChange = function(value)
        setPreview(tonumber(value) or get())
        render()
      end,
      onDragEnd = function(value)
        -- onDragEnd's own `value` arg unreliably reports the pre-drag value,
        -- not where the drag actually ended (confirmed empirically - onChange
        -- during the drag gets the correct live value every time, onDragEnd's
        -- own argument does not) - getPreview() holds the last-known-good
        -- value onChange already captured, so prefer that and only fall back
        -- to onDragEnd's argument for the rare case there was no onChange
        -- (e.g. a tap without any drag).
        local target = getPreview() or tonumber(value) or get()
        setPreview(nil)
        if target == get() then
          render()
          return
        end
        busy = true
        render()
        noctalia.runAsync(buildCmd(target), function(result)
          busy = false
          if type(result) == "table" and result.exitCode == 0 then
            onSuccess(target)
            errorText = nil
          else
            errorText = noctalia.tr("ui.write-failed")
          end
          render()
        end, 10000)
      end,
    }),
  }
end

-- Tried surfacing an extra hint for these three toggles three ways
-- (2026-08-09): a static description row (worked, but pushed panel height
-- back up), `tooltip` directly on ui.toggle (silently unsupported -
-- Noctalia's own source shows kToggle's prop allowlist has no `tooltip`,
-- unlike kButton), and a small ui.button({glyph="help-circle", tooltip=...})
-- next to the toggle (matches kButton's confirmed-working tooltip wiring
-- exactly, icon rendered correctly, but the hover popup itself never
-- appeared in practice - live-tested, no fix found). Dropped all three -
-- not worth chasing further. Revisit if this becomes reliable.
local function toggleRow(key, labelText, checked, buildCmd, onSuccess)
  return ui.row({ key = key, gap = 8, align = "center" }, {
    ui.toggle({
      key = key .. "-toggle",
      checked = checked,
      enabled = not busy,
      onChange = function(value)
        local target = value == "true"
        if target == checked then
          return
        end
        busy = true
        render()
        noctalia.runAsync(buildCmd(target), function(result)
          busy = false
          if type(result) == "table" and result.exitCode == 0 then
            onSuccess(target)
            errorText = nil
          else
            errorText = noctalia.tr("ui.write-failed")
          end
          render()
        end, 10000)
      end,
    }),
    ui.label({ key = key .. "-label", text = labelText, flexGrow = 1 }),
  })
end

function render()
  local rows = {}

  if errorText ~= nil then
    table.insert(rows, ui.label({ key = "error", text = errorText, color = "error" }))
  end

  local loaded = #dpiStages > 0 or #pollingRates > 0 or #ledEffects > 0

  if not loaded and errorText == nil then
    table.insert(rows, ui.label({ key = "loading", text = noctalia.tr("ui.loading"), color = "outline" }))
    panel.render(ui.scroll({ flexGrow = 1, gap = 10 }, rows))
    return
  end

  if numProfiles > 1 then
    -- No separate label row above this - "Profile" prefixes each option
    -- text instead ("Profile 1", "Profile 2", ...), saving a whole row's
    -- height (this panel was fighting its own scroll safety net at 320px
    -- wide with a standalone label here).
    local profileOptions = {}
    for i = 1, numProfiles do
      table.insert(profileOptions, `{noctalia.tr("ui.profile-label")} {i}`)
    end
    table.insert(rows, ui.select({
      key = "profile",
      options = profileOptions,
      selectedIndex = profile - 1,
      enabled = not busy,
      onChange = "onProfileChange",
    }))
  end

  -- No native tabs control - segmented buttons standing in for one, same
  -- variant-swap pattern as the DPI/polling stage buttons used to use
  -- before they became sliders. Power only applies to wireless mice (power
  -- saving timeout, low-battery threshold) - hidden entirely on a wired
  -- one. Four tabs no longer fit legibly in one row at this panel's 320px
  -- width (confirmed by eye once Advanced was added) - split into two rows
  -- of two instead of shrinking the buttons.
  local function tabButton(tab, labelKey)
    return ui.button({
      key = `tab-{tab}`,
      text = noctalia.tr(labelKey),
      variant = (activeTab == tab) and "primary" or "outline",
      flexGrow = 1,
      onClick = function()
        activeTab = tab
        render()
      end,
    })
  end
  table.insert(rows, ui.row({ key = "tabs-1", gap = 6 }, {
    tabButton("sensor", "ui.tab-sensor"),
    tabButton("advanced", "ui.tab-advanced"),
  }))
  local tabButtons2 = { tabButton("lighting", "ui.tab-lighting") }
  if wireless then
    table.insert(tabButtons2, tabButton("power", "ui.tab-power"))
  end
  table.insert(rows, ui.row({ key = "tabs-2", gap = 6 }, tabButtons2))

  if activeTab == "sensor" and #dpiStages > 0 then
    local shownIndex = dpiPreviewIndex or dpiActive
    local shownDpi = dpiStages[shownIndex]
    table.insert(rows, ui.label({
      key = "dpi-label",
      text = `{noctalia.tr("ui.dpi-label")} — {shownDpi}`,
      fontSize = 13,
      color = "on_surface_variant",
    }))
    table.insert(rows, ui.slider({
      key = "dpi",
      min = 1,
      max = #dpiStages,
      step = 1,
      value = shownIndex,
      enabled = not busy,
      onChange = function(value)
        dpiPreviewIndex = math.floor(tonumber(value) or dpiActive)
        render()
      end,
      onDragEnd = function(value)
        -- Prefer the live-drag preview over onDragEnd's own `value` arg - see
        -- sliderRow()'s onDragEnd for why (empirically unreliable, always
        -- reports the pre-drag value here too).
        local target = dpiPreviewIndex or math.floor(tonumber(value) or dpiActive)
        dpiPreviewIndex = nil
        if target == dpiActive then
          render()
          return
        end
        busy = true
        render()
        noctalia.runAsync(
          `pulsar-mouse --profile {profile} --active-stage {target}`,
          function(result)
            busy = false
            if type(result) == "table" and result.exitCode == 0 then
              dpiActive = target
              errorText = nil
            else
              errorText = noctalia.tr("ui.write-failed")
            end
            render()
          end,
          10000
        )
      end,
    }))
  end

  if activeTab == "sensor" and #pollingRates > 0 then
    local shownPollIndex = pollPreviewIndex or pollingRateIndex()
    local shownHz = pollingRates[shownPollIndex]
    table.insert(rows, ui.label({
      key = "polling-label",
      text = `{noctalia.tr("ui.polling-label")} — {shownHz} Hz`,
      fontSize = 13,
      color = "on_surface_variant",
    }))
    table.insert(rows, ui.slider({
      key = "polling",
      min = 1,
      max = #pollingRates,
      step = 1,
      value = shownPollIndex,
      enabled = not busy,
      onChange = function(value)
        pollPreviewIndex = math.floor(tonumber(value) or pollingRateIndex())
        render()
      end,
      onDragEnd = function(value)
        -- Prefer the live-drag preview over onDragEnd's own `value` arg - see
        -- sliderRow()'s onDragEnd for why.
        local targetIndex = pollPreviewIndex or math.floor(tonumber(value) or pollingRateIndex())
        pollPreviewIndex = nil
        local hz = pollingRates[targetIndex]
        if hz == nil or hz == pollingRate then
          render()
          return
        end
        busy = true
        render()
        noctalia.runAsync(`pulsar-mouse --poll {hz}`, function(result)
          busy = false
          if type(result) == "table" and result.exitCode == 0 then
            pollingRate = hz
            errorText = nil
          else
            errorText = noctalia.tr("ui.write-failed")
          end
          render()
        end, 10000)
      end,
    }))
  end

  if activeTab == "sensor" and lod ~= nil then
    for _, node in ipairs(sliderRow(
      "lod",
      noctalia.tr("ui.lod-label"),
      function(v) return `{string.format("%.1f", v)}mm` end,
      lod.min, lod.max, lod.step,
      function() return lod.value end,
      function() return lodPreview end,
      function(v) lodPreview = v end,
      function(v) return `pulsar-mouse --profile {profile} --lod {string.format("%.1f", v)}` end,
      function(v) lod.value = v end
    )) do
      table.insert(rows, node)
    end
  end

  if activeTab == "advanced" and debounce ~= nil then
    for _, node in ipairs(sliderRow(
      "debounce",
      noctalia.tr("ui.debounce-label"),
      function(v) return `{math.floor(v)}ms` end,
      debounce.min, debounce.max, 1,
      function() return debounce.value end,
      function() return debouncePreview end,
      function(v) debouncePreview = v end,
      function(v) return `pulsar-mouse --debounce {math.floor(v)}` end,
      function(v) debounce.value = math.floor(v) end
    )) do
      table.insert(rows, node)
    end
  end

  if activeTab == "advanced" and angleSnap ~= nil then
    table.insert(rows, toggleRow(
      "angle-snap",
      noctalia.tr("ui.angle-snap-label"),
      angleSnap,
      function(v) return `pulsar-mouse --angle-snap {v and "on" or "off"}` end,
      function(v) angleSnap = v end
    ))
  end

  if activeTab == "advanced" and rippleControl ~= nil then
    table.insert(rows, toggleRow(
      "ripple",
      noctalia.tr("ui.ripple-label"),
      rippleControl,
      function(v) return `pulsar-mouse --ripple {v and "on" or "off"}` end,
      function(v) rippleControl = v end
    ))
  end

  if activeTab == "advanced" and motionSync ~= nil then
    table.insert(rows, toggleRow(
      "motion-sync",
      noctalia.tr("ui.motion-sync-label"),
      motionSync,
      function(v) return `pulsar-mouse --motion-sync {v and "on" or "off"}` end,
      function(v) motionSync = v end
    ))
  end

  if activeTab == "power" and powerSaving ~= nil then
    for _, node in ipairs(sliderRow(
      "power-saving",
      noctalia.tr("ui.power-saving-label"),
      function(v) return string.format("%d:%02d", math.floor(v / 60), math.floor(v) % 60) end,
      powerSaving.min, powerSaving.max, 30,
      function() return powerSaving.value end,
      function() return powerSavingPreview end,
      function(v) powerSavingPreview = v end,
      function(v) return `pulsar-mouse --power-saving {math.floor(v)}` end,
      function(v) powerSaving.value = math.floor(v) end
    )) do
      table.insert(rows, node)
    end
  end

  if activeTab == "power" and lowPower ~= nil then
    for _, node in ipairs(sliderRow(
      "low-power",
      noctalia.tr("ui.low-power-label"),
      function(v) return `{math.floor(v)}%` end,
      lowPower.min, lowPower.max, 5,
      function() return lowPower.value end,
      function() return lowPowerPreview end,
      function(v) lowPowerPreview = v end,
      function(v) return `pulsar-mouse --low-power {math.floor(v)}` end,
      function(v) lowPower.value = math.floor(v) end
    )) do
      table.insert(rows, node)
    end
  end

  if activeTab == "lighting" and #ledEffects > 0 then
    table.insert(rows, ui.label({ key = "led-label", text = noctalia.tr("ui.led-label"), fontSize = 13, color = "on_surface_variant" }))

    local effectOptions = {}
    local effectSelectedIndex = 0
    for i, effect in ipairs(ledEffects) do
      table.insert(effectOptions, effect)
      if effect == ledEffect then
        effectSelectedIndex = i - 1
      end
    end
    table.insert(rows, ui.select({
      key = "led-effect",
      options = effectOptions,
      selectedIndex = effectSelectedIndex,
      enabled = not busy,
      onChange = "onEffectChange",
    }))

    local shownBrightness = brightnessPreview or brightnessPct
    table.insert(rows, ui.label({
      key = "brightness-label",
      text = `{noctalia.tr("ui.brightness-label")} — {shownBrightness}%`,
      fontSize = 13,
      color = "on_surface_variant",
    }))
    table.insert(rows, ui.slider({
      key = "brightness",
      min = 0,
      max = 100,
      step = 1,
      value = shownBrightness,
      enabled = not busy,
      onChange = function(value)
        brightnessPreview = math.floor(tonumber(value) or brightnessPct)
        render()
      end,
      onDragEnd = function(value)
        -- Prefer the live-drag preview over onDragEnd's own `value` arg - see
        -- sliderRow()'s onDragEnd for why.
        local target = brightnessPreview or math.floor(tonumber(value) or brightnessPct)
        brightnessPreview = nil
        if target == brightnessPct then
          render()
          return
        end
        busy = true
        render()
        noctalia.runAsync(
          `pulsar-mouse --profile {profile} --brightness-percent {target}`,
          function(result)
            busy = false
            if type(result) == "table" and result.exitCode == 0 then
              brightnessPct = target
              errorText = nil
            else
              errorText = noctalia.tr("ui.write-failed")
            end
            render()
          end,
          10000
        )
      end,
    }))

    if breatheSpeedRelevant() then
      local shownSpeed = breatheSpeedPreview or breatheSpeed
      table.insert(rows, ui.label({
        key = "speed-label",
        text = `{noctalia.tr("ui.speed-label")} — {shownSpeed}`,
        fontSize = 13,
        color = "on_surface_variant",
      }))
      table.insert(rows, ui.slider({
        key = "speed",
        min = 0,
        max = 100,
        step = 1,
        value = shownSpeed,
        enabled = not busy,
        onChange = function(value)
          breatheSpeedPreview = math.floor(tonumber(value) or breatheSpeed)
          render()
        end,
        onDragEnd = function(value)
          -- Prefer the live-drag preview over onDragEnd's own `value` arg -
          -- see sliderRow()'s onDragEnd for why.
          local target = breatheSpeedPreview or math.floor(tonumber(value) or breatheSpeed)
          breatheSpeedPreview = nil
          if target == breatheSpeed then
            render()
            return
          end
          busy = true
          render()
          noctalia.runAsync(
            `pulsar-mouse --profile {profile} --breathe-speed {target}`,
            function(result)
              busy = false
              if type(result) == "table" and result.exitCode == 0 then
                breatheSpeed = target
                errorText = nil
              else
                errorText = noctalia.tr("ui.write-failed")
              end
              render()
            end,
            10000
          )
        end,
      }))
    end
  end

  panel.render(ui.scroll({ flexGrow = 1, gap = 10 }, rows))
end

-- Clears `busy` on every terminal path (all the early returns below, and
-- the final success path at the end) - NOT on the bootstrap-resync path,
-- which recurses into another readStatus() call that owns clearing it
-- once that one actually finishes. Bug, found in review: onProfileChange
-- sets busy=true then calls this expecting it to clear busy on success,
-- but until this fix it never did on any path - after a successful
-- profile switch the whole panel (every slider/toggle/dropdown, since
-- they're all `enabled = not busy`) went permanently read-only, with no
-- error shown, since nothing was ever wrong from the user's perspective.
local function readStatus()
  if not noctalia.commandExists("pulsar-mouse") then
    busy = false
    errorText = noctalia.tr("ui.not-installed")
    render()
    return
  end
  noctalia.runAsync(
    `pulsar-mouse --status-json --profile {profile}`,
    function(result)
      if type(result) ~= "table" or result.timedOut or result.exitCode ~= 0 then
        busy = false
        errorText = noctalia.tr("ui.no-mouse")
        render()
        return
      end
      local decoded = noctalia.json.decode(result.stdout or "")
      -- type(decoded.dpi) checked here too, not just polling_rate - cli.py
      -- always emits it today so this is theoretical, but decoded.dpi.active
      -- below would otherwise throw on a malformed response and skip
      -- clearing `busy`, the exact failure mode the rest of this function
      -- was just fixed to avoid.
      if type(decoded) ~= "table" or decoded.polling_rate == nil or type(decoded.dpi) ~= "table" then
        busy = false
        errorText = noctalia.tr("ui.no-mouse")
        render()
        return
      end
      numProfiles = decoded.num_profiles or numProfiles
      -- Once-per-open bootstrap: this query targeted --profile {profile}
      -- (the value left over from the last time the panel was open, or the
      -- placeholder 1 on first load), but decoded.active_profile is the
      -- ground truth of what's actually live on the mouse regardless of
      -- that. Resync `profile` to it and re-fetch once so every field below
      -- reflects the real active profile from the start, not some other
      -- profile's stored settings - see `profile`'s own comment above for
      -- why this can legitimately differ.
      --
      -- `profileSynced` is module-scoped and so survives the panel closing,
      -- which used to make this a once-per-*process* bootstrap: only the
      -- very first open ever re-synced. Switching profiles by any other
      -- means afterwards (the physical profile button, `pulsar-mouse
      -- --active-profile`, Fusion on another OS) then left every reopen
      -- showing - and writing to - the stale profile this panel last knew
      -- about. onOpen() clears the flag so each open re-syncs.
      if not profileSynced then
        profileSynced = true
        if decoded.active_profile ~= nil and decoded.active_profile ~= profile then
          profile = decoded.active_profile
          readStatus()
          return
        end
      end
      errorText = nil
      wireless = decoded.wireless == true
      pollingRate = decoded.polling_rate
      pollingRates = decoded.polling_rates or {}
      dpiActive = decoded.dpi.active
      dpiStages = decoded.dpi.stages or {}
      if type(decoded.debounce) == "table" then
        debounce = decoded.debounce
      end
      if type(decoded.angle_snap) == "boolean" then
        angleSnap = decoded.angle_snap
      end
      if type(decoded.ripple_control) == "boolean" then
        rippleControl = decoded.ripple_control
      end
      if type(decoded.motion_sync) == "boolean" then
        motionSync = decoded.motion_sync
      end
      if type(decoded.lod) == "table" and decoded.lod.step ~= nil then
        -- Only the continuous-slider shape (lod_step set) is handled here -
        -- a driver with a discrete lod_values list instead (no "step") isn't
        -- supported by this panel, same as the DPI/polling stage sliders
        -- assume their own value lists are always present and non-empty.
        lod = decoded.lod
      end
      if type(decoded.power_saving) == "table" then
        powerSaving = decoded.power_saving
      end
      if type(decoded.low_power) == "table" then
        lowPower = decoded.low_power
      end
      if type(decoded.led) == "table" then
        ledEffects = decoded.led.effects or {}
        ledEffect = decoded.led.effect
        brightnessPct = decoded.led.brightness_percent
        breatheSpeed = decoded.led.breathe_speed
      end
      busy = false
      render()
    end,
    10000
  )
end

function onOpen(_context)
  -- Re-arm the active-profile resync on every open, not just the first
  -- one of the process - see readStatus()'s own comment for what went
  -- wrong without this. Deliberately not reset anywhere else: by the time
  -- onProfileChange runs, this open's resync has already happened, and
  -- re-arming it there would let a not-yet-settled --status-json read
  -- (still reporting the outgoing profile) undo the switch the user just
  -- made.
  profileSynced = false
  render() -- immediate placeholder while the read below is in flight
  readStatus()
end

function onProfileChange(index, label)
  local optionIndex = tonumber(index)
  if optionIndex == nil then
    return
  end
  local target = optionIndex + 1
  if target == profile then
    return
  end
  busy = true
  render()
  noctalia.runAsync(`pulsar-mouse --active-profile {target}`, function(result)
    if type(result) == "table" and result.exitCode == 0 then
      -- Switching the active profile changes essentially every field this
      -- panel shows (DPI/LOD/LED belong to the newly-active profile now,
      -- and the poll/debounce/etc. group tracks whichever profile is
      -- active directly - see `profile`'s comment above) - a single
      -- optimistic field update like onEffectChange's isn't enough, this
      -- needs a full re-fetch. readStatus() clears `busy` and re-renders
      -- itself once that completes, so neither happens here.
      profile = target
      errorText = nil
      readStatus()
    else
      busy = false
      errorText = noctalia.tr("ui.write-failed")
      render()
    end
  end, 10000)
end

function onEffectChange(index, label)
  local optionIndex = tonumber(index)
  if optionIndex == nil or ledEffects[optionIndex + 1] == nil then
    return
  end
  local effect = ledEffects[optionIndex + 1]
  busy = true
  render()
  noctalia.runAsync(`pulsar-mouse --profile {profile} --led {effect}`, function(result)
    busy = false
    if type(result) == "table" and result.exitCode == 0 then
      ledEffect = effect
      errorText = nil
    else
      errorText = noctalia.tr("ui.write-failed")
    end
    render()
  end, 10000)
end
