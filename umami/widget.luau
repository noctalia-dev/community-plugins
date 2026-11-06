--!nonstrict
local umami = require("./umami.luau")
local generation = 0

local function showMessage(glyph, message)
  barWidget.setGlyph(glyph)
  barWidget.setText("")
  barWidget.setTooltip(message)
end

local function showOnline(online)
  barWidget.setGlyph("chart-line")
  barWidget.setText(tostring(online))
  barWidget.setTooltip(noctalia.tr("tooltip.online", { count = online }))
end

local function refresh()
  generation += 1
  local current = generation
  if not umami.isConfigured() then
    showMessage("settings", noctalia.tr("error.not_configured"))
    return
  end
  local fail = function(key, subst)
    if current == generation then
      showMessage("alert-triangle", noctalia.tr(key, subst))
    end
  end
  umami.auth(function(auth)
    umami.get(auth, "/websites?pageSize=100&includeTeams=true", function(body)
      local sites = body.data or body
      local pending, online = #sites, 0
      if pending == 0 and current == generation then
        showOnline(0)
      end
      for _, site in sites do
        umami.get(auth, `{umami.websitePath(site.id)}/active`, function(active)
          online += umami.count(active.visitors or active.x)
          pending -= 1
          if pending == 0 and current == generation then
            showOnline(online)
          end
        end, fail)
      end
    end, fail)
  end, fail)
end

local function applyInterval()
  noctalia.setUpdateInterval(math.max(15, tonumber(noctalia.getConfig("refresh_seconds")) or 60) * 1000)
end

applyInterval()
refresh()

function update()
  refresh()
end

function onConfigChanged()
  umami.logout()
  applyInterval()
  refresh()
end

function onClick()
  if umami.isConfigured() then
    noctalia.togglePanel("ak4duy/umami:dashboard")
  else
    noctalia.openSettings()
  end
end

function onRightClick()
  refresh()
end
