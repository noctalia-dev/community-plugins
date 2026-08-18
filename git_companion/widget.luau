-- Git Companion Bar Widget
-- Shows the platform icon and counts of issues/PRs from the service state.
-- This is purely an indicator; the data is displayed on the Desktop Widget.

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
  local platform = noctalia.getConfig("platform")
  local requestLabel = platform == "gitlab" and tr("mrs") or tr("prs")
  local mode = noctalia.getConfig("bar_display_mode") or "both"

  -- Format text based on display mode
  local text = ""
  if mode == "both" then
    if issuesCount > 0 or prsCount > 0 then
      text = string.format("%d/%d", issuesCount, prsCount)
    end
  elseif mode == "prs" then
    if prsCount > 0 then text = tostring(prsCount) end
  elseif mode == "issues" then
    if issuesCount > 0 then text = tostring(issuesCount) end
  end
  -- mode == "none" leaves text as ""

  barWidget.setGlyph(getPlatformIcon())
  barWidget.setText(text)

  local tooltip = tr("tooltip", { issues = issuesCount, prs = prsCount, label = requestLabel })
  barWidget.setTooltip(tooltip)
end

-- Initial render
render()

-- Watch for state changes from the service
noctalia.state.watch("issues_count", render)
noctalia.state.watch("prs_count", render)

function onClick()
  noctalia.togglePanel("tphilippot/git_companion:main")
end
