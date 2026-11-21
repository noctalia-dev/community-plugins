--!nonstrict
-- Browse… for files and folders, in a page of its own (route `files`, helper `list-dir`): the same in the app
-- and in the plugin panel, which stays above every window and would hide a chooser window.
local kit = require("../ui/kit.luau")

local M = {}

-- The helper turns the chosen path into the value (relative to the config, `$HOME`, a command).
local function request(ctx, options, chosen)
  return { filter = options.filter, start = options.start, relative = options.relative,
           command = options.command, chosen = chosen, config = ctx.store.state and ctx.store.state.path }
end

-- options: mode ("file"/"folder"), title, filter, start, relative, command; `onChosen(value)`.
-- `replace`: the page asking is itself a picker step, so the browser takes its place (back = its caller).
function M.open(ctx, options, onChosen, replace)
  local view = ctx.view
  view.pick, view.files, view.fileQuery = { options = options, onChosen = onChosen }, nil, ""
  local route = { name = "files" }
  if replace then ctx.replace(route) else ctx.go(route) end
end

local function join(folder, name)
  return (folder == "/" and "" or folder) .. "/" .. name
end

local function load(ctx, path)
  local view, pick = ctx.view, ctx.view.pick
  local previous = view.files
  view.files = { loading = true, path = path or (previous and previous.path), error = nil }
  local req = request(ctx, pick.options)
  req.path, req.folders = path, pick.options.mode == "folder"
  ctx.helper.call("list-dir", req, function(err, data)
    if view.pick ~= pick then return end
    if err then
      -- keep the folder that was shown: a typed path that isn't a folder only adds the error
      view.files = previous and not previous.error and previous or { path = path }
      view.files.loading, view.files.error = false, err.error
    else
      view.files = { path = data.path, parent = data.parent, home = data.home, folders = data.folders or {},
                     files = data.files or {}, truncated = data.truncated }
      if not previous or previous.path ~= data.path then
        view.fileQuery = ""
        ctx.bump("fileQuery")
      end
    end
    view.filesTyped = nil
    ctx.bump("files-path")
    ctx.render()
  end)
end

local function choose(ctx, path)
  local view, pick = ctx.view, ctx.view.pick
  view.files.choosing = true
  ctx.render()
  ctx.helper.call(pick.options.mode == "folder" and "pick-folder" or "pick-file", request(ctx, pick.options, path),
    function(err, data)
      if view.pick ~= pick then return end
      view.files.choosing = false
      if err then ctx.flash(err.error, "warning"); ctx.render(); return end
      view.pick = nil
      pick.onChosen(data.path)
      ctx.back()
    end)
end

function M.render(ctx)
  local view = ctx.view
  local pick = view.pick
  if not pick then return { header = { kit.header(ctx, "Browse") }, content = { kit.empty("Nothing to choose.") } } end
  local folderMode = pick.options.mode == "folder"
  local state = view.files
  if not state then
    load(ctx, nil)
    state = view.files
  end
  local busy = state.loading or state.choosing
  local header = {
    kit.header(ctx, pick.options.title or (folderMode and "Choose a folder" or "Choose a file"), state.path),
    ui.row({ key = "files-bar", gap = 6, align = "center" }, {
      kit.iconButton("arrow-up", "Parent folder", function() load(ctx, state.parent) end,
                     state.parent ~= nil and not busy, "files-up"),
      kit.iconButton("home", "Home folder", function() load(ctx, "~") end, not busy, "files-home"),
      ui.input({ key = "files-path-" .. ctx.gen("files-path"), value = state.path or "", flexGrow = 1,
                 controlSize = "sm", placeholder = "Folder path",
                 onChange = function(text) view.filesTyped = text end,
                 onSubmit = function(text) load(ctx, noctalia.string.trim(text)) end }),
      ui.button({ key = "files-go", glyph = "arrow-right", variant = "outline", controlSize = "sm",
                  tooltip = "Open this folder", enabled = not busy,
                  onClick = function() load(ctx, noctalia.string.trim(view.filesTyped or state.path or "")) end }),
    }),
    kit.filterBox(ctx, "fileQuery", { focus = true, placeholder = folderMode and "Filter folders" or "Filter this folder" }),
  }
  local content = {}
  if state.error then table.insert(content, kit.notice(state.error, "error", nil, "files-error")) end
  if folderMode and state.path and not state.loading then
    table.insert(content, ui.row({ key = "files-use", gap = 6 }, {
      ui.button({ text = "Use this folder", glyph = "check", controlSize = "sm", enabled = not busy,
                  onClick = function() choose(ctx, state.path) end }),
    }))
  end
  if state.loading then
    table.insert(content, kit.loading())
    return { header = header, content = content }
  end
  local query = kit.filterText(ctx, "fileQuery")
  local shown, more = 0, false
  local function add(name, isFolder)
    if query ~= "" and not kit.contains(name, query) then return end
    if shown >= kit.LIST_CAP then more = true; return end
    shown = shown + 1
    local path = join(state.path, name)
    table.insert(content, kit.navRow({ key = (isFolder and "folder-" or "file-") .. name,
      glyph = isFolder and "folder" or "file", title = name, trailing = isFolder and "chevron-right" or "corner-down-left",
      onClick = function()
        if busy then return end
        if isFolder then load(ctx, path) else choose(ctx, path) end
      end }))
  end
  for _, name in ipairs(state.folders or {}) do add(name, true) end
  for _, name in ipairs(state.files or {}) do add(name, false) end
  if more or state.truncated then table.insert(content, kit.muted("Type to find more.")) end
  if shown == 0 and not state.error then
    table.insert(content, kit.empty(query ~= "" and "Nothing here matches." or "This folder is empty.", "folder"))
  end
  return { header = header, content = content }
end

return M
