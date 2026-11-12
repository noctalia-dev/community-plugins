--!nonstrict
-- Loads plugin sources the way Noctalia does: each entry in its own global
-- environment (backed by the fake host's globals), with require("./x.luau")
-- resolved relative to the requiring file and cached per entry.

local M = {}

local function normalize(path: string): string
  local parts = {}
  for part in string.gmatch(path, "[^/]+") do
    if part == ".." then
      table.remove(parts)
    elseif part ~= "." then
      table.insert(parts, part)
    end
  end
  return table.concat(parts, "/")
end

local function dirname(path: string): string
  return path:match("^(.*)/[^/]*$") or ""
end

-- Returns an entry runtime: { env, require(path) }. `env` holds the globals
-- the entry defines (update, onClick, ...).
function M.entry(sources, host, entryPath: string)
  local cache = {}
  local env = setmetatable({}, { __index = function(_, k)
    local v = host.globals[k]
    if v ~= nil then
      return v
    end
    return getfenv(0)[k]
  end })

  local load

  local function requireFrom(fromPath: string)
    return function(rel: string)
      assert(rel:sub(1, 2) == "./" or rel:sub(1, 3) == "../", `non-relative require '{rel}' in {fromPath}`)
      assert(rel:sub(-5) == ".luau", `require '{rel}' in {fromPath} must name the .luau file`)
      local base = dirname(fromPath)
      return load(normalize(if base == "" then rel else base .. "/" .. rel))
    end
  end

  function load(path: string, isEntry: boolean?)
    if cache[path] ~= nil then
      return cache[path]
    end
    local source = sources[path]
    assert(source, `no such source: {path}`)
    local fn, err = loadstring(source, "@" .. path)
    assert(fn, err)
    -- Modules get their own globals, like Noctalia (and unlike the entry's).
    local moduleEnv = if isEntry then env else setmetatable({}, { __index = env })
    rawset(moduleEnv, "require", requireFrom(path))
    setfenv(fn, moduleEnv)
    local result = fn()
    cache[path] = if result == nil then true else result
    return result
  end

  local runtime = { env = env }
  function runtime.require(path: string)
    return load(path)
  end
  function runtime.start()
    load(entryPath, true)
    return runtime
  end
  -- Calls a global the entry defined, if any.
  function runtime.call(name: string, ...)
    local fn = rawget(env, name)
    assert(type(fn) == "function", `entry {entryPath} does not define {name}()`)
    return fn(...)
  end
  return runtime
end

return M
