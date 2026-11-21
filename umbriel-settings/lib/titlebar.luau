--!nonstrict
-- Title-bar backgrounds that follow Noctalia's palette: helper `titlebar` (state) and `titlebar-follow`.
-- The chosen color is queued as an ordinary edit for review; afterwards Noctalia's post_hook keeps it current.
local fields = require("../ui/fields.luau")
local format = require("../ui/format.luau")

local M = {}

local INCLUDE_FID = "include.optional.files"

local function configPath(ctx)
  return ctx.store.state and ctx.store.state.path or nil
end

local function fieldName(fid)
  return string.match(fid, "^colors%.title_bar%.(.+)$")
end

-- The loaded state (nil until the helper answers); loads once per config.
function M.state(ctx)
  local view, path = ctx.view, configPath(ctx)
  if view.titlebarPath ~= path then
    view.titlebar, view.titlebarPath, view.titlebarBusy, view.titlebarQueued = nil, path, {}, {}
  end
  view.titlebarBusy, view.titlebarQueued = view.titlebarBusy or {}, view.titlebarQueued or {}
  if view.titlebar == nil and not view.titlebarLoading then
    view.titlebarLoading = true
    ctx.helper.call("titlebar", { config = path }, function(err, data)
      view.titlebarLoading = false
      view.titlebar = err and { fields = {}, error = err.error } or data
      ctx.render()
    end)
  end
  return view.titlebar
end

-- How `fid` follows Noctalia ({ source, alpha, color }), or nil when it doesn't.
function M.following(ctx, fid)
  local name = fieldName(fid)
  local state = name and M.state(ctx)
  return state and state.fields and state.fields[name] or nil
end

local function queueConfigEdits(ctx, fid, color, oldInclude)
  local store = ctx.store
  if color then store.setField(fid, color) end
  local files = store.value(INCLUDE_FID)
  if type(files) ~= "table" or not oldInclude then return end
  local list, found = {}, false
  for _, name in ipairs(files) do
    if name == oldInclude then found = true else table.insert(list, name) end
  end
  if found then store.setField(INCLUDE_FID, list) end  -- the old include approach is no longer used
end

-- Follow with `source` ("kde"/"kde_header") at `opacity` (0-1); source nil stops following.
-- Slider drags send at most one request at a time; the newest value waits for the running one.
function M.follow(ctx, fid, source, opacity)
  local view, name = ctx.view, fieldName(fid)
  M.state(ctx)
  local item = view.titlebar and view.titlebar.fields and view.titlebar.fields[name]
  if item and source == item.source and opacity then  -- show the new opacity before the helper answers
    item.alpha = format.alphaByte(opacity)
  end
  if view.titlebarBusy[fid] then
    view.titlebarQueued[fid] = { source = source, opacity = opacity }
    return
  end
  view.titlebarBusy[fid] = true
  ctx.helper.call("titlebar-follow", { config = configPath(ctx), field = name, source = source, opacity = opacity or 1 },
    function(err, data)
      view.titlebarBusy[fid] = nil
      if err then
        ctx.flash(err.error, "error")
      else
        view.titlebar = data
        local item = data.fields and data.fields[name]
        if source then queueConfigEdits(ctx, fid, item and item.color, data.old_include) end
        local key = fields.rowKey(fid)  -- the row's hex input shows the followed color
        ctx.bump(key)
      end
      local queued = view.titlebarQueued[fid]
      view.titlebarQueued[fid] = nil
      if queued then M.follow(ctx, fid, queued.source, queued.opacity) else ctx.render() end
    end)
end

return M
