--!nonstrict
-- Obsidian panel: daily capture, recent notes, git sync.

local STATE_KEY = "obs_snapshot"
local COMMAND_KEY = "obs_command"
local RESULT_KEY = "obs_action_result"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  loading = true,
  busy = false,
  vaultName = "",
  dailyRel = "",
  dailyExists = false,
  dailyPreview = "",
  recent = {},
  git = {
    isRepo = false,
    branch = "",
    dirty = 0,
    ahead = 0,
    behind = 0,
    clean = true,
    files = {},
  },
  error = "",
  updatedAt = 0,
  revision = 0,
}

local tab = "daily" -- daily | recent | git
local selectedId = ""
local filterText = ""
local filterKey = 0
local captureText = ""
local captureKey = 0
local commitText = ""
local commitKey = 0
local requestCounter = 0
local feedback = ""
local feedbackError = false
local dirty = true

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function nextRequestId()
  requestCounter += 1
  return `panel-{requestCounter}`
end

local function send(action, values)
  local command = { action = action, requestId = nextRequestId() }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
  return command.requestId
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function matchesFilter(...)
  local q = noctalia.string.trim(filterText)
  if q == "" then return true end
  for raw in q:gmatch("%S+") do
    local term = lower(raw)
    local hit = false
    for i = 1, select("#", ...) do
      local part = lower(select(i, ...))
      if part ~= "" and part:find(term, 1, true) then
        hit = true
        break
      end
    end
    if not hit then return false end
  end
  return true
end

local function listButton(props)
  props.contentAlign = "start"
  props.controlSize = props.controlSize or "md"
  return ui.button(props)
end

local function selectedRecent()
  if tab ~= "recent" then return nil end
  for _, n in ipairs(snapshot.recent or {}) do
    if n.id == selectedId then return n end
  end
  return nil
end

local function gitSummary()
  local g = snapshot.git or {}
  if not g.isRepo then
    return tr("panel.git_nogit")
  end
  if g.clean then
    return tr("panel.git_clean") .. (g.branch ~= "" and (` · {g.branch}`) or "")
  end
  return tr("panel.git_branch", {
    branch = g.branch ~= "" and g.branch or "—",
    ahead = g.ahead or 0,
    behind = g.behind or 0,
    dirty = g.dirty or 0,
  })
end

local function emptyList(msg)
  return ui.column({
    key = "empty-" .. tab,
    align = "center",
    justify = "center",
    padding = 24,
    gap = 8,
    flexGrow = 1,
  }, {
    ui.glyph({ name = "search", size = 36, color = "on_surface_variant" }),
    ui.label({ text = msg, color = "on_surface_variant", textAlign = "center" }),
  })
end

