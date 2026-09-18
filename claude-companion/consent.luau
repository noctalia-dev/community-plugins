-- The consent panel — the desktop half of the tool-approval gate.
--
-- hooks/consent.py blocks a Claude Code PreToolUse call and writes a request into
-- $XDG_RUNTIME_DIR/claude-companion/consent/<id>.req, then dispatches consent_request
-- into pulse-svc, which opens this panel with the id as its context. Answering writes
-- the matching .res; the hook wakes, hands Claude the verdict, and the tool proceeds
-- or does not. No answer before the hook's own deadline and Claude Code asks in the
-- terminal exactly as it always did.
--
-- Pure renderer, same doctrine as the orb, the answer panel and the sessions panel.
-- It holds no policy: it does not decide what is dangerous, does not classify a
-- command, and never writes the allowlist directly. Every mutation goes back through
-- the one door (`consent.py reply`), which is also where the request nonce stays —
-- so the only untrusted thing this file puts on a command line is an id the hook
-- already sanitised to [A-Za-z0-9_-].

local SELF = "lowcache/claude-companion:consent"
local HOOK = "$HOME/.local/share/noctalia/plugins/claude-companion/hooks/consent.py"
local KEY = "claude.consent"
local KEY_PULSE = "claude.pulse"

local function tr(key, args) return noctalia.tr(key, args) end

-- Panel surface is 480 logical px (plugin.toml); leave room for the scrollbar.
local WRAP = 424
local PAD = 14

local ERROR_RGB = "#FF4D1F"

local current = nil -- request id this panel is currently showing
local answered = {} -- ids already replied to, while their request file is cleaned up
local render        -- forward declaration: answer() advances to the next prompt

local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Double-quoted so $HOME still expands, unlike shq. Fixed trusted strings only.
local function dq(s) return '"' .. tostring(s):gsub('"', '\\"') .. '"' end

-- No guessed fallback: without XDG_RUNTIME_DIR there is no request to read, and a
-- guessed uid path would read some other user's directory. Same stance as the hook.
local function runtime_dir()
  local v = noctalia.getenv and noctalia.getenv("XDG_RUNTIME_DIR")
  if type(v) == "string" and v ~= "" then return v .. "/claude-companion" end
  return nil
end

-- The id reaches a shell command, so it is allowlisted rather than quoted — same
-- discipline as the sessions panel's retire control and the shim's injection review.
local function safe_id(id)
  return type(id) == "string" and id ~= "" and id:match("^[%w_%-]+$") ~= nil
end

local function request_path(id)
  local dir = runtime_dir()
  return dir and (dir .. "/consent/" .. id .. ".req") or nil
end

local function read_request(id)
  if not safe_id(id) then return nil end
  local path = request_path(id)
  if not path then return nil end
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

-- The service queues every outstanding request. An id whose request file is gone was
-- answered or timed out; `answered` covers the gap between our reply and the hook
-- removing the file, so a just-answered prompt is never offered again.
-- The learn log lives beside the allowlist in durable state, mirroring _state_dir()
-- in hooks/consent.py. Counting lines is enough for the prompt; the hook does the
-- real de-duplication when it folds them in.
local function state_dir()
  local v = noctalia.getenv and noctalia.getenv("XDG_STATE_HOME")
  if type(v) == "string" and v ~= "" then return v .. "/noctalia/claude-companion" end
  local home = noctalia.getenv and noctalia.getenv("HOME")
  if type(home) == "string" and home ~= "" then
    return home .. "/.local/state/noctalia/claude-companion"
  end
  return nil
end

local function observation_count()
  local dir = state_dir()
  if not dir then return 0 end
  local raw = noctalia.readFile(dir .. "/learn.jsonl")
  if type(raw) ~= "string" or raw == "" then return 0 end
  local n = 0
  for _ in raw:gmatch("[^\n]+") do n = n + 1 end
  return n
end

