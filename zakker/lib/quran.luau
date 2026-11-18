-- api.alquran.cloud client.
-- Used by the service for Quran-verse turns; offline pool stays in lib/reminders.luau.

local M = {}

M.BASE = "https://api.alquran.cloud/v1"
M.AYAHS_COUNT = 6236

local function clean(s)
  if type(s) ~= "string" then
    return ""
  end
  -- api prefixes text with a BOM (U+FEFF)
  if s:sub(1, 3) == "\239\187\191" then
    s = s:sub(4)
  end
  return s
end

function M.ayahUrl(number, edition)
  return ("%s/ayah/%d/%s"):format(M.BASE, number, edition)
end

---@param data table raw `data` object from the api
---@param fallback_edition string
---@return table AyahData
function M.normalize(data, fallback_edition)
  local surah = data.surah or {}
  local audio = ""
  if type(data.audio) == "string" and data.audio ~= "" then
    audio = data.audio
  elseif type(data.audioSecondary) == "string" then
    audio = data.audioSecondary
  elseif type(data.audioSecondary) == "table" and type(data.audioSecondary[1]) == "string" then
    audio = data.audioSecondary[1]
  end
  return {
    number = data.number,
    text = clean(data.text),
    surah_name = clean(surah.name or ""),
    surah_english = surah.englishName or "",
    number_in_surah = data.numberInSurah,
    audio = audio,
    edition = (data.edition and data.edition.identifier) or fallback_edition,
  }
end

---@param a table AyahData
---@return string reference line
function M.header(a)
  return ("#%d • %s (%s) • ayah %d"):format(
    a.number,
    a.surah_english,
    a.surah_name,
    a.number_in_surah or 0
  )
end

return M