local function recentRows()
  local rows = {}
  for _, n in ipairs(snapshot.recent or {}) do
    if matchesFilter(n.name, n.rel) then
      local selected = n.id == selectedId
      local when = ""
      if (n.mtime or 0) > 0 then
        when = noctalia.formatTime("%m-%d %H:%M", n.mtime)
      end
      table.insert(rows, listButton({
        key = "note-" .. n.id,
        text = (when ~= "" and (when .. "  ·  ") or "") .. n.rel,
        glyph = "file-text",
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = n.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

local function gitFileRows()
  local rows = {}
  for _, f in ipairs((snapshot.git and snapshot.git.files) or {}) do
    if matchesFilter(f.path, f.code) then
      table.insert(rows, listButton({
        key = "gf-" .. f.id,
        text = `{f.code}  {f.path}`,
        glyph = "git-commit",
        variant = "outline",
        onClick = function()
          selectedId = f.id
          render()
        end,
      }))
    end
  end
  return rows
end

local function itemList()
  if tab == "daily" then
    local preview = snapshot.dailyPreview
    if type(preview) ~= "string" or preview == "" then
      return emptyList(
        snapshot.dailyExists and tr("panel.empty") or tr("panel.daily_missing")
      )
    end
    return ui.column({
      key = "daily-preview",
      gap = 8,
      padding = 8,
      align = "stretch",
      flexGrow = 1,
    }, {
      ui.label({
        text = preview,
        color = "on_surface",
        fontSize = 12,
        maxLines = 24,
      }),
    })
  end

  local rows
  if tab == "recent" then
    rows = recentRows()
  else
    rows = gitFileRows()
  end
  if #rows == 0 then
    return emptyList(tr("panel.empty"))
  end
  return ui.column({
    key = "items-" .. tab,
    align = "stretch",
    justify = "start",
    gap = 8,
    flexGrow = 1,
  }, rows)
end

local function toolbar()
  local busy = snapshot.busy == true

  if tab == "daily" then
    return ui.column({ gap = 8, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
      ui.label({
        text = tr("panel.daily_path", {
          path = snapshot.dailyRel ~= "" and snapshot.dailyRel or "—",
        }),
        color = "on_surface_variant",
        fontSize = 12,
        maxLines = 2,
      }),
      ui.input({
        key = `capture-{captureKey}`,
        value = captureText,
        placeholder = tr("panel.capture_placeholder"),
        flexGrow = 1,
        controlSize = "md",
        onChange = "onCaptureChange",
        onSubmit = "onCapture",
        submitOnEnter = true,
      }),
      ui.row({ gap = 6 }, {
        ui.button({
          text = tr("actions.capture"),
          glyph = "plus",
          variant = "primary",
          enabled = not busy and snapshot.available == true,
          onClick = "onCapture",
        }),
        ui.button({
          text = tr("actions.open_daily"),
          glyph = "external-link",
          variant = "outline",
          enabled = snapshot.available == true,
          onClick = "onOpenDaily",
        }),
      }),
    })
  end

  if tab == "recent" then
    local n = selectedRecent()
    if not n then
      return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
    end
    return ui.column({ gap = 6, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
      ui.label({ text = n.rel, fontWeight = "bold", maxLines = 2 }),
      ui.row({ gap = 6 }, {
        ui.button({ text = tr("actions.open_note"), glyph = "external-link", variant = "primary", onClick = "onOpenNote" }),
        ui.button({ text = tr("actions.copy_link"), glyph = "link", variant = "outline", onClick = "onCopyLink" }),
        ui.button({ text = tr("actions.copy_path"), glyph = "copy", variant = "ghost", onClick = "onCopyPath" }),
      }),
    })
  end

  -- git tab
  local g = snapshot.git or {}
  local inProg = type(g.inProgress) == "string" and g.inProgress ~= ""
  local gitOk = g.isRepo == true and not inProg
  local rows = {
    ui.label({
      text = inProg
        and tr("panel.git_in_progress", { kind = g.inProgress })
        or gitSummary(),
      color = inProg and "error"
        or ((g.isRepo and not g.clean) and "#73c936" or "on_surface_variant"),
      fontSize = 12,
      maxLines = 2,
    }),
  }
  if inProg then
    table.insert(rows, ui.row({ gap = 6 }, {
      ui.button({
        text = tr("actions.git_abort"),
        glyph = "x",
        variant = "primary",
        enabled = not busy,
        onClick = "onGitAbort",
      }),
    }))
  else
    table.insert(rows, ui.input({
      key = `commit-{commitKey}`,
      value = commitText,
      placeholder = tr("panel.commit_placeholder"),
      flexGrow = 1,
      controlSize = "md",
      onChange = "onCommitChange",
      onSubmit = "onGitCommit",
      submitOnEnter = true,
    }))
    table.insert(rows, ui.row({ gap = 6 }, {
      ui.button({
        text = tr("actions.git_commit"),
        glyph = "git-commit",
        variant = "primary",
        enabled = not busy and gitOk,
        onClick = "onGitCommit",
      }),
      ui.button({
        text = tr("actions.git_pull"),
        glyph = "cloud-download",
        variant = "outline",
        enabled = not busy and gitOk,
        onClick = "onGitPull",
      }),
      ui.button({
        text = tr("actions.git_push"),
        glyph = "cloud-upload",
        variant = "outline",
        enabled = not busy and gitOk,
        onClick = "onGitPush",
      }),
      ui.button({
        text = tr("actions.git_sync"),
        glyph = "refresh",
        variant = "outline",
        enabled = not busy and gitOk,
        onClick = "onGitSync",
      }),
    }))
  end
  return ui.column({
    gap = 8,
    padding = 10,
    fill = "surface_variant/0.45",
    radius = 10,
    align = "stretch",
  }, rows)
end

local function tabButton(label, id, cb)
  return ui.button({
    text = label,
    selected = tab == id,
    variant = tab == id and "primary" or "ghost",
    onClick = cb,
  })
end

render = function()
  dirty = false
  local notes = {}
  if snapshot.loading then
    table.insert(notes, ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }))
  end
  if snapshot.busy then
    table.insert(notes, ui.label({ text = tr("panel.busy"), color = "primary" }))
  end
  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(notes, ui.label({ text = snapshot.error, color = "error", maxLines = 3 }))
  end
  if feedback ~= "" then
    table.insert(notes, ui.label({
      text = feedback,
      color = feedbackError and "error" or "tertiary",
      maxLines = 2,
    }))
  end

  local g = snapshot.git or {}
  local gitLabel = "—"
  if g.isRepo then
    gitLabel = g.clean and "clean" or (tostring(g.dirty or 0) .. " dirty")
  else
    gitLabel = "no git"
  end

  local summary = tr("panel.summary", {
    daily = snapshot.dailyExists and "✓" or "·",
    recent = #(snapshot.recent or {}),
    git = gitLabel,
  })

  local titleIcon = snapshot.available and "assets/obsidian-purple.png" or "assets/obsidian-grey.png"
  if snapshot.available and g.isRepo and not g.clean then
    titleIcon = "assets/obsidian-green.png"
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.image({ path = titleIcon, width = 28, height = 28, fit = "contain" }),
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold" }),
        ui.label({
          text = tr("panel.vault", {
            name = snapshot.vaultName ~= "" and snapshot.vaultName or "—",
          }),
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.button({ text = tr("actions.open_vault"), glyph = "external-link", variant = "outline", onClick = "onOpenVault" }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
      ui.button({ glyph = "close", onClick = "onClose" }),
    }),

    ui.row({ gap = 4, align = "center" }, {
      tabButton(tr("tabs.daily"), "daily", "onTabDaily"),
      tabButton(tr("tabs.recent"), "recent", "onTabRecent"),
      tabButton(tr("tabs.git"), "git", "onTabGit"),
    }),

    ui.label({
      text = summary,
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    }),

    ui.row({ gap = 8, align = "center", visible = tab == "recent" or tab == "git" }, {
      ui.input({
        key = `filter-{tab}-{filterKey}`,
        value = filterText,
        placeholder = tr("filter.placeholder"),
        flexGrow = 1,
        controlSize = "sm",
        onChange = "onFilterChange",
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        visible = filterText ~= "",
        onClick = "onClearFilter",
      }),
    }),

    toolbar(),
    ui.column({ gap = 3, align = "stretch" }, notes),
    ui.scroll({
      key = "scroll-" .. tab,
      flexGrow = 1,
      gap = 8,
      align = "stretch",
    }, { itemList() }),
    ui.label({
      text = (snapshot.updatedAt or 0) > 0
        and tr("panel.updated", { time = noctalia.formatTime("%H:%M:%S", snapshot.updatedAt) })
        or "",
      color = "on_surface_variant",
      fontSize = 11,
    }),
  }))
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then return end
  snapshot = value
  if selectedId ~= "" and tab == "recent" and not selectedRecent() then
    selectedId = ""
  end
  dirty = true
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" then return end
  if type(result.requestId) ~= "string" or not result.requestId:match("^panel%-") then return end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  if result.ok == true and result.action == "capture" then
    captureText = ""
    captureKey += 1
  end
  if result.ok == true and result.action == "git_commit" then
    commitText = ""
    commitKey += 1
  end
  dirty = true
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  feedback = ""
  send("refresh")
  render()
