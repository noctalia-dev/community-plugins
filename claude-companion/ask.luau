-- The ask panel — a one-off question without going through the launcher.
--
-- Quick-ask was only ever reachable as `/claude ? …`, which means opening the
-- launcher, typing a prefix, and remembering the `?`. That is a lot of ceremony for
-- the lightest thing this plugin does, and it is why the feature went unused. A
-- middle-click on the bar pulse opens this instead: type, Enter, done.
--
-- Pure surface, same doctrine as every other panel here. It owns no backend: the
-- question goes to a file and a bare `ask` poke goes to the claude entry, which runs
-- the SAME run_ask() the launcher uses. The panel never sees the read-only flags in
-- backend_command(), so there is no second copy of them to drift.
--
-- The answer does not come back here — it lands in the answer panel and a toast,
-- exactly as it does for a launcher ask. One delivery path, one place to look.

local SELF = "lowcache/claude-companion:ask"
-- The claude ENTRY is a launcher_provider and cannot receive IPC; claude-ask is the
-- service entry pointed at the same file, and is the addressable half. See plugin.toml.
local BACKEND = "lowcache/claude-companion:claude-ask"

local function tr(key, args) return noctalia.tr(key, args) end

-- Panel surface is 460 logical px (plugin.toml).
local WRAP = 404
local PAD = 14
-- The panel's first child is a text label whose line box carries ~5px of slack above
-- the cap line; its last is a filled button rect that carries none. So a uniform inset
-- puts the title 19px from the top edge and the button 14px from the bottom, and the
-- eye reads that as top-heavy. The 5px goes back UNDER the button rather than coming
-- off the top: a per-side padding table is silently ignored on a column by Noctalia
-- 5.0.0 (it zeroes the top and widens the row), while on a row it is honoured.
local SLACK = 5

local draft = ""

local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Same stance as the consent panel and the hook: without XDG_RUNTIME_DIR there is
-- nowhere private to put the question, and a guessed uid path is worse than none.
local function runtime_dir()
  local v = noctalia.getenv and noctalia.getenv("XDG_RUNTIME_DIR")
  if type(v) == "string" and v ~= "" then return v .. "/claude-companion" end
  return nil
end

-- The question reaches a shell command, so it is QUOTED (shq), never allowlisted:
-- unlike a session id or a request id this is free-form user text and restricting
-- its alphabet would break the feature. printf %s takes it as a literal operand.
-- onSubmit hands the current value straight to the callback, so Enter does not
-- depend on an onChange having landed first; the button path falls back to `draft`.
local function submit(value)
  local q = (type(value) == "string" and value ~= "") and value or draft
  if type(q) ~= "string" then return end
  q = q:gsub("^%s+", ""):gsub("%s+$", "")
  if q == "" then return end

  local dir = runtime_dir()
  if not dir then
    noctalia.notifyError(tr("notify.title"), tr("ask.no_runtime"))
    return
  end

  -- Write, then poke. The backend reads the file on the other side of the dispatch,
  -- so the write must land first — hence one shell command, not two runAsync calls
  -- whose ordering is not guaranteed.
  noctalia.runAsync(
    "mkdir -p -m 700 " .. shq(dir)
      .. " && printf %s " .. shq(q) .. " > " .. shq(dir .. "/ask")
      .. " && noctalia msg plugin " .. shq(BACKEND) .. " all ask"
  )
  draft = ""
  noctalia.runAsync("noctalia msg panel-close " .. shq(SELF))
end

local function render()
  local rows = {
    ui.label({ text = tr("ask.title"), fontWeight = "bold" }),
    ui.input({
      -- `key` is the host's identity for the field across re-renders; a stable one
      -- keeps focus and the caret where they are instead of resetting mid-type.
      key = "ask-input",
      value = draft,
      placeholder = tr("ask.placeholder"),
      -- The whole point is that this is faster than the launcher, so it takes focus
      -- on open: middle-click, type, Enter — no click into the field first.
      focus = true,
      -- No flexGrow: the parent is a COLUMN, so growth there is VERTICAL — the field
      -- would eat the panel's slack and paint over what follows it. Width comes free
      -- from the column's cross-axis stretch, which is what the field actually wants.
      onChange = function(v) draft = tostring(v or "") end,
      onSubmit = submit,
    }),
    -- Say where the answer goes, because it does NOT come back to this panel.
    ui.label({ text = tr("ask.delivery"), maxWidth = WRAP, opacity = 0.6 }),
    -- Action last and trailing-aligned, the shape a confirm control is looked for in.
    ui.row({ justify = "end", gap = 8, padding = { bottom = SLACK } }, {
      ui.button({ text = tr("ask.send"), variant = "primary", onClick = function() submit(draft) end }),
    }),
  }

  -- Deliberately UNFILLED, same as the other panels: the host insets a decorated
  -- panel, so a fill on the root leaves the panel colour as a rim.
  panel.render(ui.column({ padding = PAD, gap = 6, flexGrow = 1 }, rows))
end

function onOpen(_context)
  draft = ""
  render()
end
