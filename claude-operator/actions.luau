--!nonstrict
-- The actions a session card or launcher result can take: focus a session's window, open
-- a URL, start or resume claude (a kitty tab or window through scripts/launch.sh, else the
-- configured terminal or Noctalia's) and open a file in an editor. No state of its own.
--
-- focus, launch and resume from claude-sessions (lfdominguez, MIT).
local M = {}
local SCRIPTS = noctalia.pluginDir() .. "/scripts"
local HOME = noctalia.getenv("HOME") or ""
local DEFAULT_DIR = HOME .. "/.claude"

local function trim(v) return noctalia.string.trim(tostring(v or "")) end

function M.quote(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end

-- The claude binary. Noctalia's environment often lacks the user's shell PATH, so look
-- where the installers put it: native (~/.local/bin), the older local install
-- (~/.claude/local), npm with a user prefix (~/.npm-global/bin), bun, and /usr/local.
function M.claudeBin()
  if noctalia.commandExists("claude") then return "claude" end
  for _, p in ipairs({ HOME .. "/.local/bin/claude", HOME .. "/.claude/local/claude",
    HOME .. "/.npm-global/bin/claude", HOME .. "/.bun/bin/claude", "/usr/local/bin/claude" }) do
    if noctalia.fileExists(p) then return p end
  end
  return nil
end

-- argv running claude (plus args) under the given account.
function M.claudeArgv(account, ...)
  local argv = {}
  if account and account ~= DEFAULT_DIR then argv = { "env", "CLAUDE_CONFIG_DIR=" .. account } end
  argv[#argv + 1] = M.claudeBin() or "claude"
  for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
  return argv
end

function M.open(target) return noctalia.runAsync({ "xdg-open", target }) end

-- Brings the session's terminal to the front (the exact kitty tab with kitty remote
-- control, the exact pane in tmux). A Remote Control session with no window, e.g. a
-- headless `claude remote-control`, opens on claude.ai instead; anything else says why
-- nothing happened.
function M.focus(s)
  noctalia.runAsync({ "bash", SCRIPTS .. "/focus.sh", tostring(s.pid) }, function(r)
    if r.exitCode == 0 then return end
    if s.remote then
      M.open(s.remote)
    else
      noctalia.notify("Claude Operator", "Could not find this session's window. Window focus works on Hyprland, "
        .. "niri, sway and Umbriel; inside tmux it needs an attached client.")
    end
  end, 10000)
end

-- A configured terminal is wired the way the host does it: `<term> -e sh -lc <cmd>`,
-- with `--` for the GTK terminals that need it.
local function inTerminal(cmd)
  local term = trim(noctalia.getConfig("terminal"))
  if term == "" then return noctalia.runInTerminal(cmd) end
  local bin = string.match(string.match(term, "^%S+") or term, "([^/]+)$") or term
  local sep = (bin == "gnome-terminal" or bin == "kgx" or bin == "ptyxis") and "--" or "-e"
  return noctalia.runAsync(term .. " " .. sep .. " sh -lc " .. M.quote(cmd))
end

-- Runs argv (or a shell when empty) in dir: a new tab (or, with open_in = "window", a new
-- OS window) in the most recently focused kitty when no terminal is configured and kitty
-- remote control is on, else in a terminal.
function M.launch(dir, argv)
  argv = argv or {}
  local function fallback()
    local words = {}
    for _, a in ipairs(argv) do words[#words + 1] = M.quote(a) end
    local run = #words > 0 and table.concat(words, " ") or "exec \"${SHELL:-sh}\""
    inTerminal(`cd {M.quote(dir)} && {run}`)
  end
  if trim(noctalia.getConfig("terminal")) ~= "" then return fallback() end
  local cmd = { "bash", SCRIPTS .. "/launch.sh" }
  if noctalia.getConfig("open_in") == "window" then cmd[#cmd + 1] = "--window" end
  cmd[#cmd + 1] = dir
  for _, a in ipairs(argv) do cmd[#cmd + 1] = a end
  if not noctalia.runAsync(cmd, function(r) if r.exitCode ~= 0 then fallback() end end, 15000) then fallback() end
end

-- Starts claude in dir under the default account: in the Claude desktop app's Code tab
-- when new_session_in is "desktop", else the way launch opens it. When nothing handles
-- claude:// links, the session opens in the terminal and a notice says why.
function M.newSession(dir)
  local function inTerminalInstead() M.launch(dir, M.claudeArgv(nil)) end
  if noctalia.getConfig("new_session_in") ~= "desktop" then return inTerminalInstead() end
  local url = "claude://code/new?folder=" .. noctalia.string.urlEncode(dir)
  local function onDone(r)
    if r.exitCode == 0 then return end
    noctalia.notify("Claude Operator", "Nothing handles claude:// links (is the Claude desktop app installed?), so the session opened in a terminal.")
    inTerminalInstead()
  end
  if not noctalia.runAsync({ "bash", SCRIPTS .. "/open-desktop.sh", url }, onDone, 15000) then inTerminalInstead() end
end

function M.resume(account, cwd, sid) M.launch(cwd, M.claudeArgv(account, "--resume", sid)) end

function M.resumeCommand(account, cwd, sid)
  local env = account and account ~= DEFAULT_DIR and `CLAUDE_CONFIG_DIR={M.quote(account)} ` or ""
  return `cd {M.quote(cwd)} && {env}claude --resume {sid}`
end

-- The configured editor, else the first of code / zed that is installed. No $EDITOR
-- fallback: that is usually a terminal editor, which fails without a tty.
function M.openInEditor(path)
  local configured = trim(noctalia.getConfig("editor_command"))
  local bin = configured ~= "" and configured
    or noctalia.commandExists("code") and "code" or noctalia.commandExists("zed") and "zed" or nil
  if not bin then
    noctalia.notifyError("Claude Operator", "No editor found: set Editor command in the plugin settings.")
    return false
  end
  local argv = {}
  for word in string.gmatch(bin, "%S+") do argv[#argv + 1] = word end
  argv[#argv + 1] = path
  return noctalia.runAsync(argv)
end

return M
