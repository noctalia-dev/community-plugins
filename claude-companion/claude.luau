-- /claude — the hands: launch Claude Code, or a quick one-shot ask.
--   /claude <task>   → real Claude Code TUI in the terminal (full fidelity)
--   /claude          → resume last session (claude --continue)
--   /claude ? <q>    → one-shot read-only ask, streamed; answer in the answer panel
--
-- Holds the BACKEND CHOKEPOINT (invoke + parse). v5 plugins load each entry as a
-- single chunk (no module system), and this launcher is the only entry that talks to a model,
-- so the seam lives here, inlined.

-- noctalia.runInTerminal / runStream both exec via `/bin/sh -c <string>`, so every
-- interpolated value must be shell-quoted. Single-quote wrap + escape embedded
-- single quotes ('\'') is sh-safe for arbitrary text.
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- User-facing display strings live in translations/<lang>.json; resolve them at
-- call time (the noctalia global is ready by then). Model-facing prompts
-- (ASK_NOTE, SYSTEM_NOTE below) are deliberately NOT translated — they are
-- instructions to the model, not UI, and rewording them can shift its behavior.
local function tr(key, args) return noctalia.tr(key, args) end

-- A double-quoted sh argument: unlike shq it lets the shell expand $VAR (we need
-- $HOME in the shim path so nothing user-specific is hardcoded). ONLY use this on
-- fixed, trusted strings — never on user input, which must go through shq().
local function dq(s) return '"' .. tostring(s):gsub('"', '\\"') .. '"' end

-- ── backend seam: normalize at the boundary ──────────────────────────────────
-- Everything downstream consumes this vocabulary, never raw backend output.
local EVENT = {
  turn_start = "turn_start", text = "text", tool_start = "tool_start",
  tool_end = "tool_end", needs_attention = "needs_attention",
  turn_end = "turn_end", error = "error",
}

