--!nonstrict
-- Git Companion panel — a mini-docker-style dashboard for your PRs and issues.
-- Tabs switch between pull requests and issues; clicking an item opens it on
-- the web (GitHub/GitLab) via xdg-open. Layout mirrors mini-docker's panel:
-- tab buttons with selected/ghost variants, an outline button-card list, and
-- a centered empty state with a large glyph.

local snapshot = {
  prs = noctalia.state.get("prs") or {},
  issues = noctalia.state.get("issues") or {},
  reviews = noctalia.state.get("reviews") or {},
  prsCount = noctalia.state.get("prs_count") or 0,
  issuesCount = noctalia.state.get("issues_count") or 0,
  reviewsCount = noctalia.state.get("reviews_count") or 0,
  updatedAt = noctalia.state.get("last_update") or "",
  status = noctalia.state.get("status") or "ok",
  username = noctalia.state.get("username") or "",
  bio = noctalia.state.get("bio") or "",
  avatarPath = noctalia.state.get("avatar_path") or "",
}
local currentTab = "prs" -- a TABS id
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

local TABS = {
  { id = "prs", setting = "show_prs", glyph = "git-pull-request" },
  { id = "issues", setting = "show_issues", glyph = "info-circle" },
  { id = "reviews", setting = "show_reviews", glyph = "eye" },
}

local function visibleTabs()
  local shown = {}
  for _, tab in ipairs(TABS) do
    if noctalia.getConfig(tab.setting) ~= false then table.insert(shown, tab) end
  end
  return shown
end

local function resolveTab(shown)
  for _, tab in ipairs(shown) do
    if tab.id == currentTab then return tab end
  end
  return shown[1]
end

local function itemGlyph()
  for _, tab in ipairs(TABS) do
    if tab.id == currentTab then return tab.glyph end
  end
  return "info-circle"
end

local BADGE_BUCKETS = {
  { key = "branch_badge_primary", color = "primary" },
  { key = "branch_badge_secondary", color = "secondary" },
  { key = "branch_badge_tertiary", color = "tertiary" },
  { key = "branch_badge_alert", color = "error" },
}

local function matchesBranch(branch, pattern)
  local prefix = pattern:match("^(.*)%*$")
  if prefix then return branch:sub(1, #prefix) == prefix end
  return branch == pattern
end

-- First bucket holding a matching pattern wins. A branch listed under two
-- colours is the user's call, so there is nothing to arbitrate here.
local function branchColor(branch)
  if not branch or branch == "" then return nil end
  for _, bucket in ipairs(BADGE_BUCKETS) do
    local patterns = noctalia.getConfig(bucket.key)
    if type(patterns) == "table" then
      for _, pattern in ipairs(patterns) do
        if type(pattern) == "string" then
          local trimmed = noctalia.string.trim(pattern)
          if trimmed ~= "" and matchesBranch(branch, trimmed) then
            return bucket.color
          end
        end
      end
    end
  end
  return nil
end

local function branchBadge(branch, color, hovered)
  local textColor = hovered and "on_tertiary" or color
  return ui.row({
    fill = textColor .. "/0.18",
    border = textColor .. "/0.32",
    borderWidth = 1,
    radius = 8,
    paddingH = 7,
    paddingV = 2,
    align = "center",
  }, {
    ui.label({ text = branch, fontSize = 10, fontWeight = "medium", color = textColor }),
  })
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
  return status ~= nil and status ~= "ok"
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


  local children = {}
  if snapshot.username ~= "" then
    table.insert(children, avatar())
    table.insert(children, ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = snapshot.username, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = subtitle, fontWeight = "thin", color = "on_surface", fontSize = 11, maxLines = 1 }),
    }))
  else
    table.insert(children, ui.spacer({ flexGrow = 1 }))
  end
  table.insert(children, ui.column({ gap = 2, align = "end" }, {
    ui.label({ text = tr("last_update"), color = "on_surface_variant", fontSize = 10 }),
    ui.label({ text = updatedAt ~= "" and updatedAt or tr("last_update_placeholder"), color = "on_surface", fontSize = 11 }),
  }))
  return ui.row({ gap = 10, align = "center" }, children)
end

local function itemCard(item)
  local key = tostring(item.url or item.ref or item.title)
  local hovered = hoveredKey == key

  -- Second line: the branch badge, when the target branch matches a configured
  -- pattern, then the reference. Issues carry no target branch, so they never
  -- get a badge without an explicit check.
  local subtitle = {}
  local badgeColor = branchColor(item.targetBranch)
  if badgeColor then
    table.insert(subtitle, branchBadge(item.targetBranch, badgeColor, hovered))
  end
  table.insert(subtitle, ui.label({
    text = item.ref or "",
    fontSize = 11,
    color = hovered and "on_tertiary" or "on_surface_variant",
    maxLines = 1,
  }))

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
        ui.row({ gap = 6, align = "center" }, subtitle),
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

-- Only the PR/MR label depends on the platform, so labels stay per-tab.
local function tabLabel(tab)
  if tab.id == "prs" then
    local platform = noctalia.getConfig("platform")
    local requestLabel = platform == "gitlab" and tr("merge_requests") or tr("pull_requests")
    return tr("tab_prs", { label = requestLabel, count = snapshot.prsCount })
  elseif tab.id == "issues" then
    return tr("tab_issues", { count = snapshot.issuesCount })
  end
  return tr("tab_reviews", { count = snapshot.reviewsCount })
end

local TAB_ACTIONS = {
  prs = "onTabPrs",
  issues = "onTabIssues",
  reviews = "onTabReviews",
}

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
  local blocked = hasBlockingStatus()
  local shown = visibleTabs()
  local active = resolveTab(shown)
  if active then currentTab = active.id end

  -- Body: the tabbed list when healthy, a centered status box otherwise.
  -- The tab row is hidden in the blocking state so the card collapses.
  local body = {}
  if blocked then
    local glyph, message = statusInfo()
    table.insert(body, statusBox(glyph, message))
  elseif not active then
    -- Every tab turned off: nothing to select, so say so rather than render an
    -- empty strip above an empty list.
    table.insert(body, userRow())
    table.insert(body, statusBox("eye-off", tr("no_tabs")))
  else
    table.insert(body, userRow())
    local strip = {}
    for _, tab in ipairs(shown) do
      table.insert(strip, tabButton(tabLabel(tab), tab.id, TAB_ACTIONS[tab.id]))
    end
    table.insert(body, ui.row({ gap = 4, align = "center" }, strip))
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
function onTabReviews() switchTab("reviews") end

function onCloseClicked() panel.close() end

function onRefreshClicked()
  noctalia.runAsync("noctalia msg plugin tphilippot/git_companion:service all refresh")
end

-- Watch for state changes from the service
noctalia.state.watch("prs", function(value) snapshot.prs = value or {}; render() end)
noctalia.state.watch("issues", function(value) snapshot.issues = value or {}; render() end)
noctalia.state.watch("reviews", function(value) snapshot.reviews = value or {}; render() end)
noctalia.state.watch("prs_count", function(value) snapshot.prsCount = value or 0; render() end)
noctalia.state.watch("issues_count", function(value) snapshot.issuesCount = value or 0; render() end)
noctalia.state.watch("reviews_count", function(value) snapshot.reviewsCount = value or 0; render() end)
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
