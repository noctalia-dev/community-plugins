--!nonstrict
-- Launcher provider: lists Remmina connection profiles under /rmn and opens
-- the selected one with `remmina -c`.

local shared = require("./shared.luau")

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function maxResults()
  local n = noctalia.getConfig("max_results")
  return (type(n) == "number" and n > 0) and math.floor(n) or 30
end

local function showGroup()
  return noctalia.getConfig("show_group") ~= false
end

local function statusRow(title, subtitle, glyph)
  return { id = "", title = title, subtitle = subtitle, glyph = glyph }
end

-- "Group · user@host · RDP", skipping whichever parts are missing.
local function subtitleFor(profile)
  local parts = {}
  if showGroup() and profile.group ~= "" then
    table.insert(parts, profile.group)
  end
  local target = shared.targetOf(profile)
  if target ~= "" then
    table.insert(parts, target)
  end
  if profile.protocol ~= "" then
    table.insert(parts, profile.protocol)
  end
  return table.concat(parts, " · ")
end

local function scoreFor(filter, profile)
  for _, text in ipairs({ profile.name, profile.group, profile.server, profile.protocol }) do
    if text ~= "" then
      local score = noctalia.fuzzyScore(filter, text)
      if score then
        return score
      end
    end
  end
  return nil
end

-- Enough to outrank any fuzzy score, so a pinned profile stays on top however
-- the host orders the results; the bonus is constant, so pinned rows keep
-- their relative fuzzy ranking among themselves.
local PIN_SCORE_BONUS = 1e6

local function appendRows(rows, list, filter, limit, pinned)
  for _, profile in ipairs(list) do
    if #rows >= limit then
      return
    end
    local score = filter == "" and nil or scoreFor(filter, profile)
    if filter == "" or score ~= nil then
      if pinned and score ~= nil then
        score = score + PIN_SCORE_BONUS
      end
      table.insert(rows, {
        id = profile.path,
        title = profile.name,
        subtitle = subtitleFor(profile),
        glyph = shared.glyphFor(profile.protocol),
        badge = pinned and "★" or nil,
        score = score,
      })
    end
  end
end

-- Pinned profiles are emitted first and left out of the main pass, so they sit
-- at the top of an unfiltered list and never appear twice.
local function makeRows(list, filter)
  local rows = {}
  local limit = maxResults()
  local pinned, rest = shared.partitionPinned(list)
  appendRows(rows, pinned, filter, limit, true)
  appendRows(rows, rest, filter, limit, false)
  return rows
end

function onQuery(query)
  local filter = trim(query)

  if not noctalia.commandExists("remmina") then
    launcher.setResults(query, {
      statusRow(noctalia.tr("err-no-remmina"), noctalia.tr("err-no-remmina-subtitle"), "alert-triangle"),
    })
    return
  end

  local list, err = shared.profiles(noctalia.getConfig("profiles_path"))
  if list == nil then
    launcher.setResults(query, {
      statusRow(noctalia.tr("profiles-missing"), err ~= nil and err or shared.profilesPath(noctalia.getConfig("profiles_path")), "file-x"),
    })
    return
  end

  local rows = makeRows(list, filter)
  if #rows == 0 then
    launcher.setResults(query, {
      statusRow(
        noctalia.tr("no-profiles-found"),
        filter ~= "" and noctalia.tr("filter-empty", { filter = filter }) or noctalia.tr("profiles-empty"),
        "screen-share"
      ),
    })
    return
  end

  launcher.setResults(query, rows)
end

function onActivate(id)
  if id == "" then
    return
  end
  if not shared.open(id) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("err-launch"))
  end
end
