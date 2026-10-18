--!nonstrict
-- Launcher provider: /nwg <query> fuzzy-finds a profile; Enter applies it.

local nwg = require("./lib/nwg.luau")

local tr = noctalia.tr

function onQuery(text)
  local profiles = nwg.listProfiles() or {}
  local active = nwg.readActiveProfile()
  local results = {}

  for _, name in ipairs(profiles) do
    local score = nil
    if text ~= "" then
      score = noctalia.fuzzyScore(text, name)
    end

    if text == "" or score ~= nil then
      table.insert(results, {
        id = name,
        title = name,
        subtitle = name == active and tr("launcher.active") or tr("launcher.apply"),
        glyph = name == active and "check" or "device-desktop",
        score = score,
      })
    end
  end

  if #results == 0 then
    table.insert(results, {
      id = "",
      title = #profiles == 0 and tr("launcher.no_profiles") or tr("launcher.no_match"),
      glyph = "info-circle",
    })
  end

  launcher.setResults(text, results)
end

function onActivate(id)
  if id == "" then
    return
  end

  nwg.apply(id, function(ok, err)
    if not ok then
      noctalia.notifyError(tr("notify.apply_failed", { profile = id }), err or "")
    end
  end)
end
