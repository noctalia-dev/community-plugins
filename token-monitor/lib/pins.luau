-- Persist only the selected stable account key for the active Hub source.
local Pins = {}
local MAX_FILE_SIZE = 16 * 1024
local MAX_KEY_LENGTH = 2048
local MAX_SCOPE_LENGTH = 2048

local function validKey(key)
  return type(key) == "string" and #key > 0 and #key <= MAX_KEY_LENGTH
      and not key:find("[%c]")
end

local function providersHaveUniqueKey(providers, key)
  if type(providers) ~= "table" then return false end
  local matches = 0
  for _, account in pairs(providers) do
    if type(account) == "table" and account.key == key then
      if type(account.provider) ~= "string" or account.provider == "" then return false end
      matches += 1
    end
  end
  return matches == 1
end

function Pins.new(env)
  local state = { ready = false, key = "", scope = "", error = "" }
  local generation, selectionRevision = 0, 0

  local function publish()
    env.publish({ ready = state.ready, key = state.key, scope = state.scope, error = state.error })
  end

  local function safeDecode(text)
    if type(text) ~= "string" or #text > MAX_FILE_SIZE then return nil, "cache_invalid" end
    local ok, value = pcall(env.decode, text)
    if not ok or type(value) ~= "table" then return nil, "cache_invalid" end
    return value
  end

  local function persist(key, scope)
    local ok, encoded = pcall(env.encode, { schema = 1, scope = scope, key = key })
    if not ok or type(encoded) ~= "string" or #encoded > MAX_FILE_SIZE then return false end
    local pathOk, path = pcall(env.path)
    if not pathOk or type(path) ~= "string" or path == "" then return false end
    local writeOk, result = pcall(env.write, path, encoded)
    return writeOk and result == true
  end

  local engine = {}

  function engine.configure(scope)
    if type(scope) ~= "string" or #scope > MAX_SCOPE_LENGTH then scope = "" end
    if scope == state.scope and generation > 0 then return end
    generation += 1
    selectionRevision += 1
    local epoch, revision = generation, selectionRevision
    state = { ready = false, key = "", scope = scope, error = "" }
    publish()

    local pathOk, path = pcall(env.path)
    if not pathOk or type(path) ~= "string" or path == "" then
      if epoch == generation then
        state.ready, state.error = true, "read_failed"
        publish()
      end
      return
    end

    local function finish(contents)
      if epoch ~= generation or revision ~= selectionRevision then return end
      local record, error = nil, ""
      if contents ~= nil then
        record, error = safeDecode(contents)
      end
      if record and record.schema == 1 and record.scope == scope and validKey(record.key) then
        state.key = record.key
      elseif record and (record.schema ~= 1 or type(record.scope) ~= "string"
          or (record.key ~= "" and not validKey(record.key))) then
        error = "cache_invalid"
      end
      state.ready, state.error = true, error
      publish()
    end

    local function callback(contents, readError)
      if readError then
        if epoch ~= generation or revision ~= selectionRevision then return end
        state.ready, state.error = true, "read_failed"
        publish()
        return
      end
      finish(contents)
    end
    local ok, accepted = pcall(env.read, path, callback)
    if not ok or accepted == false then callback(nil, true) end
  end

  function engine.select(key, providers)
    if key ~= "" and (not validKey(key) or not providersHaveUniqueKey(providers, key)) then
      return false
    end
    if not persist(key, state.scope) then
      state.error = "write_failed"
      publish()
      return false
    end
    selectionRevision += 1
    state.key, state.error, state.ready = key, "", true
    publish()
    return true
  end

  function engine.get()
    return { ready = state.ready, key = state.key, scope = state.scope, error = state.error }
  end

  return engine
end

return Pins
