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

local function emptyMessage()
  return tr("no_items")
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
    ui.row({ gap = 10, align = "start" }, {
      ui.glyph({ name = itemGlyph(), size = 16, color = hovered and "on_tertiary" or "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = item.title or tr("untitled"), color = hovered and "on_tertiary" or "on_surface", fontWeight = "bold", maxLines = 2 }),
        ui.label({ text = item.ref or "", fontSize = 11, color = hovered and "on_tertiary" or "on_surface_variant", maxLines = 1 }),
      }),
    }),
  })
end

local function itemList()
  local items = itemsForTab()
  if #items == 0 then
    return {
      ui.column({ align = "center", padding = 24 }, {
        ui.glyph({ name = itemGlyph(), size = 42, color = "primary" }),
        ui.label({ text = emptyMessage(), color = "on_surface", textAlign = "center" }),
      }),
    }
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
  local updatedAt = snapshot.updatedAt

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    -- Header
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = platform == "gitlab" and "brand-gitlab" or "brand-github", size = 24, color = "primary" }),
      ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),
    -- Tabs (mini-docker style: selected = primary, else ghost) + last-updated time
    ui.row({ gap = 4, align = "center" }, {
      tabButton(tr("tab_prs", { label = requestLabel, count = snapshot.prsCount }), "prs", "onTabPrs"),
      tabButton(tr("tab_issues", { count = snapshot.issuesCount }), "issues", "onTabIssues"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = updatedAt ~= "" and updatedAt or tr("last_update_placeholder"),
        color = "on_surface_variant",
        fontSize = 11,
      }),
    }),
    -- List
    ui.scroll({ flexGrow = 1, gap = 8, align = "stretch", justify = "start" }, itemList()),
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

-- Periodically re-render to pick up setting changes (like platform)
noctalia.setUpdateInterval(5000)
function update() render() end

-- Initial render
render()
