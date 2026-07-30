-- The sessions panel — per-session detail and actuation for every live Claude
-- session. Right-click the bar pulse to open it (onClick keeps the answer panel).
--
-- The bar tooltip already lists concurrent sessions, but a tooltip cannot be acted
-- on: it vanishes on the way to it. This panel is the actionable form of the same
-- rollup — one row per session with its state, model and token burn, plus a retire
-- control for the one documented failure mode: a session that ended without its
-- SessionEnd hook firing (terminal killed, hook interrupted mid-distill) sits at
-- idle forever and keeps inflating the count. Retiring it is a local correction
-- that needs no terminal.
--
-- Pure subscriber, same doctrine as the orb and the answer panel: pulse-svc owns the
-- session table, this panel only renders it and speaks the documented IPC vocabulary
-- back. It adds NO new protocol — a retire is the ordinary `session_end` event with
-- a session-tagged payload, exactly what hooks/pulse.py sends (see PROTOCOL.md).

local KEY = "claude.pulse"
local SVC = "lowcache/claude-companion:pulse-svc"

local function tr(key, args) return noctalia.tr(key, args) end

-- Panel surface is 440 logical px (plugin.toml); leave room for the scrollbar.
local WRAP = 388
local PAD = 14

local ERROR_RGB = "#FF4D1F"

-- Compact per-session words, same vocabulary as the bar tooltip.
local STATE_WORD = {
  idle = "state.word.idle", turn_start = "state.word.turn_start", text = "state.word.text",
  tool_start = "state.word.tool_start", needs_attention = "state.word.needs_attention",
  turn_end = "state.word.turn_end", error = "state.word.error",
}

local last = nil -- fingerprint of the last render (an unconditional one would reset scroll)

local function kfmt(n)
  n = tonumber(n) or 0
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(n)
end

-- A session id reaches a shell command below, so it is allowlisted first. Session
-- ids come from our own service, but the shim's injection review (a caller-supplied
-- id concatenated into a command language) is the same shape of risk, so the same
-- discipline applies here: anything outside [A-Za-z0-9._-] is refused rather than
-- quoted, and a refused row simply renders without its retire control.
local function safe_sid(sid)
  return type(sid) == "string" and sid ~= "" and sid:match("^[%w%._%-]+$") ~= nil
end

-- Retire one session by speaking the ordinary protocol: session_end carrying a
-- payload whose only populated field is the trailing session id. parse_payload in
-- pulse-svc reads field 6, so ",,,,,<sid>" is a well-formed session-tagged event
-- with no telemetry — no new IPC verb, no service change.
local function retire(sid)
  if not safe_sid(sid) then return end
  noctalia.runAsync("noctalia msg plugin '" .. SVC .. "' all session_end ',,,,," .. sid .. "'")
end

local function session_row(s)
  local word = STATE_WORD[s.state] and tr(STATE_WORD[s.state]) or tostring(s.state)
  local line = tostring(s.sid) .. " · " .. word
  if s.model and s.model ~= "?" and ((s.tin or 0) + (s.tout or 0)) > 0 then
    line = line .. " · " .. s.model .. " " .. kfmt(s.tin) .. "/" .. kfmt(s.tout)
  end
  if (s.cr or 0) > 0 then
    line = line .. " · " .. tr("pulse.cached", { n = kfmt(s.cr) })
  end

  local cells = {
    ui.label({
      text = line,
      maxWidth = WRAP - 92,
      maxLines = 2,
      color = s.state == "error" and ERROR_RGB or nil,
      flexGrow = 1,
    }),
  }
  -- The retire control is omitted rather than disabled for a non-conforming id:
  -- a button that cannot act is worse than no button.
  if safe_sid(s.sid) then
    local sid = s.sid -- captured per row; the handler table is rebuilt each render
    cells[#cells + 1] = ui.button({
      text = tr("sessions.retire"),
      variant = "secondary",
      onClick = function() retire(sid) end,
    })
  end
  return ui.row({ gap = 8, align = "center" }, cells)
end

local function render(snap)
  local list = (type(snap) == "table" and type(snap.sessions) == "table") and snap.sessions or {}
  local count = #list

  -- Separate singular/plural keys rather than a "1 sessions" fudge: the count is
  -- prominent in the header, so the disagreement reads as a bug.
  local title = count == 1 and tr("sessions.title_one") or tr("sessions.title", { count = count })
  local rows = { ui.label({ text = title, fontWeight = "bold" }) }

  local body
  if count == 0 then
    body = ui.column({ gap = 6 }, {
      ui.label({ text = tr("sessions.empty"), maxWidth = WRAP, opacity = 0.7 }),
    })
  else
    local items = {}
    local Tin, Tout = 0, 0
    for i, s in ipairs(list) do
      if i > 1 then items[#items + 1] = ui.separator({}) end
      items[#items + 1] = session_row(s)
      Tin = Tin + (tonumber(s.tin) or 0)
      Tout = Tout + (tonumber(s.tout) or 0)
    end
    if (Tin + Tout) > 0 then
      items[#items + 1] = ui.separator({})
      items[#items + 1] = ui.label({
        text = tr("pulse.total", { tin = kfmt(Tin), tout = kfmt(Tout) }),
        opacity = 0.7,
      })
    end
    body = ui.column({ gap = 6 }, items)
  end

  rows[#rows + 1] = ui.separator({})
  rows[#rows + 1] = ui.scroll({ flexGrow = 1 }, { body })
  -- flexGrow on the root column is load-bearing for the same reason as the answer
  -- panel: without it the column takes its full-content height and the panel clips
  -- instead of the scroll child being bounded.
  --
  -- Deliberately UNFILLED, same as answer.luau. A decorated panel is inset by the
  -- host (panel_manager.cpp: `hasDecoration ? contentScale * Style::panelPadding`),
  -- and no [[panel]] manifest key opts out of decoration — so any fill on the root
  -- is painted INSIDE that inset and leaves the host's panel colour as a rim. The
  -- host background is the themed panel surface; letting it through is what makes
  -- this panel read as part of the shell instead of a card floating in a frame.
  -- Contrast comes from the tinted controls, not from repainting the backdrop.
  panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1 }, rows))
end

-- Fingerprint the rendered fields only, so a re-render happens on a real change and
-- not on every tick (which would reset the scroll position mid-read).
local function fingerprint(snap)
  if type(snap) ~= "table" or type(snap.sessions) ~= "table" then return "" end
  local parts = {}
  for i, s in ipairs(snap.sessions) do
    parts[i] = table.concat({
      tostring(s.sid), tostring(s.state), tostring(s.model),
      tostring(s.tin), tostring(s.tout), tostring(s.cr),
    }, "\2")
  end
  return table.concat(parts, "\1")
end

function onOpen(_context)
  panel.setWantsSecondTicks(true) -- host stops ticks on close, re-arms on reopen
  local snap = noctalia.state.get and noctalia.state.get(KEY)
  last = fingerprint(snap)
  render(snap)
end

function update()
  local snap = noctalia.state.get and noctalia.state.get(KEY)
  local fp = fingerprint(snap)
  if fp ~= last then
    last = fp
    render(snap)
  end
end
