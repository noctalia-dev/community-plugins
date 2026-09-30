--!strict
local Razer = require("./razer_dbus.luau")

local function tr(key: string, defaultText: string): string
  if type(noctalia.tr) == "function" then
    local res = noctalia.tr(key)
    if res and res ~= "" and res ~= key then
      return res
    end
  end
  return defaultText
end

local lastRenderedSignature = ""

function onOpen()
  lastRenderedSignature = ""
  update()
end

function onIpc(event: string, payload: string)
  if event == "refresh" then
    lastRenderedSignature = ""
    update()
  end
end

function update()
  local daemonActive = noctalia.state.get("razer_daemon_active")
  local devices = noctalia.state.get("razer_devices") or {}

  -- Build state signature to skip re-rendering if nothing changed
  local sigParts = { tostring(daemonActive), tostring(#devices) }
  for _, dev in ipairs(devices) do
    table.insert(sigParts, string.format("%s:%d:%d:%d:%s:%s",
      dev.serial, dev.dpi or 0, dev.brightness or 0, dev.battery or 0,
      dev.activeLightingMode or "", dev.currentColorHex or ""))
  end
  local sig = table.concat(sigParts, "|")
  if sig == lastRenderedSignature and lastRenderedSignature ~= "" then
    return
  end
  lastRenderedSignature = sig

  -- Case 1: Daemon not running
  if daemonActive == false then
    panel.render(ui.column({ gap = 12, padding = 16, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 32, color = "error" }),
      ui.label({ text = tr("ui.daemon_not_running", "OpenRazer Daemon Not Running"), fontWeight = "bold", fontSize = 14 }),
      ui.label({
        text = tr("ui.start_daemon_hint", "Start the daemon with:\nsystemctl --user start openrazer-daemon"),
        textAlign = "center",
        color = "on_surface_variant",
        fontSize = 12,
      }),
      ui.button({
        text = tr("ui.start_daemon", "Start Daemon"),
        variant = "primary",
        onClick = function()
          noctalia.runAsync({"systemctl", "--user", "start", "openrazer-daemon"}, function(res)
            if res.exitCode == 0 then
              noctalia.notify("OpenRazer", "Started daemon successfully")
              noctalia.runAsync({"noctalia", "msg", "plugin", "detluck/razer:monitor", "all", "refresh"})
            else
              noctalia.notifyError("OpenRazer", "Failed to start daemon")
            end
          end)
        end
      }),
    }))
    return
  end

  -- Case 2: No devices found
  if #devices == 0 then
    panel.render(ui.column({ gap = 12, padding = 20, align = "center" }, {
      ui.glyph({ name = "mouse-2", size = 36, color = "on_surface_variant" }),
      ui.label({ text = tr("ui.no_devices", "No Razer Devices Found"), fontWeight = "bold", fontSize = 14 }),
      ui.label({
        text = tr("ui.no_devices_hint", "Connect a supported Razer mouse, keyboard, or headset via USB / 2.4GHz dongle."),
        textAlign = "center",
        color = "on_surface_variant",
        fontSize = 12,
      }),
      ui.button({
        text = tr("ui.refresh", "Refresh"),
        variant = "outline",
        onClick = function()
          noctalia.runAsync({"noctalia", "msg", "plugin", "detluck/razer:monitor", "all", "refresh"})
        end
      }),
    }))
    return
  end

  -- Case 3: Connected devices
  local children = {}

  -- Title row
  table.insert(children, ui.row({ align = "center", justify = "space_between", paddingV = 4 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "device-gamepad-2", size = 20, color = "primary" }),
      ui.label({ text = tr("ui.panel_title", "Razer Control Center"), fontWeight = "bold", fontSize = 15 }),
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("ui.refresh", "Refresh"),
      onClick = function()
        noctalia.runAsync({"noctalia", "msg", "plugin", "detluck/razer:monitor", "all", "refresh"})
      end
    })
  }))

  table.insert(children, ui.separator({ spacing = 8 }))

  -- Device Cards
  local deviceCards = {}
  for _, dev in ipairs(devices) do
    local devChildren = {}

    -- Device Header & Icon
    local glyphName = "mouse-2"
    local t = (dev.deviceType or ""):lower()
    if t:find("keyboard") or t:find("keypad") then
      glyphName = "keyboard"
    elseif t:find("headset") or t:find("headphone") then
      glyphName = "headphones"
    elseif t:find("mic") then
      glyphName = "microphone"
    elseif t:find("mat") or t:find("pad") then
      glyphName = "square"
    end

    local statusText = tr("ui.wired", "Wired")
    if dev.hasBattery then
      statusText = dev.battery .. "%" .. (dev.isCharging and " ⚡" or "")
    elseif dev.dpi and dev.dpi > 0 and t:find("mouse") then
      statusText = dev.dpi .. " DPI"
    end

    table.insert(devChildren, ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = glyphName, size = 18, color = "primary" }),
        ui.label({ text = dev.name, fontWeight = "bold", fontSize = 13 }),
      }),
      ui.label({
        text = statusText,
        color = (dev.hasBattery and dev.battery <= 20) and "error" or "on_surface_variant",
        fontSize = 12,
        fontWeight = "bold",
      })
    }))

    -- Battery Bar (if battery device)
    if dev.hasBattery then
      table.insert(devChildren, ui.progress({
        progress = dev.battery / 100,
        fill = dev.battery <= 20 and "error" or "primary",
      }))
    end

    -- DPI Section (only for mouse devices)
    if (t:find("mouse") or t == "device" or t == "") and dev.dpi and dev.dpi > 0 then
      table.insert(devChildren, ui.row({ align = "center", justify = "space_between", paddingV = 2 }, {
        ui.label({ text = tr("ui.sensitivity", "Sensitivity (DPI)"), fontSize = 12, fontWeight = "bold" }),
        ui.label({ text = tostring(dev.dpi) .. " DPI", fontSize = 12, fontWeight = "bold", color = "primary" }),
      }))

      -- Helper to build DPI preset pill
      local function makeDpiPill(targetDpi: number)
        local isSelected = (dev.dpi == targetDpi)
        return ui.button({
          text = tostring(targetDpi),
          variant = isSelected and "primary" or "outline",
          selected = isSelected,
          controlSize = "sm",
          flexGrow = 1,
          onClick = function()
            dev.dpi = targetDpi
            dev.customDpiInput = tostring(targetDpi)
            noctalia.state.set("razer_devices", devices)
            lastRenderedSignature = ""
            update()
            Razer.setDPI(dev.serial, targetDpi, function()
              noctalia.notify("Razer DPI", dev.name .. " set to " .. targetDpi .. " DPI")
            end)
          end
        })
      end

      -- Two rows of 3 buttons so 4-digit numbers fit cleanly without truncation
      table.insert(devChildren, ui.row({ gap = 6, justify = "space_between" }, {
        makeDpiPill(800), makeDpiPill(1200), makeDpiPill(1600)
      }))
      table.insert(devChildren, ui.row({ gap = 6, justify = "space_between" }, {
        makeDpiPill(1800), makeDpiPill(2400), makeDpiPill(3200)
      }))

      -- Custom DPI Input Field
      local function applyCustomDpi(valStr)
        local num = tonumber(valStr)
        if num and num >= 100 and num <= 20000 then
          dev.dpi = num
          dev.customDpiInput = tostring(num)
          noctalia.state.set("razer_devices", devices)
          lastRenderedSignature = ""
          update()
          Razer.setDPI(dev.serial, num, function()
            noctalia.notify("Razer DPI", dev.name .. " set to " .. num .. " DPI")
          end)
        else
          noctalia.notifyError("Razer DPI", "Please enter a valid DPI between 100 and 20000")
        end
      end

      table.insert(devChildren, ui.row({ gap = 6, align = "center", paddingV = 2 }, {
        ui.input({
          placeholder = tr("ui.custom_dpi_placeholder", "Custom DPI (e.g. 1500)"),
          value = dev.customDpiInput or "",
          controlSize = "sm",
          flexGrow = 1,
          onChange = function(val)
            dev.customDpiInput = val
          end,
          onSubmit = function(val)
            applyCustomDpi(val)
          end
        }),
        ui.button({
          text = tr("ui.set", "Set"),
          variant = "outline",
          controlSize = "sm",
          onClick = function()
            applyCustomDpi(dev.customDpiInput)
          end
        })
      }))
    end

    -- Brightness Slider
    table.insert(devChildren, ui.row({ align = "center", justify = "space_between", paddingV = 2 }, {
      ui.label({ text = tr("ui.brightness", "LED Brightness"), fontSize = 12, fontWeight = "bold" }),
      ui.label({ text = dev.brightness .. "%", fontSize = 12, color = "on_surface_variant" }),
    }))
    table.insert(devChildren, ui.slider({
      min = 0, max = 100, step = 5, value = dev.brightness, controlSize = "sm",
      onChange = function(val)
        local num = tonumber(val) or 100
        dev.brightness = num
        noctalia.state.set("razer_devices", devices)
        lastRenderedSignature = ""
        update()
        Razer.setBrightness(dev.serial, num)
      end
    }))

    -- Lighting Presets & Custom Color
    local activeMode = dev.activeLightingMode or "theme"
    local activeColor = dev.currentColorHex or "#00FF00"

    -- Function to apply a hex color code
    local function applyHexColor(rawHex)
      if not rawHex or rawHex == "" then return end
      local clean = rawHex:gsub("#", "")
      if #clean == 3 then
        clean = clean:sub(1,1):rep(2) .. clean:sub(2,2):rep(2) .. clean:sub(3,3):rep(2)
      end
      if #clean ~= 6 then
        noctalia.notifyError("Razer Color", "Invalid color hex. Example: #FF0055")
        return
      end
      local r = tonumber(clean:sub(1, 2), 16)
      local g = tonumber(clean:sub(3, 4), 16)
      local b = tonumber(clean:sub(5, 6), 16)
      if not r or not g or not b then
        noctalia.notifyError("Razer Color", "Invalid color characters")
        return
      end

      local formatted = "#" .. clean:upper()
      dev.activeLightingMode = "custom"
      dev.currentColorHex = formatted
      dev.customColorInput = formatted
      noctalia.state.set("razer_devices", devices)
      lastRenderedSignature = ""
      update()
      Razer.setStatic(dev.serial, r, g, b)
      noctalia.notify("Razer Color", dev.name .. " set to " .. formatted)
    end

    table.insert(devChildren, ui.row({ align = "center", justify = "space_between", paddingV = 2 }, {
      ui.label({ text = tr("ui.lighting_effect", "Lighting Effect"), fontSize = 12, fontWeight = "bold" }),
      ui.label({
        text = activeMode == "theme" and tr("ui.theme_sync", "Theme Sync")
          or activeMode == "green" and tr("ui.razer_green", "Razer Green")
          or activeMode == "spectrum" and tr("ui.spectrum", "Spectrum")
          or activeMode == "custom" and activeColor
          or tr("ui.off", "Off"),
        fontSize = 11,
        color = "primary",
        fontWeight = "bold"
      }),
    }))

    -- Preset Buttons Row
    table.insert(devChildren, ui.row({ gap = 6, justify = "space_between", paddingV = 2 }, {
      ui.button({
        text = tr("ui.theme_sync", "Theme Sync"),
        variant = (activeMode == "theme") and "primary" or "outline",
        selected = (activeMode == "theme"),
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          dev.activeLightingMode = "theme"
          noctalia.state.set("razer_devices", devices)
          lastRenderedSignature = ""
          update()
          local primaryHex, found = Razer.getThemeColor()
          local cleanHex = primaryHex:gsub("#", "")
          local r = tonumber(cleanHex:sub(1, 2), 16) or 0
          local g = tonumber(cleanHex:sub(3, 4), 16) or 255
          local b = tonumber(cleanHex:sub(5, 6), 16) or 0
          Razer.setStatic(dev.serial, r, g, b)
          if found then
            noctalia.notify("Razer Lighting", "Synced with theme: #" .. cleanHex)
          else
            noctalia.notify("Razer Lighting", "Theme accent unavailable, defaulted to Razer Green")
          end
        end
      }),
      ui.button({
        text = tr("ui.razer_green", "Razer Green"),
        variant = (activeMode == "green") and "primary" or "outline",
        selected = (activeMode == "green"),
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          dev.activeLightingMode = "green"
          dev.currentColorHex = "#00FF00"
          noctalia.state.set("razer_devices", devices)
          lastRenderedSignature = ""
          update()
          Razer.setStatic(dev.serial, 0, 255, 0)
        end
      }),
      ui.button({
        text = tr("ui.spectrum", "Spectrum"),
        variant = (activeMode == "spectrum") and "primary" or "outline",
        selected = (activeMode == "spectrum"),
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          dev.activeLightingMode = "spectrum"
          noctalia.state.set("razer_devices", devices)
          lastRenderedSignature = ""
          update()
          Razer.setSpectrum(dev.serial)
        end
      }),
      ui.button({
        text = tr("ui.off", "Off"),
        variant = (activeMode == "off") and "primary" or "ghost",
        selected = (activeMode == "off"),
        controlSize = "sm",
        onClick = function()
          dev.activeLightingMode = "off"
          noctalia.state.set("razer_devices", devices)
          lastRenderedSignature = ""
          update()
          Razer.setNone(dev.serial)
        end
      }),
    }))

    -- Custom Color Input Field + Palette Color Picker Button
    table.insert(devChildren, ui.row({ gap = 6, align = "center", paddingV = 2 }, {
      ui.input({
        placeholder = tr("ui.custom_color_placeholder", "Hex color (e.g. #FF0055)"),
        value = dev.customColorInput or "",
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(val)
          dev.customColorInput = val
        end,
        onSubmit = function(val)
          applyHexColor(val)
        end
      }),
      ui.button({
        text = tr("ui.set", "Set"),
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          applyHexColor(dev.customColorInput)
        end
      }),
      ui.button({
        glyph = "palette",
        text = tr("ui.picker", "Picker"),
        variant = (activeMode == "custom") and "primary" or "outline",
        selected = (activeMode == "custom"),
        controlSize = "sm",
        tooltip = "Choose color from palette",
        onClick = function()
          local cur = dev.currentColorHex or "#00FF00"
          if type(noctalia.openColorPicker) == "function" then
            noctalia.openColorPicker(cur, function(picked)
              if picked and picked ~= "" then
                applyHexColor(picked)
              end
            end)
          else
            noctalia.notify("Razer Color", "Please enter a hex color in the text field")
          end
        end
      })
    }))

    table.insert(deviceCards, ui.column({
      gap = 8, padding = 12, fill = "surface_variant/0.4", radius = 10
    }, devChildren))
  end

  table.insert(children, ui.scroll({ flexGrow = 1 }, {
    ui.column({ gap = 10 }, deviceCards)
  }))

  panel.render(ui.column({ gap = 8, padding = 14, width = 430, height = 590 }, children))
end
