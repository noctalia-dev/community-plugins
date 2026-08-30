local util = require("./util.luau")

local M = {}

M.OPTIONS = {
  { key = "enabled",                                path = { "enabled" },                          kind = "bool" },
  { key = "work_duration",                          path = { "work_duration" },                    kind = "int" },
  { key = "rest_duration",                          path = { "rest_duration" },                    kind = "int" },
  { key = "auto_transition",                        path = { "auto_transition" },                  kind = "bool" },
  { key = "title__enabled",                         path = { "title", "enabled" },                 kind = "bool" },
  { key = "title__all_windows",                     path = { "title", "all_windows" },             kind = "bool" },
  { key = "title__reserve_space_all",               path = { "title", "reserve_space_all" },       kind = "bool" },
  { key = "title__floating_window",                 path = { "title", "floating_window" },         kind = "bool" },
  { key = "title__position",                        path = { "title", "position" },                kind = "string" },
  { key = "title__overlay",                         path = { "title", "overlay" },                 kind = "bool" },
  { key = "title__margin",                          path = { "title", "margin" },                  kind = "int" },
  { key = "title__spacing",                         path = { "title", "spacing" },                 kind = "int" },
  { key = "border__enabled",                        path = { "border", "enabled" },                kind = "bool" },
  { key = "border__all_windows",                    path = { "border", "all_windows" },            kind = "bool" },
  { key = "border__floating_window",                path = { "border", "floating_window" },        kind = "bool" },
  { key = "border__color",                          path = { "border", "color" },                  kind = "color", alphaFrom = "border__alpha",
    exprWhen = { setting = "border__color_source", value = "accent", expr = "border_color" } },
  { key = "text__color",                            path = { "text", "color" },                    kind = "color" },
  { key = "text__font",                             path = { "text", "font" },                     kind = "string" },
  { key = "text__size",                             path = { "text", "size" },                     kind = "int" },
  { key = "text__work_prefix",                      path = { "text", "work_prefix" },              kind = "string" },
  { key = "text__rest_prefix",                      path = { "text", "rest_prefix" },              kind = "string" },
  { key = "text__waiting_prefix",                   path = { "text", "waiting_prefix" },           kind = "string" },
  { key = "text__skip_on_click",                    path = { "text", "skip_on_click" },            kind = "bool" },
  { key = "sound__player",                          path = { "sound", "player" },                  kind = "string" },
  { key = "sound__work_end",                        path = { "sound", "work_end" },                kind = "string", expand = true },
  { key = "sound__rest_end",                        path = { "sound", "rest_end" },                kind = "string", expand = true },
  { key = "notification__enabled",                  path = { "notification", "enabled" },          kind = "bool" },
  { key = "notification__use_system_notifications", path = { "notification", "use_system_notifications" }, kind = "bool" },
  { key = "notification__work_end",                 path = { "notification", "work_end" },         kind = "string" },
  { key = "notification__rest_end",                 path = { "notification", "rest_end" },         kind = "string" },
  { key = "exec_on_work_end",                       path = { "exec_on_work_end" },                 kind = "string" },
  { key = "exec_on_rest_end",                       path = { "exec_on_rest_end" },                 kind = "string" },
  { key = "buttons__size",                          path = { "buttons", "size" },                  kind = "int" },
  { key = "buttons__color__foreground",             path = { "buttons", "color", "foreground" },   kind = "color" },
  { key = "buttons__color__background",             path = { "buttons", "color", "background" },   kind = "color", alphaFrom = "buttons__background_alpha" },
  { key = "hover__text",                            path = { "hover", "text" },                    kind = "bool" },
  { key = "hover__buttons",                         path = { "hover", "buttons" },                 kind = "bool" },
  { key = "hover__height",                          path = { "hover", "height" },                  kind = "float" },
  { key = "hover__width",                           path = { "hover", "width" },                   kind = "float" },
  { key = "window__min_width",                      path = { "window", "min_width" },              kind = "int" },
  { key = "window__padding",                        path = { "window", "padding" },                kind = "int" },
}

M.LOCAL_ONLY = {
  config_path = true, manage_config_file = true, presets = true,
  border__color_source = true,
  poll_interval_running = true, poll_interval_idle = true,
  defer_writes_while_running = true,
  border__alpha = true, buttons__background_alpha = true,
}

