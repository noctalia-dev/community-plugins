--!strict

-- Talks to `fluxcast` (github.com/IlyaP358/fluxcast) directly — no dependency
-- on any personal dotfiles wrapper script, so this plugin is self-contained:
-- install it anywhere `fluxcast` is installed and it works. The flag choices
-- below (wf-recorder capture backend, --wfd-no-audio default, 6M bitrate)
-- were tuned interactively on a niri/wlroots setup — see README.md.

local BITRATE_OPTIONS = { "4M", "6M", "8M", "10M" }
local DEFAULT_BITRATE_INDEX = 1 -- "6M" — a good default for slides/tickets over Wi-Fi Direct

type Peer = { mac: string, label: string }

local peers: { Peer } = {}
local selectedIndex = 0
local scanning = false
local scanError: string? = nil
local res720 = false
local audio = false
local bitrateIndex = DEFAULT_BITRATE_INDEX
local casting = false
local fluxcastAvailable = true

-- Host callback args always arrive as strings (ControlCallback is
-- string-typed on the wire), regardless of what the .d.luau type hints say.
local function asBool(value: any): boolean
  return value == true or value == "true"
end

local function asIndex(value: any): number
  return tonumber(value) or 0
end

local function peerNames(): { string }
  local names = {}
  for i, p in peers do
    names[i] = p.label
  end
  return names
end

-- noctalia.focusedOutputName() tracks keyboard-focused-window state, which a
-- panel isn't tied to the way a bar widget instance is — it can legitimately
-- come back nil here. Scan noctalia.outputs() for the focused one instead,
-- falling back to the first output (always resolves on a single-monitor setup).
local function detectMonitor(): string?
  local outputs = noctalia.outputs()
  for _, o in outputs do
    if o.focused then
      return o.name
    end
  end
  if #outputs > 0 then
    return outputs[1].name
  end
  return nil
end

local render
local startScan
local startCast
local stopCast

-- POSIX single-quote escaping: wrap in '...', turn each embedded ' into '\''.
-- Needed because this build's `runAsync` only accepts a shell command string
-- (the argv-table calling form errors "string expected, got table" here —
-- it's a real plugin_api >= 24 feature this binary doesn't implement, not
-- just a manifest-declared-version formality).
local function shellQuote(s: string): string
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function render()
  if not fluxcastAvailable then
    panel.render(ui.column(
      { padding = 12, gap = 8 },
      {
        ui.row(
          { align = "center", gap = 8 },
          {
            ui.glyph({ name = "cast-off", size = 18, color = "on_surface_variant" }),
            ui.label({ text = "Cast to TV", fontSize = 16, fontWeight = "semibold", color = "on_surface", flexGrow = 1 }),
          }
        ),
        ui.label({
          text = "fluxcast is not installed. Install it (e.g. `paru -S fluxcast-git`) and reopen this panel.",
          fontSize = 13,
          color = "on_surface_variant",
        }),
      }
    ))
    return
  end

  local tvSection
  if scanning then
    tvSection = ui.label({
      text = "Scanning for TVs…",
      fontSize = 13,
      color = "on_surface_variant",
    })
  elseif scanError ~= nil then
    tvSection = ui.label({
      text = scanError,
      fontSize = 13,
      color = "error",
    })
  elseif #peers == 0 then
    tvSection = ui.label({
      text = "No Wi-Fi Direct TVs found nearby.",
      fontSize = 13,
      color = "on_surface_variant",
    })
  else
    tvSection = ui.select({
      options = peerNames(),
      selectedIndex = selectedIndex,
      controlSize = "sm",
      flexGrow = 1,
      onChange = function(idx: any, _text: any)
        selectedIndex = asIndex(idx)
        render()
      end,
    })
  end

  local castLabel = casting and "Stop Casting" or "Cast"
  local castGlyph = casting and "cast-off" or "cast"
  local castVariant = casting and "destructive" or "primary"
  local castEnabled = casting or #peers > 0

  panel.render(ui.column(
    { padding = 12, gap = 12 },
    {
      ui.row(
        { align = "center", gap = 8 },
        {
          ui.glyph({ name = "cast", size = 18, color = "primary" }),
          ui.label({
            text = "Cast to TV",
            fontSize = 16,
            fontWeight = "semibold",
            color = "on_surface",
            flexGrow = 1,
          }),
          ui.button({
            glyph = "refresh",
            variant = "ghost",
            controlSize = "sm",
            tooltip = "Rescan",
            enabled = not scanning,
            onClick = function()
              startScan()
            end,
          }),
        }
      ),
      ui.column(
        { fill = "surface_variant/0.55", radius = 6, padding = 8, gap = 6 },
        {
          ui.row(
            { align = "center", gap = 6 },
            {
              ui.glyph({ name = "device-tv", size = 14, color = "on_surface_variant" }),
              ui.label({ text = "Smart TV", fontSize = 13, color = "on_surface_variant", flexGrow = 1 }),
            }
          ),
          tvSection,
        }
      ),
      ui.column(
        { fill = "surface_variant/0.55", radius = 6, padding = 8, gap = 8 },
        {
          ui.label({ text = "Options", fontSize = 13, color = "on_surface_variant" }),
          ui.row(
            { align = "center", gap = 8, minHeight = 32 },
            {
              ui.label({ text = "1280×720 (more fluid)", fontSize = 14, color = "on_surface", flexGrow = 1 }),
              ui.toggle({
                checked = res720,
                onChange = function(value: any)
                  res720 = asBool(value)
                  render()
                end,
              }),
            }
          ),
          ui.row(
            { align = "center", gap = 8, minHeight = 32 },
            {
              ui.label({ text = "Include TV audio", fontSize = 14, color = "on_surface", flexGrow = 1 }),
              ui.toggle({
                checked = audio,
                onChange = function(value: any)
                  audio = asBool(value)
                  render()
                end,
              }),
            }
          ),
          ui.row(
            { align = "center", gap = 8, minHeight = 32 },
            {
              ui.label({ text = "Bitrate", fontSize = 14, color = "on_surface", flexGrow = 1 }),
              ui.select({
                options = BITRATE_OPTIONS,
                selectedIndex = bitrateIndex,
                controlSize = "sm",
                width = 90,
                onChange = function(idx: any, _text: any)
                  bitrateIndex = asIndex(idx)
                  render()
                end,
              }),
            }
          ),
        }
      ),
      ui.button({
        text = castLabel,
        glyph = castGlyph,
        variant = castVariant,
        enabled = castEnabled,
        onClick = function()
          if casting then
            stopCast()
          else
            startCast()
          end
        end,
      }),
    }
  ))
