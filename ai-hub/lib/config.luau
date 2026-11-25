--[[
  config.luau - the host-facing layer: declared settings, credential lookup and
  the small amount of state that must survive a restart.

  This is the module that reads `noctalia.*`, so it is not unit-tested on its
  own; the parsing it depends on lives in the pure modules next to it. Two rules
  hold throughout:

    * a key travels from `read()` straight into the request headers. It is never
      logged, never published to shared state and never printed in an error;
    * a missing or unusable credential produces a readable message, never a
      crash and never a silent unauthenticated request.
]]

local providers = require("./providers.luau")
local credentials = require("./credentials.luau")

local M = {}

-- The credential file only changes when the user runs `opencode auth login`,
-- but both the service and the panel ask for it, so a short cache avoids
-- re-reading and re-parsing it on every turn and every render.
local AUTH_CACHE_MS = 5000
local auth_cache = nil
local auth_cache_at = 0
local auth_cache_error = nil

local function trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function setting_string(key: string, fallback: string): string
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" then
    return fallback
  end
  -- pasted keys and URLs arrive with stray whitespace more often than not
  return trim(value)
end

local function setting_bool(key: string, fallback: boolean): boolean
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then
    return value
  end
  return fallback
end

local function setting_number(key: string, fallback: number, minimum: number?, maximum: number?): number
  local value = tonumber(noctalia.getConfig(key))
  if value == nil then
    return fallback
  end
  if minimum ~= nil and value < minimum then
    return minimum
  end
  if maximum ~= nil and value > maximum then
    return maximum
  end
  return value
end

function M.auth_table()
  local now = noctalia.nowMs()
  if auth_cache ~= nil and (now - auth_cache_at) < AUTH_CACHE_MS then
    return auth_cache, auth_cache_error
  end
  auth_cache_at = now
  auth_cache = nil
  auth_cache_error = nil

  local path = credentials.auth_path(noctalia.getenv("XDG_DATA_HOME"), noctalia.getenv("HOME"))
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then
    auth_cache_error = "No se pudo leer " .. path .. "."
    return nil, auth_cache_error
  end
  local decoded, decode_error = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    auth_cache_error = "auth.json no es JSON válido: " .. tostring(decode_error)
    return nil, auth_cache_error
  end
  auth_cache = decoded
  return auth_cache, nil
end

-- Names with a usable key, for the panel's hint text.
function M.credential_names()
  return credentials.names(M.auth_table())
end

function M.all_credential_names()
  return credentials.all_names(M.auth_table())
end

-- ---------------------------------------------------------------------------
-- Persisted state (survives restarts, unlike noctalia.state)
-- ---------------------------------------------------------------------------

local STATE_FILE = "state.json"

local function state_path(): string?
  local directory = noctalia.pluginDataDir()
  if type(directory) ~= "string" or directory == "" then
    return nil
  end
  return directory .. "/" .. STATE_FILE
end

function M.load_state()
  local path = state_path()
  if path == nil then
    return {}
  end
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then
    return {}
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    noctalia.log("ai-hub: state.json ilegible, se ignora")
    return {}
  end
  return decoded
end

function M.save_state(state): boolean
  local path = state_path()
  if path == nil then
    return false
  end
  local encoded, encode_error = noctalia.json.encode(state)
  if type(encoded) ~= "string" then
    noctalia.log("ai-hub: no se pudo codificar el estado: " .. tostring(encode_error))
    return false
  end
  local ok, write_error = noctalia.writeFile(path, encoded)
  if ok ~= true then
    noctalia.log("ai-hub: no se pudo escribir el estado: " .. tostring(write_error))
  end
  return ok == true
end

-- ---------------------------------------------------------------------------
-- Persistent credential store (keys per provider, survive provider switches)
-- ---------------------------------------------------------------------------

--[[
  Save a credential for a provider so it survives provider switches.
  Stored in state.json under credential_store[provider] = { key = "...", auth_provider = "..." }
  When auth_provider is empty, it means the key was manually typed.
]]
function M.save_credential(state, provider: string, key: string, auth_provider: string?)
  if type(state) ~= "table" then
    return false
  end
  if type(key) ~= "string" or key == "" then
    -- Remove stored credential for this provider when key is cleared
    if type(state.credential_store) == "table" then
      state.credential_store[provider] = nil
    end
    M.save_state(state)
    return true
  end
  if type(state.credential_store) ~= "table" then
    state.credential_store = {}
  end
  state.credential_store[provider] = {
    key = key,
    auth_provider = (type(auth_provider) == "string" and auth_provider ~= "") and auth_provider or "",
  }
  M.save_state(state)
  return true
end

--[[
  Load a credential for a provider from the store.
  Returns { key = "...", auth_provider = "..." } or nil.
]]
function M.load_credential(state, provider: string)
  if type(state) ~= "table" or type(provider) ~= "string" or provider == "" then
    return nil
  end
  local store = state.credential_store
  if type(store) ~= "table" then
    return nil
  end
  local entry = store[provider]
  if type(entry) ~= "table" or type(entry.key) ~= "string" then
    return nil
  end
  return { key = entry.key, auth_provider = entry.auth_provider or "" }
end

function M.delete_credential(state, provider: string)
  if type(state) ~= "table" then
    return false
  end
  if type(state.credential_store) == "table" then
    state.credential_store[provider] = nil
  end
  M.save_state(state)
  return true
end

--[[
  Return a table of all saved credentials (provider -> key label), for
  display in the panel settings.
]]
function M.list_credentials(state)
  local out = {}
  if type(state) ~= "table" then
    return out
  end
  local store = state.credential_store
  if type(store) ~= "table" then
    return out
  end
  for provider, entry in pairs(store) do
    if type(entry) == "table" and type(entry.key) == "string" and entry.key ~= "" then
      local label = entry.auth_provider ~= "" and ("auth.json: " .. entry.auth_provider) or "(manual)"
      out[provider] = label
    end
  end
  return out
