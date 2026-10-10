-- Keyboard model of panel.luau: the selection, wrap-around, hold-to-repeat
-- timing and Enter, with the host stubbed. Run through tests/run.sh, which
-- prepends the unmodified panel source as PANEL_SRC.

local rendered, opened, frameTick
local searches = {} -- callbacks of the fzf runs the panel has started

local function node(kind)
    return function(props, children)
        return { kind = kind, props = props, children = children }
    end
end
ui = setmetatable({}, { __index = function(_, kind) return node(kind) end })
panel = {
    render = function(tree) rendered = tree end,
    setNeedsFrameTick = function(on) frameTick = on end,
    close = function() end,
    openContextMenu = function() end,
}
noctalia = {
    readFile = function() return nil end,
    writeFile = function() return true end,
    log = function() end,
    getConfig = function() return nil end,
    fileInfo = function() return nil end,
    fileExists = function() return true end,
    commandExists = function() return true end,
    nowMs = function() return 0 end,
    notify = function() end,
    copyToClipboard = function() end,
    openSettings = function() end,
    diskStats = function() return nil end,
    state = { set = function() end },
    runAsync = function(_, callback)
        table.insert(searches, callback)
        return true
    end,
}
local shared = {
    roots = { "/home" }, mounts = {}, scope = "folder", whole = false,
    ranking = "path", schemeSupported = true,
    NEXT_RANKING = { path = "default", default = "path" },
    NEXT_SCOPE = { folder = "all" }, RANKING_GLYPHS = {}, SCOPE_GLYPHS = {},
    tr = function(key) return key end,
    trim = function(value) return value:match("^%s*(.-)%s*$") end,
    dataDir = function() return "/data" end,
    cacheTag = function() return "folder" end,
    searchRoot = function() return "/home" end,
    computeRoots = function() return { "/home" } end,
    indexRootsOf = function() return nil end,
    cacheFresh = function() return true end,
    autoIndexAllowed = function() return true end,
    cacheSh = function() return "" end,
    searchCommand = function() return "fzf" end,
    readScope = function() return "folder" end,
    readWhole = function() return false end,
    readRanking = function() return "path" end,
    probeMounts = function(_, callback) callback() end,
    probeFzfScheme = function() end,
    formatBytes = function() return "0 B" end,
    absolutePath = function(rel) return "/home/" .. rel end,
    openPath = function(path) opened = path end,
}
local usage = {
    state = "idle", slices = {}, skipped = {}, total = 0,
    load = function() return false end,
    scan = function() end,
    writeSvg = function() end,
}
require = function(path)
    return path == "./shared.luau" and shared or usage
end
assert(loadstring(PANEL_SRC, "=panel.luau"))()

local function hits()
    for _, child in ipairs(rendered.children) do
        if child.props.key == "body" then
            return child.children[1]
        end
    end
end

local function selectedRow()
    for _, row in ipairs(hits().children) do
        if row.props.selected then
            return row.props.key
        end
    end
end

-- Answer the pending search with n results.
local function results(n)
    local lines = {}
    for i = 1, n do
        lines[i] = "file" .. i
    end
    local callback = table.remove(searches)
    callback({ exitCode = 0, timedOut = false, stdout = table.concat(lines, "\n") })
end

local function press(chord)
    onKey(chord, true)
    onKey(chord, false)
end

onOpen(nil)
results(50)
assert(selectedRow() == "hit-1")
assert(hits().props.revealKey == "hit-1")
assert(#hits().children == 50)

press("down")
press("down")
assert(selectedRow() == "hit-3")
assert(hits().props.revealKey == "hit-3")
onOpenSelected("")
assert(opened == "/home/file3")

-- A fresh press wraps at either end.
press("up")
press("up")
press("up")
assert(selectedRow() == "hit-50")
press("down")
assert(selectedRow() == "hit-1")

-- Holding repeats after the delay, then at the step rate, until released.
onKey("down", true)
assert(frameTick == true)
onFrameTick(300)
assert(selectedRow() == "hit-2")
onFrameTick(60)
assert(selectedRow() == "hit-3")
onFrameTick(16)
assert(selectedRow() == "hit-3")
onFrameTick(50)
assert(selectedRow() == "hit-4")
onKey("down", false)
assert(frameTick == false)
onFrameTick(500)
assert(selectedRow() == "hit-4")

-- A repeat stops at the end instead of wrapping.
onKey("down", true)
for _ = 1, 100 do
    onFrameTick(400)
end
assert(selectedRow() == "hit-50")
assert(frameTick == false)
onKey("down", false)

-- New results put the selection back on the top match.
onQueryChanged("x")
results(3)
assert(selectedRow() == "hit-1")
press("up")
assert(selectedRow() == "hit-3")

-- An empty list takes keys and Enter without complaint.
opened = nil
onQueryChanged("none")
results(0)
press("down")
onOpenSelected("none")
assert(opened == nil)

-- Closing the panel stops a held key's repeat.
onKey("up", true)
assert(frameTick == true)
onClose()
assert(frameTick == false)

print("file-search panel key tests: ok")