end

function startScan()
  if not fluxcastAvailable then
    return
  end
  scanning = true
  scanError = nil
  peers = {}
  render()
  noctalia.runAsync("fluxcast --protocol wfd --wfd-scan", function(result)
    scanning = false
    if result.timedOut then
      scanError = "Scan timed out."
    elseif result.exitCode ~= 0 then
      -- A nonzero exit is always a real failure, whether or not fluxcast
      -- printed anything to stdout (its own error messages go to stdout,
      -- not stderr, so the old `and result.stdout == ""` check let real
      -- failures — e.g. WiFi radio soft-blocked, wpa_supplicant not
      -- managing the interface — silently masquerade as "no TVs found").
      scanError = "Scan failed — is Wi-Fi Direct available?"
    end
    local found: { Peer } = {}
    for line in result.stdout:gmatch("[^\n]+") do
      local mac, name = line:match("%[%d+%]%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(.-)%s+via NetworkManager")
      if mac then
        table.insert(found, { mac = mac, label = (name ~= "" and name) or mac })
      end
    end
    peers = found
    if #peers > 0 then
      selectedIndex = 0
    end
    render()
  end, 15000)
end

function startCast()
  if #peers == 0 then
    return
  end
  local peer = peers[selectedIndex + 1]
  if peer == nil then
    return
  end
  local monitor = detectMonitor()
  if monitor == nil then
    noctalia.notifyError("Cast to TV", "Could not detect the active output.")
    return
  end

  -- --wfd-capture-backend wf-recorder: skips FluxCast's default portal capture
  -- negotiation, which can take ~15s and time out some TVs (confirmed on a
  -- niri/wlroots setup — see README.md). --wfd-no-audio is the default since
  -- typical use is screen-sharing slides/tickets, not video/sound.
  local argv = {
    "fluxcast",
    "--wfd-capture-backend", "wf-recorder",
    "--wfd-monitor", shellQuote(monitor),
    "--bitrate", BITRATE_OPTIONS[bitrateIndex + 1],
    "--wfd-peer", shellQuote(peer.mac),
  }
  if not audio then
    table.insert(argv, "--wfd-no-audio")
  end
  if res720 then
    table.insert(argv, "--output-res")
    table.insert(argv, "1280x720")
  end

  noctalia.runAsync(table.concat(argv, " "))
  casting = true
  noctalia.notify("Casting to " .. peer.label)
  render()
end

function stopCast()
  -- "wfd-peer" (no leading dashes) — pkill's getopt parser treats a
  -- "--"-prefixed pattern as an unrecognized option, not the search text.
  noctalia.runAsync("pkill -f wfd-peer", function(_result)
    casting = false
    render()
  end)
end

function onOpen(_context: any)
  fluxcastAvailable = noctalia.commandExists("fluxcast")
  casting = false
  render()
  if not fluxcastAvailable then
    return
  end
  noctalia.processMatches(function(matched: boolean)
    if matched ~= casting then
      casting = matched
      render()
    end
  end, "fluxcast", "--wfd-peer")
  startScan()
end
