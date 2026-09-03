--!nonstrict
-- /ob launcher: daily, capture, git, panel.

local STATE_KEY = "obs_snapshot"
local COMMAND_KEY = "obs_command"
local PANEL_ID = "davemhammer/obsidian:manager"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  loading = true,
  vaultName = "",
  dailyRel = "",
  git = { dirty = 0, isRepo = false, clean = true },
  recent = {},
}

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
  end
end)

local function trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function send(action, values)
  local command = { action = action, requestId = "launcher-" .. tostring(os.time()) }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
end

local function statusRow(title, subtitle, glyph)
  return { id = "", title = title, subtitle = subtitle, glyph = glyph or "notebook" }
end

local function topCategories()
  local g = snapshot.git or {}
  local gitSub = "—"
  if g.isRepo then
    gitSub = g.clean and "clean" or (tostring(g.dirty or 0) .. " dirty")
  else
    gitSub = "no git"
  end
  return {
    { id = "act:daily", title = noctalia.tr("launcher.cat.daily"), subtitle = snapshot.dailyRel or "", glyph = "calendar", score = 100 },
    { id = "act:capture", title = noctalia.tr("launcher.cat.capture"), subtitle = noctalia.tr("launcher.cat.capture-sub"), glyph = "plus", score = 95 },
    { id = "act:git", title = noctalia.tr("launcher.cat.git"), subtitle = gitSub, glyph = "git-commit", score = 90 },
    { id = "act:panel", title = noctalia.tr("launcher.cat.panel"), subtitle = noctalia.tr("launcher.cat.panel-sub"), glyph = "layout-dashboard", score = 80 },
    { id = "act:refresh", title = noctalia.tr("launcher.cat.refresh"), subtitle = noctalia.tr("launcher.cat.refresh-sub"), glyph = "refresh", score = 50 },
  }
end

function search(query)
  query = trim(query)
  if not snapshot.available and not snapshot.loading then
    launcher.setResults(query, { statusRow(noctalia.tr("launcher.missing"), "", "alert-triangle") })
    return
  end
  if snapshot.loading and not snapshot.available then
    launcher.setResults(query, { statusRow(noctalia.tr("launcher.loading"), snapshot.vaultName, "loader") })
    send("refresh")
    return
  end

  local head, rest = query:match("^(%S+)%s*(.-)$")
  head = lower(head or "")
  rest = trim(rest or "")

  if head == "" then
    launcher.setResults(query, topCategories())
    return
  end

  if head == "capture" or head == "c" or head == "note" then
    if rest ~= "" then
      launcher.setResults(query, {
        {
          id = "do:capture:" .. rest,
          title = "Add to daily",
          subtitle = rest,
          glyph = "plus",
          score = 100,
        },
      })
      return
    end
    launcher.setResults(query, {
      statusRow(noctalia.tr("launcher.cat.capture"), noctalia.tr("launcher.cat.capture-sub"), "plus"),
    })
    return
  end

  if head == "daily" or head == "d" then
    launcher.setResults(query, {
      { id = "act:daily", title = noctalia.tr("launcher.cat.daily"), subtitle = snapshot.dailyRel or "", glyph = "calendar", score = 100 },
    })
    return
  end

  if head == "git" or head == "g" then
    launcher.setResults(query, {
      { id = "act:git", title = noctalia.tr("launcher.cat.git"), subtitle = "", glyph = "git-commit", score = 100 },
      { id = "act:commit", title = "Commit", subtitle = "git add -A && commit", glyph = "git-commit", score = 90 },
      { id = "act:pull", title = "Pull", subtitle = "git pull (merge)", glyph = "cloud-download", score = 80 },
      { id = "act:push", title = "Push", subtitle = "git push", glyph = "cloud-upload", score = 70 },
      { id = "act:sync", title = "Sync", subtitle = "pull + push", glyph = "refresh", score = 60 },
    })
    return
  end

  -- free text: match recent note titles
  local rows = {}
  local q = lower(query)
  for _, n in ipairs(snapshot.recent or {}) do
    if lower(n.name):find(q, 1, true) or lower(n.rel):find(q, 1, true) then
      table.insert(rows, {
        id = "note:" .. n.rel,
        title = n.name,
        subtitle = n.rel,
        glyph = "file-text",
        score = 50,
      })
    end
  end
  for _, row in ipairs(topCategories()) do
    if lower(row.title):find(q, 1, true) then
      table.insert(rows, row)
    end
  end
  if #rows == 0 then
    rows = topCategories()
  end
  launcher.setResults(query, rows)
end

function activate(id)
  if type(id) ~= "string" or id == "" then return end

  if id == "act:daily" then
    send("open_daily")
    return
  end
  if id == "act:capture" then
    launcher.setQuery("capture ")
    return
  end
  if id == "act:git" or id == "act:panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  end
  if id == "act:refresh" then
    send("refresh")
    return
  end
  if id == "act:commit" then
    send("git_commit", {})
    return
  end
  if id == "act:pull" then
    send("git_pull")
    return
  end
  if id == "act:push" then
    send("git_push")
    return
  end
  if id == "act:sync" then
    send("git_sync")
    return
  end

  local cap = id:match("^do:capture:(.+)$")
  if cap then
    send("capture", { text = cap })
    return
  end

  local note = id:match("^note:(.+)$")
  if note then
    send("open_note", { rel = note })
  end
end
