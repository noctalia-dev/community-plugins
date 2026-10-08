--!nonstrict
local h = require("./harness")
local fmt = require("../fmt")

return function()
  h.describe("digits", function()
    h.eq(fmt.digits(1405, "latin"), "1405", "latin passes through")
    h.eq(fmt.digits(1405, "persian"), "۱۴۰۵", "persian uses U+06F0 range")
    h.eq(fmt.digits(0, "persian"), "۰", "zero converts")
    h.eq(fmt.digits(31, "persian"), "۳۱", "two digits convert")
  end)

  h.describe("month names", function()
    h.eq(fmt.monthName(1, "persian"), "فروردین", "farvardin in persian")
    h.eq(fmt.monthName(6, "persian"), "شهریور", "shahrivar in persian")
    h.eq(fmt.monthName(12, "persian"), "اسفند", "esfand in persian")
    h.eq(fmt.monthName(1, "latin"), "Farvardin", "farvardin in latin")
    h.eq(fmt.monthName(7, "latin"), "Mehr", "mehr in latin")
  end)

  h.describe("gregorian month names", function()
    h.eq(fmt.gregorianMonthName(1, "latin"), "January", "january in latin")
    h.eq(fmt.gregorianMonthName(9, "latin"), "September", "september in latin")
    h.eq(fmt.gregorianMonthName(9, "persian"), "سپتامبر", "september in persian")
    h.eq(fmt.gregorianMonthName(12, "persian"), "دسامبر", "december in persian")
  end)

  h.describe("hijri month names", function()
    h.eq(fmt.hijriMonthName(1, "persian"), "محرم", "muharram in persian")
    h.eq(fmt.hijriMonthName(9, "persian"), "رمضان", "ramadan in persian")
    h.eq(fmt.hijriMonthName(1, "latin"), "Muharram", "muharram in latin")
    h.eq(fmt.hijriMonthName(12, "latin"), "Dhu al-Hijjah", "dhul-hijjah in latin")
  end)

  h.describe("weekday names", function()
    h.eq(fmt.weekdayName(0, "persian", false), "شنبه", "saturday is shanbeh")
    h.eq(fmt.weekdayName(6, "persian", false), "جمعه", "friday is jomeh")
    h.eq(fmt.weekdayName(0, "persian", true), "ش", "short saturday")
    h.eq(fmt.weekdayName(0, "latin", false), "Shanbeh", "saturday in latin")
  end)

  h.describe("ui strings follow the plugin language, not the shell", function()
    h.eq(fmt.text("today", "persian"), "امروز", "today in persian")
    h.eq(fmt.text("today", "latin"), "Today", "today in latin")
    h.eq(fmt.text("no_occasion", "persian"), "بدون مناسبت", "no occasion in persian")
    h.eq(fmt.text("no_occasion", "latin"), "No occasion", "no occasion in latin")
    h.eq(fmt.text("hijri", "persian"), "قمری", "hijri label")
    h.eq(fmt.text("gregorian", "latin"), "Gregorian", "gregorian label")
    h.eq(fmt.text("nonexistent", "persian"), "nonexistent", "unknown key falls back to the key")
  end)

  h.describe("templates", function()
    local parts = { day = "۳۱", month = "شهریور", year = "۱۴۰۵", weekday = "دوشنبه" }
    h.eq(
      fmt.formatTemplate("{day} {month} {year}", parts),
      "۳۱ شهریور ۱۴۰۵",
      "three-part template"
    )
    h.eq(
      fmt.formatTemplate("{weekday} {day} {month}", parts),
      "دوشنبه ۳۱ شهریور",
      "weekday template"
    )
    h.eq(fmt.formatTemplate("no placeholders", parts), "no placeholders", "literal text")
    h.eq(fmt.formatTemplate("{bogus}", parts), "{bogus}", "unknown placeholder is left alone")
  end)
end
