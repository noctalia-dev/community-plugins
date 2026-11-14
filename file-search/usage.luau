--!nonstrict
-- file-search — disk usage donut for the panel.
--
-- `du` (spawned as an argv) measures the direct children of the search root;
-- the biggest few become a donut, the rest is folded into one "other" slice.
-- The chart is an SVG written into the plugin data directory and shown with
-- ui.image. Colours come from two fixed ramps chosen with isDarkMode().
--
-- State keys (module fields, read by the panel): state, slices, total, root,
-- scannedAt, errText, imagePath, skipped, looseLabel, otherLabel.

local shared = require("./shared.luau")

local usage = {}

-- Same as the palette length.
usage.MAX_SLICES = 8

-- A measurement younger than this is reused; refresh ignores it.
usage.TTL_SECONDS = 86400
usage.TIMEOUT_MS = 120000

-- Fixed order: a folder keeps its colour between measurements.
usage.PALETTE_DARK = {
    "#7aa2f7", "#9ece6a", "#e0af68", "#f7768e",
    "#bb9af7", "#2ac3de", "#ff9e64", "#73daca",
}
usage.PALETTE_LIGHT = {
    "#3b5fc0", "#4f8a2b", "#b07708", "#c2405a",
    "#7c4dbd", "#0e7490", "#c25a12", "#2f8f7a",
}

-- ── measured state ───────────────────────────────────────────────────────────

usage.state = "idle"   -- "idle" | "scanning" | "ready" | "error"
-- { label, bytes, color, kind }, biggest first. kind is "folder", "loose"
-- (what the root holds outside any subfolder) or "other" (the merged tail);
-- only "folder" names something the panel can search inside.
usage.slices = {}
usage.total = 0        -- bytes of the scanned root itself
usage.root = nil       -- what the numbers above describe
usage.scannedAt = 0    -- unix seconds, 0 = never
usage.errText = nil
usage.imagePath = nil  -- current SVG, nil until one is written
usage.skipped = {}     -- mount points under the root, so they can be named

-- Set by the panel from translations/en.json.
usage.looseLabel = "(files)"
usage.otherLabel = "other"

-- Two file names, alternating.
local SVG_NAMES = { "usage-a.svg", "usage-b.svg" }
local svgSlot = 0
local scanning = false

-- ── settings ─────────────────────────────────────────────────────────────────

-- The usage_exclude_dirs setting as du --exclude patterns: a bare name matches
-- anywhere below the root, a path matches one folder. A leading '~' is
-- expanded; entries with a newline or NUL are dropped.
function usage.excludes()
    local raw = noctalia.getConfig("usage_exclude_dirs")
    if type(raw) ~= "string" then
        return {}
    end
    local out = {}
    for entry in raw:gmatch("[^,;]+") do
        local name = entry:match("^%s*(.-)%s*$")
        if name ~= "" then
            if name:find("[\n\r%z]") then
                noctalia.log("file-search: ignoring usage exclude with a control character")
            else
                if name:sub(1, 1) == "~" then
                    name = noctalia.expandPath(name)
                end
                if #name > 1 then
                    name = name:gsub("/+$", "")
                end
                table.insert(out, name)
            end
        end
    end
    return out
end

-- ── mounts ───────────────────────────────────────────────────────────────────

