--!nonstrict
-- Presentation helpers: numerals, calendar names, and the widget's format
-- template.
--
-- Month and weekday names are calendar data, identical in every UI language,
-- so they live here rather than in translations/.

local M = {}

-- Extended Arabic-Indic digits, U+06F0..U+06F9. NOT the Arabic-Indic U+0660
-- range, which renders wrong for a Persian reader.
local PERSIAN_DIGITS = { "۰", "۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹" }

local MONTHS_FA = {
  "فروردین",
  "اردیبهشت",
  "خرداد",
  "تیر",
  "مرداد",
  "شهریور",
  "مهر",
  "آبان",
  "آذر",
  "دی",
  "بهمن",
  "اسفند",
}

local MONTHS_LATIN = {
  "Farvardin",
  "Ordibehesht",
  "Khordad",
  "Tir",
  "Mordad",
  "Shahrivar",
  "Mehr",
  "Aban",
  "Azar",
  "Dey",
  "Bahman",
  "Esfand",
}

local GREGORIAN_FA = {
  "ژانویه", "فوریه", "مارس", "آوریل", "مه", "ژوئن",
  "ژوئیه", "اوت", "سپتامبر", "اکتبر", "نوامبر", "دسامبر",
}

local GREGORIAN_LATIN = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
}

local HIJRI_FA = {
  "محرم", "صفر", "ربیع‌الاول", "ربیع‌الثانی", "جمادی‌الاول", "جمادی‌الثانی",
  "رجب", "شعبان", "رمضان", "شوال", "ذی‌القعده", "ذی‌الحجه",
}

local HIJRI_LATIN = {
  "Muharram", "Safar", "Rabi al-Awwal", "Rabi al-Thani",
  "Jumada al-Awwal", "Jumada al-Thani", "Rajab", "Shaban",
  "Ramadan", "Shawwal", "Dhu al-Qidah", "Dhu al-Hijjah",
}

-- Index 1 is Saturday, matching dayOfWeek() + 1.
local WEEKDAYS_FA = { "شنبه", "یکشنبه", "دوشنبه", "سه‌شنبه", "چهارشنبه", "پنجشنبه", "جمعه" }
local WEEKDAYS_FA_SHORT = { "ش", "ی", "د", "س", "چ", "پ", "ج" }
local WEEKDAYS_LATIN = {
  "Shanbeh",
  "Yekshanbeh",
  "Doshanbeh",
  "Seshanbeh",
  "Chaharshanbeh",
  "Panjshanbeh",
  "Jomeh",
}
local WEEKDAYS_LATIN_SHORT = { "Sa", "Su", "Mo", "Tu", "We", "Th", "Fr" }

-- The plugin's own UI strings.
--
-- These deliberately do NOT go through noctalia.tr: that resolves against the
-- *shell's* language, so a Persian calendar running in an English shell would
-- show Persian dates next to an English "Today". One setting governs the whole
-- surface instead. translations/*.json still covers the settings labels, which
-- the host renders.
local TEXT = {
  persian = {
    today = "امروز",
    no_occasion = "بدون مناسبت",
    hijri = "قمری",
    gregorian = "میلادی",
    year = "سال",
    pick_month = "انتخاب ماه",
  },
  latin = {
    today = "Today",
    no_occasion = "No occasion",
    hijri = "Hijri",
    gregorian = "Gregorian",
    year = "Year",
    pick_month = "Pick month",
  },
}

function M.text(key: string, lang: string): string
  local table_ = if lang == "persian" then TEXT.persian else TEXT.latin
  return table_[key] or key
end

function M.digits(n: number, style: string): string
  local s = tostring(math.floor(n))
  if style ~= "persian" then
    return s
  end
  -- Parenthesised: gsub returns (result, count) and an unwrapped return would
  -- leak the replacement count as a second value.
  return (s:gsub("%d", function(d)
    return PERSIAN_DIGITS[tonumber(d) + 1]
  end))
end

function M.monthName(jm: number, lang: string): string
  local names = if lang == "persian" then MONTHS_FA else MONTHS_LATIN
  return names[jm] or ""
end

function M.gregorianMonthName(gm: number, lang: string): string
  local names = if lang == "persian" then GREGORIAN_FA else GREGORIAN_LATIN
  return names[gm] or ""
end

function M.hijriMonthName(hm: number, lang: string): string
  local names = if lang == "persian" then HIJRI_FA else HIJRI_LATIN
  return names[hm] or ""
end

function M.weekdayName(dow: number, lang: string, short: boolean): string
  local names
  if lang == "persian" then
    names = if short then WEEKDAYS_FA_SHORT else WEEKDAYS_FA
  else
    names = if short then WEEKDAYS_LATIN_SHORT else WEEKDAYS_LATIN
  end
  return names[dow + 1] or ""
end

function M.formatTemplate(tpl: string, parts: { [string]: string }): string
  return (tpl:gsub("{(%w+)}", function(key)
    -- Unknown placeholders come back verbatim so a typo in the user's format
    -- setting is visible rather than silently swallowed. Built by concatenation
    -- because Luau forbids `{{` inside an interpolated string.
    return parts[key] or ("{" .. key .. "}")
  end))
end

return M
