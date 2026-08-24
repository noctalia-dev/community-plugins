--!nonstrict
-- Git Companion panel — a mini-docker-style dashboard for your PRs and issues.
-- Tabs switch between pull requests and issues; clicking an item opens it on
-- the web (GitHub/GitLab) via xdg-open. Layout mirrors mini-docker's panel:
-- tab buttons with selected/ghost variants, an outline button-card list, and
-- a centered empty state with a large glyph.

local snapshot = {
  prs = noctalia.state.get("prs") or {},
  issues = noctalia.state.get("issues") or {},
  prsCount = noctalia.state.get("prs_count") or 0,
  issuesCount = noctalia.state.get("issues_count") or 0,
  updatedAt = noctalia.state.get("last_update") or "",
  status = noctalia.state.get("status") or "ok",
  username = noctalia.state.get("username") or "",
  bio = noctalia.state.get("bio") or "",
  avatarPath = noctalia.state.get("avatar_path") or "",
}
local currentTab = "prs" -- "prs" or "issues"
local hoveredKey = nil

local render

local function tr(key, args) return noctalia.tr("panel." .. key, args) end

-- Open a PR/issue URL in the default browser. Single quotes are escaped so the
-- URL can't break out of the shell argument.
local function openLink(link)
  if not link or link == "" then return end
  local safe = link:gsub("'", "'\\''")
  noctalia.runAsync("xdg-open '" .. safe .. "'")
end

local function itemsForTab()
  local value = snapshot[currentTab]
  return type(value) == "table" and value or {}
end

local function itemGlyph()
  return currentTab == "prs" and "git-pull-request" or "info-circle"
end

local function statusBox(glyph, message)
  return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center", padding = 24 }, {
    ui.glyph({ name = glyph, size = 42, color = "on_surface_variant" }),
    ui.label({ text = message, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
  })
end

local function statusInfo()
  local platform = noctalia.getConfig("platform")
  local bin = platform == "gitlab" and "glab" or "gh"
  local status = snapshot.status
  if status == "bin_missing" then
    return platform == "gitlab" and "brand-gitlab" or "brand-github",
           tr("bin_missing", { bin = bin })
  end
  if status == "gitlab_scope_missing" then
    return "alert-triangle", tr("gitlab_scope_missing")
  end
  return "alert-triangle", tr("no_items")
end

local function hasBlockingStatus()
  local status = snapshot.status
  return status ~= nil and status ~= "ok" and status ~= "loading"
end

local function getSubtitle(group, repo, bio)
  if group ~= "" then return group end
  if repo ~= "" then return repo end
  if bio ~= "" then return bio end
  return nil
end

local function avatar()
  if snapshot.avatarPath ~= "" then
    return ui.image({
      path = snapshot.avatarPath,
      width = 40, height = 40, radius = 20,
      fit = "cover", border = "primary", borderWidth = 2,
    })
  end
  return ui.column({
    width = 40, height = 40, radius = 20,
    border = "primary", borderWidth = 2,
    align = "center", justify = "center",
  }, {
    ui.glyph({ name = "user", size = 24, color = "on_surface_variant" }),
  })
end

local function userRow()
  local group = noctalia.getConfig("group") or ""
  local repo = noctalia.getConfig("repo") or ""
  local subtitle = getSubtitle(group, repo, snapshot.bio)
  local updatedAt = snapshot.updatedAt
  return ui.row({ gap = 10, align = "center" }, {
    avatar(),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = snapshot.username, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = subtitle, fontWeight = "thin", color = "on_surface", fontSize = 11, maxLines = 1 }),
    }),
    ui.column({ gap = 2, align = "end" }, {
      ui.label({ text = tr("last_update"), color = "on_surface_variant", fontSize = 10 }),
      ui.label({ text = updatedAt ~= "" and updatedAt or tr("last_update_placeholder"), color = "on_surface", fontSize = 11 }),
    }),
  })
end

