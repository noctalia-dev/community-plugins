--!nonstrict
local M = {}

local dir: string = (noctalia.pluginDataDir()) or error("plugin data directory unavailable")

function M.read(name: string): any
  local raw = noctalia.readFile(`{dir}/{name}`)
  if not raw then
    return nil
  end
  return (noctalia.json.decode(raw))
end

function M.write(name: string, value: any)
  local text = noctalia.json.encode(value)
  if text then
    noctalia.writeFile(`{dir}/{name}`, text)
  end
end

return M
