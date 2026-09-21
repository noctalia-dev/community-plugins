--!nonstrict
-- Screen Toolkit — headless [[service]].
--
-- Owns every tool pipeline (color pick, OCR, QR, palette, lens, annotate,
-- measure, recording, sharing) plus state persistence. The bar [[widget]], the
-- control-center [[shortcut]], and the main [[panel]] are thin clients: they
-- read the published state and drive this service by writing to the plugin's
-- "command" state channel (or by IPC). A capture can be started even with no
-- UI entry placed.
--
-- Region selection shells out to `slurp` (which draws its own crosshair), then
-- `grim` captures the geometry. No custom overlay is possible in the v5 plugin
-- API, so the legacy in-shell region selector is replaced by slurp.
--
-- Recording runs `wl-screenrec` (preferred) or `wf-recorder`. The raw output
-- lands in /tmp as MP4; GIF is produced on save via record.sh convert-gif.

local PANEL_ID = "alexander/screen-toolkit:panel"
local LEGACY_PANEL_ID = "alexander/screen-toolkit:panel-legacy"
local RESULT_PANEL_ID = "alexander/screen-toolkit:result"

local SCRIPT_CAPTURE = noctalia.pluginDir() .. "/scripts/capture.sh"
local SCRIPT_CAPTURE_NIRI = noctalia.pluginDir() .. "/scripts/capture-niri.sh"
local SCRIPT_OCR = noctalia.pluginDir() .. "/scripts/ocr.sh"
local SCRIPT_LENS = noctalia.pluginDir() .. "/scripts/lens-upload.sh"
local SCRIPT_RECORD = noctalia.pluginDir() .. "/scripts/record.sh"
local SCRIPT_SHARE = noctalia.pluginDir() .. "/scripts/share-upload.sh"
local SCRIPT_PICKER = noctalia.pluginDir() .. "/scripts/color-picker.sh"

local COLOR_PNG = "/tmp/screen-toolkit-colorpicker.png"
local QR_PNG = "/tmp/screen-toolkit-qr.png"
local ANNOTATE_PNG = "/tmp/screen-toolkit-annotate.png"

local MAX_HISTORY = 8

-- ── Small helpers ──────────────────────────────────────────────────────────

local function cfg(key)
  return noctalia.getConfig(key)
end

local function log(msg)
  noctalia.log(`screen-toolkit: {msg}`)
end

local function trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function copyFileUri(path)
  local escaped = tostring(path):gsub(" ", "%%20"):gsub("'", "%%27"):gsub('"', "%%22")
  noctalia.copyToClipboard(`file://{escaped}`, "text/uri-list")
end

-- Compositor detection. `niri msg` talks over a socket whose path niri exports
-- as NIRI_SOCKET; when that is set we route annotate-window through the niri
-- capture script, otherwise we fall back to the Hyprland path (hyprctl).
local function isNiri()
  return (noctalia.getenv("NIRI_SOCKET") or "") ~= ""
end

-- Whether the cursor is excluded from recordings. Grim screenshots exclude the
-- cursor by default, so screenshots do not need a pointer-moving workaround.
-- This also keeps color picking and slurp interaction reliable on Hyprland.
local cursorHidden = true
local CAPTURE_DELAY = 0.15

-- Grim excludes the cursor unless `-c` is passed. Do not move the
-- pointer: that breaks color picking and is compositor-specific. Recorder
-- backends receive their own cursor flag in buildRecorderArgv below.
local function hideCursorForCapture(argv, cb, extraDelay)
  noctalia.runAsync({ "sleep", tostring(CAPTURE_DELAY) }, function()
    if extraDelay then
      noctalia.runAsync({ "sleep", tostring(extraDelay) }, function()
        noctalia.runAsync(argv, cb)
      end)
    else
      noctalia.runAsync(argv, cb)
    end
  end)
end

-- Scripts that capture via grim read this variable to decide on `-c`.
-- Argv exec has no shell, so it is set via `env` instead of a prefix.
local function withCaptureEnv(argv)
  if cursorHidden then return argv end
  table.insert(argv, 1, "SCREEN_TOOLKIT_CAPTURE_CURSOR=1")
  table.insert(argv, 1, "env")
  return argv
end

local function publish(key, value)
  noctalia.state.set(key, value)
end

-- `noctalia.outputs()` reports logical geometry; grim, gpu-screen-recorder, wl_screenrec and wf-recorder want logical geometry. Except for gpu-screen-recorder, they all take geometry as formated by this function.
local function focusedGeometry()
  local outputs = noctalia.outputs()
  for _, o in ipairs(outputs) do
    if o.focused then
      return string.format(
        "%d,%d %dx%d",
        o.x,
        o.y,
        o.width,
        o.height
      )
    end
  end
  if outputs and #outputs > 0 then
    local o = outputs[1]
    return string.format(
      "%d,%d %dx%d",
      o.x,
      o.y,
      o.width,
      o.height
    )
  end
  return nil
end

local function parseGeometry(geom)
  local gx, gy, gw, gh = geom:match("^(-?%d+),(-?%d+)%s+(%d+)x(%d+)$")
  if not gx then return nil end
  return tonumber(gx), tonumber(gy), tonumber(gw), tonumber(gh)
