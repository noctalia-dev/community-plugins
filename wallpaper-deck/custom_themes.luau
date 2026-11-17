--!nonstrict
-- custom_themes.luau — Custom Themes module for Wallpaper Deck
--
-- Manages user-created palettes stored directly in ~/.config/noctalia/palettes/
-- using Noctalia Format 2. Exposes backend helpers (list, save, delete, apply)
-- and a modal UI renderer.
--
-- IMPORTANT: The `ui` global is only available in the main plugin chunk, NOT
-- in required modules. All UI-building functions accept `ui` as an explicit
-- first parameter (called `U` here to avoid any shadowing confusion).
--
-- Noctalia UI API (confirmed from picker.luau and palette-creator):
--   U.label({ text, color, fontSize, fontWeight, width, flexGrow })
--   U.input({ key, value, placeholder, controlSize, frameVisible, flexGrow, width, onChange })
--   U.button({ text?, glyph?, variant, controlSize, tooltip?, onClick })
--   U.box({ width, height, radius, fill, border, borderWidth })
--   U.row({ align, justify, gap, height, width?, flexGrow?, fill?, ... }, children)
--   U.column({ key?, gap, padding?, align?, justify?, fill?, ... }, children)
--   U.scroll({ key?, height?, flexGrow?, gap?, align?, justify? }, children)
--   U.spacer({ width?, height? })
--   U.select({ key, options, selectedIndex, controlSize, width, onChange })
--
-- Constraints:
--   • Format 2 JSON only (version=2, dark={}, light={})
--   • Strict 6-digit lowercase #rrggbb in role fields
--   • No middleman ledger file — native palettes dir only
--   • No nil/false in UI child tables — use table.insert() for conditionals
--   • Semi-transparent overlays: role-name fills only ("shadow/0.75")

-- ── Constants ─────────────────────────────────────────────────────────────────

local PALETTES_DIR = noctalia.expandPath("~/.config/noctalia/palettes")

local ROLE_KEYS = {
  "primary", "on_primary",
  "secondary", "on_secondary",
  "tertiary", "on_tertiary",
  "error", "on_error",
  "surface", "on_surface",
  "surface_container", "on_surface_variant",
  "outline_variant", "shadow",
  "hover", "on_hover",
}

local DARK_DEFAULTS = {
  primary           = "#80a9ff",
  on_primary        = "#003060",
  secondary         = "#bfc6dc",
  on_secondary      = "#293041",
  tertiary          = "#dab9d5",
  on_tertiary       = "#3d2440",
  error             = "#ffb4ab",
  on_error          = "#690005",
  surface           = "#111318",
  on_surface        = "#e1e2e9",
  surface_container = "#1e2027",
  on_surface_variant = "#c3c6d4",
  outline_variant   = "#43474e",
  shadow            = "#000000",
  hover             = "#2a2d35",
  on_hover          = "#e1e2e9",
}

local LIGHT_DEFAULTS = {
  primary           = "#005cbb",
  on_primary        = "#ffffff",
  secondary         = "#575e71",
  on_secondary      = "#ffffff",
  tertiary          = "#71546d",
  on_tertiary       = "#ffffff",
  error             = "#ba1a1a",
  on_error          = "#ffffff",
  surface           = "#f9f9ff",
  on_surface        = "#191c20",
  surface_container = "#e3e3ec",
  on_surface_variant = "#43474e",
  outline_variant   = "#c3c6d4",
  shadow            = "#000000",
  hover             = "#e8e8f0",
  on_hover          = "#191c20",
}

-- ── Module table ──────────────────────────────────────────────────────────────

local M = {}

M.isOpen      = false
M.themeName   = ""
M.dark        = {}
M.light       = {}
M.selectedIdx = 1
M.statusText  = ""
M.statusIsError = false

-- ── Color math ────────────────────────────────────────────────────────────────

local function hexToRgb(hex)
  hex = hex:gsub("#", "")
  if #hex == 3 then
    hex = hex:sub(1,1):rep(2) .. hex:sub(2,2):rep(2) .. hex:sub(3,3):rep(2)
  end
  return (tonumber(hex:sub(1,2), 16) or 0)/255,
         (tonumber(hex:sub(3,4), 16) or 0)/255,
         (tonumber(hex:sub(5,6), 16) or 0)/255
end