-- Names of the mount points directly inside `root`, from /proc/self/mounts.
function usage.mountChildren(root)
    local text = noctalia.readFile("/proc/self/mounts")
    if type(text) ~= "string" then
        return {}
    end
    local prefix = root .. "/"
    local names, seen = {}, {}
    for line in text:gmatch("[^\n]+") do
        -- Second field is the target, octal-escaped.
        local target = line:match("^%S+%s+(%S+)")
        if target ~= nil then
            target = target:gsub("\\(%d%d%d)", function(digits)
                return string.char(tonumber(digits, 8))
            end)
            if target:sub(1, #prefix) == prefix then
                local rest = target:sub(#prefix + 1)
                if rest ~= "" and not rest:find("/") and not seen[rest] then
                    seen[rest] = true
                    table.insert(names, rest)
                end
            end
        end
    end
    table.sort(names)
    return names
end

-- ── du output ────────────────────────────────────────────────────────────────

-- One `<bytes>\t<path>` line per direct child, the root itself last. Only
-- paths that are a direct child of the root are kept (names may forge lines).
local function parseDu(out, root)
    local entries, rootBytes = {}, nil
    local prefix = root .. "/"
    for line in out:gmatch("[^\n]+") do
        local bytes, path = line:match("^(%d+)\t(.+)$")
        if bytes ~= nil then
            bytes = tonumber(bytes)
            if path == root then
                rootBytes = bytes
            elseif path:sub(1, #prefix) == prefix then
                local name = path:sub(#prefix + 1)
                if name ~= "" and not name:find("/") and bytes > 0 then
                    table.insert(entries, { name = name, bytes = bytes })
                end
            end
        end
    end
    return entries, rootBytes
end

-- Colours the slices by position, in place.
function usage.paint(slices)
    local palette = noctalia.isDarkMode() and usage.PALETTE_DARK or usage.PALETTE_LIGHT
    local rank = 0
    for _, slice in ipairs(slices) do
        if slice.kind == "other" then
            -- "other" is outside the ramp.
            slice.color = noctalia.isDarkMode() and "#5b6180" or "#9aa2b8"
        else
            rank += 1
            slice.color = palette[((rank - 1) % #palette) + 1]
        end
    end
    return slices
end

-- Biggest MAX_SLICES children, the tail merged, plus what the root holds
-- outside any child folder.
local function toSlices(entries, rootBytes, looseLabel, otherLabel)
    table.sort(entries, function(a, b)
        return a.bytes > b.bytes
    end)

    local childSum = 0
    for _, entry in ipairs(entries) do
        childSum += entry.bytes
    end
    local loose = rootBytes - childSum
    if loose > 0 then
        table.insert(entries, { name = looseLabel, bytes = loose, kind = "loose" })
        table.sort(entries, function(a, b)
            return a.bytes > b.bytes
        end)
    end

    local slices, tail = {}, 0
    for index, entry in ipairs(entries) do
        if index <= usage.MAX_SLICES then
            table.insert(slices, {
                label = entry.name,
                bytes = entry.bytes,
                kind = entry.kind or "folder",
            })
        else
            tail += entry.bytes
        end
    end
    if tail > 0 then
        table.insert(slices, { label = otherLabel, bytes = tail, kind = "other" })
    end
    return usage.paint(slices)
end

-- ── SVG ──────────────────────────────────────────────────────────────────────

local function escapeXml(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- One ring segment, drawn as a dashed circle.
local function segment(cx, cy, radius, width, color, fromFraction, lengthFraction)
    local circumference = 2 * math.pi * radius
    -- A hairline gap between neighbours.
    local run = circumference * lengthFraction - 1.5
    if run <= 0 then
        return ""
    end
    return string.format(
        '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="none" stroke="%s" stroke-width="%.2f"'
            .. ' stroke-dasharray="%.3f %.3f" stroke-dashoffset="%.3f"'
            .. ' transform="rotate(-90 %.2f %.2f)"/>',
        cx, cy, radius, color, width, run, circumference - run,
        -circumference * fromFraction, cx, cy
    )
end

-- `size` is the CSS pixel box; the host rasterizes at 3× the element size.
function usage.svg(slices, total, size, thickness, centerTop, centerBottom)
    local dark = noctalia.isDarkMode()
    local track = dark and "#2a2e3f" or "#e3e6ee"
    local strong = dark and "#e6e9f0" or "#1c2030"
    local dim = dark and "#9aa2b8" or "#5a627a"
    local cx, cy = size / 2, size / 2
    local radius = (size - thickness) / 2 - 1

    local parts = {
        string.format(
            '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">',
            size, size, size, size
        ),
        string.format(
            '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="none" stroke="%s" stroke-width="%.2f"/>',
            cx, cy, radius, track, thickness
        ),
    }

    local denominator = total > 0 and total or 1
    local accumulated = 0.0
    for _, slice in ipairs(slices) do
        local fraction = slice.bytes / denominator
        if fraction > 0 then
            table.insert(parts, segment(cx, cy, radius, thickness, slice.color, accumulated, fraction))
            accumulated += fraction
        end
    end

    table.insert(parts, string.format(
        '<text x="%.2f" y="%.2f" text-anchor="middle" font-family="sans-serif" font-size="%.1f"'
            .. ' font-weight="600" fill="%s">%s</text>',
        cx, cy - 1, size * 0.145, strong, escapeXml(centerTop)
    ))
    table.insert(parts, string.format(
        '<text x="%.2f" y="%.2f" text-anchor="middle" font-family="sans-serif" font-size="%.1f"'
            .. ' fill="%s">%s</text>',
        cx, cy + size * 0.105, size * 0.10, dim, escapeXml(centerBottom)
    ))
    table.insert(parts, "</svg>")
    return table.concat(parts, "")
end

-- Write the chart and point usage.imagePath at it, removing the other name.
function usage.writeSvg(dataDir, size, thickness, centerTop, centerBottom)
    if dataDir == nil then
        return
    end
    svgSlot = (svgSlot % #SVG_NAMES) + 1
    local previous = usage.imagePath or (dataDir .. "/" .. SVG_NAMES[(svgSlot % #SVG_NAMES) + 1])
    local path = dataDir .. "/" .. SVG_NAMES[svgSlot]
    local ok, err = noctalia.writeFile(path, usage.svg(usage.slices, usage.total, size, thickness, centerTop, centerBottom))
    if not ok then
        noctalia.log("file-search: could not write the usage chart: " .. tostring(err))
        return
    end
    usage.imagePath = path
    if previous ~= nil and previous ~= path then
        noctalia.removeFile(previous)
    end
end

-- ── persistence ──────────────────────────────────────────────────────────────

-- The measurement is cached on disk; an unreadable or other-version file is discarded.
local STORE_VERSION = 1

function usage.save(dataDir)
    if dataDir == nil or usage.state ~= "ready" then
        return
    end
    local plain = {}
    for _, slice in ipairs(usage.slices) do
        table.insert(plain, { label = slice.label, bytes = slice.bytes, kind = slice.kind })
    end
    local text = noctalia.json.encode({
        version = STORE_VERSION,
        root = usage.root,
        total = usage.total,
        at = usage.scannedAt,
        slices = plain,
        skipped = usage.skipped,
    })
    if type(text) ~= "string" then
        return
    end
    local ok, err = noctalia.writeFile(dataDir .. "/usage.json", text)
    if not ok then
        noctalia.log("file-search: could not save the usage measurement: " .. tostring(err))
    end
end

function usage.load(dataDir)
    if dataDir == nil or usage.state == "ready" then
        return false
    end
    local text = noctalia.readFile(dataDir .. "/usage.json")
    if type(text) ~= "string" or text == "" then
        return false
    end
    local ok, data = pcall(noctalia.json.decode, text)
    if not ok or type(data) ~= "table" or data.version ~= STORE_VERSION then
        return false
    end
    if type(data.root) ~= "string" or type(data.total) ~= "number" or type(data.slices) ~= "table" then
        return false
    end
    local slices = {}
    for _, slice in ipairs(data.slices) do
        if type(slice) == "table" and type(slice.label) == "string" and type(slice.bytes) == "number" then
            table.insert(slices, { label = slice.label, bytes = slice.bytes, kind = slice.kind or "folder" })
        end
    end
    if #slices == 0 then
        return false
    end
    usage.root = data.root
    usage.total = data.total
    usage.scannedAt = type(data.at) == "number" and data.at or 0
    usage.slices = usage.paint(slices)
    usage.skipped = type(data.skipped) == "table" and data.skipped or {}
    usage.state = "ready"
    usage.errText = nil
    return true
end

-- ── measuring ────────────────────────────────────────────────────────────────

function usage.fresh(root)
    return usage.state == "ready" and usage.root == root
        and (shared.now() - usage.scannedAt) < usage.TTL_SECONDS
end

-- Measure `root`, then call done() either way. `force` skips the TTL; a scan
-- already in flight is never doubled. du: -x stays on one filesystem, -d1 stops
-- at the direct children, -B1 prints plain bytes.
function usage.scan(root, dataDir, force, done)
    if scanning then
        return
    end
    if not force and usage.fresh(root) then
        done()
        return
    end
    if not noctalia.commandExists("du") then
        usage.state = "error"
        usage.errText = "du"
        done()
        return
    end

    local argv = { "du", "-x", "-d1", "-B1" }
    for _, pattern in ipairs(usage.excludes()) do
        table.insert(argv, "--exclude=" .. pattern)
    end
    table.insert(argv, "--")
    table.insert(argv, root)

    scanning = true
    usage.state = "scanning"
    local started = noctalia.runAsync(argv, function(result)
        scanning = false
        local entries, rootBytes = parseDu(result.stdout or "", root)
        -- The output decides, not the exit status.
        if result.timedOut or rootBytes == nil then
            usage.state = "error"
            usage.errText = result.timedOut and "timeout" or "empty"
            done()
            return
        end
        usage.root = root
        usage.total = rootBytes
        usage.slices = toSlices(entries, rootBytes, usage.looseLabel, usage.otherLabel)
        usage.skipped = usage.mountChildren(root)
        usage.scannedAt = shared.now()
        usage.state = "ready"
        usage.errText = nil
        usage.save(dataDir)
        done()
    end, usage.TIMEOUT_MS)

    if not started then
        scanning = false
        usage.state = "error"
        usage.errText = "spawn"
        done()
    end
end

return usage
