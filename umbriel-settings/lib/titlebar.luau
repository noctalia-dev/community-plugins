--!nonstrict
-- Title-bar backgrounds that follow Noctalia's palette. Helper `titlebar` reads what follows and the palette
-- colors behind each source; starting or stopping is queued as an ordinary field edit with a `follow` intent
-- (store.setField), so Review shows it, Discard and Undo drop it, and only the helper's `save` installs or removes
-- Noctalia's post_hook. Afterwards the hook keeps the color current.
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

-- The loaded state (nil until the helper answers); loads once per config and again after reopening.
function M.state(ctx)
  local view, path = ctx.view, configPath(ctx)
  if view.titlebarPath ~= path then
    view.titlebar, view.titlebarPath = nil, path
  end
  if view.titlebar == nil and not view.titlebarLoading then
    view.titlebarLoading = true
    ctx.helper.call("titlebar", { config = path }, function(err, data)
      view.titlebarLoading = false
      view.titlebar = err and { fields = {}, sources = {}, error = err.error } or data
      ctx.render()
    end)
  end
  return view.titlebar
end

-- What is on disk for `fid` ({ source, alpha, color }), or nil.
local function onDisk(ctx, name)
  local state = M.state(ctx)
  return state and state.fields and state.fields[name] or nil
end

-- How `fid` follows Noctalia ({ source, alpha, color }), or nil: a pending start or stop wins over the disk.
function M.following(ctx, fid)
  local name = fieldName(fid)
  if not name then return nil end
  local change = ctx.store.fieldChanges[fid]
  if change and change.follow ~= nil then
    if change.follow == false then return nil end
    return { source = change.follow.source, alpha = change.follow.alpha, color = change.value }
  end
  return onDisk(ctx, name)
end

-- The old include approach (a titlebar.toml include) is no longer used: drop it in the same step.
local function dropOldInclude(ctx)
  local store, state = ctx.store, M.state(ctx)
  local oldInclude = state and state.old_include
  local files = store.value(INCLUDE_FID)
  if type(files) ~= "table" or not oldInclude then return end
  local list, found = {}, false
  for _, name in ipairs(files) do
    if name == oldInclude then found = true else table.insert(list, name) end
  end
  if found then store.setField(INCLUDE_FID, list) end
end

-- Follow with `source` ("kde"/"kde_header") at `opacity` (0-1); source nil stops following. Queued until saved.
function M.follow(ctx, fid, source, opacity)
  local store, name = ctx.store, fieldName(fid)
  local disk = onDisk(ctx, name)
  if not source then
    -- stopping a start that isn't saved yet just drops it; stopping what is on disk is an edit of its own
    -- (the color stays as it is)
    if not disk then
      store.revertField(fid)
    else
      store.setField(fid, store.value(fid) or disk.color, false)
    end
    ctx.bump(fields.rowKey(fid))
    return
  end
  local state = M.state(ctx)
  local base = state and state.sources and state.sources[name] and state.sources[name][source]
  if not base then
    ctx.flash("Noctalia's palette isn't available yet, so this title bar can't follow it.", "error")
    return
  end
  local alpha = format.alphaByte(opacity or 1)
  -- the same source and opacity as on disk is no change of its own
  local same = disk and disk.source == source and disk.alpha == alpha
  store.group(function()
    store.setField(fid, base .. alpha, not same and { source = source, alpha = alpha } or nil)
    dropOldInclude(ctx)
  end)
  ctx.bump(fields.rowKey(fid))  -- the row's hex input shows the followed color
end

-- A fixed color for `fid` (nil: unset it): stops following once saved.
function M.setFixed(ctx, fid, value)
  local name = fieldName(fid)
  local stop = nil  -- (`x and false or nil` is always nil in Lua)
  if name and onDisk(ctx, name) then stop = false end
  if value == nil then ctx.store.unsetField(fid, stop) else ctx.store.setField(fid, value, stop) end
end

return M
