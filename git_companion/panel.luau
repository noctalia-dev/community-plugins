--!nonstrict
-- Git Companion panel: a triage view of your pull/merge requests and issues.
-- Requests are sorted by what they ask of you (needs you, ready to merge,
-- waiting) when the platform reports a merge status; clicking an item opens it
-- on the web via xdg-open.

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
  errorDetail = noctalia.state.get("error_detail") or "",
  deploys = noctalia.state.get("deploys") or {},
}
local currentTab = "prs" -- a TABS id
local hoveredKey = nil

local render

local status = require("./status.luau")
local deploys = require("./deploys.luau")

local function tr(key, args) return noctalia.tr("panel." .. key, args) end

-- Open a PR/issue URL in the default browser. The URL is passed as its own
-- argv entry, so no shell ever parses it.
local function openLink(link)
  if not link or link == "" then return end
  noctalia.runAsync({"xdg-open", link})
end

local function itemsForTab()
  local value = snapshot[currentTab]
  return type(value) == "table" and value or {}
end

local TABS = {
  { id = "prs", setting = "show_prs", glyph = "git-pull-request" },
  { id = "issues", setting = "show_issues", glyph = "circle-dot" },
  { id = "reviews", setting = "show_reviews", glyph = "eye" },
  -- No setting: shown when there is a repository to follow (see deploys.luau).
  { id = "deploys", glyph = "rocket" },
}

local function visibleTabs()
  local shown = {}
  for _, tab in ipairs(TABS) do
    local visible
    if tab.id == "deploys" then
      visible = deploys.enabled(noctalia.getConfig("platform") or "github")
    else
      visible = noctalia.getConfig(tab.setting) ~= false
    end
    if visible then table.insert(shown, tab) end
  end
  return shown
end

local function resolveTab(shown)
  for _, tab in ipairs(shown) do
    if tab.id == currentTab then return tab end
  end
  return shown[1]
end

local function tabGlyph(id)
  for _, tab in ipairs(TABS) do
    if tab.id == id then return tab.glyph end
  end
  return "circle-dot"
end

-- ── Branch badges ────────────────────────────────────────────

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

-- ── Platform ─────────────────────────────────────────────────

local PLATFORM_BIN = {
  github = "gh",
  gitlab = "glab",
  gitea = "gt",
}
local PLATFORM_GLYPH = {
  github = "brand-github",
  gitlab = "brand-gitlab",
  gitea = "brand-git", -- Tabler ships no Gitea brand glyph
}

local function platform() return noctalia.getConfig("platform") or "github" end
local function platformBin() return PLATFORM_BIN[platform()] or "gh" end
local function platformGlyph() return PLATFORM_GLYPH[platform()] or "brand-git" end
-- ── Header ───────────────────────────────────────────────────

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

-- "<username> · <scope>", scope being the group, else the repo, else the bio.
local function caption()
  local group = noctalia.getConfig("group") or ""
  local repo = noctalia.getConfig("repo") or ""
  local scope = group ~= "" and group or (repo ~= "" and repo or snapshot.bio)
  local parts = {}
  if snapshot.username ~= "" then table.insert(parts, snapshot.username) end
  if scope ~= "" then table.insert(parts, scope) end
  return table.concat(parts, " · ")
end