-- maxLines clips host-side with nothing to show for it, so clip here and say so:
-- an approval dialog must never hide part of what it is approving.
local function clip(text, max_lines, max_chars)
  local s = tostring(text or "")
  local out, n = {}, 0
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if n > max_lines then return table.concat(out, "\n"), true end
    out[#out + 1] = line
  end
  local joined = table.concat(out, "\n")
  if #joined > max_chars then return string.sub(joined, 1, max_chars), true end
  return joined, false
end

local function add_clipped(rows, text, max_lines, max_chars, props)
  local shown, clipped = clip(text, max_lines, max_chars)
  local label = { text = shown, maxWidth = WRAP }
  for k, v in pairs(props or {}) do label[k] = v end
  rows[#rows + 1] = ui.label(label)
  if clipped then
    rows[#rows + 1] = ui.label({ text = tr("consent.truncated"), maxWidth = WRAP, opacity = 0.7 })
  end
end

local function next_pending()
  local snap = noctalia.state.get and noctalia.state.get(KEY)
  if type(snap) ~= "table" then return nil, nil end
  local ids = type(snap.ids) == "table" and snap.ids or { snap.id }
  for _, id in ipairs(ids) do
    if safe_id(id) and not answered[id] then
      local req = read_request(id)
      if req then return id, req end
    end
  end
  return nil, nil
end

-- Answer, then move on. Claude issues tool calls in parallel, so a batch of prompts is
-- ordinary: closing on the first answer would leave the rest with no surface, stalled
-- until their deadlines. Close only once nothing is left.
local function answer(id, choice)
  if not safe_id(id) then return end
  noctalia.runAsync("python3 " .. dq(HOOK) .. " reply " .. shq(id) .. " " .. choice)
  answered[id] = true
  current = nil
  local nid, nreq = next_pending()
  if nid then
    current = nid
    render(nid, nreq)
    return
  end
  noctalia.runAsync("noctalia msg panel-close " .. shq(SELF))
end

function render(id, req)
  local rows = {}

  if not req then
    -- Either nothing is pending or the request expired while the panel was opening.
    -- Say so plainly: a consent panel showing a stale command is worse than an empty one.
    rows[#rows + 1] = ui.label({ text = tr("consent.title"), fontWeight = "bold" })
    rows[#rows + 1] = ui.separator({})
    rows[#rows + 1] = ui.label({ text = tr("consent.empty"), maxWidth = WRAP, opacity = 0.7 })

    -- `promote` is otherwise CLI-only, so someone who flips consent_mode from learn to
    -- enforce in the settings skips the step that makes enforce quiet. Offer it where
    -- they are already looking, and only when there is something to fold in.
    local waiting = observation_count()
    if waiting > 0 then
      rows[#rows + 1] = ui.separator({})
      rows[#rows + 1] = ui.label({
        text = tr("consent.promote_hint", { count = tostring(waiting) }),
        maxWidth = WRAP, opacity = 0.7,
      })
      rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.button({
          text = tr("consent.promote"),
          variant = "secondary",
          onClick = function()
            noctalia.runAsync("python3 " .. dq(HOOK) .. " promote")
          end,
        }),
      })
    end

    panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1 }, rows))
    return
  end

  rows[#rows + 1] = ui.label({
    text = tr("consent.title_tool", { tool = tostring(req.tool or "?") }),
    fontWeight = "bold",
  })

  -- The thing being authorised comes FIRST. `description` and the presence line below
  -- are both written by the model whose action this approves; letting either caption
  -- the command from above turns a reassuring sentence into the headline of a security
  -- decision. For a path tool the subject is the path, and the content follows it.
  rows[#rows + 1] = ui.separator({})
  local subject = req.command
  if type(subject) ~= "string" or subject == "" then subject = req.path end
  if type(subject) == "string" and subject ~= "" then
    add_clipped(rows, subject, 8, 480, {})
  end

  -- A path without its content is not informed consent: approving "Write ~/.bashrc"
  -- would otherwise authorise bytes the user never saw.
  local content = type(req.content) == "string" and req.content or ""
  if content ~= "" then
    add_clipped(rows, content, 12, 900, { opacity = 0.9 })
  end

  rows[#rows + 1] = ui.separator({})

  -- Claude's own one-line description of what the command is for.
  local desc = type(req.description) == "string" and req.description or ""
  if desc ~= "" then
    rows[#rows + 1] = ui.label({ text = desc, maxWidth = WRAP, maxLines = 3 })
  end

  -- The presence line (shim set_presence) says what Claude is TRYING to do. It carries
  -- no session id, so it is only unambiguous while a single session is running -- with
  -- several it could be describing any of them, including one that already ended.
  local snap = noctalia.state.get and noctalia.state.get(KEY_PULSE)
  local said = ""
  if type(snap) == "table" and type(snap.message) == "string" then
    if (tonumber(snap.count) or 0) <= 1 then said = snap.message end
  end
  if said ~= "" then
    rows[#rows + 1] = ui.label({
      text = tr("consent.said", { said = said }),
      maxWidth = WRAP, maxLines = 3, opacity = 0.85,
    })
  end

  local meta = {}
  if type(req.cwd) == "string" and req.cwd ~= "" then
    meta[#meta + 1] = tr("consent.in_dir", { dir = req.cwd })
  end
  if type(req.session) == "string" and req.session ~= "" then
    meta[#meta + 1] = tr("consent.session", { sid = req.session })
  end
  if #meta > 0 then
    rows[#rows + 1] = ui.label({
      text = table.concat(meta, " · "), maxWidth = WRAP, maxLines = 2, opacity = 0.7,
    })
  end

  rows[#rows + 1] = ui.separator({})
  rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.button({
      text = tr("consent.allow_once"),
      variant = "primary",
      onClick = function() answer(id, "allow") end,
    }),
    ui.button({
      text = tr("consent.allow_always"),
      variant = "secondary",
      onClick = function() answer(id, "always") end,
    }),
    ui.button({
      text = tr("consent.deny"),
      variant = "secondary",
      color = ERROR_RGB,
      onClick = function() answer(id, "deny") end,
    }),
  })

  -- Timing out is a real outcome and the panel says so, so an unanswered prompt does
  -- not read as the plugin having swallowed the tool call.
  rows[#rows + 1] = ui.label({ text = tr("consent.fallthrough"), maxWidth = WRAP, opacity = 0.55 })

  -- Deliberately UNFILLED, same as answer.luau and sessions.luau: the host insets a
  -- decorated panel, so any fill on the root leaves the panel colour as a rim.
  panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1 }, rows))