local function rgbToHex(r, g, b)
  return string.format("#%02x%02x%02x",
    math.floor(math.max(0, math.min(1, r)) * 255 + 0.5),
    math.floor(math.max(0, math.min(1, g)) * 255 + 0.5),
    math.floor(math.max(0, math.min(1, b)) * 255 + 0.5))
end

local function rgbToHsv(r, g, b)
  local mx = math.max(r, g, b)
  local mn = math.min(r, g, b)
  local d  = mx - mn
  local s  = (mx == 0) and 0 or d / mx
  local h  = 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h / 6
    if h < 0 then h = h + 1 end
  end
  return h, s, mx
end

local function hsvToRgb(h, s, v)
  local i = math.floor(h * 6) % 6
  local f = h * 6 - math.floor(h * 6)
  local p = v*(1-s); local q = v*(1-f*s); local t = v*(1-(1-f)*s)
  if i==0 then return v,t,p elseif i==1 then return q,v,p
  elseif i==2 then return p,v,t elseif i==3 then return p,q,v
  elseif i==4 then return t,p,v else return v,p,q end
end

local function brighten(hex)
  local r, g, b = hexToRgb(hex)
  local h, s, v = rgbToHsv(r, g, b)
  return rgbToHex(hsvToRgb(h, math.max(0, s-0.1), math.min(1.0, v+0.15)))
end

-- ── Public helpers ────────────────────────────────────────────────────────────

function M.sanitizeHex(hex, fallback)
  local fb = fallback or "#000000"
  if type(hex) ~= "string" then return fb end
  local c = hex:gsub("#",""):gsub("%s+",""):lower()
  if #c == 3 then c = c:sub(1,1):rep(2)..c:sub(2,2):rep(2)..c:sub(3,3):rep(2) end
  if #c == 8 then c = c:sub(1,6) end
  if #c == 6 and c:match("^[0-9a-f]+$") then return "#"..c end
  return fb
end

function M.sanitizeName(raw)
  local n = noctalia.string.trim(tostring(raw or ""))
  n = n:gsub("[/\\]",""):gsub("%.%.",""):gsub("[^%w %-_%(%)%.]","")
  n = noctalia.string.trim(n):gsub("%s+","_")
  return n
end

local function generateTerminal(s)
  local pr, pg, pb = hexToRgb(s.primary)
  local _, ps, _   = rgbToHsv(pr, pg, pb)
  local sat = (ps > 0.3) and ps or 0.70
  local function colorAt(deg) return rgbToHex(hsvToRgb(deg/360, sat, 0.80)) end
  local g = colorAt(135); local y = colorAt(55)
  return {
    normal = {
      black=s.surface:lower(), red=s.error:lower(), green=g, yellow=y,
      blue=s.primary:lower(), magenta=s.secondary:lower(), cyan=s.tertiary:lower(),
      white=s.on_surface:lower(),
    },
    bright = {
      black=s.surface_container:lower(), red=brighten(s.error),
      green=brighten(g), yellow=brighten(y), blue=brighten(s.primary),
      magenta=brighten(s.secondary), cyan=brighten(s.tertiary), white="#ffffff",
    },
    background=s.surface:lower(), foreground=s.on_surface:lower(),
    cursor=s.primary:lower(), cursor_text=s.on_primary:lower(),
    selection_bg=s.primary:lower(), selection_fg=s.on_primary:lower(),
  }
end

local function buildScheme(colors, defaults)
  local s = {}
  for _, key in ipairs(ROLE_KEYS) do
    local raw = colors and colors[key]
    local def = defaults[key] or "#000000"
    s[key] = (type(raw)=="string" and raw~="") and M.sanitizeHex(raw, def) or def
  end
  return s
end

-- ── Backend API ───────────────────────────────────────────────────────────────

function M.list()
  local entries = noctalia.listDir(PALETTES_DIR)
  if type(entries) ~= "table" then return {} end
  local ids = {}
  for _, name in ipairs(entries) do
    if type(name)=="string" and name:sub(-5)==".json" then
      local id = name:sub(1,-6)
      if id ~= "" and id:sub(1,1) ~= "_" then
        table.insert(ids, id)
      end
    end
  end
  table.sort(ids, function(a,b) return string.lower(a)<string.lower(b) end)
  return ids
end

