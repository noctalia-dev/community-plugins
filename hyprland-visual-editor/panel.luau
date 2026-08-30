--!nonstrict
-- HVE v5 — Panel Principal

local home = noctalia.getenv("HOME") or "/home/fertxo"
local pdir = noctalia.pluginDir() or (home .. "/.config/noctalia/plugins/hyprland-visual-editor")
local cacheDir = (noctalia.getenv("XDG_CACHE_HOME") or (home .. "/.cache")) .. "/noctalia/HVE"
local stateFile = cacheDir .. "/hve_state.txt"

local function parseItems(text)
  if not text or text == "" then return {} end
  local items = {}
  for obj in text:gmatch("%{[^}]+%}") do
    local file = obj:match('"file"%s*:%s*"([^"]*)') or ""
    local title = obj:match('"rawTitle"%s*:%s*"([^"]*)') or file
    if file ~= "" then
      table.insert(items, { file = file, title = title,
        desc = obj:match('"rawDesc"%s*:%s*"([^"]*)') or "",
        icon = obj:match('"icon"%s*:%s*"([^"]*)') or "help",
        color = obj:match('"color"%s*:%s*"([^"]*)') or "#888",
        tag = obj:match('"tag"%s*:%s*"([^"]*)') or "USER",
      })
    end
  end
  return items
end

local function loadItems(category)
  local content = noctalia.readFile(cacheDir .. "/" .. category .. ".json")
  if content then return parseItems(content) end
  return {}
end

local function loadState()
  local nativeActive = noctalia.getConfig("is_system_active")
  local isActive = (nativeActive == "true" or nativeActive == true)
  local anim = noctalia.getConfig("active_anim_file") or ""
  local border = noctalia.getConfig("active_border_file") or ""
  local shader = noctalia.getConfig("active_shader_file") or ""

  local content = noctalia.readFile(stateFile)
  if content then
    for line in content:gmatch("[^\n]+") do
      local key, val = line:match("^(%w+)=(.*)$")
      if key == "isActive" then isActive = (val == "true") or isActive
      elseif key == "activeAnim" and anim == "" then anim = val
      elseif key == "activeBorder" and border == "" then border = val
      elseif key == "activeShader" and shader == "" then shader = val
      end
    end
  end
  return isActive, anim, border, shader
end

local activeTab = 0
local isActive, activeAnim, activeBorder, activeShader = loadState()
local selAnim, selBorder, selShader = 0, 0, 0
local animItems = loadItems("animations")
local borderItems = loadItems("borders")
local shaderItems = loadItems("shaders")
local tabIcons = { "home", "movie", "border-all", "wand" }

local function t(key)
  return noctalia.tr(key)
end

-- Resuelve el destino: "archivo" si hay preset seleccionado y HVE activo, "none" si no
local function resolveTarget(isOn, file)
  if isOn and file ~= "" then return file end
  return "none"
end

local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function requestSave()
  local state = "isActive=" .. tostring(isActive) .. "\n"
    .. "activeAnim=" .. activeAnim .. "\n"
    .. "activeBorder=" .. activeBorder .. "\n"
    .. "activeShader=" .. activeShader
  noctalia.runAsync("mkdir -p " .. shq(cacheDir) .. " && printf '%s' " .. shq(state) .. " > " .. shq(stateFile), nil, 5000)
end

local function applyAnimation(file)
  noctalia.runAsync("bash " .. shq(pdir .. "/assets/scripts/apply_animation.sh") .. " " .. shq(file) .. " && hyprctl reload 2>/dev/null", nil, 10000)
end
local function applyBorder(file)
  noctalia.runAsync("bash " .. shq(pdir .. "/assets/scripts/border.sh") .. " " .. shq(file) .. " && hyprctl reload 2>/dev/null", nil, 10000)
end
local function applyShader(file)
  noctalia.runAsync("bash " .. shq(pdir .. "/assets/scripts/shader.sh") .. " " .. shq(file) .. " && hyprctl reload 2>/dev/null", nil, 10000)
end

local function tabBar()
  local names = { t("panel.home"), t("panel.animations"), t("panel.borders"), t("panel.effects") }
  local btns = {}
  for i = 1, 4 do
    table.insert(btns, ui.button({
      text = names[i], glyph = tabIcons[i],
      onClick = "onTab" .. (i - 1), flexGrow = 1,
    }))
  end
  return ui.row({ gap = 4, align = "stretch" }, btns)
end