local function header(withRefresh)
  local titleColumn = {
    ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", maxLines = 1 }),
  }
  local text = caption()
  if text ~= "" then
    table.insert(titleColumn, ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = platformGlyph(), size = 14, color = "primary" }),
      ui.label({ text = text, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
    }))
  end

  local children = {
    snapshot.username ~= "" and avatar() or ui.glyph({ name = platformGlyph(), size = 24, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, titleColumn),
  }
  -- Settings stay reachable in every state, a blocking one included.
  table.insert(children, ui.button({
    glyph = "settings", variant = "ghost", controlSize = "sm",
    tooltip = tr("settings"), onClick = "onOpenSettings",
  }))
  if withRefresh then
    table.insert(children, ui.button({
      glyph = "refresh", variant = "ghost", controlSize = "sm",
      tooltip = tr("refresh"), onClick = "onRefreshClicked",
    }))
  end
  table.insert(children, ui.button({ glyph = "close", controlSize = "sm", onClick = "onCloseClicked" }))
  return ui.row({ align = "center", gap = 8 }, children)
end

-- ── Rows ─────────────────────────────────────────────────────

local function itemRow(item)
  local key = tostring(item.url or item.ref or item.title)
  local hovered = hoveredKey == key
  local group = status.group(item.mergeStatus)
  local accent = group and status.GROUP_COLOR[group] or "primary"
  local ink = hovered and "on_tertiary" or accent

  -- The chip: the status glyph in its group colour, on a tint of that colour.
  local chip = ui.column({
    width = 32, height = 32, radius = 8,
    align = "center", justify = "center",
    fill = ink .. "/0.18",
  }, {
    ui.glyph({ name = status.glyph(item.mergeStatus) or "circle-dot", size = 18, color = ink }),
  })

  -- Second line: the status in words, then the reference.
  local line = {}
  if group then
    table.insert(line, ui.label({
      text = tr("merge_status." .. item.mergeStatus),
      fontSize = 11, fontWeight = "semibold", color = ink, maxLines = 1,
    }))
  end
  table.insert(line, ui.label({
    text = item.ref or "",
    fontSize = 11,
    color = hovered and "on_tertiary" or "on_surface_variant",
    maxLines = 1,
    flexGrow = 1,
  }))

  local children = {
    chip,
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({
        text = item.title or "",
        color = hovered and "on_tertiary" or "on_surface",
        fontWeight = "bold", maxLines = 2,
      }),
      ui.row({ gap = 6, align = "center" }, line),
    }),
  }

  -- Trailing: the target branch badge when it matches a configured pattern,
  -- else an open-in-browser hint while hovered.
  local badgeColor = branchColor(item.targetBranch)
  if badgeColor then
    table.insert(children, branchBadge(item.targetBranch, badgeColor, hovered))
  elseif hovered then
    table.insert(children, ui.glyph({ name = "external-link", size = 16, color = "on_tertiary" }))
  end

  return ui.row({
    key = key,
    gap = 10,
    padding = 10,
    radius = 8,
    align = "center",
    border = hovered and "tertiary" or "outline_variant",
    borderWidth = 1,
    fill = hovered and "tertiary" or "surface_container",
    onClick = function() openLink(item.url); panel.close() end,
    onHover = function(state)
      hoveredKey = (state == "true") and key or nil
      render()
    end,
  }, children)
end