function M.toHyprColor(value, alpha)
  if type(value) ~= "string" then return nil end
  local hex = util.trim(value):gsub("^#", "")
  if hex:match("^%x%x%x$") then
    hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
  end

  if hex:match("^%x%x%x%x%x%x%x%x$") then
    return "rgba(" .. hex:lower() .. ")"
  end
  if not hex:match("^%x%x%x%x%x%x$") then
    return nil
  end

  local a = util.clamp(util.round(alpha == nil and 255 or alpha), 0, 255)
  return string.format("rgba(%s%02x)", hex:lower(), a)
end

function M.literal(opt, getConfig, resolveExpr)

  if opt.exprWhen and not resolveExpr and getConfig(opt.exprWhen.setting) == opt.exprWhen.value then
    return opt.exprWhen.expr
  end

  local value = getConfig(opt.key)
  if value == nil then return nil end

  if opt.kind == "bool" then
    return value and "true" or "false"

  elseif opt.kind == "int" then
    local n = tonumber(value)
    if n == nil then return nil end
    return tostring(util.round(n))

  elseif opt.kind == "float" then
    local n = tonumber(value)
    if n == nil then return nil end

    return string.format("%.4g", n)

  elseif opt.kind == "color" then
    local alpha = opt.alphaFrom and getConfig(opt.alphaFrom) or nil
    local color = M.toHyprColor(value, alpha)
    if color == nil then return nil end

    return util.luaStr(color)

  elseif opt.kind == "string" then
    local s = tostring(value)
    if opt.expand and s ~= "" then s = noctalia.expandPath(s) end

    return util.luaStr(s)
  end

  return nil
end

function M.legacyValue(opt, getConfig)
  local lit = M.literal(opt, getConfig, true)
  if lit == nil then return nil end
  if opt.kind == "bool" then
    return lit == "true" and "1" or "0"
  elseif opt.kind == "string" or opt.kind == "color" then
    return lit:sub(2, -2):gsub('\\"', '"'):gsub("\\\\", "\\")
  end
  return lit
end

local function insertPath(tree, path, literal)
  local node = tree
  for i = 1, #path - 1 do
    local seg = path[i]
    if node[seg] == nil then
      node[seg] = { __keys = {} }
      table.insert(node.__keys, seg)
    end
    node = node[seg]
  end
  local leaf = path[#path]
  node[leaf] = literal
  table.insert(node.__keys, leaf)
end

local function serialise(node, indent, pretty)
  local parts = {}
  for _, key in ipairs(node.__keys) do
    local value = node[key]
    if type(value) == "table" then
      local inner = serialise(value, indent .. "  ", pretty)
      if inner ~= "" then
        if pretty then
          table.insert(parts, indent .. key .. " = {\n" .. inner .. "\n" .. indent .. "}")
        else
          table.insert(parts, key .. " = { " .. inner .. " }")
        end
      end
    elseif pretty then
      table.insert(parts, indent .. key .. " = " .. value)
    else
      table.insert(parts, key .. " = " .. value)
    end
  end

  if #parts == 0 then return "" end

  if pretty then
    return table.concat(parts, ",\n") .. ","
  end
  return table.concat(parts, ", ")
end

function M.body(getConfig, pretty, baseIndent, resolveExpr)
  local tree = { __keys = {} }
  local count = 0
  for _, opt in ipairs(M.OPTIONS) do
    local lit = M.literal(opt, getConfig, resolveExpr)
    if lit ~= nil then
      insertPath(tree, opt.path, lit)
      count = count + 1
    end
  end
  if count == 0 then return "" end
  return serialise(tree, baseIndent or "", pretty)
end

function M.usesDerivedColor(getConfig)
  for _, opt in ipairs(M.OPTIONS) do
    if opt.exprWhen and getConfig(opt.exprWhen.setting) == opt.exprWhen.value then
      return true
    end
  end
  return false
end

function M.legacyPairs(getConfig)
  local out = {}
  for _, opt in ipairs(M.OPTIONS) do
    local v = M.legacyValue(opt, getConfig)
    if v ~= nil then
      table.insert(out, { table.concat(opt.path, ":"), v })
    end
  end
  return out
end

return M