local function itemCard(item)
  local key = tostring(item.url or item.ref or item.title)
  local hovered = hoveredKey == key
  return ui.column({
    key = key,
    gap = 8,
    padding = 10,
    radius = 8,
    border = "outline",
    borderWidth = 1,
    fill = hovered and "tertiary" or "surface_variant",
    onClick = function() openLink(item.url); panel.close() end,
    onHover = function(state)
      hoveredKey = (state == "true") and key or nil
      render()
    end,
  }, {
    ui.row({ gap = 10, align = "center" }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = item.title or tr("untitled"), color = hovered and "on_tertiary" or "on_surface", fontWeight = "bold", maxLines = 2 }),
        ui.label({ text = item.ref or "", fontSize = 11, color = hovered and "on_tertiary" or "on_surface_variant", maxLines = 1 }),
      }),
      ui.glyph({ name = "circle-check", size = 24, color = hovered and "on_tertiary" or "primary", visible = item.detailed_merge_status == "mergeable" }),
    }),
  })
end

local function itemList()
  local items = itemsForTab()
  if #items == 0 then
    return { statusBox(itemGlyph(), tr("no_items")) }
  end
  local rows = {}
  for _, item in ipairs(items) do
    table.insert(rows, itemCard(item))
  end
  return rows
end

local function tabButton(label, tab, callback)
  return ui.button({
    text = label,
    selected = currentTab == tab,
    variant = currentTab == tab and "primary" or "ghost",
    onClick = callback,
  })
end

local function switchTab(tab)
  currentTab = tab
  hoveredKey = nil
  render()
end

render = function()
  local platform = noctalia.getConfig("platform")
  local requestLabel = platform == "gitlab" and tr("merge_requests") or tr("pull_requests")
  local blocked = hasBlockingStatus()

  -- Body: the tabbed list when healthy, a centered status box otherwise.
  -- The tab row is hidden in the blocking state so the card collapses.
  local body = {}
  if blocked then
    local glyph, message = statusInfo()
    table.insert(body, statusBox(glyph, message))
  else
    if snapshot.username ~= "" then
      table.insert(body, userRow())
    end
    table.insert(body, ui.row({ gap = 4, align = "center" }, {
      tabButton(tr("tab_prs", { label = requestLabel, count = snapshot.prsCount }), "prs", "onTabPrs"),
      tabButton(tr("tab_issues", { count = snapshot.issuesCount }), "issues", "onTabIssues"),
    }))
    table.insert(body, ui.scroll({ flexGrow = 1, gap = 8, align = "stretch", justify = "start" }, itemList()))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    -- Header
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = platform == "gitlab" and "brand-gitlab" or "brand-github", size = 24, color = "primary" }),
      ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),
    table.unpack(body),
  }))
end

function onTabPrs() switchTab("prs") end
function onTabIssues() switchTab("issues") end

function onCloseClicked() panel.close() end

function onRefreshClicked()
  noctalia.runAsync("noctalia msg plugin tphilippot/git_companion:service all refresh")
end

-- Watch for state changes from the service
noctalia.state.watch("prs", function(value) snapshot.prs = value or {}; render() end)
noctalia.state.watch("issues", function(value) snapshot.issues = value or {}; render() end)
noctalia.state.watch("prs_count", function(value) snapshot.prsCount = value or 0; render() end)
noctalia.state.watch("issues_count", function(value) snapshot.issuesCount = value or 0; render() end)
noctalia.state.watch("last_update", function(value) snapshot.updatedAt = value or ""; render() end)
noctalia.state.watch("status", function(value) snapshot.status = value or "ok"; render() end)
noctalia.state.watch("username", function(value) snapshot.username = value or ""; render() end)
noctalia.state.watch("bio", function(value) snapshot.bio = value or ""; render() end)
noctalia.state.watch("avatar_path", function(value) snapshot.avatarPath = value or ""; render() end)

-- Periodically re-render to pick up setting changes (like platform)
noctalia.setUpdateInterval(5000)
function update() render() end

-- Initial render
render()