function M.save(name, darkColors, lightColors)
  local id = M.sanitizeName(name)
  if id == "" then return false, "Theme name cannot be empty." end

  -- Reject duplicate names
  local existingPath = PALETTES_DIR .. "/" .. id .. ".json"
  if noctalia.fileExists(existingPath) then
    return false, "A theme named \"" .. id .. "\" already exists. Choose a different name."
  end

  local dk = buildScheme(darkColors,  DARK_DEFAULTS)
  local lk = buildScheme(lightColors, LIGHT_DEFAULTS)
  local payload = { version=2, dark=dk, light=lk }
  payload.dark.terminal  = generateTerminal(dk)
  payload.light.terminal = generateTerminal(lk)

  local ok, encoded = pcall(noctalia.json.encode, payload)
  if not ok then return false, "JSON error: "..tostring(encoded) end

  if not noctalia.mkdirAll(PALETTES_DIR) then
    return false, "Could not create palettes directory."
  end

  local okW, werr = noctalia.writeFile(PALETTES_DIR.."/"..id..".json", encoded)
  if not okW then return false, "Write failed: "..tostring(werr) end
  return true
end

function M.delete(id)
  if type(id)~="string" or id=="" then return end
  pcall(noctalia.removeFile, PALETTES_DIR.."/"..id..".json")
end

function M.apply(id)
  if type(id)~="string" or id=="" then return end
  noctalia.runAsync({"noctalia","msg","color-scheme-set","custom",id}, function() end)
end

function M.loadIntoModal(id)
  M.themeName = id or ""
  M.dark = {}; M.light = {}
  for _, key in ipairs(ROLE_KEYS) do
    M.dark[key]  = DARK_DEFAULTS[key]
    M.light[key] = LIGHT_DEFAULTS[key]
  end
  if type(id)~="string" or id=="" then return end

  local path = PALETTES_DIR.."/"..id..".json"
  if not noctalia.fileExists(path) then return end
  local raw = noctalia.readFile(path)
  if not raw or raw=="" then return end

  local ok, dec = pcall(noctalia.json.decode, raw)
  if not ok or type(dec)~="table" then return end

  if type(dec.dark)=="table" then
    for _, key in ipairs(ROLE_KEYS) do
      local v = dec.dark[key]
      if type(v)=="string" and v~="" then M.dark[key]=M.sanitizeHex(v, DARK_DEFAULTS[key]) end
    end
  end
  if type(dec.light)=="table" then
    for _, key in ipairs(ROLE_KEYS) do
      local v = dec.light[key]
      if type(v)=="string" and v~="" then M.light[key]=M.sanitizeHex(v, LIGHT_DEFAULTS[key]) end
    end
  end
end

function M.resetModal()
  M.themeName=""; M.statusText=""; M.statusIsError=false
  M.dark={}; M.light={}
  for _, key in ipairs(ROLE_KEYS) do
    M.dark[key]=DARK_DEFAULTS[key]; M.light[key]=LIGHT_DEFAULTS[key]
  end
end

-- ── UI builder (U = the `ui` global passed from picker.luau) ─────────────────

local function buildColorRow(U, label, roleKey, colorTable, modePrefix, R, renderFn)
  local currentHex = colorTable[roleKey] or "#000000"
  local inputKey   = "ct_"..modePrefix.."_"..roleKey

  return U.row({ align="center", gap=8 }, {
    U.box({
      width=20, height=20, radius=R(4),
      fill=currentHex, border="outline_variant/0.4", borderWidth=1,
    }),
    U.label({
      text=label,
      color="on_surface_variant",
      fontSize=11,
      flexGrow=1,
    }),
    U.input({
      key=inputKey,
      value=currentHex,
      placeholder="#rrggbb",
      controlSize="sm",
      frameVisible=true,
      width=90,
      onChange=function(val)
        colorTable[roleKey] = val or ""
        renderFn()
      end,
    }),
    U.button({
      glyph="color-swatch",
      variant="ghost",
      controlSize="sm",
      tooltip="Pick color",
      onClick=function()
        if type(noctalia.openColorPicker)=="function" then
          pcall(noctalia.openColorPicker, currentHex, function(picked)
            if picked and picked~="" then
              colorTable[roleKey]=M.sanitizeHex(picked, currentHex)
              renderFn()
            end
          end)
        end
      end,
    }),
  })
end

-- ── Modal renderer ────────────────────────────────────────────────────────────

