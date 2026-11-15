--!nonstrict
-- Pure launcher view-model: (snapshot, query, fuzzy, tr) -> { LauncherResult }.
-- Pins first, then recents. A non-empty query keeps entries whose title matches, ranked
-- above those that match only on the path, best score first inside each group. At most
-- MAX results. A result's id is the entry key; an empty id marks an info row.
-- `fuzzy` is noctalia.fuzzyScore, injected so this module stays pure.

local M = {}

local MAX = 50

local function info(tr, key)
  return { { id = "", title = tr(key), glyph = "info-circle" } }
end

local function iconFor(snapshot)
  local flavor = snapshot.flavor
  if type(flavor) == "table" and type(flavor.iconPath) == "string" and flavor.iconPath ~= "" then
    return { icon = flavor.iconPath }
  end
  return { glyph = "brand-vscode" }
end

-- Returns tier (1 title, 2 path) and score, or nil when the entry does not match.
local function match(fuzzy, query, e)
  local s = fuzzy(query, e.title or "")
  if s ~= nil then
    return 1, s
  end
  s = fuzzy(query, e.path or e.subtitle or "")
  if s ~= nil then
    return 2, s
  end
  return nil
end

function M.results(snapshot, query, fuzzy, tr)
  if type(snapshot) ~= "table" then
    return info(tr, "launcher.loading")
  end
  if snapshot.flavor == nil then
    return info(tr, "launcher.no_flavor")
  end
  local pinned = snapshot.pinned or {}
  local recent = snapshot.recent or {}
  if #pinned == 0 and #recent == 0 then
    return info(tr, snapshot.loading and "launcher.loading" or "launcher.empty")
  end

  query = query or ""
  local picked = {}
  local order = 0
  local function add(list, group)
    for _, e in ipairs(list) do
      order = order + 1
      local tier, score = 1, 0
      if query ~= "" then
        tier, score = match(fuzzy, query, e)
      end
      if tier ~= nil then
        picked[#picked + 1] = { e = e, group = group, tier = tier, score = score, order = order }
      end
    end
  end
  add(pinned, 1)
  add(recent, 2)

  table.sort(picked, function(a, b)
    if a.group ~= b.group then
      return a.group < b.group
    end
    if a.tier ~= b.tier then
      return a.tier < b.tier
    end
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.order < b.order
  end)

  local icon = iconFor(snapshot)
  local out = {}
  for i, p in ipairs(picked) do
    if i > MAX then
      break
    end
    out[i] = {
      id = p.e.key,
      title = p.e.title,
      subtitle = p.e.subtitle,
      icon = icon.icon,
      glyph = icon.glyph,
      badge = p.e.missing and tr("launcher.missing") or (p.group == 1 and tr("launcher.pinned") or nil),
      score = MAX + 1 - i,
    }
  end
  return out
end

return M