end

function M.persist_model(state, model: string, setting_model: string)
  local next_state = state or {}
  next_state.model = model
  next_state.setting_model = setting_model or ""
  M.save_state(next_state)
  return next_state
end

local function random_hex(count: number): string
  local out = {}
  for _ = 1, count do
    out[#out + 1] = string.format("%x", math.random(0, 15))
  end
  return table.concat(out)
end

--[[
  A stable per-install id, used as OpenCode Zen's `x-opencode-session`. It is
  generated once and stored next to the rest of the plugin's state, because a
  value that changes every boot defeats the prompt cache the header feeds.
]]
function M.session_id(state)
  if type(state) == "table" and type(state.session_id) == "string" and #state.session_id >= 8 then
    return state.session_id
  end
  math.randomseed(noctalia.nowMs() % 2147483647)
  local id = string.format("%s-%s-4%s-%x%s-%s%s",
    random_hex(8), random_hex(4), random_hex(3),
    math.random(8, 11), random_hex(3),
    random_hex(4), random_hex(8))
  if type(state) == "table" then
    state.session_id = id
    M.save_state(state)
  end
  return id
end

-- ---------------------------------------------------------------------------

function M.tool_blocklist()
  local declared = noctalia.getConfig("tool_blocklist")
  local list = {}
  if type(declared) == "table" then
    for _, entry in ipairs(declared) do
      if type(entry) == "string" and trim(entry) ~= "" then
        table.insert(list, trim(entry))
      end
    end
  end
  return list
end

--[[
  Everything a turn and the panel need, in one read.

  The model has two sources on purpose: the settings window seeds a default,
  while the panel's picker persists its choice. If the user edited the setting
  since the last persisted pick, the setting wins - so changing it in either
  place is never silently ignored.
]]
function M.read()
  local state = M.load_state()
  local resolved = providers.resolve(setting_string("provider", "omniroute"), setting_string("endpoint", ""))

  local key_source = setting_string("key_source", "manual")
  local key, key_origin, key_error = "", "manual", nil

  -- Check credential store first (persistent per-provider keys)
  local _key_store_mode = setting_string("key_store_mode", "global")
  local stored = M.load_credential(state, resolved.id)
  if stored ~= nil then
    key = stored.key
    key_origin = stored.auth_provider ~= "" and ("auth.json: " .. stored.auth_provider) or ("saved for " .. resolved.id)
  elseif key_source == "auth.json" then
    key_origin = "auth.json"
    local auth, auth_error = M.auth_table()
    if auth == nil then
      key_error = auth_error
    else
      local found, label, pick_error = credentials.pick(auth, setting_string("auth_provider", ""))
      if found ~= nil then
        key = found
        key_origin = "auth.json: " .. tostring(label)
      else
        key_error = pick_error
      end
    end
  else
    -- Fall back to the api_key setting (or empty if not set)
    key = setting_string("api_key", "")
    if key ~= "" then
      key_origin = "manual"
    end
  end

  local model_setting = setting_string("model", "")
  local persisted_model = trim(state.model)
  local model = persisted_model ~= "" and persisted_model or model_setting

  local cfg = {
    provider = resolved.id,
    resolved = resolved,
    endpoint = resolved.base,
    key = key,
    has_key = key ~= "",
    key_origin = key_origin,
    key_error = key_error,
    key_source = key_source,
    model = model,
    model_setting = model_setting,
    stream = setting_bool("stream", true),
    tool_permission = setting_string("tool_permission", "off"),
    web_search = setting_bool("web_search", false),
    tool_blocklist = M.tool_blocklist(),
    max_tokens = setting_number("max_tokens", 0, 0, 1000000),
    max_history = setting_number("max_history", 40, 2, 200),
    system_prompt = setting_string("system_prompt", ""),
    state = state,
    session_id = resolved.send_session and M.session_id(state) or "",
  }
  return cfg, state
end

--[[
  The subset published to the panel and the widget. Deliberately built field by
  field rather than filtered: a key that is never named here can never leak
  through shared state.
]]
function M.fingerprint(cfg)
  return {
    provider = cfg.provider,
    provider_label = cfg.resolved.label,
    notes = cfg.resolved.notes,
    endpoint = cfg.endpoint,
    endpoint_overridden = cfg.resolved.overridden,
    has_key = cfg.has_key,
    key_origin = cfg.key_origin,
    key_error = cfg.key_error,
    key_required = cfg.resolved.key_required,
    local_only = cfg.resolved.local_only,
    credential_names = M.all_credential_names(),
    model = cfg.model,
    stream = cfg.stream,
    tool_permission = cfg.tool_permission,
    web_search = cfg.web_search,
    max_tokens = cfg.max_tokens,
    max_history = cfg.max_history,
    needs_endpoint = cfg.endpoint == "",
    needs_key = cfg.resolved.key_required and not cfg.has_key,
  }
end

--[[
  Why this configuration cannot answer a request yet, or nil when it can. Used
  before spending a network round trip, and by "Probar conexión".
]]
function M.blocking_problem(cfg): string?
  if cfg.endpoint == "" then
    return noctalia.tr("error.no_endpoint")
  end
  if not cfg.resolved.auth then
    return nil
  end
  if cfg.key_error ~= nil then
    return cfg.key_error
  end
  if cfg.resolved.key_required and not cfg.has_key then
    return noctalia.tr("error.no_key")
  end
  return nil
end

return M
