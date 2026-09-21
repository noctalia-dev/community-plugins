--!nonstrict
-- Launcher provider for the example plugin.
--
-- Type this provider's prefix (default `/ex`) in the launcher. The top level lists
-- categories; pressing Enter on one calls launcher.setQuery() to open it WITHOUT
-- closing the launcher. Pressing Enter on a leaf item copies it and lets the
-- launcher close normally.
--
-- launcher.setQuery(text) sets the input to this provider's prefix followed by
-- `text`, so the panel stays in this provider whatever prefix the user configured
-- (the plugin never hardcodes it). Called synchronously from onActivate it keeps
-- the panel open and updates the query, the basis for autocomplete and stepping
-- through nested results.

local CATEGORIES = {
  fruits = { "Apple", "Apricot", "Banana", "Cherry" },
  animals = { "Aardvark", "Bear", "Cat", "Dolphin" },
  colors = { "Amber", "Azure", "Crimson", "Teal" },
}

-- Top level: one row per category. Activating a row opens it.
local function categoryRows()
  local rows = {}
  for name in CATEGORIES do
    table.insert(rows, {
      id = "category:" .. name,
      title = name,
      subtitle = "Browse " .. name .. " - press Enter to open",
      glyph = "folder",
    })
  end
  return rows
end

-- Inside a category: the items matching the text typed after the category name.
local function itemRows(category, filter)
  local rows = {}
  for _, item in CATEGORIES[category] do
    if filter == "" or item:lower():find(filter:lower(), 1, true) then
      table.insert(rows, {
        id = item,
        title = item,
        subtitle = category .. " - press Enter to copy",
        glyph = "tag",
      })
    end
  end
  if #rows == 0 then
    rows[1] = { id = "", title = "No matches", subtitle = category, glyph = "mood-empty" }
  end
  return rows
end

-- `query` is the launcher text after this provider's prefix, leading space trimmed.
function onQuery(query)
  local text = noctalia.string.trim(query)
  local category, rest = text:match("^(%S+)%s*(.*)$")
  if category and CATEGORIES[category] then
    launcher.setResults(query, itemRows(category, noctalia.string.trim(rest)))
  else
    launcher.setResults(query, categoryRows())
  end
end

function onActivate(id)
  local category = id:match("^category:(.+)$")
  if category then
    -- Open the category: set our query to it (trailing space so the user can keep
    -- typing a filter) and stay open. The host adds our prefix.
    launcher.setQuery(category .. " ")
    return
  end
  if id ~= "" then
    noctalia.copyToClipboard(id, "text/plain")
    noctalia.notify("Example", id .. " copied to clipboard")
  end
end
