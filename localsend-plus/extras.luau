--!nonstrict
-- Files the plugin copies outside its folders while their setting is on:
-- file manager entries and the `localsend` command with its completions.
-- Each shell loads its completion folder by itself, so no shell config is
-- touched. A marker in the data dir keeps what the plugin wrote to each
-- path, and a file is replaced or removed only while it still holds that.

local lib = require("./lib.luau")

local M = {}

local EXTRAS = {
  {
    setting = "dolphin_menu",
    files = {
      -- KDE skips service menus in the home folder that are not executable.
      ["extras/localsend-plus.desktop"] = {
        path = "~/.local/share/kio/servicemenus/localsend-plus.desktop",
        executable = true,
      },
    },
  },
  {
    setting = "nautilus_menu",
    files = {
      -- The file name is the label in Nautilus's Scripts submenu.
      ["extras/file-managers/nautilus-script"] = {
        path = "~/.local/share/nautilus/scripts/Send with LocalSend Plus",
        executable = true,
      },
    },
  },
  {
    setting = "nemo_menu",
    files = {
      ["extras/file-managers/localsend-plus.nemo_action"] = {
        path = "~/.local/share/nemo/actions/localsend-plus.nemo_action",
      },
      ["extras/file-managers/localsend-plus-send.sh"] = {
        path = "~/.local/share/nemo/actions/localsend-plus-send.sh",
        executable = true,
      },
    },
  },
  {
    setting = "terminal_command",
    files = {
      ["extras/terminal/localsend"] = { path = "~/.local/bin/localsend", executable = true },
      ["extras/terminal/localsend.fish"] = { path = "~/.local/share/fish/vendor_completions.d/localsend.fish" },
      ["extras/terminal/localsend.bash"] = { path = "~/.local/share/bash-completion/completions/localsend" },
      ["extras/terminal/_localsend"] = { path = "~/.local/share/zsh/site-functions/_localsend" },
    },
  },
}

local warned = {} -- settings whose blocked install was reported this run

local function tr(key, args)
  return noctalia.tr(key, args)
end

-- The content the plugin last wrote, by absolute path. A marker that does
-- not parse records nothing, so every file it named counts as the user's.
local function readMark(mark)
  local raw = mark and noctalia.readFile(mark)
  local data = raw and noctalia.json.decode(raw)
  local files = {}
  if type(data) == "table" and type(data.files) == "table" then
    for path, content in pairs(data.files) do
      if type(path) == "string" and type(content) == "string" then files[path] = content end
    end
  end
  return files
end

local function writeMark(mark, files)
  if mark ~= nil then lib.writeJson(mark, { files = files }) end
end

local function install(extra, mark, recorded)
  local plan, conflicts = {}, {}
  for source, file in pairs(extra.files) do
    local content = noctalia.readFile(lib.PLUGIN_DIR .. "/" .. source)
    if content == nil then return end
    local path = noctalia.expandPath(file.path)
    local current = noctalia.readFile(path)
    if current == nil or current == content or current == recorded[path] then
      table.insert(plan, { path = path, content = content, write = current ~= content, executable = file.executable })
    else
      table.insert(conflicts, path)
    end
  end
  -- All or nothing: completions next to someone else's `localsend` would
  -- complete the wrong command.
  if #conflicts > 0 then
    if not warned[extra.setting] then
      warned[extra.setting] = true
      table.sort(conflicts)
      noctalia.notifyError(tr("notify.title"), tr("error.extra_exists", { path = table.concat(conflicts, ", ") }))
    end
    return
  end
  local files = table.clone(recorded)
  for _, item in ipairs(plan) do
    if item.write then
      local ok, err = noctalia.mkdirAll(lib.dirname(item.path))
      if ok then
        ok, err = noctalia.writeFile(item.path, item.content)
      end
      if not ok then
        writeMark(mark, files) -- keeps what did get written
        noctalia.notifyError(
          tr("notify.title"),
          tr("error.install_extra", { path = item.path, reason = tostring(err) })
        )
        return
      end
    end
    files[item.path] = item.content
    if item.executable then noctalia.runAsync({ "chmod", "755", item.path }) end
  end
  writeMark(mark, files)
end

local function uninstall(mark, recorded)
  local kept = {}
  for path, content in pairs(recorded) do
    local current = noctalia.readFile(path)
    if current == content then
      noctalia.removeFile(path)
    elseif current ~= nil then
      table.insert(kept, path)
    end
  end
  noctalia.removeFile(mark)
  if #kept > 0 then
    table.sort(kept)
    noctalia.notify(tr("notify.title"), tr("error.extra_kept", { path = table.concat(kept, ", ") }))
  end
end

-- Brings every integration in line with its setting.
function M.sync()
  for _, extra in ipairs(EXTRAS) do
    local mark = lib.dataFile(extra.setting)
    local recorded = readMark(mark)
    if noctalia.getConfig(extra.setting) == true then
      install(extra, mark, recorded)
    else
      warned[extra.setting] = nil
      if mark ~= nil and noctalia.fileExists(mark) then uninstall(mark, recorded) end
    end
  end
end

return M
