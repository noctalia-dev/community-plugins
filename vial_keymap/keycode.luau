--!nonstrict
-- QMK/Vial keycode string -> human-readable keycap label. Port of Keycode.swift.
--
-- A label is { primary, secondary?, secondaryKind = "mod"|"layer"|"info", style }
-- with style one of "normal", "transparent", "none", "layer", "modifier", "special".

local M = {}

-- Modifier legends as Tabler glyph tokens: "{name}" is drawn as an icon by the panel (see
-- legendNode in panel.luau), anything else as text. Change the icon here if you prefer
-- e.g. "{command}" or "{diamond}" for Super.
M.MODS = { C = "{chevron-up}", A = "⎇", S = "{arrow-big-up}", G = "{command}" }

local function mods(spec)
  local out = ""
  for ch in spec:gmatch(".") do out = out .. (M.MODS[ch] or ch) end
  return out
end

local modBase = {}
local function reg(spec, ...)
  for _, name in ipairs({ ... }) do modBase[name] = spec end
end
reg("C", "LCTL", "CTL", "C", "RCTL")
reg("S", "LSFT", "SFT", "S", "RSFT")
reg("A", "LALT", "ALT", "A", "LOPT", "OPT", "RALT", "ROPT", "ALGR")
reg("G", "LGUI", "GUI", "G", "LCMD", "CMD", "LWIN", "WIN", "RGUI", "RCMD", "RWIN")
reg("CA", "LCA"); reg("SA", "LSA", "RSA"); reg("CG", "LCG", "RCG"); reg("AG", "LAG", "RAG")
reg("SG", "LSG", "RSG", "SGUI", "SCMD", "SWIN"); reg("CS", "RCS", "C_S", "LCS")
reg("CAG", "LCAG", "RCAG"); reg("CAS", "MEH"); reg("CASG", "HYPR", "ALL")

function M.modSymbols(name)
  local spec = modBase[name]
  return spec and mods(spec) or nil
end

-- "MOD_LSFT|MOD_LCTL" -> "⇧⌃"
function M.modMaskSymbols(mask)
  local out = {}
  for rawPart in mask:gmatch("[^|]+") do
    local part = rawPart:gsub("^%s+", ""):gsub("%s+$", "")
    local base = part:gsub("^MOD_", "")
    local spec = modBase[base]
    if spec == nil then return nil end
    table.insert(out, mods(spec))
  end
  if #out == 0 then return nil end
  return table.concat(out, "")
end