-- noctalia launches us with the GUI-session PATH, which lacks ~/.local/bin (it's
-- added by the user's shell profile, not the graphical session). Claude Code's
-- session hooks commonly call tools installed there, so a /claude session would
-- hit "command not found" that a terminal-started one never does. Prepend it to
-- every launch so a /claude session inherits the same PATH as a terminal. Fixed,
-- trusted literal — $HOME/$PATH are meant to expand in the `/bin/sh -c` context.
local PATH_PREFIX = 'PATH="$HOME/.local/bin:$PATH" '

-- A quick-ask answer opens in a small desktop panel, so steer the model toward
-- short answers at the source. Long answers still arrive intact: the panel scrolls.
local ASK_NOTE = table.concat({
  "Your answer is shown in a small desktop panel. Lead with the direct answer",
  "in one or two short sentences; add detail only if the question genuinely needs it.",
  "Plain text only — no markdown formatting.",
}, " ")

-- claude only; this is the single backend seam.
-- A quick-ask is promised as read-only (README "Use"), so it must NOT inherit
-- the user's Claude config, where pre-authorized permissions would let a plain
-- question run commands or edit files: --tools "" strips every built-in tool,
-- --strict-mcp-config (with no --mcp-config) strips inherited MCP servers, and
-- --setting-sources "" skips user/project settings and with them hooks, plugins,
-- and permission grants. NOT --bare: it never reads OAuth logins, which are the
-- auth path quick-ask depends on (see the auth guard below).
local function backend_command(prompt)
  -- Claude Code: -p (print/non-interactive) requires --verbose for stream-json.
  -- `-p --` before the prompt is load-bearing: without the `--` end-of-options
  -- marker, a question whose first token starts with `-` (e.g. pasted text
  -- leading with `--dangerously-skip-permissions`) is parsed as CLI flags and
  -- can undo the read-only sandbox above. `--` forces the prompt to be a
  -- positional (verified: a prompt of "--version" is answered, not executed).
  return PATH_PREFIX .. "claude --tools '' --strict-mcp-config --setting-sources ''"
      .. " --output-format stream-json --verbose"
      .. " --append-system-prompt " .. shq(ASK_NOTE) .. " -p -- " .. shq(prompt)
end

-- one stream-json line → an EVENT (or nil). Claude Code emits one JSON object per
-- line: type "system" (init), "assistant" (a message; content is an array of
-- text / tool_use blocks), "user" (tool_result), "result" (final). We map the
-- subset we care about and ignore the rest (version-defensive).
-- Note: the content-block shape can shift across claude versions — if events
-- stop firing, re-dump a live stream and re-check the field names here.
local function parse(line)
  local ok, msg = pcall(noctalia.json.decode, line)
  if not ok or type(msg) ~= "table" then return nil end
  local t = msg.type
  if t == "system" then
    return { kind = EVENT.turn_start }
  elseif t == "assistant" then
    local content = type(msg.message) == "table" and msg.message.content or msg.content
    local text = ""
    if type(content) == "table" then
      for _, block in ipairs(content) do
        if type(block) == "table" then
          if block.type == "tool_use" then
            return { kind = EVENT.tool_start }
          elseif block.type == "text" and type(block.text) == "string" then
            text = text .. block.text
          end
        end
      end
    end
    return { kind = EVENT.text, text = text }
  elseif t == "user" then
    -- a tool result came back; the model is thinking again (clears tool_start)
    return { kind = EVENT.turn_start }
  elseif t == "result" then
    local err = msg.is_error == true or msg.subtype == "error_during_execution"
    return { kind = err and EVENT.error or EVENT.turn_end, text = msg.result }
  end
  return nil
end

-- publish quick-ask state for the pulse widget (cross-VM channel via shared
-- state). Only the hookless `/claude ? <q>` stream uses this; the widget tracks it as
-- one ephemeral "ask" session and drops it when the ask ends.
local function set_state(s) noctalia.state.set("claude.state", s) end

-- ── answer delivery ──────────────────────────────────────────────────────────
-- Every quick-ask outcome (answer, error, remedy) is published to "claude.answer"
-- and the answer panel (answer.luau) opens on it, wrapped and scrollable. No toast:
-- one surface per answer. panel-open, not -toggle, so an already-open panel stays
-- open and live-refreshes. Reopen later from the "Show last answer" row or the CLI.
local ANSWER_PANEL = "lowcache/claude-companion:answer"

local function deliver(q, text, is_err)
  noctalia.state.set("claude.answer", {
    q = q,
    text = text,
    error = is_err == true,
    at = noctalia.formatTime("%H:%M"),
  })
  noctalia.runAsync("noctalia msg panel-open " .. shq(ANSWER_PANEL))
end

-- ── auth guard ───────────────────────────────────────────────────────────────
-- Headless `claude -p` does NOT refresh an expired OAuth access token (8 h
-- lifetime) even when the refresh token is valid — only an interactive session
-- does (upstream: anthropics/claude-code#53063 and friends). So a quick-ask can
-- 401 whenever no terminal session has run recently. Two layers, both fail-open:
-- a pre-flight that skips the launch when the token is positively expired, and
-- an error-text match that swaps the raw API error for the remedy.
-- Resolved per call, not once at load: a language change should be reflected in the
-- remedy text without a plugin reload.
local function auth_remedy() return tr("notify.auth_remedy") end

local CREDS_PATH = "~/.claude/.credentials.json"

-- true ONLY when the credentials file positively says the token is expired.
-- Missing file, undecodable JSON, absent expiresAt, or no epoch clock all mean
-- "unknown" → proceed and let the error match below catch a real failure. The
-- token itself is never read, only the expiry timestamp.
-- Note: %s is a glibc strftime extension; if noctalia's formatTime doesn't
-- pass it through, tonumber yields nil and the pre-flight silently disables —
-- the detect layer still covers.
local function token_expired()
  local now = tonumber(noctalia.formatTime("%s"))
  if not now then return false end
  local raw = noctalia.readFile(noctalia.expandPath(CREDS_PATH))
  if type(raw) ~= "string" then return false end
  local ok, creds = pcall(noctalia.json.decode, raw)
  if not ok or type(creds) ~= "table" then return false end
  local oauth = creds.claudeAiOauth
  local exp = type(oauth) == "table" and tonumber(oauth.expiresAt) or nil
  if not exp then return false end
  if exp > 1e12 then exp = exp / 1000 end -- stored in ms; tolerate seconds too
  return exp <= now + 30 -- 30 s margin: don't start an ask about to 401 mid-flight
end

-- Recognize the auth-failure shapes claude -p emits in its result line:
-- "Not logged in · Please run /login" (no credentials) and "Failed to
-- authenticate. API Error: 401 {...authentication_error...}" (expired token).
local function is_auth_error(text)
  return text:find("Please run /login", 1, true) ~= nil
      or text:find("API Error: 401", 1, true) ~= nil
      or text:find("authentication_error", 1, true) ~= nil
end

-- ── context injection ────────────────────────────────────────────────────────
-- Make /claude-launched sessions desktop-AWARE (senses) and desktop-CAPABLE (hands)
-- by wiring the noctalia MCP shim and a role note into the launch.
--
-- We pass the shim via inline --mcp-config (not a file) so the terminal's cwd is
-- irrelevant: /claude opens in the user's project dir, not the plugin dir. We push a
-- role note, NOT a senses snapshot — a snapshot taken at launch is stale before
-- the first turn; instead Claude pulls fresh senses on demand via the tools.
-- The shim path comes from the host (a catalog install lives under
-- ~/.local/state/.../materialized, not the dev symlink path). It lands inside JSON
-- inside dq(), so a dir with a quote, backslash, $ or backtick falls back to the
-- dev path, which keeps $HOME bare for the shell to expand.
local function shim_path()
  local dir = noctalia.pluginDir and noctalia.pluginDir()
  if type(dir) ~= "string" or dir == "" or dir:find("[\"\\$`]") then
    dir = "$HOME/.local/share/noctalia/plugins/claude-companion"
  end
  return dir .. "/shim/noctalia-mcp.py"
end
local SHIM = shim_path()
local MCP_JSON = '{"mcpServers":{"noctalia":{"command":"python3","args":["' .. SHIM .. '"]}}}'

local SYSTEM_NOTE = table.concat({
  "You are running inside the Noctalia desktop shell (Wayland — niri, Hyprland, or Sway), launched from its Claude Code companion plugin.",
  "An MCP server named 'noctalia' gives you live desktop senses and hands:",
  "PERCEIVE — get_window (focused app/title), get_workspace (focused output + workspace), get_media (now playing), get_shell_state (shell status), get_power (battery/AC), get_network (connectivity/Wi-Fi), get_processes (top by CPU).",
  "ACT — notify (desktop toast), set_theme_mode (dark/light/auto), set_color_scheme, focus_window (by the id from get_window), switch_workspace (by index/name), move_to_workspace (move focused window), set_wallpaper (path or random).",
  "Call the perceive tools when current desktop context matters instead of assuming it, and use notify for ambient status updates.",
}, " ")

-- Flags shared by every interactive launch (task + continue). Built once.
local CONTEXT_FLAGS =
  "--mcp-config " .. dq(MCP_JSON) .. " --append-system-prompt " .. shq(SYSTEM_NOTE)

-- ── /claude routing ──────────────────────────────────────────────────────────────
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- The last quick-ask answer, if any, earns a launcher row that reopens the
-- answer panel after it has been dismissed.
local function answer_row()
  local a = noctalia.state.get("claude.answer")
  if type(a) ~= "table" or type(a.text) ~= "string" or a.text == "" then return nil end
  return { id = "answer", title = tr("launcher.show_answer"), subtitle = a.q, glyph = "message-2" }
end

function onQuery(query)
  local text = trim(query)
  if text == "" then
    local results = {
      { id = "continue", title = tr("launcher.continue"), glyph = "robot" },
    }
    results[#results + 1] = answer_row()
    launcher.setResults(query, results)
    return
  end
  local ask = text:match("^%?%s*(.*)$")
  if ask ~= nil then
    if ask == "" then
      local results = {
        { id = "_askhint", title = tr("launcher.ask"), subtitle = tr("launcher.ask_hint"), glyph = "message-dots" },
      }
      results[#results + 1] = answer_row()
      launcher.setResults(query, results)
    else
      launcher.setResults(query, {
        { id = "ask:" .. ask, title = tr("launcher.ask"), subtitle = ask, glyph = "message-dots" },
      })
    end
    return
  end
  launcher.setResults(query, {
    { id = "task:" .. text, title = tr("launcher.launch"), subtitle = text, glyph = "robot" },
  })
end


-- The quick-ask, extracted so the launcher and the ask panel share ONE path.
-- v5 has no plugin module system, so a second caller would otherwise mean a second
-- copy of the read-only backend flags in backend_command() -- and a copy that
-- drifted would silently hand a "question" the tools it is promised not to have.
local function run_ask(ask)
  -- pre-flight: an expired token would 401 only after burning the request,
  -- and the remedy needs a terminal anyway — so say so now and skip the
  -- launch. No claude.state touch: no ask session ever starts.
  if token_expired() then
    deliver(ask, auth_remedy(), true)
    return
  end
  set_state(EVENT.turn_start)
  -- Accumulate streamed assistant text; the final `result` event also carries
  -- the full text, so prefer it at turn_end and fall back to the accumulation.
  local acc = ""
  noctalia.runStream(backend_command(ask), function(line)
    local ev = parse(line)
    if not ev then return end
    set_state(ev.kind)
    if ev.kind == EVENT.text and ev.text and ev.text ~= "" then
      acc = acc .. ev.text
    elseif ev.kind == EVENT.turn_end then
      local final = (ev.text and ev.text ~= "") and ev.text or acc
      if final == "" then
        deliver(ask, tr("notify.no_output"), true)
      else
        deliver(ask, final, false)
      end
    elseif ev.kind == EVENT.error then
      local final = (ev.text and ev.text ~= "") and ev.text or acc
      if final == "" then final = tr("notify.ask_failed") end
      -- a 401 that slipped past the pre-flight: deliver the remedy, not the
      -- raw API error blob
      if is_auth_error(final) then final = auth_remedy() end
      deliver(ask, final, true)
    end
  end)
end

function onActivate(id)
  -- A launched TUI session drives the pulse itself via the global Claude Code
  -- hooks (with its own session id + token telemetry), so we DON'T set claude.state
  -- here — doing so would register a phantom session the hooks never update or
  -- retire. claude.state is only for the hookless quick-ask stream below.
  if id == "continue" then
    noctalia.runInTerminal(PATH_PREFIX .. "claude " .. CONTEXT_FLAGS .. " --continue")
    return
  end
  if id == "answer" then
    -- reopen the answer panel with the last quick-ask answer (fixed id, no user input)
    noctalia.runAsync("noctalia msg panel-open " .. shq(ANSWER_PANEL))
    return
  end
  local task = id:match("^task:(.*)$")
  if task then
    noctalia.runInTerminal(PATH_PREFIX .. "claude " .. CONTEXT_FLAGS .. " " .. shq(task))
    return
  end
  local ask = id:match("^ask:(.*)$")
  if ask then
    run_ask(ask)
    return
  end
  -- "_askhint" and any other ids: no-op.
end

-- ── ask over IPC (the bar-widget entry point) ────────────────────────────────
-- The ask panel (ask.luau, opened by a left-click on the bar pulse) cannot call
-- run_ask directly: v5 has no plugin module system and entries share no state. So it
-- hands the question over the same way presence and the consent request do — the text
-- goes to a file, and a bare poke arrives here — because an IPC payload is a single
-- space-free token (PROTOCOL.md "Transport") and a question is neither.
--
-- This keeps claude.luau the one door: the panel owns no backend flags, so the
-- read-only sandbox in backend_command() cannot drift between two callers.
local function ask_question_path()
  local dir = noctalia.getenv and noctalia.getenv("XDG_RUNTIME_DIR")
  if type(dir) ~= "string" or dir == "" then return nil end
  return dir .. "/claude-companion/ask"
end

function onIpc(event, _payload)
  if event ~= "ask" then return end
  local path = ask_question_path()
  if not path then return end
  local q = noctalia.readFile(path)
  if type(q) ~= "string" then return end
  -- Consume it before dispatching: left in place, a duplicate poke or a second Enter
  -- re-runs the same question -- another billed request, claude.answer overwritten.
  noctalia.runAsync("rm -f " .. shq(path))
  q = trim(q)
  if q == "" then return end
  run_ask(q)
end
