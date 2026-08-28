--!nonstrict
-- [[panel]] entry: pull requests grouped by repository, rendered from the
-- shared state the fetch service publishes. Each pull request uses two lines so
-- long titles cannot collide with the author or status badges; clicking the
-- title opens the PR in the browser. The header carries the last-refresh time,
-- an icon-only refresh action, and a close button.
--
local MAX_ROWS = 80
local CENTERED_LAYOUT = { flexGrow = 1, align = "center", justify = "center", gap = 8 }

local CI_APPEARANCE = {
  SUCCESS = { glyph = "circle-check", color = "primary" },
  FAILURE = { glyph = "circle-x", color = "error" },
  ERROR = { glyph = "alert-circle", color = "error" },
  PENDING = { glyph = "clock", color = "tertiary" },
  EXPECTED = { glyph = "clock", color = "tertiary" },
}
local CI_NONE = { glyph = "circle-dashed", color = "on_surface_variant" }

local REVIEW_BADGE = {
  APPROVED = { key = "panel.review.approved", color = "primary" },
  CHANGES_REQUESTED = { key = "panel.review.changes_requested", color = "error" },
  REVIEW_REQUIRED = { key = "panel.review.review_required", color = "tertiary" },
}

local prs = {}
local fetchStatus = "loading"
local errorMessage = ""
local lastUpdatedText = ""
local rulesCount = nil
local overflowCount = 0
local isOpen = false
local collapsedRepos = {}

local render

local tr = noctalia.tr

local function syncFromState()
  prs = noctalia.state.get("prs")
  fetchStatus = noctalia.state.get("fetch_status")
  errorMessage = noctalia.state.get("error_message")
  lastUpdatedText = noctalia.state.get("last_updated_text")
  rulesCount = noctalia.state.get("rules_count")
  overflowCount = noctalia.state.get("overflow_count")

  local activeRepos = {}
  for _, pr in ipairs(prs) do
    activeRepos[pr.repo] = true
  end
  for repo, _ in pairs(collapsedRepos) do
    if not activeRepos[repo] then
      collapsedRepos[repo] = nil
    end
  end
end

local function badge(text, color, fillAlpha)
  return ui.row({
    fill = `{color}/{fillAlpha}`,
    border = color .. "/0.24",
    borderWidth = 1,
    radius = 8,
    paddingH = 7,
    paddingV = 2,
    align = "center",
  }, {
    ui.label({ text = text, fontSize = 11, fontWeight = "medium", color = color }),
  })
end

local function prRow(pr)
  local ci = CI_APPEARANCE[pr.ci] or CI_NONE

  local statusChildren = {
    ui.glyph({ name = "user", size = 13, color = "on_surface_variant" }),
    ui.label({
      text = pr.author,
      fontSize = 11,
      color = "on_surface_variant",
      flexGrow = 1,
      maxLines = 1,
    }),
    ui.glyph({ name = ci.glyph, size = 16, color = ci.color }),
  }
  if pr.isDraft then
    table.insert(statusChildren, badge(tr("panel.draft"), "on_surface_variant", "0.15"))
  end
  local review = REVIEW_BADGE[pr.reviewDecision]
  if review then
    table.insert(statusChildren, badge(tr(review.key), review.color, "0.2"))
  end

  return ui.column({ key = pr.url, gap = 4, paddingH = 10, paddingV = 7, align = "stretch" }, {
    ui.row({ gap = 9, align = "center" }, {
      ui.glyph({ name = "git-pull-request", size = 15, color = "primary" }),
      ui.button({
        key = `open:{pr.url}`,
        text = `#{pr.number} {pr.title}`,
        variant = "ghost",
        contentAlign = "start",
        flexGrow = 1,
        onClick = function()
          local url = "'" .. pr.url:gsub("'", "'\\''") .. "'"
          noctalia.runAsync("xdg-open " .. url)
        end,
      }),
    }),
    ui.row({ gap = 7, align = "center", paddingH = 24 }, statusChildren),
  })
end

