-- Split reset: puts every dwindle split on a workspace back to 50/50,
-- the way windows tile when they first open.
--
-- Hyprland has no "equalize" layout message, and `splitratio` only reaches
-- the focused window's direct parent, so the middle divider of a 2x2 grid
-- can't be reset with it. Instead this rebuilds the split tree from the
-- window geometry and moves each divider with a relative resize on a window
-- next to it. Resizes target windows by address, so focus never changes.
--
-- The bar widget runs this file with `hyprctl eval`. To use it from a
-- keybind too, require it from hyprland.lua.
--
--   split_reset()                          active workspace
--   split_reset({ monitor = "DP-1" })      that monitor's active workspace
--   split_reset({ workspace = "77" })      a given workspace
--   split_reset({ snap = 0.05 })           only dividers within 5% of center

local TOL = 2 -- px a divider may sit off center and still count as centered

local function resolve_workspace(opts)
    if opts.workspace ~= nil then
        return hl.get_workspace(opts.workspace)
    end
    if opts.monitor ~= nil then
        local mon = hl.get_monitor(opts.monitor)
        return mon and mon.active_workspace or nil
    end
    return hl.get_active_workspace()
end

-- Tiled windows on the workspace as plain boxes, or nil if the
-- workspace isn't a resettable dwindle workspace.
local function tiled_windows(ws)
    local out = {}
    for _, w in ipairs(hl.get_windows({ workspace = ws })) do
        -- the filter falls back to all windows on a bad selector, so check again
        if w.workspace and w.workspace.id == ws.id and not w.floating then
            if w.fullscreen ~= 0 then
                return nil
            end
            local layout = w.layout
            if not layout or layout.name ~= "dwindle" then
                return nil
            end
            out[#out + 1] = { addr = w.address, x = w.at.x, y = w.at.y, w = w.size.x, h = w.size.y }
        end
    end
    return out
end

local function lo(win, horiz) return horiz and win.y or win.x end
local function hi(win, horiz) return horiz and (win.y + win.h) or (win.x + win.w) end

local function bbox(wins)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, w in ipairs(wins) do
        x0, y0 = math.min(x0, w.x), math.min(y0, w.y)
        x1, y1 = math.max(x1, w.x + w.w), math.max(y1, w.y + w.h)
    end
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Every straight line that splits `wins` into two groups. A divider sits in
-- the middle of the gap, which is where dwindle puts the node edge.
local function find_cuts(wins, horiz)
    local cuts, seen = {}, {}
    for _, c in ipairs(wins) do
        local edge = hi(c, horiz)
        if not seen[edge] then
            seen[edge] = true
            local a, b, ok = {}, {}, true
            for _, w in ipairs(wins) do
                if hi(w, horiz) <= edge + TOL then
                    a[#a + 1] = w
                elseif lo(w, horiz) >= edge - TOL then
                    b[#b + 1] = w
                else
                    ok = false
                    break
                end
            end
            if ok and #b > 0 then
                local start = math.huge
                for _, w in ipairs(b) do start = math.min(start, lo(w, horiz)) end
                cuts[#cuts + 1] = { horiz = horiz, pos = (edge + start) / 2, a = a, b = b }
            end
        end
    end
    return cuts
end

-- Guesses the split tree. Where several cuts are possible, the one closest
-- to the center wins: after a reset that is the real top split.
local function build(wins, box)
    if #wins < 2 then
        return nil
    end
    local best, bestd
    for _, horiz in ipairs({ false, true }) do
        local start, size = horiz and box.y or box.x, horiz and box.h or box.w
        for _, c in ipairs(find_cuts(wins, horiz)) do
            c.target = start + size / 2
            c.size = size
            local d = math.abs(c.pos - c.target) / size
            if not best or d < bestd then
                best, bestd = c, d
            end
        end
    end
    if not best then
        return nil
    end
    best.box = box
    local half1, half2
    if best.horiz then
        half1 = { x = box.x, y = box.y, w = box.w, h = box.h / 2 }
        half2 = { x = box.x, y = box.y + box.h / 2, w = box.w, h = box.h / 2 }
    else
        half1 = { x = box.x, y = box.y, w = box.w / 2, h = box.h }
        half2 = { x = box.x + box.w / 2, y = box.y, w = box.w / 2, h = box.h }
    end
    best.children = { build(best.a, half1), build(best.b, half2) }
    return best
end

local function node_key(node)
    local parts = {}
    for _, w in ipairs(node.a) do parts[#parts + 1] = w.addr end
    table.sort(parts)
    return (node.horiz and "h:" or "v:") .. table.concat(parts, ",")
end

-- Divider position and outer box of a node, measured from fresh geometry.
local function measure(node, ws)
    local wins = tiled_windows(ws)
    if not wins then
        return nil
    end
    local byaddr = {}
    for _, w in ipairs(wins) do byaddr[w.addr] = w end
    local all, edge, start = {}, -math.huge, math.huge
    for _, w in ipairs(node.a) do
        local f = byaddr[w.addr]
        if not f then return nil end
        all[#all + 1] = f
        edge = math.max(edge, hi(f, node.horiz))
    end
    for _, w in ipairs(node.b) do
        local f = byaddr[w.addr]
        if not f then return nil end
        all[#all + 1] = f
        start = math.min(start, lo(f, node.horiz))
    end
    return (edge + start) / 2, bbox(all)
end

local function resize(addr, horiz, d)
    hl.dispatch(hl.dsp.window.resize({
        x = horiz and 0 or d,
        y = horiz and d or 0,
        relative = true,
        window = "address:" .. addr,
    }))
end

local function same_box(p, q)
    return math.abs(p.x - q.x) <= 1 and math.abs(p.y - q.y) <= 1
        and math.abs(p.w - q.w) <= 1 and math.abs(p.h - q.h) <= 1
end

-- A resize moves the window's nearest split of that orientation, which may
-- not be this node. Try the windows touching the divider, biggest first
-- (a direct child spans the whole node), and undo any try that doesn't
-- move this divider alone.
local function fix(node, ws)
    local _, before = measure(node, ws)
    if not before then
        return false
    end
    local cands = {}
    local a_edge, b_start = -math.huge, math.huge
    for _, w in ipairs(node.a) do a_edge = math.max(a_edge, hi(w, node.horiz)) end
    for _, w in ipairs(node.b) do b_start = math.min(b_start, lo(w, node.horiz)) end
    for _, w in ipairs(node.a) do
        if hi(w, node.horiz) >= a_edge - TOL then cands[#cands + 1] = w end
    end
    for _, w in ipairs(node.b) do
        if lo(w, node.horiz) <= b_start + TOL then cands[#cands + 1] = w end
    end
    local function span(w) return node.horiz and w.w or w.h end
    table.sort(cands, function(p, q) return span(p) > span(q) end)

    local off = node.target - node.pos
    for _, w in ipairs(cands) do
        resize(w.addr, node.horiz, off)
        local pos, box = measure(node, ws)
        if pos and same_box(box, before) and math.abs(node.target - pos) < math.abs(off) - 0.5 then
            return true
        end
        resize(w.addr, node.horiz, -off)
    end
    return false
end

function split_reset(opts)
    opts = opts or {}
    local ws = resolve_workspace(opts)
    if not ws then
        return
    end
    local skip = {}
    for _ = 1, 64 do
        local wins = tiled_windows(ws)
        if not wins or #wins < 2 then
            return
        end
        -- first divider off center, top-down, so parents settle before children
        local queue, todo = { build(wins, bbox(wins)) }, nil
        while #queue > 0 and not todo do
            local node = table.remove(queue, 1)
            if node then
                local off = math.abs(node.target - node.pos)
                if off > TOL and not skip[node_key(node)]
                    and (not opts.snap or off <= opts.snap * node.size) then
                    todo = node
                else
                    queue[#queue + 1] = node.children[1]
                    queue[#queue + 1] = node.children[2]
                end
            end
        end
        if not todo then
            return
        end
        if not fix(todo, ws) then
            skip[node_key(todo)] = true
        end
    end
end
