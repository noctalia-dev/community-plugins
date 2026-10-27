--!nonstrict
-- Helpers shared by the widget, panel and launcher: formatting, the pace model and the
-- actions a session card or launcher result can take. No state of its own.
--
-- pace and planName are ported from jrohland/noctalia-v5-claudecode via claude-cockpit
-- (MIT); focus, launch and resume from claude-sessions (lfdominguez, MIT).
local M = {}
local PLUGIN = noctalia.pluginDir()
local SCRIPTS = PLUGIN .. "/scripts"
local HOME = noctalia.getenv("HOME") or ""
local DEFAULT_DIR = HOME .. "/.claude"

M.HOUR_MS = 3600000
M.DAY_MS = 86400000

local function trim(v) return noctalia.string.trim(tostring(v or "")) end

-- ── Paths ───────────────────────────────────────────────────────────────────

local function workPrefix()
  local root = trim(noctalia.getConfig("work_root"))
  return root ~= "" and (string.gsub(noctalia.expandPath(root), "/+$", "") .. "/") or nil
end

-- Paths under the projects folder show relative to it, anything under $HOME as ~/...
function M.projectPath(p)
  p = p or ""
  local work = workPrefix()
  if work and string.sub(p, 1, #work) == work then return string.sub(p, #work + 1) end
  if HOME ~= "" and string.sub(p, 1, #HOME + 1) == HOME .. "/" then return "~" .. string.sub(p, #HOME + 1) end
  return p
end

function M.workRoot()
  local work = workPrefix()
  return work and string.sub(work, 1, -2) or HOME
end

function M.transcript(account, cwd, sid)
  return `{account or DEFAULT_DIR}/projects/{(string.gsub(cwd, "[^%w]", "-"))}/{sid}.jsonl`
end

-- ── Formatting ──────────────────────────────────────────────────────────────

function M.round(x) return math.floor((tonumber(x) or 0) + 0.5) end

function M.dur(s)
  s = math.max(0, math.floor(s))
  if s < 60 then return `{s}s` elseif s < 3600 then return `{s // 60}m` elseif s < 86400 then return `{s // 3600}h` end
  return `{s // 86400}d`
end

function M.ago(ms) return M.dur((noctalia.nowMs() - ms) / 1000) end

-- Time until `ms`, coarse enough for a tooltip column: "4d 2h", "3h 12m", "8m".
function M.countdown(ms)
  if not ms then return nil end
  local left = math.floor((ms - noctalia.nowMs()) / 60000)
  if left <= 0 then return "resetting" end
  if left >= 1440 then return `{left // 1440}d {left % 1440 // 60}h` end
  if left >= 60 then return `{left // 60}h {left % 60}m` end
  return `{left}m`
end

-- Wall-clock time of `ms` in the shell's time format, with the weekday when it is
-- more than a day away.
function M.clock(ms)
  if not ms then return nil end
  local fmt = "%H:%M"
  local ok, shellFmt = pcall(noctalia.timeFormat)
  local inner = ok and type(shellFmt) == "string" and string.match(shellFmt, "{:(.-)}") or nil
  if inner and inner ~= "" then fmt = inner end
  local secs = math.floor(ms / 1000)
  if ms - noctalia.nowMs() >= M.DAY_MS then fmt = "%a " .. fmt end
  -- The shell's format is chrono's; os.date rejects codes such as %T or %e.
  local ok, s = pcall(os.date, fmt, secs)
  if ok then return s end
  return os.date(string.sub(fmt, 1, 3) == "%a " and "%a %H:%M" or "%H:%M", secs)
end

function M.tokens(n)
  n = tonumber(n) or 0
  if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.0fk", n / 1e3) end
  return tostring(math.floor(n + 0.5))
end

local CURRENCY = {
  usd = { "$", "" }, eur = { "", " €" }, gbp = { "£", "" }, jpy = { "¥", "" }, cny = { "CN¥", "" },
  chf = { "", " CHF" }, aud = { "A$", "" }, cad = { "C$", "" }, inr = { "₹", "" },
}

-- A USD amount in the configured currency. `rates` is the published pricing.rates; with
-- no rate yet the amount stays in USD, symbol included.
function M.money(usd, rates)
  local n = tonumber(usd) or 0
  local code = noctalia.getConfig("currency")
  local sym = CURRENCY.usd
  if CURRENCY[code] and code ~= "usd" and type(rates) == "table" then
    local rate = tonumber(rates[string.upper(code)])
    if rate and rate > 0 then n, sym = n * rate, CURRENCY[code] end
  end
  local text
  if n >= 1000 then text = string.format("%.1fk", n / 1000)
  elseif n >= 100 then text = tostring(math.floor(n + 0.5))
  elseif n >= 10 then text = string.format("%.1f", n)
  else text = string.format("%.2f", n) end
  return sym[1] .. text .. sym[2]
end

-- ── Plan and pace ───────────────────────────────────────────────────────────

local PLAN_WORDS = { free = "Free", pro = "Pro", max = "Max", team = "Team", enterprise = "Enterprise", business = "Business" }

-- "team" + "default_claude_max_5x" -> "Claude Team 5x".
function M.planName(subscription, tier)
  local function clean(v)
    if type(v) ~= "string" then return nil end
    v = string.lower(v)
    return (v ~= "" and v ~= "unknown") and v or nil
  end
  subscription, tier = clean(subscription), clean(tier)
  if not subscription and not tier then return "Claude" end
  local rest = string.gsub(string.gsub(string.gsub(tier or "", "^default_", ""), "^t%d+_", ""), "^claude_", "")
  local words, multiplier, family = {}, nil, nil
  for word in string.gmatch(rest, "[^_]+") do
    if string.match(word, "^%d+x$") then
      multiplier = word
    else
      if PLAN_WORDS[word] and not family then family = word end
      words[#words + 1] = word
    end
  end
  local plan = PLAN_WORDS[subscription or ""] or (family and PLAN_WORDS[family])
  if not plan then
    local shown = {}
    for _, w in ipairs(words) do shown[#shown + 1] = string.upper(string.sub(w, 1, 1)) .. string.sub(w, 2) end
    plan = #shown > 0 and table.concat(shown, " ") or subscription
  end
  local parts = { "Claude" }
  if plan and plan ~= "" then parts[#parts + 1] = plan end
  if multiplier then parts[#parts + 1] = multiplier end
  return table.concat(parts, " ")
end

-- How long a window must have run before its average burn rate means anything: twenty
-- minutes of a week is noise.
local MIN_ELAPSED = { session = 15 * 60000, weekly = 6 * M.HOUR_MS }

local function isSession(w) return w.kind == "session" end

-- Where the window is heading at the current burn rate.
--   status   idle (no active window) | early (too soon to project) | ok | tight (on course
--            for 85%+, or 100% only just before the reset) | hit (100% well before the
--            reset) | soon (100% within the hour for the 5-hour window, within a day for a
--            weekly one) | limit (at 100%)
--   rate     percent per hour: the recent rate from the service's samples for the 5-hour
--            window when it has them (`recent` = true), else the window's average so far
--   projected percent at reset; etaMs = time until 100% when that is before the reset.
--            "soon" from the API's severity alone may have no etaMs (and no projection).
--   budget   percent per hour that would last exactly until the reset
--   timeFrac share of the window's time already gone
-- The API's own severity wins when it is worse.
function M.pace(w)
  local util = tonumber(w.percent) or 0
  local now = noctalia.nowMs()
  local p = { util = util }
  if not w.resetsAt or w.resetsAt <= now then
    p.status = util >= 100 and "limit" or "idle"
    return p
  end
  local dur = w.durationMs or 7 * M.DAY_MS
  local remaining = w.resetsAt - now
  local elapsed = math.max(0, math.min(dur, dur - remaining))
  p.remainingMs, p.timeFrac = remaining, elapsed / dur
  p.budget = math.max(0, 100 - util) / (remaining / M.HOUR_MS)
  if util >= 100 then
    p.status = "limit"
    return p
  end
  local rate
  if isSession(w) and w.rate then
    rate, p.recent = w.rate, true
  elseif elapsed >= MIN_ELAPSED[isSession(w) and "session" or "weekly"] then
    rate = util / (elapsed / M.HOUR_MS)
  end
  if not rate then
    p.status = util >= 85 and "tight" or "early"
  else
    p.rate = rate
    p.projected = util + rate * remaining / M.HOUR_MS
    if rate > 0 then
      local eta = (100 - util) / rate * M.HOUR_MS
      if eta < remaining then p.etaMs = eta end
    end
    local soon = isSession(w) and M.HOUR_MS or M.DAY_MS
    if p.etaMs and p.etaMs < soon then p.status = "soon"
    elseif p.etaMs and p.etaMs < remaining * 0.9 then p.status = "hit"
    elseif p.projected >= 85 then p.status = "tight"
    else p.status = "ok" end
  end
  local vendor = w.severity == "critical" and "soon" or w.severity == "high" and "tight" or nil
  local rank = { idle = 0, early = 0, ok = 0, tight = 1, hit = 2, soon = 3, limit = 4 }
  if vendor and rank[vendor] > rank[p.status] then p.status = vendor end
  return p
end

-- "12%/h" for the 5-hour window, "14%/day" for weekly ones.
function M.rateText(w, perHour)
  if isSession(w) then return string.format("%.0f%%/h", perHour) end
  return string.format("%.0f%%/day", perHour * 24)
end

-- Duration in ms as "2d 4h", "3h 10m" or "25m".
function M.span(ms)
  local m = math.max(0, math.floor(ms / 60000))
  if m >= 1440 then return `{m // 1440}d {m % 1440 // 60}h` end
  if m >= 60 then return `{m // 60}h {m % 60}m` end
  return `{m}m`
end

-- Two lines for a window: what will happen, then when it resets and what you can spend.
function M.paceText(w, p)
  p = p or M.pace(w)
  local resets = w.resetsAt and `resets in {M.countdown(w.resetsAt)} ({M.clock(w.resetsAt)})` or nil
  if p.status == "idle" then return "No active window", "starts with your next message" end
  if p.status == "limit" then return "Limit reached", resets end
  local budget = p.budget and `{resets} · budget {M.rateText(w, p.budget)}` or resets
  if (p.status == "hit" or p.status == "soon") and p.etaMs then
    return `Limit in {M.span(p.etaMs)} at this rate ({M.clock(noctalia.nowMs() + p.etaMs)})`, budget
  end
  if p.status == "soon" then return "Close to the limit", budget end
  if not p.projected then return "Too early to project", budget end
  local how = p.recent and `at the last {M.span(w.rateSpanMs or 0)}'s rate` or "at this rate"
  return `On course for ~{M.round(math.min(p.projected, 100))}% by reset {how}`, budget
end

-- A few words for tight spaces (the Live strip): what happens next.
function M.paceShort(w, p)
  p = p or M.pace(w)
  if p.status == "idle" then return "not started" end
  if p.status == "limit" then return w.resetsAt and `full · resets {M.clock(w.resetsAt)}` or "full" end
  if (p.status == "hit" or p.status == "soon") and p.etaMs then return `full by {M.clock(noctalia.nowMs() + p.etaMs)}` end
  if p.status == "soon" then return "almost full" end
  if not p.projected then return `resets in {M.countdown(w.resetsAt)}` end
  return `~{M.round(math.min(p.projected, 100))}% by reset`
end

-- Red only when it is urgent; a limit days away is a warning, not an alarm.
function M.paceColor(status, calm)
  if status == "limit" or status == "soon" then return "error" end
  if status == "hit" or status == "tight" then return "tertiary" end
  return calm
end

-- ── Accounts ────────────────────────────────────────────────────────────────

function M.accounts() return noctalia.state.get("accounts") or {} end

function M.multiAccount() return #M.accounts() > 1 end

function M.accountLabel(dir)
  for _, a in ipairs(M.accounts()) do if a.dir == dir then return a.label end end
  return dir and (string.match(dir, "([^/]+)$") or dir) or "default"
end

-- ── Actions ─────────────────────────────────────────────────────────────────

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

-- Runs argv (or a shell when empty) in dir: a new tab in the most recently focused kitty
-- when no terminal is configured and kitty remote control is on, else in a terminal.
function M.launch(dir, argv)
  argv = argv or {}
  local function fallback()
    local words = {}
    for _, a in ipairs(argv) do words[#words + 1] = M.quote(a) end
    local run = #words > 0 and table.concat(words, " ") or "exec \"${SHELL:-sh}\""
    inTerminal(`cd {M.quote(dir)} && {run}`)
  end
  if trim(noctalia.getConfig("terminal")) ~= "" then return fallback() end
  local cmd = { "bash", SCRIPTS .. "/launch.sh", dir }
  for _, a in ipairs(argv) do cmd[#cmd + 1] = a end
  if not noctalia.runAsync(cmd, function(r) if r.exitCode ~= 0 then fallback() end end, 15000) then fallback() end
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

-- Ask the service to refresh everything now (the panel's refresh button).
function M.requestRefresh(action)
  noctalia.state.set("command", { action = action or "refresh", at = noctalia.nowMs() })
end

return M
