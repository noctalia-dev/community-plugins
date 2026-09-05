-- scroll_state.luau — semantic fingerprints and publish-if-changed helpers.
--
-- Fingerprints match what each UI surface actually displays, so irrelevant
-- JSON churn (e.g. scale precision the bar rounds away) does not wake watchers.

local M = {}

local lastFingerprints = {}

local function boolStr(value)
  return value and "1" or "0"
end

-- Fields used by scroller_widget composeText (scale rounded to 2 decimals).
function M.scrollerFingerprint(scroller)
  if scroller == nil then
    return ""
  end
  local scalePart = ""
  if scroller.scaled then
    scalePart = string.format("%.2f", scroller.scale or 1.0)
  end
  return table.concat({
    tostring(scroller.mode or ""),
    tostring(scroller.insert or ""),
    boolStr(scroller.focus == true),
    tostring(scroller.reorder or ""),
    tostring(scroller.fit or ""),
    boolStr(scroller.center_horizontal == true),
    boolStr(scroller.center_vertical == true),
    boolStr(scroller.overview == true),
    boolStr(scroller.scaled == true),
    scalePart,
  }, "|")
end

-- Fields used by trails_widget composeText.
function M.trailsFingerprint(trails)
  if trails == nil then
    return ""
  end
  return table.concat({
    tostring(trails.active or 0),
    tostring(trails.length or 0),
    tostring(trails.trail_length or 0),
  }, "|")
end

-- Fields used by scroller_panel buildTree (excludes scale/overview/scaled).
function M.panelScrollerFingerprint(scroller)
  if scroller == nil then
    return ""
  end
  return table.concat({
    tostring(scroller.mode or ""),
    tostring(scroller.insert or ""),
    boolStr(scroller.focus == true),
    tostring(scroller.reorder or ""),
    tostring(scroller.fit or ""),
    boolStr(scroller.center_horizontal == true),
    boolStr(scroller.center_vertical == true),
  }, "|")
end

-- Publish value to noctalia.state only when the fingerprint changed.
function M.publishIfChanged(key, value, fingerprint)
  if fingerprint == lastFingerprints[key] then
    return false
  end
  lastFingerprints[key] = fingerprint
  noctalia.state.set(key, value)
  return true
end

return M
