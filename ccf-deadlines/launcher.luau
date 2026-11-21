--!nonstrict
-- CCF Deadlines launcher provider, under the `/ddl` prefix.
--
-- Empty query lists the next deadlines; any text is fuzzy-matched against
-- conference name, description and category. Activating a result opens the
-- conference site.

local Common = require("./lib/common.luau")

local MAX_RESULTS = 30
local byId = {}

local function result(item, now, score)
  local star = if item.starred then "★ " else ""
  local kind = if item.kind == "abstract" then ` · {noctalia.tr("kind.abstract")}` else ""
  local comment = if type(item.comment) == "string" and item.comment ~= "" then ` · {item.comment}` else ""
  byId[item.id] = item
  return {
    id = item.id,
    title = `{star}{Common.itemTitle(item)} — {Common.countdown(item.due - now)}`,
    subtitle = `CCF {item.ccf} · {item.sub} · {noctalia.formatTime("%Y-%m-%d %H:%M", item.due)}{kind}{comment}`,
    glyph = if item.starred then "star-filled" else "calendar-due",
    score = score,
  }
end

function onQuery(query)
  byId = {}
  local state = noctalia.state.get(Common.STATE_KEY)
  local items = type(state) == "table" and state.items or {}
  local now = Common.nowSec()
  local results = {}
  local trimmed = noctalia.string.trim(query or "")

  for _, item in ipairs(items) do
    if item.due > now then
      if trimmed == "" then
        table.insert(results, result(item, now, MAX_RESULTS - #results))
        if #results >= MAX_RESULTS then
          break
        end
      else
        local score = noctalia.fuzzyScore(trimmed, item.title)
          or noctalia.fuzzyScore(trimmed, `{item.title} {item.description} {item.sub}`)
        if score ~= nil then
          table.insert(results, result(item, now, score))
        end
      end
    end
  end
  launcher.setResults(query, results)
end

function onActivate(id)
  local item = byId[id]
  if item ~= nil then
    Common.openUrl(item.link)
  end
end
