-- The answer panel — the full-length surface for /claude ? quick-ask answers.
-- A notification toast clips long bodies and cannot scroll, so claude.luau publishes
-- the complete answer to noctalia.state "claude.answer" and this panel renders it
-- wrapped and scrollable. Ways in: click the bar pulse, the "Show last answer"
-- row under /claude, or `noctalia msg panel-open lowcache/claude-companion:answer`.
--
-- Pure subscriber, same doctrine as the orb: claude.luau owns the state, this panel
-- only renders it. state.watch() callbacks proved unreliable for bar widgets
-- (see pulse.luau) and a panel only lives while open anyway, so this polls on
-- second ticks and re-renders only when the payload actually changed — an
-- unconditional re-render each second would reset the scroll position mid-read.

local KEY = "claude.answer"

-- User-facing display strings live in translations/<lang>.json.
local function tr(key, args) return noctalia.tr(key, args) end

-- The panel surface is 460 logical px wide (plugin.toml); wrap text inside the
-- padding with room for the scrollbar.
local WRAP = 408
local PAD = 14

-- Fallback error accent, same as the pulse dot; normal body text keeps the
-- theme's default foreground by not setting a color at all.
local ERROR_RGB = "#FF4D1F"

local last = nil -- fingerprint of the last-rendered payload (skip no-op renders)

local function fingerprint(a)
  if type(a) ~= "table" then return "" end
  return tostring(a.at) .. "\1" .. tostring(a.q) .. "\1" .. tostring(a.error) .. "\1" .. tostring(a.text)
end

local function render(a)
  local rows = { ui.label({ text = tr("answer.title"), fontWeight = "bold" }) }
  local body
  if type(a) ~= "table" or type(a.text) ~= "string" or a.text == "" then
    body = ui.label({
      text = tr("answer.empty"),
      maxWidth = WRAP,
      opacity = 0.7,
    })
  else
    if type(a.q) == "string" and a.q ~= "" then
      local q = "? " .. a.q .. (type(a.at) == "string" and a.at ~= "" and (" · " .. a.at) or "")
      rows[#rows + 1] = ui.label({ text = q, maxWidth = WRAP, maxLines = 3, opacity = 0.7 })
    end
    body = ui.label({
      text = a.text,
      maxWidth = WRAP,
      color = a.error == true and ERROR_RGB or nil,
    })
  end
  rows[#rows + 1] = ui.separator({})
  rows[#rows + 1] = ui.scroll({ flexGrow = 1 }, { body })
  -- flexGrow on the ROOT is load-bearing: the host sizes its root flex to the
  -- panel, but this column is a child of it — without grow it takes its natural
  -- (full-content) height, overflows, and the panel hard-clips the answer. Grown
  -- to the panel height, the scroll child above is the one that gets bounded and
  -- actually scrolls.
  panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1 }, rows))
end

-- Visibility flag for claude.luau: while the panel is open it live-refreshes the
-- answer (update below), so a toast for the same answer would be a redundant
-- second surface — and dismissing that toast clicks outside the panel, which
-- the click-shield turns into closing the panel too. claude.luau reads this flag
-- and skips the toast when the panel is already showing.
local OPEN_KEY = "claude.answer.open"

function onOpen(_context)
  panel.setWantsSecondTicks(true) -- the host stops ticks on close, re-arms on reopen
  noctalia.state.set(OPEN_KEY, true)
  local a = noctalia.state.get(KEY)
  last = fingerprint(a)
  render(a)
end

function onClose()
  noctalia.state.set(OPEN_KEY, false)
end

function update()
  local a = noctalia.state.get(KEY)
  local fp = fingerprint(a)
  if fp ~= last then
    last = fp
    render(a)
  end
end