local function buildCategory(items, activeFile, category)
  if #items == 0 then
    return ui.label({ text = t("panel.no_presets"), color = "on_surface_variant" })
  end
  local opts = { t("panel.none") }
  for i, item in ipairs(items) do
    local mark = (item.file == activeFile) and " ★" or ""
    table.insert(opts, item.title .. mark)
  end
  local selVal = 0
  if category == "Anim" then selVal = selAnim
  elseif category == "Border" then selVal = selBorder
  elseif category == "Shader" then selVal = selShader end
  local applied = activeFile ~= "" and activeFile or t("panel.none")
  return ui.scroll({ flexGrow = 1, gap = 8 }, {
    ui.label({ text = #items .. " " .. t("panel.presets_available"), fontSize = 12, color = "on_surface_variant" }),
    ui.select({ options = opts, selectedIndex = selVal, onChange = "onSel" .. category }),
    ui.button({ text = t("panel.apply"), onClick = "onApply" .. category, flexGrow = 1 }),
    ui.label({ text = t("panel.current_preset") .. ": " .. applied, fontSize = 11, color = "primary" }),
  })
end

function render()
  local content
  if activeTab == 0 then
    local summary = "✦ " .. #animItems .. " " .. t("panel.count_animations")
      .. " | " .. #borderItems .. " " .. t("panel.count_borders")
      .. " | " .. #shaderItems .. " " .. t("panel.count_shaders")
    local homeChildren = {
      ui.label({ text = "🏠 " .. string.upper(t("panel.home")), fontSize = 16, color = "primary" }),
      ui.row({ gap = 8, align = "center" }, {
        ui.toggle({ checked = isActive, onChange = "onToggleActive" }),
        ui.label({ text = isActive and t("panel.enabled") or t("panel.disabled"), flexGrow = 1 }),
      }),
      ui.label({ text = summary, fontSize = 12, color = "on_surface_variant" }),
    }
    if not isActive then
      table.insert(homeChildren, ui.label({ text = "⚠️ " .. t("panel.enable_warning"), fontSize = 11, color = "error" }))
    end
    table.insert(homeChildren, ui.label({ text = "ℹ️ " .. t("panel.apply_hint"), fontSize = 11, color = "on_surface_variant" }))
    table.insert(homeChildren, ui.label({ text = t("panel.credits"), fontSize = 11, color = "on_surface_variant" }))
    content = ui.scroll({ flexGrow = 1, gap = 12 }, homeChildren)
  elseif activeTab == 1 then
    content = ui.scroll({ flexGrow = 1, gap = 8 }, {
      ui.label({ text = "🎬 " .. string.upper(t("panel.animations")), fontSize = 16, color = "primary" }),
      buildCategory(animItems, activeAnim, "Anim"),
    })
  elseif activeTab == 2 then
    content = ui.scroll({ flexGrow = 1, gap = 8 }, {
      ui.label({ text = "🔲 " .. string.upper(t("panel.borders")), fontSize = 16, color = "primary" }),
      buildCategory(borderItems, activeBorder, "Border"),
    })
  elseif activeTab == 3 then
    content = ui.scroll({ flexGrow = 1, gap = 8 }, {
      ui.label({ text = "✨ " .. string.upper(t("panel.effects")), fontSize = 16, color = "primary" }),
      buildCategory(shaderItems, activeShader, "Shader"),
    })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = "🦉 Hyprland Visual Editor", fontSize = 16, fontWeight = "bold", color = "primary" }),
      ui.button({ glyph = "close", onClick = "onClose" }),
    }),
    tabBar(),
    content,
  }))
end

function onToggleActive(value)
  isActive = (value == "true")
  requestSave()
  render()
end
function onTab0() activeTab = 0; render() end
function onTab1() activeTab = 1; render() end
function onTab2() activeTab = 2; render() end
function onTab3() activeTab = 3; render() end
function onSelAnim(idx) selAnim = tonumber(idx) or 0; render() end
function onSelBorder(idx) selBorder = tonumber(idx) or 0; render() end
function onSelShader(idx) selShader = tonumber(idx) or 0; render() end

function onApplyAnim()
  if selAnim > 0 and selAnim <= #animItems then
    activeAnim = animItems[selAnim].file
  else
    activeAnim = ""
  end
  applyAnimation(resolveTarget(isActive, activeAnim))
  requestSave()
  render()
end
function onApplyBorder()
  if selBorder > 0 and selBorder <= #borderItems then
    activeBorder = borderItems[selBorder].file
  else
    activeBorder = ""
  end
  applyBorder(resolveTarget(isActive, activeBorder))
  requestSave()
  render()
end
function onApplyShader()
  if selShader > 0 and selShader <= #shaderItems then
    activeShader = shaderItems[selShader].file
  else
    activeShader = ""
  end
  applyShader(resolveTarget(isActive, activeShader))
  requestSave()
  render()
end
function onClose() panel.close() end
function onOpen(_context) render() end