end

local function screenshotDir()
  local p = noctalia.expandPath(cfg("screenshot-path") or "")
  if p == "" then p = noctalia.expandPath("~/Pictures/Screenshots") end
  return p
end

local function videoDir()
  local p = noctalia.expandPath(cfg("video-path") or "")
  if p == "" then p = noctalia.expandPath("~/Videos") end
  return p
end

local function buildFilename(tool, ext)
  local stem = noctalia.formatTime(cfg("filename-format") or "")
  if stem == nil or stem == "" then
    stem = tool .. "-" .. noctalia.formatTime("%Y-%m-%d_%H-%M-%S")
  end
  return stem .. ext
end

-- ── Region selection (slurp) ───────────────────────────────────────────────

local slurping = false
local ocrRunning = false
local ocrSerial = 0

-- Draws the slurp crosshair after a short delay so the just-closed panel's
-- close animation is not captured. Invokes callback(geom) or nothing on cancel.
local function slurpGeometry(callback)
  if slurping then
    noctalia.notify(noctalia.tr("panel.running"))
    return
  end
  slurping = true
  -- slurp blocks for as long as the user is dragging the selection. Give it a
  -- generous timeout; the default runAsync one cancels a slow/long drag.
  if not noctalia.runAsync({ "sleep", "0.3" }, function()
    noctalia.runAsync({ "slurp", "-f", "%x,%y %wx%h" }, function(res)
      slurping = false
      if res.exitCode ~= 0 then return end -- cancelled
      local geom = trim(res.stdout or "")
      if geom == "" then return end
      callback(geom)
    end, 600000)
  end) then
    slurping = false
  end
end