M.shiftedSymbols = {
  ["`"] = "~", ["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%", ["6"] = "^",
  ["7"] = "&", ["8"] = "*", ["9"] = "(", ["0"] = ")", ["-"] = "_", ["="] = "+", ["["] = "{",
  ["]"] = "}", ["\\"] = "|", [";"] = ":", ["'"] = '"', [","] = "<", ["."] = ">", ["/"] = "?",
}

-- MARK: tables -------------------------------------------------------------------------

local modKeys = {}
for _, n in ipairs({ "KC_LCTRL", "KC_LCTL", "KC_RCTRL", "KC_RCTL" }) do modKeys[n] = mods("C") end
for _, n in ipairs({ "KC_LSHIFT", "KC_LSFT", "KC_RSHIFT", "KC_RSFT" }) do modKeys[n] = mods("S") end
for _, n in ipairs({ "KC_LALT", "KC_LOPT", "KC_RALT", "KC_ROPT", "KC_ALGR" }) do modKeys[n] = mods("A") end
for _, n in ipairs({ "KC_LGUI", "KC_LCMD", "KC_LWIN", "KC_RGUI", "KC_RCMD", "KC_RWIN" }) do modKeys[n] = mods("G") end
modKeys["KC_HYPR"] = mods("CASG")
modKeys["KC_MEH"] = mods("CAS")

local function L(primary, style, secondary, kind)
  return { primary = primary, style = style or "normal", secondary = secondary, secondaryKind = kind or "info" }
end

local specials = {
  QK_CAPS_WORD_TOGGLE = L("CapsWd", "special"), CAPS_WORD = L("CapsWd", "special"), CW_TOGG = L("CapsWd", "special"),
  QK_LAYER_LOCK = L("LyrLk", "layer"), QK_LLCK = L("LyrLk", "layer"),
  MAGIC_TOGGLE_NKRO = L("NKRO", "special"), NK_TOGG = L("NKRO", "special"),
  QK_CLEAR_EEPROM = L("EE clr", "special"), EE_CLR = L("EE clr", "special"),
  QK_BOOT = L("Boot", "special"), RESET = L("Boot", "special"), QK_REBOOT = L("Reboot", "special"),
  QK_REPEAT_KEY = L("Rep", "special"), QK_REP = L("Rep", "special"),
  QK_ALT_REPEAT_KEY = L("ARep", "special"), QK_AREP = L("ARep", "special"),
  QK_DYNAMIC_TAPPING_TERM_UP = L("TT+", "special"), QK_DYNAMIC_TAPPING_TERM_DOWN = L("TT-", "special"),
  QK_DYNAMIC_TAPPING_TERM_PRINT = L("TT?", "special"),
  KC_LSPO = L("(", "normal", mods("S"), "mod"), KC_RSPC = L(")", "normal", mods("S"), "mod"),
  KC_LCPO = L("(", "normal", mods("C"), "mod"), KC_RCPC = L(")", "normal", mods("C"), "mod"),
  KC_LAPO = L("(", "normal", mods("A"), "mod"), KC_RAPC = L(")", "normal", mods("A"), "mod"),
  KC_SFTENT = L("⏎", "normal", mods("S"), "mod"),
  SH_TOGG = L("Swap", "special"), SH_MON = L("Swap", "special"), SH_OS = L("Swap", "special"),
  SH_ON = L("Swap", "special"), SH_OFF = L("Swap", "special"), SH_TT = L("Swap", "special"),
}

local basic = {}
for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do basic["KC_" .. c] = c end
for d in ("1234567890"):gmatch(".") do basic["KC_" .. d] = d; basic["KC_KP_" .. d] = "KP" .. d; basic["KC_P" .. d] = "KP" .. d end
for i = 1, 24 do basic["KC_F" .. i] = "F" .. i end
local pairs_ = {
  { "⏎", { "KC_ENTER", "KC_ENT", "KC_KP_ENTER", "KC_PENT" } },
  { "Esc", { "KC_ESCAPE", "KC_ESC" } },
  { "⌫", { "KC_BSPACE", "KC_BSPC" } },
  { "⇥", { "KC_TAB" } },
  { "␣", { "KC_SPACE", "KC_SPC" } },
  { "-", { "KC_MINUS", "KC_MINS" } }, { "=", { "KC_EQUAL", "KC_EQL" } },
  { "[", { "KC_LBRACKET", "KC_LBRC" } }, { "]", { "KC_RBRACKET", "KC_RBRC" } },
  { "\\", { "KC_BSLASH", "KC_BSLS" } }, { "#", { "KC_NONUS_HASH", "KC_NUHS" } },
  { ";", { "KC_SCOLON", "KC_SCLN" } }, { "'", { "KC_QUOTE", "KC_QUOT" } },
  { "`", { "KC_GRAVE", "KC_GRV" } }, { ",", { "KC_COMMA", "KC_COMM" } },
  { ".", { "KC_DOT" } }, { "/", { "KC_SLASH", "KC_SLSH" } },
  { "⇪", { "KC_CAPSLOCK", "KC_CAPS" } },
  { "PrtSc", { "KC_PSCREEN", "KC_PSCR" } },
  { "ScrLk", { "KC_SCROLLLOCK", "KC_SLCK", "KC_SCRL", "KC_BRMD" } },
  { "Pause", { "KC_PAUSE", "KC_PAUS", "KC_BRK", "KC_BRMU" } },
  { "Ins", { "KC_INSERT", "KC_INS" } }, { "Home", { "KC_HOME" } }, { "PgUp", { "KC_PGUP" } },
  { "⌦", { "KC_DELETE", "KC_DEL" } }, { "End", { "KC_END" } }, { "PgDn", { "KC_PGDOWN", "KC_PGDN" } },
  { "→", { "KC_RIGHT", "KC_RGHT" } }, { "←", { "KC_LEFT" } }, { "↓", { "KC_DOWN" } }, { "↑", { "KC_UP" } },
  { "Num", { "KC_NUMLOCK", "KC_NLCK", "KC_NUM" } },
  { "Menu", { "KC_APPLICATION", "KC_APP" } },
  { "Power", { "KC_POWER", "KC_PWR", "KC_SYSTEM_POWER" } },
  { "Sleep", { "KC_SYSTEM_SLEEP", "KC_SLEP" } }, { "Wake", { "KC_SYSTEM_WAKE", "KC_WAKE" } },
  { "Mute", { "KC_AUDIO_MUTE", "KC_MUTE" } },
  { "Vol+", { "KC_AUDIO_VOL_UP", "KC_VOLU" } }, { "Vol-", { "KC_AUDIO_VOL_DOWN", "KC_VOLD" } },
  { "⏭", { "KC_MEDIA_NEXT_TRACK", "KC_MNXT" } }, { "⏮", { "KC_MEDIA_PREV_TRACK", "KC_MPRV" } },
  { "⏹", { "KC_MEDIA_STOP", "KC_MSTP" } }, { "⏯", { "KC_MEDIA_PLAY_PAUSE", "KC_MPLY" } },
  { "⏏", { "KC_MEDIA_EJECT", "KC_EJCT" } },
  { "Bri+", { "KC_BRIGHTNESS_UP", "KC_BRIU" } }, { "Bri-", { "KC_BRIGHTNESS_DOWN", "KC_BRID" } },
  { "Calc", { "KC_CALCULATOR", "KC_CALC" } }, { "Mail", { "KC_MAIL" } },
  { "Www", { "KC_WWW_HOME", "KC_WHOM" } }, { "Back", { "KC_WWW_BACK", "KC_WBAK" } }, { "Fwd", { "KC_WWW_FORWARD", "KC_WFWD" } },
  { "Ms↑", { "KC_MS_UP", "KC_MS_U", "MS_UP" } }, { "Ms↓", { "KC_MS_DOWN", "KC_MS_D", "MS_DOWN" } },
  { "Ms←", { "KC_MS_LEFT", "KC_MS_L", "MS_LEFT" } }, { "Ms→", { "KC_MS_RIGHT", "KC_MS_R", "MS_RGHT" } },
  { "Btn1", { "KC_MS_BTN1", "KC_BTN1", "MS_BTN1" } }, { "Btn2", { "KC_MS_BTN2", "KC_BTN2", "MS_BTN2" } },
  { "Btn3", { "KC_MS_BTN3", "KC_BTN3", "MS_BTN3" } }, { "Btn4", { "KC_MS_BTN4", "KC_BTN4", "MS_BTN4" } },
  { "Btn5", { "KC_MS_BTN5", "KC_BTN5", "MS_BTN5" } },
  { "Wh↑", { "KC_MS_WH_UP", "KC_WH_U", "MS_WHLU" } }, { "Wh↓", { "KC_MS_WH_DOWN", "KC_WH_D", "MS_WHLD" } },
  { "Wh←", { "KC_MS_WH_LEFT", "KC_WH_L", "MS_WHLL" } }, { "Wh→", { "KC_MS_WH_RIGHT", "KC_WH_R", "MS_WHLR" } },
  { "Acc0", { "KC_MS_ACCEL0", "KC_ACL0", "MS_ACL0" } }, { "Acc1", { "KC_MS_ACCEL1", "KC_ACL1", "MS_ACL1" } },
  { "Acc2", { "KC_MS_ACCEL2", "KC_ACL2", "MS_ACL2" } },
  { "KP/", { "KC_KP_SLASH", "KC_PSLS" } }, { "KP*", { "KC_KP_ASTERISK", "KC_PAST" } },
  { "KP-", { "KC_KP_MINUS", "KC_PMNS" } }, { "KP+", { "KC_KP_PLUS", "KC_PPLS" } },
  { "KP.", { "KC_KP_DOT", "KC_PDOT" } }, { "KP=", { "KC_KP_EQUAL", "KC_PEQL" } }, { "KP,", { "KC_KP_COMMA", "KC_PCMM" } },
  { "~", { "KC_TILDE", "KC_TILD" } }, { "!", { "KC_EXCLAIM", "KC_EXLM" } }, { "@", { "KC_AT" } },
  { "#", { "KC_HASH" } }, { "$", { "KC_DOLLAR", "KC_DLR" } }, { "%", { "KC_PERCENT", "KC_PERC" } },
  { "^", { "KC_CIRCUMFLEX", "KC_CIRC" } }, { "&", { "KC_AMPERSAND", "KC_AMPR" } }, { "*", { "KC_ASTERISK", "KC_ASTR" } },
  { "(", { "KC_LEFT_PAREN", "KC_LPRN" } }, { ")", { "KC_RIGHT_PAREN", "KC_RPRN" } },
  { "_", { "KC_UNDERSCORE", "KC_UNDS" } }, { "+", { "KC_PLUS" } },
  { "{", { "KC_LEFT_CURLY_BRACE", "KC_LCBR" } }, { "}", { "KC_RIGHT_CURLY_BRACE", "KC_RCBR" } },
  { "|", { "KC_PIPE" } }, { ":", { "KC_COLON", "KC_COLN" } }, { '"', { "KC_DOUBLE_QUOTE", "KC_DQUO", "KC_DQT" } },
  { "<", { "KC_LEFT_ANGLE_BRACKET", "KC_LABK", "KC_LT" } }, { ">", { "KC_RIGHT_ANGLE_BRACKET", "KC_RABK", "KC_GT" } },
  { "?", { "KC_QUESTION", "KC_QUES" } }, { "§", { "KC_NONUS_BSLASH", "KC_NUBS" } },
  { "RGB", { "RGB_TOG", "RM_TOGG" } }, { "RGB▸", { "RGB_MOD", "RM_NEXT" } }, { "RGB◂", { "RGB_RMOD", "RM_PREV" } },
  { "Hue+", { "RGB_HUI", "RM_HUEU" } }, { "Hue-", { "RGB_HUD", "RM_HUED" } },
  { "Sat+", { "RGB_SAI", "RM_SATU" } }, { "Sat-", { "RGB_SAD", "RM_SATD" } },
  { "RGB+", { "RGB_VAI", "RM_VALU" } }, { "RGB-", { "RGB_VAD", "RM_VALD" } },
  { "Spd+", { "RGB_SPI", "RM_SPDU" } }, { "Spd-", { "RGB_SPD", "RM_SPDD" } },
  { "BL", { "BL_TOGG" } }, { "BL+", { "BL_INC", "BL_UP" } }, { "BL-", { "BL_DEC", "BL_DOWN" } },
}
for _, p in ipairs(pairs_) do
  for _, code in ipairs(p[2]) do basic[code] = p[1] end
end

-- MARK: alternate OS layout -------------------------------------------------------------

-- Fallback when the installed XKB layout cannot be read: Russian ЙЦУКЕН by physical position.
M.russianFallback = {
  KC_Q = "Й", KC_W = "Ц", KC_E = "У", KC_R = "К", KC_T = "Е", KC_Y = "Н", KC_U = "Г", KC_I = "Ш",
  KC_O = "Щ", KC_P = "З", KC_LBRACKET = "Х", KC_LBRC = "Х", KC_RBRACKET = "Ъ", KC_RBRC = "Ъ",
  KC_A = "Ф", KC_S = "Ы", KC_D = "В", KC_F = "А", KC_G = "П", KC_H = "Р", KC_J = "О", KC_K = "Л",
  KC_L = "Д", KC_SCOLON = "Ж", KC_SCLN = "Ж", KC_QUOTE = "Э", KC_QUOT = "Э",
  KC_Z = "Я", KC_X = "Ч", KC_C = "С", KC_V = "М", KC_B = "И", KC_N = "Т", KC_M = "Ь",
  KC_COMMA = "Б", KC_COMM = "Б", KC_DOT = "Ю", KC_SLASH = ".", KC_SLSH = ".",
  KC_GRAVE = "Ё", KC_GRV = "Ё",
}

-- The letter this key produces in the alternate layout, looking through mod-tap / layer-tap
-- wrappers (their tap key is what the OS sees). nil for anything else.
function M.altLegend(code, map)
  local expr = M.parse(code)
  while expr.kind == "call" do
    local name, args = expr.name, expr.args
    if (name:sub(-2) == "_T" or name:match("^LT%d+$") or name == "SH_T") and args[1] then
      expr = args[1]
    elseif name == "LT" and args[2] then
      expr = args[2]
    else
      return nil
    end
  end
  return map[expr.name]
end

-- MARK: predicates ---------------------------------------------------------------------

function M.isEmpty(code)
  return code == "-1" or code == "KC_NO" or code == "XXXXXXX" or code == "" or code == nil
end

function M.isTransparent(code)
  return code == "KC_TRNS" or code == "KC_TRANSPARENT" or code == "_______"
end

-- MARK: parsing ------------------------------------------------------------------------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- "LT(3, KC_X)" -> { kind = "call", name = "LT", args = { atom "3", atom "KC_X" } }
function M.parse(raw)
  local s = trim(raw or "")
  local open = s:find("(", 1, true)
  if open == nil or s:sub(-1) ~= ")" then return { kind = "atom", name = s } end
  local name = s:sub(1, open - 1)
  local inner = s:sub(open + 1, -2)
  local args, depth, cur = {}, 0, ""
  for ch in inner:gmatch(".") do
    if ch == "(" then depth = depth + 1 end
    if ch == ")" then depth = depth - 1 end
    if ch == "," and depth == 0 then
      table.insert(args, M.parse(cur)); cur = ""
    else
      cur = cur .. ch
    end
  end
  if trim(cur) ~= "" then table.insert(args, M.parse(cur)) end
  return { kind = "call", name = name, args = args }
end

-- MARK: labelling ----------------------------------------------------------------------

local function layerName(ctx, n)
  local names = ctx and ctx.layerNames or {}
  local nm = names[n + 1]
  if nm ~= nil and nm ~= "" then return nm end
  return "L" .. tostring(n)
end

local labelExpr

local function atomLabel(a, ctx)
  if M.isEmpty(a) then return L("", "none") end
  if M.isTransparent(a) then return L("▽", "transparent") end
  local macro = a:match("^M(%d+)$")
  if macro then return L("M" .. macro, "special", "macro", "info") end
  local sp = specials[a]
  if sp then return { primary = sp.primary, style = sp.style, secondary = sp.secondary, secondaryKind = sp.secondaryKind } end
  local b = basic[a]
  if b then return L(b, "normal") end
  local m = modKeys[a]
  if m then return L(m, "modifier") end
  -- Fallback: strip a known prefix and title-case the words.
  local s = a
  for _, p in ipairs({ "KC_", "QK_", "RM_", "RGB_" }) do
    if s:sub(1, #p) == p then s = s:sub(#p + 1); break end
  end
  local words = {}
  for w in s:gmatch("[^_]+") do
    if #w <= 3 then table.insert(words, w) else table.insert(words, w:sub(1, 1) .. w:sub(2):lower()) end
  end
  return L(table.concat(words, " "), "special")
end

local function layerTap(n, kc, ctx)
  local l = labelExpr(kc, ctx)
  l.secondary = layerName(ctx, n)
  l.secondaryKind = "layer"
  return l
end

local function tapDanceLabel(n, ctx)
  local tds = ctx and ctx.tapDances or {}
  local d = tds[n + 1]
  if d == nil or M.isEmpty(d.tap) then return L("TD" .. n, "special") end
  local sub = { layerNames = ctx.layerNames }
  local l = M.label(d.tap, sub)
  l.style = "special"
  local hold = (not M.isEmpty(d.hold)) and M.short(d.hold, sub) or nil
  l.secondary = "TD" .. (hold and (" " .. hold) or "")
  l.secondaryKind = "info"
  return l
end

local layerSwitch = { MO = true, TG = true, TO = true, TT = true, DF = true, PDF = true, OSL = true }

labelExpr = function(expr, ctx)
  if expr.kind == "atom" then return atomLabel(expr.name, ctx) end
  local name, args = expr.name, expr.args
  local first = args[1]
  local firstAtom = (first and first.kind == "atom") and first.name or nil
  local firstNum = firstAtom and tonumber(firstAtom) or nil

  -- Layer-tap: LT3(KC_X) or LT(3, KC_X)
  local ltNum = name:match("^LT(%d+)$")
  if ltNum and first then return layerTap(tonumber(ltNum), first, ctx) end
  if name == "LT" and #args == 2 and firstNum then return layerTap(firstNum, args[2], ctx) end
  -- Mod-tap: LCTL_T(KC_X), HYPR_T(...), ALL_T(...)
  if name:sub(-2) == "_T" and first then
    local ms = M.modSymbols(name:sub(1, -3))
    if ms then
      local l = labelExpr(first, ctx)
      l.secondary = ms
      l.secondaryKind = "mod"
      return l
    end
  end
  if layerSwitch[name] and firstNum then
    return L(layerName(ctx, firstNum), "layer", name, "layer")
  end
  if name == "LM" and #args == 2 and firstNum and args[2].kind == "atom" then
    local m = args[2].name
    return L(layerName(ctx, firstNum), "layer", "LM " .. (M.modMaskSymbols(m) or m), "layer")
  end
  if name == "OSM" and firstAtom then
    return L(M.modMaskSymbols(firstAtom) or firstAtom, "modifier", "OSM", "info")
  end
  if name == "TD" and firstNum then return tapDanceLabel(firstNum, ctx) end
  if name == "SH_T" and first then
    local l = labelExpr(first, ctx)
    l.secondary = "SH"
    l.secondaryKind = "info"
    return l
  end
  -- Modifier wrappers: LSFT(KC_1), LCA(KC_X), HYPR(KC_X) ...
  local wrap = M.modSymbols(name)
  if wrap and first then
    local inner = labelExpr(first, ctx)
    if wrap == M.MODS.S and inner.secondary == nil and M.shiftedSymbols[inner.primary] then
      return L(M.shiftedSymbols[inner.primary], inner.style == "none" and "normal" or inner.style)
    end
    inner.primary = wrap .. inner.primary
    if inner.style == "none" then inner.style = "normal" end
    return inner
  end
  -- Unknown wrapper: show it raw but compact.
  local parts = {}
  for _, a in ipairs(args) do table.insert(parts, labelExpr(a, ctx).primary) end
  return L(name .. "(" .. table.concat(parts, ",") .. ")", "special")
end

-- ctx = { tapDances = {...}, layerNames = { [1] = name of layer 0, ... } }
function M.label(code, ctx)
  return labelExpr(M.parse(code), ctx or {})
end

-- Short single-line text, used in combo lists and encoder legends.
function M.short(code, ctx)
  local l = M.label(code, ctx)
  if l.style == "none" then return "∅" end
  if l.style == "transparent" then return "▽" end
  if l.secondary and l.secondaryKind ~= "info" then return l.primary .. "/" .. l.secondary end
  return l.primary
end

return M
