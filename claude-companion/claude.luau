-- /claude — the hands: launch Claude Code, or a quick one-shot ask.
--   /claude <task>   → real Claude Code TUI in the terminal (full fidelity)
--   /claude          → resume last session (claude --continue)
--   /claude ? <q>    → one-shot read-only ask, streamed; answer via notify
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
-- own session hooks live there (memd, agent-scaffold, …), so a /claude session would
-- hit "command not found" that a terminal-started one never does. Prepend it to
-- every launch so a /claude session inherits the same PATH as a terminal. Fixed,
-- trusted literal — $HOME/$PATH are meant to expand in the `/bin/sh -c` context.
local PATH_PREFIX = 'PATH="$HOME/.local/bin:$PATH" '

-- A quick-ask answer is delivered as a desktop toast first, and toasts clip
-- after a couple of lines with no scroll — so steer the model toward toast-sized
-- answers at the source. Long answers still arrive intact: the full text goes to
-- the answer panel (see publish_answer below), the toast just leads with less.
local ASK_NOTE = table.concat({
  "Your answer is delivered as a desktop notification. Lead with the direct answer",
  "in one or two short sentences; add detail only if the question genuinely needs it.",
  "Plain text only — no markdown formatting.",
}, " ")

-- claude only; this is the single backend seam.
-- A quick-ask is promised as read-only (README "Usage"), so it must NOT inherit
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
-- A toast clips long bodies with no scroll, so it is the preview surface only:
-- the complete answer is published to "claude.answer" and rendered wrapped +
-- scrollable by the answer panel (answer.luau). The panel opens from a click on
-- the bar pulse, the "Show last answer" launcher row, or the CLI.
local ANSWER_PANEL = "lowcache/claude-companion:answer"

local function publish_answer(q, text, is_err)
  noctalia.state.set("claude.answer", {
    q = q,
    text = text,
    error = is_err == true,
    at = noctalia.formatTime("%H:%M"),
  })
end

-- Fit the toast: collapse whitespace and cut at a word boundary. Returns the
-- preview and whether anything was dropped (→ the toast gains a pointer to the
-- full answer).
local PREVIEW_MAX = 200
local function preview(text)
  local flat = text:gsub("%s+", " ")
  if #flat <= PREVIEW_MAX then return flat, false end
  local cut = flat:sub(1, PREVIEW_MAX):match("^(.*)%s%S*$") or flat:sub(1, PREVIEW_MAX)
  return cut .. " …", true
end

-- ONE surface per answer: while the answer panel is open (it sets this flag) it
-- live-refreshes from claude.answer, so it IS the delivery — a toast on top would
-- duplicate it, and dismissing that toast clicks outside the panel, which the
-- click-shield turns into closing the panel as well (verified live: toast +
-- panel died to one click). Panel open → publish only; panel closed → toast.
local function panel_showing()
  return noctalia.state.get("claude.answer.open") == true
end

-- ── auth guard ───────────────────────────────────────────────────────────────
-- Headless `claude -p` does NOT refresh an expired OAuth access token (8 h
-- lifetime) even when the refresh token is valid — only an interactive session
-- does (upstream: anthropics/claude-code#53063 and friends). So a quick-ask can
-- 401 whenever no terminal session has run recently. Two layers, both fail-open:
-- a pre-flight that skips the launch when the token is positively expired, and
-- an error-text match that swaps the raw API error for the remedy.
-- (remedy text: tr("notify.auth_remedy"))

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
-- The shim is assumed at the canonical install path
-- ($HOME/.local/share/noctalia/plugins/<id>). $HOME stays bare for the shell to
-- expand (portable; nothing user-specific is committed). The JSON is fixed and
-- trusted (no user input), so dq() is injection-safe here.
local SHIM = "$HOME/.local/share/noctalia/plugins/claude-companion/shim/noctalia-mcp.py"
local MCP_JSON = '{"mcpServers":{"noctalia":{"command":"python3","args":["' .. SHIM .. '"]}}}'

local SYSTEM_NOTE = table.concat({
  "You are running inside the Noctalia desktop shell (Wayland — niri, Hyprland, or Sway), launched from its Claude Code companion plugin.",
  "An MCP server named 'noctalia' gives you live desktop senses and hands:",
  "PERCEIVE — get_window (focused app/title), get_workspace (focused output + workspace), get_media (now playing), get_shell_state (shell status), get_power (battery/AC), get_network (connectivity/Wi-Fi), get_processes (top by CPU).",
  "ACT — notify (desktop toast), set_theme_mode (dark/light/auto), set_color_scheme, focus_window (by the id from get_window), switch_workspace (by index/name), move_to_workspace (move focused window), set_wallpaper (path or random).",
  "MEMORY — remember (persist a durable fact for future sessions).",
  "Call the perceive tools when current desktop context matters instead of assuming it, and use notify for ambient status updates.",
}, " ")

-- Flags shared by every interactive launch (task + continue). Built once.
local CONTEXT_FLAGS =
  "--mcp-config " .. dq(MCP_JSON) .. " --append-system-prompt " .. shq(SYSTEM_NOTE)

-- ── /claude routing ──────────────────────────────────────────────────────────────
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- The last quick-ask answer, if any, earns a launcher row that reopens the
-- answer panel — the recovery path when the toast has already expired.
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
    -- pre-flight: an expired token would 401 only after burning the request,
    -- and the remedy needs a terminal anyway — so say so now and skip the
    -- launch. No claude.state touch: no ask session ever starts.
    if token_expired() then
      local remedy = tr("notify.auth_remedy")
      publish_answer(ask, remedy, true)
      if not panel_showing() then noctalia.notifyError(tr("notify.title"), remedy) end
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
          noctalia.notify(tr("notify.title"), tr("notify.no_output"))
        else
          publish_answer(ask, final, false)
          if not panel_showing() then
            local body, clipped = preview(final)
            if clipped then body = body .. "\n" .. tr("notify.full_answer_hint") end
            noctalia.notify(tr("notify.title"), body)
          end
        end
      elseif ev.kind == EVENT.error then
        local final = (ev.text and ev.text ~= "") and ev.text or acc
        if final == "" then final = tr("notify.ask_failed") end
        -- a 401 that slipped past the pre-flight: deliver the remedy, not the
        -- raw API error blob
        if is_auth_error(final) then final = tr("notify.auth_remedy") end
        publish_answer(ask, final, true)
        if not panel_showing() then
          local body, clipped = preview(final)
          if clipped then body = body .. "\n" .. tr("notify.full_answer_hint") end
          noctalia.notifyError(tr("notify.title"), body)
        end
      end
    end)
    return
  end
  -- "_askhint" and any other ids: no-op.
end
