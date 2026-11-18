--!nonstrict

-- Service state
local isAvailable = noctalia.commandExists("swaymsg")
local isStreaming = false

-- Published state
local count = nil
local hasError = false

-- Helpers
local function publish()
  noctalia.state.set("sway-scratchpad", {
    count = count,
    hasError = hasError,
  })
end

local function fail(message)
  hasError = true
  noctalia.log(message)
  publish()
end

-- Scratchpad lookup
-- Follows the scratchpad tree structure documented in man 7 sway-ipc
local function findScratchpadWorkspace(tree)
  local i3Output

  for _, node in ipairs(tree.nodes or {}) do
    if node.name == "__i3" then
      i3Output = node
      break
    end
  end

  if not i3Output then
    return
  end

  for _, node in ipairs(i3Output.nodes or {}) do
    if node.name == "__i3_scratch" then
      return node
    end
  end
end

local function getScratchpadWindowCount(tree)
  local workspace = findScratchpadWorkspace(tree)

  if not workspace then
    return
  end

  if type(workspace.floating_nodes) ~= "table" then
    return
  end

  return #workspace.floating_nodes
end

-- State refresh
local function refreshCount()
  local isAccepted = noctalia.runAsync({ "swaymsg", "--type", "get_tree" }, function(result)
    if result.exitCode ~= 0 then
      fail(noctalia.tr("error.tree_query_failed"))
      return
    end

    local decoded = noctalia.json.decode(result.stdout)

    if type(decoded) ~= "table" then
      fail(noctalia.tr("error.decode_failed"))
      return
    end

    local newCount = getScratchpadWindowCount(decoded)

    if newCount == nil then
      fail(noctalia.tr("error.invalid_data"))
      return
    end

    -- Skip publishing if data is already valid
    if newCount == count and not hasError then
      return
    end

    count = newCount
    hasError = false
    publish()
  end)

  if not isAccepted then
    fail(noctalia.tr("error.tree_query_failed"))
  end
end

-- Sway event stream
local function onLine(line)
  local decoded = noctalia.json.decode(line)

  if type(decoded) ~= "table" then
    fail(noctalia.tr("error.decode_failed"))
    return
  end

  local isRelevantChange = decoded.change == "new"
    or decoded.change == "close"
    or decoded.change == "move"
    or decoded.change == "floating"

  if not isRelevantChange then
    return
  end

  refreshCount()
end

local function subscribe()
  if not isAvailable or isStreaming then
    return
  end

  isStreaming = noctalia.runStream(
    'swaymsg --monitor --type subscribe \'["window"]\'',
    onLine
  )

  if not isStreaming then
    fail(noctalia.tr("error.stream_failed"))
  end
end

-- Get initial state, since subscribe only logs changes
refreshCount()
subscribe()
