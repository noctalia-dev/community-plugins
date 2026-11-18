--!nonstrict
-- Mathsym launcher provider.
--
-- Type `/sym` followed by a LaTeX command name (`\alpha`, `leq`, `mathbb{R}`) or a
-- Lean 4 VS Code abbreviation (`Rightarrow`, `nat`, `<=`) to find the character;
-- a description ("integral") or a code point (`U+2264`, `8804`); pasting a character finds
-- its entry. Enter copies the character to the clipboard (and optionally types it).
--
-- Script callbacks only get a 25 ms CPU budget, which parsing the ~3000-row
-- data.tsv blows through. So the search runs in search.sh (fzf) via noctalia.runAsync
-- (the same approach as the community file-search plugin) and this script only
-- relays its tab-separated rows to the launcher.

local NOTIFY = noctalia.getConfig("notify_on_copy")
NOTIFY = if type(NOTIFY) == "boolean" then NOTIFY else true

local PASTE = noctalia.getConfig("paste_after_copy")
PASTE = if type(PASTE) == "boolean" then PASTE else false
local PASTE_DELAY_MS = noctalia.getConfig("paste_delay_ms")
PASTE_DELAY_MS = if type(PASTE_DELAY_MS) == "number" then PASTE_DELAY_MS else 150

-- Plugin providers have no native auto-paste hook (the built-in emoji provider uses one),
-- and the launcher only hands focus back after onActivate returns. So wait a moment in a
-- helper process, then type the character into the focused window with wtype.
local function pasteAfterClose(ch)
  local script = 'sleep "$0"; exec wtype -- "$1"'
  local argv = { "sh", "-c", script, string.format("%.3f", PASTE_DELAY_MS / 1000), ch }
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("paste failed: " .. (result.stderr or ""))
    end
  end, 5000)
end

local function hint(query, title, subtitle, glyph)
  launcher.setResults(query, { { id = "", title = title, subtitle = subtitle, glyph = glyph } })
end

-- Title and subtitle for an empty result. Numeric-looking queries get a specific hint, since
-- "no matches" for `22` would hide that it was read as a code point and found nothing.
local function noMatchHint(text)
  local compact = (text:gsub("%s", "")):lower()
  local dec = compact:match("^%d+$")
  if dec and #dec <= 7 then
    local code = string.format("U+%04X", tonumber(dec) :: number)
    return noctalia.tr("hint.unknown_decimal_title", { dec = dec }),
      noctalia.tr("hint.unknown_decimal_subtitle", { dec = dec, code = code })
  end
  local hex = compact:match("^u%+(%x+)$") or compact:match("^0x(%x+)$") or compact:match("^\\u(%x+)$")
  if hex then
    return noctalia.tr("hint.unknown_hex_title", { hex = hex:upper() }),
      noctalia.tr("hint.unknown_hex_subtitle")
  end
  if compact:match("^%x+$") then
    return noctalia.tr("hint.no_matches_title"),
      noctalia.tr("hint.no_matches_hex_subtitle", { code = compact:upper() })
  end
  return noctalia.tr("hint.no_matches_title"), noctalia.tr("hint.no_matches_subtitle")
end

-- `query` is the launcher text after the `/sym` prefix.
function onQuery(query)
  local text = noctalia.string.trim(query)
  if text == "" then
    hint(
      query,
      noctalia.tr("hint.empty_title"),
      noctalia.tr("hint.empty_subtitle"),
      "math-symbols"
    )
    return
  end

  local dir = noctalia.pluginDir()
  if not dir then
    hint(query, noctalia.tr("hint.search_failed_title"), noctalia.tr("hint.no_dir_subtitle"), "alert-triangle")
    return
  end
  local ok = noctalia.runAsync({ "sh", dir .. "/search.sh", dir, text }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      noctalia.log(result.stderr)
      hint(query, noctalia.tr("hint.search_failed_title"), noctalia.tr("hint.search_failed_subtitle"), "alert-triangle")
      return
    end
    local rows = {}
    for line in result.stdout:gmatch("[^\n]+") do
      local rank, ch, title, subtitle = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t(.*)$")
      if rank then
        table.insert(rows, {
          -- The launcher keeps the highlight on the same result id across result updates, so a
          -- stale highlight from an earlier keystroke would survive reordering. A per-query
          -- suffix makes ids new each query, so the highlight resets to the top row.
          id = "u:" .. ch .. "\t" .. query,
          title = title,
          subtitle = subtitle,
          glyph = "math-symbols",
          score = 1000 - (tonumber(rank) :: number), -- search.sh already ranked them
        })
      end
    end
    if #rows == 0 then
      local title, subtitle = noMatchHint(text)
      hint(query, title, subtitle, "mood-empty")
      return
    end
    launcher.setResults(query, rows)
  end, 5000)
  if not ok then
    hint(query, noctalia.tr("hint.search_failed_title"), noctalia.tr("hint.no_spawn_subtitle"), "alert-triangle")
  end
end

function onActivate(id)
  -- The payload is an arbitrary character followed by a tab and the query (see onQuery).
  if id:sub(1, 2) ~= "u:" then
    return
  end
  local ch = id:sub(3):match("^[^\t]*")
  if ch == "" then
    return
  end
  noctalia.copyToClipboard(ch, "text/plain")
  if NOTIFY then
    noctalia.notify(noctalia.tr("notify.copied_title"), noctalia.tr("notify.copied_body", { char = ch }))
  end
  if PASTE then
    pasteAfterClose(ch)
  end
end
