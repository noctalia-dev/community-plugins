-- Git Companion Bar Widget
-- Shows the platform icon and counts of issues/PRs from the service state.
-- This is purely an indicator; the full lists are displayed in the panel.

local function tr(key, args) return noctalia.tr("widget." .. key, args) end

local function getPlatformIcon()
  local platform = noctalia.getConfig("platform")
  if platform == "gitlab" then
    return "brand-gitlab"
  elseif platform == "github" then
    return "brand-github"
  end
  return "brand-git" -- Fallback
end

local function render()
  local issuesCount = noctalia.state.get("issues_count") or 0
  local prsCount = noctalia.state.get("prs_count") or 0
  local reviewsCount = noctalia.state.get("reviews_count") or 0
  local platform = noctalia.getConfig("platform")

  -- show_reviews is the master switch, so a count_reviews_with_prs left on
  -- cannot fold in a feature the user has turned off. The tooltip below keeps
  -- the numbers separate either way.
  local barPrsCount = prsCount
  if noctalia.getConfig("show_reviews") ~= false and noctalia.getConfig("count_reviews_with_prs") == true then
    barPrsCount = prsCount + reviewsCount
  end
  local requestLabel = platform == "gitlab" and tr("mrs") or tr("prs")
  local mode = noctalia.getConfig("bar_display_mode") or "both"

  -- Format text based on display mode
  local text = ""
  if mode == "both" then
    if issuesCount > 0 or barPrsCount > 0 then
      text = string.format("%d/%d", issuesCount, barPrsCount)
    end
  elseif mode == "prs" then
    if barPrsCount > 0 then text = tostring(barPrsCount) end
  elseif mode == "issues" then
    if issuesCount > 0 then text = tostring(issuesCount) end
  end
  -- mode == "none" leaves text as ""

  barWidget.setGlyph(getPlatformIcon())
  barWidget.setText(text)

  local tooltip = tr("tooltip", { issues = issuesCount, prs = prsCount, label = requestLabel, reviews = reviewsCount })
  barWidget.setTooltip(tooltip)
end

-- Initial render
render()

-- Watch for state changes from the service
noctalia.state.watch("issues_count", render)
noctalia.state.watch("prs_count", render)
noctalia.state.watch("reviews_count", render)

function onClick()
  noctalia.togglePanel("tphilippot/git_companion:main")
end
