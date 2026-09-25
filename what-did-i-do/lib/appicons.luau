-- lib/appicons.luau — application icon resolution (app_id → icon path).
--
-- Thin shared wrapper over the host's noctalia.appIconPath(appIdOrIconName,
-- sizePx) — the same desktop-entry/XDG icon-theme lookup Noctalia's taskbar
-- uses. The display name is NEVER passed here: icon lookup keys on the
-- technical app_id ("@codebuff/freebuff-desktop", "brave-browser"), exactly
-- what sessions store, so a row's icon always belongs to the same app as its
-- label ("Freebuff" must not resolve Brave's icon).
--
-- The helper exists so no caller repeats the raw host call per row per
-- render: results (hits AND misses) are cached by app_id + size, because the
-- host documentation notes a lookup can touch the filesystem on a cache
-- miss. No scanning, no embedding, no network — resolution is entirely the
-- host's job; this module only validates, caches and falls back to nil.

local M = {}

-- newHost({ appIconPath }) -> resolver with resolve(appId, sizePx).
-- The host adapter is injectable so the pure caching/validation core stays
-- unit-testable; the UI entries pass { appIconPath = noctalia.appIconPath }.
function M.newResolver(host)
  host = host or {}
  local cache = {}      -- "id\0size" -> path string (resolved hits)
  local missCache = {}  -- "id\0size" -> true (nil result; don't re-ask the host every render)
  local calls = 0       -- host invocations (exposed for tests)

  local function keyOf(appId, sizePx)
    return tostring(appId) .. "\0" .. tostring(sizePx)
  end

  return {
    -- resolve(appId, sizePx) -> icon path string, or nil when nothing resolves.
    -- nil is the caller's signal to render the row without an icon (or with
    -- its existing generic glyph); it must never break the row.
    resolve = function(appId, sizePx)
      -- Validate: only a non-empty string id can resolve; booleans/numbers/
      -- tables are caller bugs and must not reach the host.
      if type(appId) ~= "string" or appId == "" then
        return nil
      end
      sizePx = tonumber(sizePx)
      local key = keyOf(appId, sizePx)
      local hit = cache[key]
      if type(hit) == "string" then
        return hit
      end
      if missCache[key] then
        return nil
      end
      -- Ask the host exactly once per (id, size), hit or miss.
      calls = calls + 1
      local ok, path = pcall(host.appIconPath, appId, sizePx)
      if ok and type(path) == "string" and path ~= "" then
        cache[key] = path
        return path
      end
      missCache[key] = true
      return nil
    end,

    -- Test/diagnostics hook: how many times the host was actually consulted.
    -- Stays flat (≤ one call per distinct id+size) across repeated renders.
    hostCallCount = function()
      return calls
    end,
  }
end

return M
