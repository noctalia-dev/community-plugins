--!nonstrict
-- Helpers the bar widget and the panel both need. Kept in one place so the two
-- surfaces cannot drift apart on which mark belongs to a provider or on how an
-- account's usage is derived.

local common = {}

function common.themeColors()
  return noctalia.getConfig("theme_colors") == true
end

-- Providers the user has chosen not to see, as a comma-separated list of ids
-- ("anthropic, xai"). A plugin setting cannot enumerate providers it only
-- learns about at runtime, so this is free text; matching is case-insensitive
-- and tolerates the label OpenCodex shows ("OpenAI Codex" -> "openai codex")
-- only insofar as the id is what OpenCodex reports.
--
-- Unlike a provider disabled in OpenCodex itself, this hides the provider from
-- this plugin alone: OpenCodex keeps routing through it.
local hiddenCache, hiddenCacheSource = {}, nil

function common.hiddenProviders()
  local raw = noctalia.getConfig("hidden_providers")
  if type(raw) ~= "string" then raw = "" end
  if raw == hiddenCacheSource then return hiddenCache end

  local set = {}
  for token in raw:gmatch("[^,%s]+") do
    set[token:lower()] = true
  end
  -- Codex-login usage is filed under either id depending on the endpoint, so
  -- naming one has to hide the other.
  if set.openai then set.codex = true end
  if set.codex then set.openai = true end

  hiddenCache, hiddenCacheSource = set, raw
  return set
end

function common.isHidden(id)
  return common.hiddenProviders()[tostring(id or ""):lower()] == true
end

-- The one test both surfaces use: a provider is shown when OpenCodex has it
-- enabled and the user has not hidden it here.
function common.providerVisible(provider)
  return provider.enabled == true and not common.isHidden(provider.id)
end

-- The worst window in a quota, or nil when it reports none.
function common.maxQuota(quota)
  local maximum = nil
  for _, window in ipairs((quota and quota.windows) or {}) do
    if type(window.usedPercent) == "number" and (maximum == nil or window.usedPercent > maximum) then
      maximum = window.usedPercent
    end
  end
  return maximum
end

function common.anyAccountQuota(provider)
  for _, account in ipairs(provider.accounts or {}) do
    if account.quota ~= nil then return true end
  end
  return false
end

-- An account's own worst window, or its provider's when OpenCodex only reports
-- quota at the provider level (xAI does this).
function common.accountUsed(provider, account, providerHasAccountQuota)
  if account.quota ~= nil then return common.maxQuota(account.quota) end
  if providerHasAccountQuota then return nil end
  return common.maxQuota(provider.quota)
end

-- Tabler glyphs already bundled with Noctalia. Unknown providers deliberately
-- use the generic robot rather than importing artwork from OpenCodex.
local PROVIDER_GLYPHS = {
  codex = "brand-openai",
  openai = "brand-openai",
  grok = "brand-x",
  xai = "brand-x",
  gemini = "brand-google",
  google = "brand-google",
  vertex = "brand-google",
  copilot = "brand-github",
  github = "brand-github",
}

function common.providerGlyph(id)
  local key = tostring(id or ""):lower()
  local named = PROVIDER_GLYPHS[key]
  if named ~= nil then return named end

  -- Deployments sometimes suffix ids, for example "openai_work".
  for provider, glyph in pairs(PROVIDER_GLYPHS) do
    if key:sub(1, #provider) == provider then return glyph end
  end
  return nil
end

return common
