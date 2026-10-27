--!nonstrict
-- CLAUDE.md tab: the global file, every CLAUDE.md under $HOME, and a "create" row for
-- each project with sessions but no file. Opens in the configured GUI editor.
-- Ported from claude-cockpit's CLAUDE.md tab (nightwatch75, MIT).
local shared = require("./shared.luau")
local kit = require("./kit.luau")
local sessionsTab = require("./tab-sessions.luau")
local M = {}
M.nav = kit.nav()

local SCRIPT = noctalia.pluginDir() .. "/scripts/find-claude-md.sh"
local HOME = noctalia.expandPath("~")
local GLOBAL = HOME .. "/.claude/CLAUDE.md"
local data = { loading = false, error = nil, paths = nil }

-- Remote filesystems the scan must never walk: a stalled share would stall it.
local REMOTE = {
  nfs = true, nfs4 = true, cifs = true, smb3 = true, smbfs = true, sshfs = true, ["fuse.sshfs"] = true,
  davfs = true, ["fuse.davfs"] = true, ["fuse.rclone"] = true, ceph = true, glusterfs = true, ["9p"] = true,
}

local function remoteMounts()
  local found = {}
  for line in string.gmatch(noctalia.readFile("/proc/mounts") or "", "[^\n]+") do
    local mount, fstype = string.match(line, "^%S+%s+(%S+)%s+(%S+)")
    if mount and REMOTE[fstype] then
      mount = string.gsub(mount, "\\(%d%d%d)", function(o) return string.char(tonumber(o, 8)) end)
      if string.sub(mount, 1, #HOME + 1) == HOME .. "/" then found[#found + 1] = mount end
    end
  end
  return found
end

function M.load(ctx)
  if data.loading then return end
  data.loading, data.error = true, nil
  local argv = { "bash", SCRIPT, HOME }
  for _, m in ipairs(remoteMounts()) do argv[#argv + 1] = m end
  local started = noctalia.runAsync(argv, function(r)
    data.loading = false
    if r.exitCode == 0 then
      local paths = {}
      for line in string.gmatch(r.stdout or "", "[^\n]+") do paths[#paths + 1] = line end
      table.sort(paths)
      data.paths = paths
    else
      data.error = "Could not scan for CLAUDE.md files"
    end
    ctx.render()
  end, 60000)
  if not started then data.loading, data.error = false, "Could not start the scan" end
  ctx.render()
end

function M.show(ctx)
  if not data.paths then M.load(ctx) end
end
function M.refresh(ctx) M.load(ctx); sessionsTab.refresh() end
function M.busy() return data.loading end

local function row(label, path, selected)
  local exists = noctalia.fileExists(path)
  return ui.row({ key = "md-" .. path, gap = 8, align = "center", padding = 6, radius = 8,
    fill = selected and "primary/0.10" or "#00000000", onClick = function() shared.openInEditor(path) end }, {
    ui.glyph({ name = exists and "file-text" or "file-plus", size = 15, color = exists and "primary" or "on_surface_variant" }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = label, fontSize = 13 }),
      kit.muted(shared.projectPath(path), 10, { maxLines = 1 }),
    }),
    kit.iconButton(exists and "external-link" or "plus", exists and "Open in editor" or "Create in editor",
      function() shared.openInEditor(path) end),
  })
end

function M.render(ctx)
  M.nav:begin()
  local rows = {}
  local function add(label, path)
    rows[#rows + 1] = row(label, path, M.nav:add("md-" .. path, function() shared.openInEditor(path) end))
  end
  add("Global (~/.claude)", GLOBAL)
  if data.error then
    rows[#rows + 1] = ui.label({ text = data.error, color = "error" })
  elseif not data.paths then
    rows[#rows + 1] = kit.muted("Scanning your home folder…")
  else
    local seen = { [GLOBAL] = true }
    for _, path in ipairs(data.paths) do
      if not seen[path] then
        seen[path] = true
        add(string.match(path, "([^/]+)/CLAUDE%.md$") or path, path)
      end
    end
    local missing = {}
    for _, g in ipairs(sessionsTab.projects(ctx) or {}) do
      local path = g.cwd .. "/CLAUDE.md"
      if string.sub(g.cwd, 1, 1) == "/" and not seen[path] and noctalia.fileExists(g.cwd) then
        seen[path] = true
        missing[#missing + 1] = { label = string.match(g.cwd, "([^/]+)/?$") or g.cwd, path = path }
      end
    end
    if #missing > 0 then
      rows[#rows + 1] = kit.muted("Projects without a CLAUDE.md", 11, { fontWeight = "bold" })
      for _, m in ipairs(missing) do add(m.label, m.path) end
    end
  end
  return ui.scroll({ key = "claudemd-scroll", flexGrow = 1, gap = 4, align = "stretch", revealKey = M.nav.reveal }, rows)
end

return M