local function sectionHeader(group, count)
  return ui.row({ gap = 6, paddingH = 2, align = "center" }, {
    ui.label({ text = tr("group_" .. group), fontSize = 11, fontWeight = "semibold", color = status.GROUP_COLOR[group] }),
    ui.label({ text = tostring(count), fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" }),
  })
end

-- Your own requests are grouped by what they ask of you, as soon as one of
-- them carries a status. Issues, reviews and status-less lists stay flat.
local function groupedRows(items)
  local buckets = {}
  for _, name in ipairs(status.GROUP_ORDER) do buckets[name] = {} end
  local any = false
  for _, item in ipairs(items) do
    local group = status.group(item.mergeStatus)
    if group then any = true end
    table.insert(buckets[group or "waiting"], item)
  end
  if not any then return nil end

  local rows = {}
  for _, name in ipairs(status.GROUP_ORDER) do
    local bucket = buckets[name]
    if #bucket > 0 then
      table.insert(rows, sectionHeader(name, #bucket))
      for _, item in ipairs(bucket) do table.insert(rows, itemRow(item)) end
    end
  end
  return rows
end

-- ── Centred blocks: empty tab, blocking states ───────────────

local function centredBlock(glyph, glyphColor, title, body, buttons)
  local children = {
    ui.glyph({ name = glyph, size = 42, color = glyphColor }),
    ui.label({ text = title, fontSize = 16, fontWeight = "bold", textAlign = "center", maxLines = 2 }),
  }
  if body and body ~= "" then
    table.insert(children, ui.label({
      text = body, color = "on_surface_variant", textAlign = "center", maxLines = 4,
    }))
  end
  if buttons and #buttons > 0 then
    table.insert(children, ui.row({ gap = 8, align = "center" }, buttons))
  end
  return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center", padding = 24 }, children)
end

local function emptyTab()
  local glyph = currentTab == "reviews" and "eye-check" or tabGlyph(currentTab)
  local color = currentTab == "reviews" and "primary" or "on_surface_variant"
  return centredBlock(glyph, color,
    tr("empty_" .. currentTab .. "_title"),
    tr("empty_" .. currentTab .. "_body"))
end

local SIGN_IN_COMMAND = {
  gh_auth_missing = "gh auth login",
  gitea_auth_missing = "gt auth login",
}

local function blockingState()
  local current = snapshot.status
  if current == "gitlab_scope_missing" then
    return centredBlock("settings", "on_surface_variant",
      tr("scope_missing_title"), tr("gitlab_scope_missing"), {
        ui.button({ text = tr("open_settings"), glyph = "settings", variant = "primary", onClick = "onOpenSettings" }),
      })
  end
  if SIGN_IN_COMMAND[current] then
    return centredBlock("lock", "on_surface_variant",
      tr(current .. "_title"), tr(current), {
        ui.button({ text = tr("copy_command"), glyph = "copy", variant = "primary", onClick = "onCopySignIn" }),
        ui.button({ text = tr("refresh"), glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
      })
  end
  -- bin_missing, and any status this panel does not know yet.
  return centredBlock(platformGlyph(), "on_surface_variant",
    tr("bin_missing_title", { bin = platformBin() }), tr("bin_missing", { bin = platformBin() }))
end

local function hasBlockingStatus()
  local current = snapshot.status
  return current ~= nil and current ~= "ok"
end

-- ── Banner and footer ────────────────────────────────────────

-- A failed fetch is reported above the list rather than replacing it, so the
-- items already on screen stay readable while the CLI's own message
-- ("Error: not found" for a mistyped repo) explains what went wrong.
local function errorBanner()
  local detail = snapshot.errorDetail
  if snapshot.updatedAt ~= "" then
    detail = detail .. " " .. tr("showing_from", { time = snapshot.updatedAt })
  end
  return ui.row({ gap = 8, padding = 10, radius = 8, fill = "error_container", align = "start" }, {
    ui.glyph({ name = "alert-triangle", size = 16, color = "on_error_container" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("fetch_failed_title", { bin = platformBin() }), fontSize = 12, fontWeight = "bold", color = "on_error_container", maxLines = 2 }),
      ui.label({ text = detail, fontSize = 11, color = "on_error_container", maxLines = 3 }),
    }),
    ui.button({ text = tr("retry"), variant = "outline", controlSize = "sm", onClick = "onRefreshClicked" }),
  })
end

local function footer()
  local failed = snapshot.errorDetail ~= ""
  local text
  if failed then
    text = snapshot.updatedAt ~= ""
      and tr("footer_failed", { time = snapshot.updatedAt })
      or tr("footer_retrying")
  elseif snapshot.updatedAt ~= "" then
    text = tr("footer", { time = snapshot.updatedAt })
  else
    return nil
  end
  return ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = failed and "alert-triangle" or "clock", size = 14, color = failed and "error" or "on_surface_variant" }),
    ui.label({ text = text, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
  })
end

-- ── Tabs ─────────────────────────────────────────────────────

local function requestLabel()
  return platform() == "gitlab" and tr("merge_requests") or tr("pull_requests")
end

local TAB_COUNT = { prs = "prsCount", issues = "issuesCount", reviews = "reviewsCount" }

-- Only the PR/MR label depends on the platform, so labels stay per-tab. The
-- count lives in the label: a button holds text and a glyph, nothing else.
local function tabLabel(tab)
  if tab.id == "prs" then
    return tr("tab_prs", { label = requestLabel(), count = snapshot.prsCount })
  elseif tab.id == "issues" then
    return tr("tab_issues", { count = snapshot.issuesCount })
  elseif tab.id == "deploys" then
    return tr("tab_deploys")
  end
  return tr("tab_reviews", { count = snapshot.reviewsCount })
end

-- Full name of a tab, the tooltip of the icon-only style.
local function tabName(tab)
  if tab.id == "prs" then return requestLabel() end
  return tr("tab_name_" .. tab.id)
end

local TAB_ACTIONS = {
  prs = "onTabPrs",
  issues = "onTabIssues",
  reviews = "onTabReviews",
  deploys = "onTabDeploys",
}

-- The tab_style setting: "simple" (label and count), "full" (the same with the
-- tab glyph) or "compact" (the glyph and the count, the Deploys tab its glyph
-- alone, with the tab name as a tooltip).
local function tabStrip(shown)
  local style = noctalia.getConfig("tab_style") or "simple"
  local iconOnly = style == "compact"
  local strip = {}
  for _, tab in ipairs(shown) do
    local selected = currentTab == tab.id
    local text = tabLabel(tab)
    if iconOnly then
      text = TAB_COUNT[tab.id] and tostring(snapshot[TAB_COUNT[tab.id]]) or nil
    end
    table.insert(strip, ui.button({
      text = text,
      glyph = style ~= "simple" and tab.glyph or nil,
      tooltip = iconOnly and tabName(tab) or nil,
      selected = selected,
      variant = selected and "primary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = TAB_ACTIONS[tab.id],
    }))
  end
  return ui.row({ gap = 4, align = "center" }, strip)
end

-- ── Deploys ──────────────────────────────────────────────────

-- "13 Nov 12:16", with the year when it is not the current one. The date goes
-- through os.date: noctalia.formatTime leaves %d and %b as they are. The time
-- keeps noctalia.timeFormat so it follows the user's 12/24 h choice.
local function deployTime(epoch)
  if not epoch then return "" end
  local datePattern = os.date("%Y", epoch) == os.date("%Y") and "%d %b" or "%d %b %Y"
  return os.date(datePattern, epoch) .. " " .. noctalia.formatTime(noctalia.timeFormat(), epoch)
end

local function deployRow(env)
  local accent = env.isTag and "primary" or "secondary"
  return ui.row({ gap = 10, align = "center" }, {
    ui.column({ width = 28, height = 28, radius = 8, align = "center", justify = "center", fill = accent .. "/0.18" }, {
      ui.glyph({ name = env.isTag and "tag" or "git-branch", size = 15, color = accent }),
    }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = env.name, fontSize = 12, fontWeight = "bold", maxLines = 1 }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = deployTime(env.at), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
      }),
      ui.label({ text = env.version, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
  })
end

-- deploy_hidden_envs: exact names or prefixes ending in `*`, matched without
-- case, like the branch badge patterns. Read at render time, so a change in
-- settings shows at once.
local function hiddenEnvironment(name)
  local patterns = noctalia.getConfig("deploy_hidden_envs")
  if type(patterns) ~= "table" then return false end
  local lower = name:lower()
  for _, pattern in ipairs(patterns) do
    if type(pattern) == "string" then
      local trimmed = noctalia.string.trim(pattern):lower()
      if trimmed ~= "" and matchesBranch(lower, trimmed) then return true end
    end
  end
  return false
end

local function deployCards()
  local cards = {}
  for _, card in ipairs(snapshot.deploys) do
    local envs = {}
    if type(card) == "table" and type(card.environments) == "table" then
      for _, env in ipairs(card.environments) do
        if not hiddenEnvironment(env.name or "") then table.insert(envs, env) end
      end
    end
    if #envs > 0 then
      local rows = {
        ui.row({ tooltip = card.repo }, {
          ui.label({ text = card.repo:match("([^/]+)$") or card.repo, fontWeight = "bold", maxLines = 1 }),
        }),
      }
      for _, env in ipairs(envs) do table.insert(rows, deployRow(env)) end
      table.insert(cards, ui.column({
        gap = 8, padding = 10, radius = 8,
        border = "outline_variant", borderWidth = 1, fill = "surface_container",
      }, rows))
    end
  end
  if #cards == 0 then
    return { centredBlock("rocket", "on_surface_variant", tr("empty_deploys_title"), tr("empty_deploys_body")) }
  end
  return { ui.scroll({ flexGrow = 1, gap = 8, align = "stretch", justify = "start" }, cards) }
end

local function listBody()
  if currentTab == "deploys" then return deployCards() end
  local items = itemsForTab()
  if #items == 0 then return { emptyTab() } end
  local rows = currentTab == "prs" and groupedRows(items) or nil
  if not rows then
    rows = {}
    for _, item in ipairs(items) do table.insert(rows, itemRow(item)) end
  end
  return { ui.scroll({ flexGrow = 1, gap = 8, align = "stretch", justify = "start" }, rows) }
end

local function switchTab(tab)
  currentTab = tab
  hoveredKey = nil
  render()
end

-- ── Render ───────────────────────────────────────────────────

render = function()
  local blocked = hasBlockingStatus()
  local shown = visibleTabs()
  local active = resolveTab(shown)
  if active then currentTab = active.id end

  local children = { header(not blocked) }
  if blocked then
    table.insert(children, blockingState())
  elseif not active then
    -- Every tab turned off: nothing to select, so say so rather than render an
    -- empty strip above an empty list.
    table.insert(children, centredBlock("eye-off", "on_surface_variant", tr("no_tabs_title"), tr("no_tabs")))
  else
    table.insert(children, tabStrip(shown))
    if snapshot.errorDetail ~= "" then table.insert(children, errorBanner()) end
    for _, node in ipairs(listBody()) do table.insert(children, node) end
    local foot = footer()
    if foot then table.insert(children, foot) end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
end

function onTabPrs() switchTab("prs") end
function onTabIssues() switchTab("issues") end
function onTabReviews() switchTab("reviews") end
function onTabDeploys() switchTab("deploys") end

function onCloseClicked() panel.close() end

function onOpenSettings() noctalia.openSettings() end

function onCopySignIn()
  local command = SIGN_IN_COMMAND[snapshot.status]
  if command then noctalia.copyToClipboard(command, "text/plain") end
end

function onRefreshClicked()
  noctalia.runAsync({"noctalia", "msg", "plugin", "tphilippot/git_companion:service", "all", "refresh"})
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
noctalia.state.watch("error_detail", function(value) snapshot.errorDetail = value or ""; render() end)
noctalia.state.watch("deploys", function(value) snapshot.deploys = value or {}; render() end)

-- Periodically re-render to pick up setting changes (like platform)
noctalia.setUpdateInterval(5000)
function update() render() end

-- Initial render
render()