-- Returns the full-panel modal overlay node, or nil if M.isOpen is false.
-- U        = the `ui` global from picker.luau
-- panelW/H = current panel dimensions
-- R        = corner-radius scaler from picker.luau
-- renderFn = picker.luau's render()
function M.renderModal(U, panelW, panelH, R, renderFn)
  if not M.isOpen then return nil end

  -- Dark column
  local darkRows = {
    U.label({ text="Dark Mode", color="primary", fontSize=12, fontWeight="semibold" }),
    U.spacer({ height=4 }),
  }
  for _, key in ipairs(ROLE_KEYS) do
    table.insert(darkRows, buildColorRow(U, key, key, M.dark, "dark", R, renderFn))
  end

  -- Light column
  local lightRows = {
    U.label({ text="Light Mode", color="secondary", fontSize=12, fontWeight="semibold" }),
    U.spacer({ height=4 }),
  }
  for _, key in ipairs(ROLE_KEYS) do
    table.insert(lightRows, buildColorRow(U, key, key, M.light, "light", R, renderFn))
  end

  -- Footer (status label conditional)
  local footerRows = {}
  if M.statusText ~= "" then
    table.insert(footerRows, U.label({
      text=M.statusText,
      color=M.statusIsError and "error" or "primary",
      fontSize=11,
    }))
    table.insert(footerRows, U.spacer({ height=4 }))
  end
  table.insert(footerRows, U.row({ align="center", justify="end", gap=8 }, {
    U.button({
      text="Cancel", variant="ghost", controlSize="sm",
      onClick=function()
        M.isOpen=false; M.statusText=""; M.statusIsError=false
        renderFn()
      end,
    }),
    U.button({
      text="Save Theme", glyph="device-floppy", variant="primary", controlSize="sm",
      onClick=function()
        local cleanName = noctalia.string.trim(M.themeName or "")
        if cleanName=="" then
          M.statusText="Please enter a theme name."; M.statusIsError=true
          renderFn(); return
        end
        local dk,lk = {},{}
        for _, key in ipairs(ROLE_KEYS) do
          dk[key]=M.sanitizeHex(M.dark[key],  DARK_DEFAULTS[key])
          lk[key]=M.sanitizeHex(M.light[key], LIGHT_DEFAULTS[key])
        end
        local ok, err = M.save(cleanName, dk, lk)
        if ok then
          M.isOpen=false; M.statusText=""; M.statusIsError=false
        else
          M.statusText=err or "Save failed."; M.statusIsError=true
        end
        renderFn()
      end,
    }),
  }))

  local scrollH = math.min(panelH - 240, 500)
  if scrollH < 260 then scrollH = 260 end

  local modalCard = U.column({
    key="ct_modal_card",
    fill="surface",
    border="outline_variant/0.4",
    borderWidth=1,
    radius=R(16),
    padding=16,
    gap=8,
    width=math.min(panelW-32, 860),
  }, {
    -- Header
    U.row({ align="center", justify="space_between" }, {
      U.label({ text="New Custom Theme", color="on_surface", fontSize=14, fontWeight="bold" }),
      U.button({
        glyph="x", variant="ghost", controlSize="sm",
        onClick=function()
          M.isOpen=false; M.statusText=""; M.statusIsError=false
          renderFn()
        end,
      }),
    }),
    U.spacer({ height=2 }),
    -- Name input
    U.row({ align="center", gap=10 }, {
      U.label({ text="Theme Name", color="on_surface_variant", fontSize=12, width=90 }),
      U.input({
        key="ct_theme_name",
        value=M.themeName,
        placeholder="My Awesome Theme",
        controlSize="sm",
        frameVisible=true,
        width=240,
        onChange=function(val) M.themeName=val or "" end,
      }),
    }),
    U.spacer({ height=4 }),
    -- Scrollable two-column role list
    U.scroll({
      key="ct_modal_scroll",
      height=scrollH,
      gap=0,
      align="stretch",
    }, {
      U.row({ align="stretch", gap=20 }, {
        U.column({ key="ct_dark_col",  gap=6, flexGrow=1 }, darkRows),
        U.box({ width=1, fill="outline_variant/0.4" }),
        U.column({ key="ct_light_col", gap=6, flexGrow=1 }, lightRows),
      }),
    }),
    U.spacer({ height=4 }),
    -- Footer
    U.column({ gap=4 }, footerRows),
  })

  -- Full-panel dim overlay
  return U.column({
    key="ct_modal_overlay",
    width=panelW,
    height=panelH,
    align="center",
    justify="center",
    fill="shadow/0.75",
  }, { modalCard })
end

return M
