desktopWidget.setWantsSecondTicks(true)
desktopWidget.setNeedsFrameTick(true)

-- Variables and settings
local lastRefresh = 0
local refreshInterval = noctalia.getConfig("refresh_interval") * 60

local showTranslation = noctalia.getConfig("show_translation")
local translationEdition = noctalia.getConfig("translation_edition")

-- Hidden placeholder text to prevent issues with the size of ui.scroll
local placeholder = "Loading... Loading... Loading... Loading... Loading... Loading... Loading... Loading... Loading... Loading..."
local ayahNumber = 1
local surahNumber = 1
local ayahSurahNumber = 1
local ayah = placeholder
local ayahTranslation = ""
local surah = ""

local tooltip="tooltips.prev_ayah"
local tooltipVisible = false

local font = noctalia.loadFont("Kitab-Regular.ttf")

-- Gets Ayah and fills variables
local function fetchAyah(random)
  lastRefresh = 0

  random = random == nil and true or random

  if (random) then
    ayahNumber = math.random(6236)
  end

  noctalia.http({ url = string.format("https://api.alquran.cloud/v1/ayah/%s/editions/quran-uthmani,%s", ayahNumber, translationEdition) }, function(res)
    if res.status == 200 then
      local json = noctalia.json.decode(res.body)
      if json.code == 200 then
        surahNumber = json.data[1].surah.number
        ayahSurahNumber = json.data[1].numberInSurah
        ayah = json.data[1].text
        ayahTranslation = json.data[2].text
        surah = string.format("%s (%s) %s:%s", json.data[1].surah.name, json.data[1].surah.englishName, json.data[1].surah.number, json.data[1].numberInSurah)
      else
        ayah = "Service Error"
        surah = string.format("Error code: %s", json.code)
      end
    else
      ayah = "Network Error"
      surah = string.format("Error code: %s", res.status)
    end
  end)
end

-- UI
function onFrameTick(_)
  desktopWidget.render(
    ui.column({padding=8, gap=8, align="center"}, {
      ui.label({text=tooltip,opacity=0}), -- Makes sure that the view is not misaligned by the addition of the tooltip
      ui.scroll({gap=4, align="center", justify="center", flexGrow=1}, {
        ui.label({
          text=ayah,
          fontFamily=font,
          maxWidth=1000,
          opacity = ayah ~= placeholder and 100 or 0,
          textAlign="center",
          fontSize=24
        }),
        ui.label({
          text=ayahTranslation,
          maxWidth=1000,
          textAlign="center",
          fontSize=12,
          visible=showTranslation
        })
      }),
        ui.label({
          text=surah,
          maxWidth=500,
          opacity = ayah ~= placeholder and 100 or 0,
          textAlign="center",
          fontSize=15
        }),
      ui.row({gap=6}, {
        ui.button({
          glyph="arrow-left",
          onHover=function(s, _) tooltip="tooltips.prev_ayah"; tooltipVisible=s=="true" end,
          enabled=ayahNumber ~= 1,
          onClick=function() ayahNumber = ayahNumber - 1; fetchAyah(false) end
        }),
        ui.button({
          glyph="arrow-right",
          onHover=function(s, _) tooltip="tooltips.next_ayah"; tooltipVisible=s=="true" end,
          enabled=ayahNumber ~= 6236,
          onClick=function() ayahNumber = ayahNumber + 1; fetchAyah(false) end
        }),
        ui.button({
          glyph="reload",
          onHover=function(s, _) tooltip="tooltips.refresh"; tooltipVisible=s=="true" end,
          onClick=function() fetchAyah() end
        }),
        ui.button({
          glyph="world-share",
          onHover=function(s, _) tooltip="tooltips.browser"; tooltipVisible=s=="true" end,
          onClick=function() noctalia.runAsync({"xdg-open", string.format("https://quran.com/%s/%s", surahNumber, ayahSurahNumber)}) end
        }),
        ui.button({
          glyph="book-2",
          onHover=function(s, _) tooltip="tooltips.tafseer"; tooltipVisible=s=="true" end,
          onClick=function() noctalia.runAsync({"xdg-open", string.format("https://quran.com/%s/%s/tafsirs", surahNumber, ayahSurahNumber)}) end
        })
      }),
      ui.label({text=noctalia.tr(tooltip),opacity=tooltipVisible and 1 or 0})
    })
  )
end

fetchAyah() -- Initial fetch
-- Refresh interval
function update()
  if refreshInterval ~= 0 then
    lastRefresh = lastRefresh + 1
    if lastRefresh >= refreshInterval then
      fetchAyah()
    end
  end
end