end

-- Context is the request id the service passed to `noctalia msg panel-open`. Opened by
-- hand with no context, fall back to whatever the service says is outstanding, so
-- `panel-toggle …:consent` still shows a pending prompt.
function onOpen(context)
  panel.setWantsSecondTicks(true) -- host stops ticks on close, re-arms on reopen
  answered = {}
  local id, req = nil, nil
  if safe_id(context) then
    req = read_request(context)
    if req then id = context end
  end
  if not req then id, req = next_pending() end
  current = id
  render(id, req)
end

-- Esc and click-outside are this plugin's dismiss idiom, but a dismissed prompt used
-- to leave the hook polling for its full 110s with the tool call still blocked. Say
-- "not here" instead: the hook falls straight through to Claude Code's own prompt.
-- answer() clears `current` before its panel-close lands, so a click never lands here.
function onClose()
  -- Everything still outstanding loses its surface when the panel goes, so answer
  -- "not here" for all of it rather than leaving those calls to time out.
  while true do
    local id = next_pending()
    if not id then break end
    noctalia.runAsync("python3 " .. dq(HOOK) .. " reply " .. shq(id) .. " dismiss")
    answered[id] = true
  end
  current = nil
end

-- Re-poll only while a request is showing: if the hook hit its deadline and cleaned
-- up, the request file vanishes and the panel drops to its empty state rather than
-- offering buttons that would answer nothing.
function update()
  if current and read_request(current) then return end
  local id, req = next_pending()
  if id == current then return end -- both nil: nothing pending, nothing to repaint
  current = id
  render(id, req)
end