end

function update()
  if dirty then render() end
end

function onClose() panel.close() end
function onRefresh() send("refresh") end
function onOpenVault() send("open_vault") end
function onOpenDaily() send("open_daily") end

function onTabDaily()
  tab = "daily"
  selectedId = ""
  filterKey += 1
  render()
end
function onTabRecent()
  tab = "recent"
  selectedId = ""
  filterKey += 1
  render()
end
function onTabGit()
  tab = "git"
  selectedId = ""
  filterKey += 1
  render()
end

function onFilterChange(value)
  filterText = if type(value) == "string" then value else ""
  render()
end
function onClearFilter()
  filterText = ""
  filterKey += 1
  render()
end

function onCaptureChange(value)
  captureText = if type(value) == "string" then value else ""
end
function onCapture()
  local text = noctalia.string.trim(captureText)
  if text == "" then return end
  send("capture", { text = text })
end

function onOpenNote()
  local n = selectedRecent()
  if n then send("open_note", { rel = n.rel }) end
end
function onCopyLink()
  local n = selectedRecent()
  if n then send("copy", { text = "[[" .. n.name .. "]]" }) end
end
function onCopyPath()
  local n = selectedRecent()
  if n then send("copy", { text = n.rel }) end
end

function onCommitChange(value)
  commitText = if type(value) == "string" then value else ""
end
function onGitCommit()
  send("git_commit", { message = commitText })
end
function onGitPull() send("git_pull") end
function onGitPush() send("git_push") end
function onGitSync() send("git_sync") end
function onGitAbort() send("git_abort") end