-- Group by repo and order groups by their newest PR activity. prs is globally
-- sorted by updatedAt desc, so appending in order also keeps each group recent.
local function groupedRows()
  local byRepo = {}
  local repoNames = {}
  for _, pr in ipairs(prs) do
    if byRepo[pr.repo] == nil then
      byRepo[pr.repo] = {}
      table.insert(repoNames, pr.repo)
    end
    table.insert(byRepo[pr.repo], pr)
  end

  local rows = {}
  local shown = 0
  local hiddenByCollapse = 0
  for _, repo in ipairs(repoNames) do
    if shown >= MAX_ROWS then
      break
    end
    local collapsed = collapsedRepos[repo]
    -- Capture this iteration's repository for the click callback.
    local repoName = repo
    local groupChildren = {
      ui.row({
        key = `repo:{repo}`,
        gap = 8,
        align = "center",
        paddingH = 11,
        paddingV = 8,
        fill = "surface_variant/0.24",
        onClick = function()
          collapsedRepos[repoName] = not collapsedRepos[repoName]
          render()
        end,
      }, {
        ui.glyph({ name = collapsed and "chevron-right" or "chevron-down", size = 15, color = "primary" }),
        ui.glyph({ name = "books", size = 16, color = "primary" }),
        ui.label({ text = repo, fontSize = 13, fontWeight = "bold", color = "primary", flexGrow = 1 }),
        badge(tostring(#byRepo[repo]), "primary", "0.14"),
      }),
    }
    if collapsed then
      hiddenByCollapse += #byRepo[repo]
    else
      for _, pr in ipairs(byRepo[repo]) do
        if shown >= MAX_ROWS then
          break
        end
        table.insert(groupChildren, ui.separator({ thickness = 1, color = "outline/0.28", spacing = 0 }))
        table.insert(groupChildren, prRow(pr))
        shown += 1
      end
    end
    table.insert(rows, ui.column({
      key = `repo-group:{repo}`,
      fill = "surface_variant/0.10",
      border = "outline/0.40",
      borderWidth = 1,
      radius = 11,
      align = "stretch",
    }, groupChildren))
  end

  local omitted = #prs - shown - hiddenByCollapse
  if omitted > 0 then
    table.insert(rows, ui.label({
      key = "more_rows",
      text = tr("panel.more_rows", { count = omitted }),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end
  if overflowCount > 0 then
    table.insert(rows, ui.label({
      key = "truncated_note",
      text = tr("panel.truncated_note", { count = overflowCount }),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end
  return rows
end

local function body()
  if #prs == 0 then
    if fetchStatus == "loading" then
      return ui.column(CENTERED_LAYOUT, {
        ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }),
      })
    end
    if fetchStatus == "error" then
      return ui.column(CENTERED_LAYOUT, {
        ui.label({ text = tr("panel.error_title"), fontWeight = "bold", color = "error" }),
        ui.label({ text = errorMessage, color = "on_surface_variant", maxLines = 4, textAlign = "center" }),
        ui.button({
          text = tr("panel.retry"),
          variant = "primary",
          onClick = function()
            noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
          end,
        }),
      })
    end
    local emptyKey = rulesCount == 0 and "panel.empty_no_rules" or "panel.empty"
    return ui.column(CENTERED_LAYOUT, {
      ui.label({ text = tr(emptyKey), color = "on_surface_variant", textAlign = "center" }),
    })
  end
  return ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, groupedRows())
end

render = function()
  if not isOpen then
    return
  end

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
        ui.glyph({ name = "brand-github", size = 20, color = "primary" }),
        ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        badge(tostring(#prs), "primary", "0.14"),
      }),
      ui.label({
        text = lastUpdatedText ~= "" and tr("panel.updated_at", { time = lastUpdatedText }) or "",
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        enabled = fetchStatus ~= "loading",
        onClick = function()
          noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
        end,
      }),
      ui.button({ glyph = "close", onClick = panel.close }),
    }),
  }

  -- Partial rule failure: data is fresh but incomplete — warn without blocking.
  if errorMessage ~= "" and fetchStatus ~= "error" then
    table.insert(children, ui.label({ text = errorMessage, fontSize = 11, color = "error", maxLines = 2 }))
  end

  table.insert(children, body())

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

noctalia.state.watch("fetch_status", function()
  syncFromState()
  render()
end)

function onOpen(_context)
  syncFromState()
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end