local function grimRegion(geom, dest, cb)
  local argv = { "grim" }
  if not cursorHidden then argv[#argv + 1] = "-c" end
  argv[#argv + 1] = "-g"
  argv[#argv + 1] = geom
  argv[#argv + 1] = dest
  hideCursorForCapture(argv, cb)
end

-- ── Color conversions ──────────────────────────────────────────────────────

local function clamp(n)
  return math.max(0, math.min(255, n))
end

local function rgbToHsv(r, g, b)
  local rn, gn, bn = r / 255, g / 255, b / 255
  local max, min = math.max(rn, gn, bn), math.min(rn, gn, bn)
  local d = max - min
  local h, sat, val = 0, 0, max
  if d ~= 0 then
    sat = d / max
    if max == rn then
      h = ((gn - bn) / d + (gn < bn and 6 or 0)) % 6
    elseif max == gn then
      h = (bn - rn) / d + 2
    else
      h = (rn - gn) / d + 4
    end
    h = math.round(h * 60)
  end
  return h, math.round(sat * 100), math.round(val * 100)
end

local function rgbToHsl(r, g, b)
  local rn, gn, bn = r / 255, g / 255, b / 255
  local max, min = math.max(rn, gn, bn), math.min(rn, gn, bn)
  local d = max - min
  local h, l = 0, (max + min) / 2
  local s = if d == 0 then 0 else d / (1 - math.abs(2 * l - 1))
  if d ~= 0 then
    if max == rn then
      h = ((gn - bn) / d + (gn < bn and 6 or 0)) % 6
    elseif max == gn then
      h = (bn - rn) / d + 2
    else
      h = (rn - gn) / d + 4
    end
    h = h / 6
  end
  return math.floor(h * 360 + 0.5), math.round(s * 100), math.round(l * 100)
end

-- ── Persistence (survives restarts; plugin data dir is update-safe) ────────

local DATA_DIR = noctalia.pluginDataDir()
local RESULTS_FILE = DATA_DIR .. "/results.json"
local HISTORY_FILE = DATA_DIR .. "/color-history.json"

local function loadState()
  local raw = noctalia.readFile(RESULTS_FILE)
  if raw then
    local d = noctalia.json.decode(raw)
    if type(d) == "table" then
      if d.activeTool then publish("activeTool", d.activeTool) end
      if d.colorResult then publish("colorResult", d.colorResult) end
      if d.ocrResult then publish("ocrResult", d.ocrResult) end
      if d.qrResult then publish("qrResult", d.qrResult) end
      if d.paletteColors then publish("paletteColors", d.paletteColors) end
    end
  end
  local hraw = noctalia.readFile(HISTORY_FILE)
  if hraw then
    local d = noctalia.json.decode(hraw)
    if type(d) == "table" then publish("colorHistory", d) end
  end
end

local function saveResults()
  local d = {
    activeTool = noctalia.state.get("activeTool"),
    colorResult = noctalia.state.get("colorResult"),
    ocrResult = noctalia.state.get("ocrResult"),
    qrResult = noctalia.state.get("qrResult"),
    paletteColors = noctalia.state.get("paletteColors"),
  }
  local enc = noctalia.json.encode(d)
  if enc then noctalia.writeFile(RESULTS_FILE, enc) end

  local h = noctalia.state.get("colorHistory") or {}
  local henc = noctalia.json.encode(h)
  if henc then noctalia.writeFile(HISTORY_FILE, henc) end
end

local function pushHistory(hex)
  hex = hex:upper()
  local history = noctalia.state.get("colorHistory") or {}
  for i, c in ipairs(history) do
    if c == hex then
      table.remove(history, i)
      break
    end
  end
  table.insert(history, 1, hex)
  while #history > MAX_HISTORY do
    table.remove(history)
  end
  publish("colorHistory", history)
end

-- ── Tools: color picker ────────────────────────────────────────────────────

local function runColorPicker()
  -- hyprpicker waits for an interactive pointer selection. Keep it on the
  -- long-lived stream API; captured runAsync callbacks can time out while the
  -- user is still choosing a color.
  -- runStream only accepts a shell string on the host, so this one keeps the
  -- shell form. COLOR_PNG is a constant without spaces, needing no quoting.
  local pickerPrefix = if cursorHidden then "" else "SCREEN_TOOLKIT_CAPTURE_CURSOR=1 "
  noctalia.runStream(`sleep {CAPTURE_DELAY}; {pickerPrefix}{SCRIPT_PICKER} {COLOR_PNG}`, function(line)
    local r, g, b = tostring(line):match("^(%d+)%s+(%d+)%s+(%d+)$")
    if not r then return end
    r, g, b = clamp(tonumber(r)), clamp(tonumber(g)), clamp(tonumber(b))
    local hex = string.format("#%02X%02X%02X", r, g, b)
    local rgb = string.format("rgb(%d, %d, %d)", r, g, b)
    local h, s, v = rgbToHsv(r, g, b)
    local hh, ss, ll = rgbToHsl(r, g, b)
    local hsv = string.format("hsv(%d, %d%%, %d%%)", h, s, v)
    local hsl = string.format("hsl(%d, %d%%, %d%%)", hh, ss, ll)

    noctalia.copyToClipboard(hex, "text/plain;charset=utf-8")
    pushHistory(hex)
    publish("colorResult", {
      hex = hex, rgb = rgb, hsv = hsv, hsl = hsl,
      capturePath = COLOR_PNG, cacheBust = os.time(),
    })
    publish("activeTool", "colorpicker")
    saveResults()
    noctalia.togglePanel(RESULT_PANEL_ID)
  end)
end

-- ── Tools: OCR ─────────────────────────────────────────────────────────────

local function ocrParams(w, h)
  local area = w * h
  local upscale = ""
  if h < 30 then
    upscale = "-resize 400%"
  elseif area < 50000 or w < 200 then
    upscale = "-resize 200%"
  end
  local ratio = w / math.max(h, 1)
  local psm = "3"
  if ratio > 8 then
    psm = "7"
  elseif area < 60000 then
    psm = "6"
  elseif h < 40 then
    psm = "7"
  end
  return upscale, psm
end

local OCR_EXIT_KEYS = {
  [2] = "ocr.exit_args",
  [3] = "ocr.exit_capture",
  [4] = "ocr.exit_process",
}

local function runOcr()
  if ocrRunning then
    noctalia.notify(noctalia.tr("panel.running"))
    return
  end
  slurpGeometry(function(geom)
    ocrRunning = true
    ocrSerial = ocrSerial + 1
    local ocrPath = "/tmp/screen-toolkit-ocr-" .. tostring(os.time()) .. "-" .. tostring(ocrSerial) .. ".png"
    local gx, gy, gw, gh = parseGeometry(geom)
    if not gx then
      ocrRunning = false
      return
    end
    local lang = cfg("selected-ocr-lang") or "eng"
    local upscale, psm = ocrParams(gw, gh)
    local argv = withCaptureEnv({ SCRIPT_OCR, tostring(gx), tostring(gy), tostring(gw), tostring(gh), lang, upscale, tostring(psm), ocrPath })
    hideCursorForCapture(argv, function(res)
      ocrRunning = false
      if res.exitCode == 1 then
        noctalia.notifyError(noctalia.tr("messages.missing_dep", { dep = trim(res.stdout or "") }))
        return
      elseif res.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr(OCR_EXIT_KEYS[res.exitCode] or "ocr.exit_unknown", { code = tostring(res.exitCode) }))
        return
      end
      local text = trim(res.stdout or "")
      if text == "" then
        noctalia.notifyError(noctalia.tr("messages.no_text"))
        return
      end
      noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
      publish("ocrResult", {
        text = text,
        capturePath = ocrPath,
        cacheBust = tostring(os.time()) .. "-" .. tostring(ocrSerial),
        gw = tonumber(gw),
        gh = tonumber(gh),
      })
      publish("translateResult", nil)
      publish("activeTool", "ocr")
      saveResults()
      noctalia.togglePanel(RESULT_PANEL_ID)
    end)
  end)
end

local function ocrSearch(payload)
  local result = noctalia.state.get("ocrResult")
  local text = if type(payload) == "table" and type(payload.text) == "string"
    then payload.text
    else type(result) == "table" and result.text or nil
  if not text or text == "" then return end
  local url = cfg("search-engine-url")
  if url == nil or url == "" then
    url = "https://www.google.com/search?q="
  end
  local encoded = noctalia.string.urlEncode(text)
  if url:find("{text}", 1, true) then
    url = url:gsub("{text}", function() return encoded end)
  else
    url = url .. encoded
  end
  noctalia.runAsync({ "xdg-open", url })
end

local function ocrTranslate(payload)
  local result = noctalia.state.get("ocrResult")
  local text = if type(payload) == "table" and type(payload.text) == "string"
    then payload.text
    else type(result) == "table" and result.text or nil
  if not text or text == "" then return end
  if not noctalia.commandExists("trans") then
    noctalia.notifyError(noctalia.tr("messages.missing_dep", { dep = "translate-shell" }))
    return
  end
  publish("translateResult", nil)
  local targetLang = if type(payload) == "table" then payload.lang else payload
  local lang = if type(targetLang) == "string" and targetLang ~= "" then targetLang else "en"
  noctalia.runAsync({ "trans", "-brief", "-no-bidi", "-to", lang, text }, function(res)
    if res.exitCode ~= 0 then
      publish("translateResult", noctalia.tr("messages.translate_failed"))
      return
    end
    -- trans bidi conversion outputs presentation-forms + terminal padding (visual order);
    -- -no-bidi gives logical order (U+0600) for Qt/HarfBuzz shaping. Collapse stray newlines.
    local out = trim(res.stdout or "")
    out = out:gsub("%s+", " ")
    -- strip BOM FEFF that trans emits in bidi mode
    out = out:gsub("^\239\187\191", "")
    publish("translateResult", out)
  end)
end

-- ── Tools: QR / palette / lens ─────────────────────────────────────────────

local function runQr()
  slurpGeometry(function(geom)
      hideCursorForCapture(withCaptureEnv({ SCRIPT_CAPTURE, "qr", geom }), function(res)
      if res.exitCode ~= 0 or trim(res.stdout or "") == "" then
        noctalia.notifyError(noctalia.tr("messages.no_qr"))
        return
      end
      local text = trim(res.stdout or "")
      noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
      publish("qrResult", { text = text, capturePath = QR_PNG })
      publish("activeTool", "qr")
      saveResults()
      noctalia.togglePanel(RESULT_PANEL_ID)
    end)
  end)
end

local function runPalette()
  slurpGeometry(function(geom)
      hideCursorForCapture(withCaptureEnv({ SCRIPT_CAPTURE, "palette", geom }), function(res)
      if res.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr("messages.palette_failed"))
        return
      end
      local colors = {}
      for line in (res.stdout or ""):gmatch("[^\n]+") do
        local c = trim(line)
        if c:match("^#%x%x%x%x%x%x$") then
          colors[#colors + 1] = c:upper()
        end
      end
      local seen, out = {}, {}
      for _, c in ipairs(colors) do
        if not seen[c] then
          seen[c] = true
          out[#out + 1] = c
        end
      end
      if #out == 0 then
        noctalia.notifyError(noctalia.tr("messages.palette_failed"))
        return
      end
      noctalia.copyToClipboard(table.concat(out, "\n"), "text/plain;charset=utf-8")
      publish("paletteColors", out)
      publish("activeTool", "palette")
      saveResults()
      noctalia.togglePanel(RESULT_PANEL_ID)
    end)
  end)
end

local function runLens()
  slurpGeometry(function(geom)
    local gx, gy, gw, gh = parseGeometry(geom)
    if not gx then return end
    noctalia.runAsync(withCaptureEnv({ SCRIPT_LENS, tostring(gx), tostring(gy), tostring(gw), tostring(gh) }), function(res)
      if res.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr("messages.lens_failed"))
      end
    end)
  end)
end

-- ── Tools: measure ─────────────────────────────────────────────────────────

local function runMeasure()
  slurpGeometry(function(geom)
    local gx, gy, gw, gh = parseGeometry(geom)
    if not gx or not gw or not gh then return end
    local text = string.format("%d x %d px", gw, gh)
    noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
    publish("measureResult", { width = gw, height = gh, text = text })
    noctalia.notify(noctalia.tr("messages.measure_result", { width = tostring(gw), height = tostring(gh) }))
  end)
end

-- ── Tools: annotate (external editor handoff) ──────────────────────────────

local function openAnnotator(file)
  publish("activeTool", "annotate")
  publish("annotateResult", { capturePath = file })
  if noctalia.commandExists("swappy") then
    noctalia.runAsync({ "swappy", "-f", file })
  elseif noctalia.commandExists("tensaku") then
    noctalia.runAsync({ "tensaku", "-f", file })
  elseif noctalia.commandExists("satty") then
    local destDir = screenshotDir()
    local out = `{destDir}/{buildFilename("annotate", ".png")}`
    noctalia.runAsync({ "satty", "--filename", file, "--output-filename", out })
  elseif noctalia.commandExists("gimp") then
    noctalia.runAsync({ "gimp", file })
  else
    -- No annotation editor installed: hand the capture over via the clipboard
    -- so the tool still does something useful.
    copyFileUri(file)
    noctalia.notify(noctalia.tr("messages.no_annotator"))
    return
  end
end

local function annotateRegion()
  slurpGeometry(function(geom)
    grimRegion(geom, ANNOTATE_PNG, function(res)
      if res.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr("messages.capture_failed"))
        return
      end
      openAnnotator(ANNOTATE_PNG)
    end)
  end)
end

local function annotateFullscreen()
  local out = noctalia.focusedOutputName()
  local argv = { "grim" }
  if not cursorHidden then argv[#argv + 1] = "-c" end
  if out and out ~= "" then
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = out
  end
  argv[#argv + 1] = ANNOTATE_PNG
  -- Give transient UI a moment to clear before the fullscreen grab.
  hideCursorForCapture(argv, function(res)
    if res.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("messages.capture_failed"))
      return
    end
    openAnnotator(ANNOTATE_PNG)
  end, 0.2)
end

local function annotateWindow()
  local script, dep
  if isNiri() then
    script, dep = SCRIPT_CAPTURE_NIRI, "niri"
  else
    script, dep = SCRIPT_CAPTURE, "hyprctl"
  end
  if not noctalia.commandExists(dep) then
    noctalia.notifyError(noctalia.tr("messages.missing_dep", { dep = dep }))
    return
  end
  noctalia.runAsync({ "sleep", tostring(CAPTURE_DELAY) }, function()
    noctalia.runAsync(withCaptureEnv({ script, "annotate-window" }), function(res)
    if res.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("messages.capture_failed"))
      return
    end
    openAnnotator(ANNOTATE_PNG)
    end)
  end)
end

-- ── Recording ──────────────────────────────────────────────────────────────

-- Recorder availability. `gpu-screen-recorder` (NVENC) is the best choice on
-- NVIDIA GPUs but can only capture monitors/windows — it cannot record an
-- arbitrary region — so fullscreen capture prefers it while region capture
-- falls back to wl-screenrec / wf-recorder.
local gsrAvailable = false
local wlScreenrecAvailable = false
local wfRecorderAvailable = false
local lastRecorderLog = ""

local recordState = "idle" -- idle | recording | converting | ready
local recordFormat = "mp4"
local rawPath = ""
local recordPath = ""
local recordStartedAt = nil

local function refreshRecorders()
  gsrAvailable = noctalia.commandExists("gpu-screen-recorder")
  wlScreenrecAvailable = noctalia.commandExists("wl-screenrec")
  wfRecorderAvailable = noctalia.commandExists("wf-recorder")
  local key = string.format(
    "%s|%s|%s", tostring(gsrAvailable), tostring(wlScreenrecAvailable), tostring(wfRecorderAvailable)
  )
  if key ~= lastRecorderLog then
    lastRecorderLog = key
    log("recorders: " .. key)
  end
end

local function bestFullscreenRecorder()
  if gsrAvailable then return "gpu-screen-recorder" end
  if wlScreenrecAvailable then return "wl-screenrec" end
  if wfRecorderAvailable then return "wf-recorder" end
  return ""
end

local function bestRegionRecorder()
  if wlScreenrecAvailable then return "wl-screenrec" end
  if wfRecorderAvailable then return "wf-recorder" end
  return ""
end

local function setRecordState(next)
  if recordState == next then return end
  recordState = next
  publish("recordState", recordState)
  publish("recording", recordState == "recording")
  publish("recordPath", recordPath)
  publish("recordFormat", recordFormat)
  publish("recordStartedAt", if recordState == "recording" then recordStartedAt else nil)
end

local overrideAudioOut = nil
local overrideAudioIn = nil

local function getAudioOut()
  if overrideAudioOut ~= nil then return overrideAudioOut end
  return cfg("record-audio-out") == true
end

local function getAudioIn()
  if overrideAudioIn ~= nil then return overrideAudioIn end
  return cfg("record-audio-in") == true
end

local function gsrAudioArgv()
  local audioOut = getAudioOut()
  local audioIn = getAudioIn()
  if audioOut and audioIn then
    return { "-a", "default_output|default_input", "-ac", "aac" }
  elseif audioOut then
    return { "-a", "default_output", "-ac", "aac" }
  elseif audioIn then
    return { "-a", "default_input", "-ac", "aac" }
  end
  return {}
end

-- Resolve the PulseAudio/PipeWire source for single-source wf-recorder /
-- wl-screenrec audio. Argv exec has no shell, so `$(pactl ...)` cannot be
-- embedded in the recorder command; look the device up first, then launch.
local function resolveAudioDevice(source, callback)
  local query = if source == "in" then "get-default-source" else "get-default-sink"
  noctalia.runAsync({ "pactl", query }, function(res)
    local name = trim(res.stdout or "")
    if res.exitCode ~= 0 or name == "" then
      callback(nil)
      return
    end
    callback(if source == "in" then name else name .. ".monitor")
  end)
end

local function buildRecorderArgv(bin, geom, out, device)
  local audioOut, audioIn = getAudioOut(), getAudioIn()
  local isRegion = geom and geom ~= "" and geom ~= "screen"
  local fps = tostring(cfg("record-fps") or 60)
  local codec = cfg("record-codec") or "h264"

  if bin == "gpu-screen-recorder" then
    local cursor = cursorHidden and "no" or "yes"
    local target = { "-w", "screen" }
    if isRegion then
      local gx, gy, gw, gh = tostring(geom):match("^(-?%d+),(-?%d+) (%d+)x(%d+)$")
      if gx then target = { "-w", "region", "-region", string.format("%sx%s+%s+%s", gw, gh, gx, gy) } end
    else
      local fg = focusedGeometry()
      if fg then
        local fx, fy, fw, fh = fg:match("^(-?%d+),(-?%d+) (%d+)x(%d+)$")
        if fx then target = { "-w", "region", "-region", string.format("%sx%s+%s+%s", fw, fh, fx, fy) } end
      end
    end
    local argv = { bin }
    for _, t in ipairs(target) do argv[#argv + 1] = t end
    argv[#argv + 1] = "-f"
    argv[#argv + 1] = fps
    argv[#argv + 1] = "-k"
    argv[#argv + 1] = codec
    argv[#argv + 1] = "-bm"
    argv[#argv + 1] = "qp"
    argv[#argv + 1] = "-ffmpeg-opts"
    argv[#argv + 1] = "qp=25"
    argv[#argv + 1] = "-cursor"
    argv[#argv + 1] = cursor
    argv[#argv + 1] = "-cr"
    argv[#argv + 1] = "limited"
    for _, a in ipairs(gsrAudioArgv()) do argv[#argv + 1] = a end
    argv[#argv + 1] = "-v"
    argv[#argv + 1] = "no"
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = out
    return argv
  end

  local isWl = bin == "wl-screenrec"
  local argv = { bin }
  if isRegion then
    argv[#argv + 1] = "-g"
    argv[#argv + 1] = geom
  else
    local focused = noctalia.focusedOutputName()
    if focused and focused ~= "" then
      argv[#argv + 1] = "-o"
      argv[#argv + 1] = focused
    else
      local fg = focusedGeometry()
      if fg then
        argv[#argv + 1] = "-g"
        argv[#argv + 1] = fg
      end
    end
  end
  argv[#argv + 1] = "-f"
  argv[#argv + 1] = out

  if isWl then
    argv[#argv + 1] = "-m"
    argv[#argv + 1] = fps
    argv[#argv + 1] = "--codec"
    argv[#argv + 1] = if codec == "h264" then "avc" else codec
    if cursorHidden then argv[#argv + 1] = "--no-cursor" end
  else
    argv[#argv + 1] = "-r"
    argv[#argv + 1] = fps
  end

  if audioOut and audioIn then
    argv[#argv + 1] = if isWl then "--audio" else "-a"
  elseif audioOut or audioIn then
    if device and device ~= "" then
      if isWl then
        argv[#argv + 1] = "--audio"
        argv[#argv + 1] = "--audio-device"
        argv[#argv + 1] = device
      else
        argv[#argv + 1] = "--audio=" .. device
      end
    else
      argv[#argv + 1] = if isWl then "--audio" else "-a"
    end
  end

  return argv
end

local function launchRecord(geom, format, bin, device)
  rawPath = `/tmp/screen-toolkit-record-{os.time()}.mp4`
  recordFormat = if format == "gif" then "gif" else "mp4"
  publish("recordFormat", recordFormat)
  recordPath = ""
  local argv = buildRecorderArgv(bin, geom, rawPath, device)
  log(`starting recording: {table.concat(argv, " ")}`)
  if #argv == 0 then
    rawPath = ""
    setRecordState("idle")
    noctalia.notifyError(noctalia.tr("messages.recording_failed"))
    return
  end
  -- Launch detached (no callback): the recorder keeps running after runAsync
  -- returns, exactly like the built-in screen recorder does. A tracked
  -- (callback) runAsync owns the command's process group and tears it down
  -- when it finishes, killing a backgrounded recorder. Direct exec has no
  -- wrapper shell, so the stop path's pkill matches the recorder's own
  -- `-f <rawPath>` argument.
  if not noctalia.runAsync(argv) then
    rawPath = ""
    setRecordState("idle")
    noctalia.notifyError(noctalia.tr("messages.recording_failed"))
    return
  end
  recordStartedAt = os.time()
  setRecordState("recording")
  noctalia.notify(noctalia.tr("plugin_name"), noctalia.tr("messages.recording_started"))
end

local function startRecord(geom, format, bin)
  refreshRecorders()
  if bin == "" then
    noctalia.notifyError(noctalia.tr("messages.no_recorder"))
    return
  end
  -- clean up old thumb so it doesn't stay stuck in preview
  if recordState ~= "idle" then return end
  local audioOut, audioIn = getAudioOut(), getAudioIn()
  if (audioOut and not audioIn) or (audioIn and not audioOut) then
    resolveAudioDevice(if audioOut then "out" else "in", function(device)
      if device == nil then log("audio device lookup failed; recording with default device") end
      launchRecord(geom, format, bin, device)
    end)
    return
  end
  launchRecord(geom, format, bin, nil)
end

local function waitForFileStable(path, callback, attempts, previousSize)
  attempts = attempts or 60
  noctalia.runAsync({ "stat", "-c", "%s", path }, function(res)
    local size = trim(res.stdout or "")
    local numSize = tonumber(size)
    if res.exitCode == 0 and numSize and numSize > 0 then
      if previousSize == numSize then
        callback(true)
        return
      end
      noctalia.runAsync({ "sleep", "0.3" }, function()
        waitForFileStable(path, callback, attempts - 1, numSize)
      end)
      return
    end
    if attempts <= 0 then
      callback(numSize ~= nil and numSize > 0)
      return
    end
    noctalia.runAsync({ "sleep", "0.2" }, function()
      waitForFileStable(path, callback, attempts - 1, previousSize)
    end)
  end)
end

local function parseRecordInfo(raw)
  local d, wh, size = tostring(raw):match("([%d%.]+)|(%d+x%d+)|(%d+)")
  local w, h = 0, 0
  if wh then
    local ww, hh = wh:match("(%d+)x(%d+)")
    w, h = tonumber(ww) or 0, tonumber(hh) or 0
  end
  return {
    duration = tonumber(d) or 0,
    width = w,
    height = h,
    size = tonumber(size) or 0,
  }
end

local function finalizeRecord(format, copyToClipboard)
  if rawPath == "" then return end
  local destDir = videoDir()
  local ext
  if format == "gif" then ext = ".gif" elseif format == "mov" then ext = ".mov" else ext = ".mp4" end
  local dest = destDir .. "/" .. buildFilename("record", ext)
  setRecordState("converting")
  local argv
  if format == "gif" then
    argv = { SCRIPT_RECORD, "convert-gif", rawPath, dest, tostring(cfg("gif-max-seconds") or 0) }
  elseif format == "mov" then
    argv = { SCRIPT_RECORD, "convert-mov", rawPath, dest }
  else
    argv = { SCRIPT_RECORD, "convert-mp4", rawPath, dest }
  end
  noctalia.runAsync(argv, function(res)
    if res.exitCode ~= 0 then
      setRecordState("idle")
      noctalia.notifyError(noctalia.tr("messages.recording_failed"))
      return
    end
    recordPath = dest
    rawPath = ""
    setRecordState("idle")
    if copyToClipboard then
      copyFileUri(dest)
      noctalia.notify(noctalia.tr("panel.copied_to_clipboard"), dest)
    else
      noctalia.notify(noctalia.tr("messages.saved_to", { path = dest }))
    end
  end, 600000)
end

local function recordStop()
  if recordState ~= "recording" then return end
  setRecordState("converting")
  noctalia.notify(noctalia.tr("plugin_name"), noctalia.tr("messages.recording_stopped"))
  -- rawPath is unique per recording, so pkill scopes to our recorder only and
  -- never touches the built-in screen recorder's process. pkill never matches
  -- itself, and direct exec leaves no wrapper shell to match either.
  noctalia.runAsync({ "pkill", "-INT", "-f", rawPath }, function()
    waitForFileStable(rawPath, function(ok)
      if not ok then
        setRecordState("idle")
        noctalia.notifyError(noctalia.tr("messages.recording_failed"))
        return
      end
      local skipConfirm = cfg("record-skip-confirmation") == true
      local toClipboard = cfg("record-copy-to-clipboard") == true
      if toClipboard then
        finalizeRecord(recordFormat, true)
      elseif skipConfirm then
        finalizeRecord(recordFormat, false)
      else
        -- Extract a mid-frame thumbnail so the result panel can preview the
        -- recording, then probe it for size / duration / resolution.
        noctalia.runAsync({ SCRIPT_RECORD, "thumb", rawPath }, function()
          noctalia.runAsync({ "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", rawPath }, function(durRes)
            local duration = trim(durRes.stdout or "")
            noctalia.runAsync({ "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=s=x:p=0", rawPath }, function(whRes)
              local wh = trim(whRes.stdout or "")
              noctalia.runAsync({ "stat", "-c", "%s", rawPath }, function(statRes)
                local size = trim(statRes.stdout or "")
                publish("recordInfo", parseRecordInfo(`{duration}|{wh}|{size}`))
                setRecordState("ready")
                noctalia.togglePanel(RESULT_PANEL_ID)
              end)
            end)
          end)
        end)
      end
    end)
  end)
end

local function recordDiscard()
  if rawPath ~= "" then
    noctalia.runAsync({ "rm", "-f", rawPath })
    rawPath = ""
  end
  -- clean up old thumb so it doesn't stay stuck in preview
  setRecordState("idle")
end

-- A recording that finished but was never saved is superseded the moment the
-- user runs any other capture tool; drop its temp file so the result panel
-- can't get stuck showing the stale "save recording" card.
local function discardPendingRecording()
  if recordState ~= "ready" then return end
  recordDiscard()
end

local SHARE_EXIT_KEYS = {
  [1] = "messages.share_bad_args",
  [2] = "messages.share_file_not_found",
  [3] = "messages.share_missing_dep",
  [4] = "messages.share_request_failed",
  [5] = "messages.share_invalid_response",
  [6] = "messages.share_file_too_large",
}

-- ── Sharing ────────────────────────────────────────────────────────────────

local function shareFile(file)
  if file == nil or file == "" then
    noctalia.notifyError(noctalia.tr("messages.share_bad_args"))
    return
  end
  local apiKey = cfg("x02-api-key") or ""
  local expiry = cfg("x02-expiry") or "7d"
  noctalia.runAsync(
    { SCRIPT_SHARE, file, apiKey, expiry },
    function(res)
      if res.exitCode ~= 0 then
        local msg = SHARE_EXIT_KEYS[res.exitCode]
        noctalia.notifyError(if msg then noctalia.tr(msg) else noctalia.tr("messages.share_unknown_error"))
        return
      end
      local url = trim(res.stdout or "")
      if url == "" then
        noctalia.notifyError(noctalia.tr("messages.share_invalid_response"))
        return
      end
      noctalia.copyToClipboard(url, "text/plain;charset=utf-8")
      noctalia.notify(noctalia.tr("panel.share_url"), url)
    end
  )
end

-- ── Result housekeeping ────────────────────────────────────────────────────

local function clearResult()
  publish("activeTool", nil)
  publish("colorResult", nil)
  publish("ocrResult", nil)
  publish("translateResult", nil)
  publish("qrResult", nil)
  publish("paletteColors", nil)
  publish("annotateResult", nil)
  saveResults()
end

local function clearHistory()
  publish("colorHistory", {})
  saveResults()
end

local function setCursorHidden(payload)
  cursorHidden = payload ~= "false"
  publish("cursorHidden", cursorHidden)
  log(`cursor hidden: {tostring(cursorHidden)}`)
end

-- ── Dispatch ───────────────────────────────────────────────────────────────

local function runRecordRegion(format)
  refreshRecorders()
  local bin = bestRegionRecorder()
  if bin == "" then noctalia.notifyError(noctalia.tr("messages.no_recorder")) return end
  slurpGeometry(function(geom) startRecord(geom, format, bin) end)
end

local function runRecordFullscreen(format)
  refreshRecorders()
  local bin = bestFullscreenRecorder()
  if bin == "" then noctalia.notifyError(noctalia.tr("messages.no_recorder")) return end
  startRecord("screen", format, bin)
end

local HANDLERS = {
  colorPicker = runColorPicker, ocr = runOcr, qr = runQr, palette = runPalette, lens = runLens, measure = runMeasure,
  annotate = annotateRegion, annotateFullscreen = annotateFullscreen, annotateWindow = annotateWindow,
  record = function() runRecordRegion("gif") end, recordMp4 = function() runRecordRegion("mp4") end,
  recordFullscreen = function() runRecordFullscreen("gif") end, recordFullscreenMp4 = function() runRecordFullscreen("mp4") end,
  recordStop = recordStop,
  recordSave = function(payload) finalizeRecord((type(payload) == "table" and payload.format or nil) or recordFormat, false) end,
  recordCopy = function() finalizeRecord(recordFormat, true) end, recordDiscard = recordDiscard,
  ocrSearch = ocrSearch, ocrTranslate = ocrTranslate, share = shareFile, clearResult = clearResult, clearHistory = clearHistory, setCursorHidden = setCursorHidden,
  setAudioOut = function(payload) overrideAudioOut = (type(payload) == "table" and payload.value or payload) == true end,
  setAudioIn = function(payload) overrideAudioIn = (type(payload) == "table" and payload.value or payload) == true end,
  toggle = function()
    local mode = cfg("panel-mode")
    local id = mode == "legacy" and LEGACY_PANEL_ID or PANEL_ID
    noctalia.togglePanel(id)
  end,
}

-- Tools that begin a brand-new capture. Starting one discards any recording
-- that finished but was never saved, so the result panel shows the new tool's
-- result instead of the stale "save recording" card.
local CAPTURE_STARTS = {
  colorPicker = true, ocr = true, qr = true, palette = true, lens = true,
  measure = true, annotate = true, annotateFullscreen = true, annotateWindow = true,
  record = true, recordMp4 = true, recordFullscreen = true, recordFullscreenMp4 = true,
}

local function dispatch(event, payload)
  if event == nil then return end
  local handler = HANDLERS[event]
  if handler then
    if CAPTURE_STARTS[event] then discardPendingRecording() end
    log(`ipc '{event}'`)
    handler(payload)
  else
    log(`unknown command '{event}'`)
  end
end

-- UI entries drive the service through this channel; the CLI uses onIpc.
noctalia.state.watch("command", function(cmd)
  if type(cmd) == "table" then
    dispatch(cmd.action, cmd.payload)
  elseif type(cmd) == "string" then
    dispatch(cmd)
  end
end)

function onIpc(event, payload)
  dispatch(event, payload)
end

-- ── Boot ───────────────────────────────────────────────────────────────────

local function boot()
  noctalia.mkdirAll(DATA_DIR)
  loadState()
  cursorHidden = cfg("hide-cursor") ~= false
  publish("cursorHidden", cursorHidden)
  refreshRecorders()
end

-- Services stay alive while plugin settings change. Keep capture and recorder
-- flags in sync without requiring the user to restart Noctalia.
function onConfigChanged()
  local nextCursorHidden = cfg("hide-cursor") ~= false
  if nextCursorHidden ~= cursorHidden then
    cursorHidden = nextCursorHidden
    publish("cursorHidden", cursorHidden)
  end
  refreshRecorders()
end

boot()
