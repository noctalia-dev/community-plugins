-- Native, time-driven adaptation of Jakub Antalik's Thinking Orbs geometry.
-- Copyright (c) 2026 Jakub Antalik; original geometry licensed under MIT.
-- https://github.com/Jakubantalik/thinking-orbs
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local TAU = math.pi * 2
local sin, cos, sqrt = math.sin, math.cos, math.sqrt
local min, max, abs = math.min, math.max, math.abs
local RISING, FALLING = { 0, 1 }, { 1, 0 }
local gray = {}
for i = 0, 255 do
    gray[i] = string.format("#%02x%02x%02x", i, i, i)
end
local ringKeys = {}
for _, prefix in ipairs({ "attention-", "track-", "progress-" }) do
    local identities = {}
    for i = 0, 47 do identities[i + 1] = prefix .. i end
    ringKeys[prefix] = identities
end
local ringGeometry = {}
for _, count in ipairs({ 24, 32, 40, 48 }) do
    local points = {}
    for i = 0, count - 1 do
        local a, b = -math.pi / 2 - i / count * TAU, -math.pi / 2 - (i + 1) / count * TAU
        points[i + 1] = { cos(a), sin(a), cos(b), sin(b), a }
    end
    ringGeometry[count] = points
end

local function clamp(value, low, high)
    return max(low, min(high, value))
end

local function smooth(value)
    return value * value * (3 - 2 * value)
end

local function hash(a, b)
    local value = sin(a * 12.9898 + b * 78.233) * 43758.5453
    return value - math.floor(value)
end

local function fibonacci(count)
    local points = {}
    local golden = math.pi * (3 - sqrt(5))
    for i = 0, count - 1 do
        local y = 1 - 2 * (i + 0.5) / count
        local radial, angle = sqrt(max(0, 1 - y * y)), i * golden
        points[i + 1] = { radial * cos(angle), y, radial * sin(angle) }
    end
    return points
end

local function lattice(rings, longitudes)
    local points = {}
    for ring = 0, rings do
        local latitude = -math.pi / 2 + ring / rings * math.pi
        local c, s = cos(latitude), sin(latitude)
        local count = max(1, math.floor(abs(c) * longitudes + 0.5))
        for i = 0, count - 1 do
            local longitude = i / count * TAU
            points[#points + 1] = { c * cos(longitude), s, c * sin(longitude), ring, longitude }
        end
    end
    return points
end

local function orbits(count, ghosts)
    local points = {}
    for orbit = 0, count - 1 do
        local h1, h2 = hash(orbit, 1.7), hash(orbit, 5.2)
        local theta, phi = h1 * TAU, math.acos(2 * h2 - 1)
        local nx, ny, nz = sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta)
        local length = max(0.000001, sqrt(nx * nx + ny * ny))
        local ux, uy = -ny / length, nx / length
        local vx, vy, vz = -nz * uy, nz * ux, nx * uy - ny * ux
        for i = 0, ghosts + 2 do
            local moving = i >= ghosts
            local angle = moving and ((i - ghosts) / 3 * TAU + h2 * 6) or (i / ghosts * TAU)
            local ca, sa = cos(angle), sin(angle)
            points[#points + 1] = {
                ux, uy, vx, vy, vz, 0.41 * (0.45 + 0.52 * h1),
                ca, sa, moving and (1 + orbit % 3) or 0,
            }
        end
    end
    return points
end

local function polygon(vertices, fraction)
    local perimeter = 0
    local lengths = {}
    for i, a in ipairs(vertices) do
        local b = vertices[i % #vertices + 1]
        lengths[i] = sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
        perimeter += lengths[i]
    end
    local target = fraction * perimeter
    for i, a in ipairs(vertices) do
        local length, b = lengths[i], vertices[i % #vertices + 1]
        if target <= length then
            local ratio = target / length
            return a[1] + (b[1] - a[1]) * ratio, a[2] + (b[2] - a[2]) * ratio
        end
        target -= length
    end
    return vertices[1][1], vertices[1][2]
end

local function shapes(count)
    local triangle = { { 0, -0.26 }, { 0.24, 0.16 }, { -0.24, 0.16 } }
    local square = { { 0, -0.2 }, { 0.2, -0.2 }, { 0.2, 0.2 }, { -0.2, 0.2 }, { -0.2, -0.2 } }
    local points = {}
    for i = 0, count - 1 do
        local fraction, angle = i / count, -math.pi / 2 + i / count * TAU
        local tx, ty = polygon(triangle, fraction)
        local sx, sy = polygon(square, fraction)
        points[i + 1] = { { cos(angle) * 0.24, sin(angle) * 0.24 }, { tx, ty }, { sx, sy } }
    end
    return points
end

local function web(count)
    local points, edges = fibonacci(count), {}
    -- A fixed four-neighbour candidate graph bounds edge cost. The original
    -- distance threshold still fades connections as the sphere deforms.
    local seen = {}
    for i, a in ipairs(points) do
        local neighbours = {}
        for j, b in ipairs(points) do
            if i ~= j then
                neighbours[#neighbours + 1] = { j, (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2 }
            end
        end
        table.sort(neighbours, function(a, b) return a[2] < b[2] end)
        for n = 1, min(4, #neighbours) do
            local first, second = min(i, neighbours[n][1]), max(i, neighbours[n][1])
            local key = first * count + second
            if not seen[key] then
                seen[key] = true
                edges[#edges + 1] = { first, second, "edge-" .. first .. "-" .. second }
            end
        end
    end
    return { points = points, edges = edges }
end

local function ribbon(lanes, segments)
    local points = {}
    for lane = 0, lanes - 1 do
        local offset = (lane - (lanes - 1) / 2) * 0.03
        local edge = abs(lane - (lanes - 1) / 2) / max(1, (lanes - 1) / 2)
        for i = 0, segments - 1 do
            local angle = i / segments * TAU
            points[#points + 1] = { cos(angle), sin(angle), angle, offset, edge, lane }
        end
    end
    return points
end

local function braid(background, strandCount)
    local points = fibonacci(background)
    for strand = 0, 2 do
        local offset = strand / 3 * TAU
        for i = 0, strandCount - 1 do
            points[#points + 1] = { i / strandCount * TAU, offset }
        end
    end
    return { points = points, background = background }
end

-- Static directions, not animation frames: 39/100 orbit particles, 54/122
-- lattice particles, 64/128 braid particles, 60/128 ribbon particles.
local small = {
    orbit = orbits(3, 10), lattice = lattice(6, 14), web = web(12),
    braid = braid(16, 16), ribbon = ribbon(3, 20), done = fibonacci(28), shape = shapes(16),
}
local large = {
    orbit = orbits(5, 17), lattice = lattice(8, 24), web = web(18),
    braid = braid(20, 36), ribbon = ribbon(4, 32), done = fibonacci(48), shape = shapes(28),
}
local keys, pool, dots, nodes = {}, {}, {}, {}
for i = 1, 128 do
    keys[i], pool[i] = "particle-" .. i, {}
end
for i = 1, 18 do nodes[i] = {} end
local ringMotion = {}
for i = 0, 8 do ringMotion[i] = {} end
local dotCount = 0
local projection = {}

local function projectSetup(size, yaw, tilt, radius)
    projection.size, projection.radius = size, radius
    projection.sy, projection.cy = sin(yaw), cos(yaw)
    projection.st, projection.ct = sin(tilt), cos(tilt)
end

local function project(x, y, z)
    local p = projection
    local x1, z1 = x * p.cy + z * p.sy, -x * p.sy + z * p.cy
    return p.size / 2 + x1 * p.radius, p.size / 2 - (y * p.ct - z1 * p.st) * p.radius,
        y * p.st + z1 * p.ct
end

local function dot(x, y, z, radius, white, alpha)
    dotCount += 1
    local d, size = pool[dotCount], projection.size
    -- Keep the whole antialiased disc within the logical square, including
    -- listening's expanded wave crests. No raster clipping or oversized cells.
    radius = max(0, min(radius, size * 0.07, x, size - x, y, size - y))
    d.x, d.y, d.z, d.radius = x, y, z, radius
    d.color, d.alpha, d.key = gray[math.floor(clamp(1 - white, 0, 1) * 255 + 0.5)], clamp(alpha, 0, 1), keys[dotCount]
    dots[dotCount] = d
end

local function place(cells, size, x, y, width, height, primitive, key)
    cells[#cells + 1] = ui.column({
        key = key, width = size, height = size,
        paddingH = max(0, min(x, size - width - x)),
        paddingV = max(0, min(y, size - height - y)),
        align = x <= (size - width) / 2 and "start" or "end",
        justify = y <= (size - height) / 2 and "start" or "end",
    }, { primitive })
end

local function line(cells, size, x1, y1, x2, y2, width, color, opacity, key)
    local w, h = max(size * 0.00001, abs(x2 - x1)), max(size * 0.00001, abs(y2 - y1))
    place(cells, size, min(x1, x2), min(y1, y2), w, h, ui.graph({
        key = key, values = (x2 - x1) * (y2 - y1) < 0 and RISING or FALLING,
        width = w, height = h, lineWidth = width, color = color,
        opacity = clamp(opacity, 0, 1), fillOpacity = 0,
    }), key)
end

local function ring(cells, size, radius, width, color, opacity, count, prefix, fraction)
    for i = 0, count - 1 do
        local p = ringGeometry[count][i + 1]
        local coverage = fraction and clamp(fraction * count - i, 0, 1) or 1
        local endX, endY = p[1], p[2]
        if coverage == 1 then
            endX, endY = p[3], p[4]
        elseif coverage > 0 then
            local b = p[5] - coverage / count * TAU
            endX, endY = cos(b), sin(b)
        end
        line(cells, size, size / 2 + p[1] * radius, size / 2 + p[2] * radius,
            size / 2 + endX * radius, size / 2 + endY * radius,
            width, color, opacity * coverage, ringKeys[prefix][i + 1])
    end
end

local function attention(cells, size, phase, state)
    local pulse = 0.5 + 0.5 * sin(phase * 2)
    ring(cells, size, size * (0.425 + 0.025 * pulse), size * 0.035,
        state == "waiting" and "#ffb74d" or "#ef5350", 0.38 + 0.32 * pulse,
        size <= 24 and 24 or 40, "attention-")
end

local function orbitDots(data, size, phase, scale)
    projectSetup(size, phase, 0.3, size)
    for _, p in ipairs(data) do
        local ca, sa = p[7], p[8]
        if p[9] ~= 0 then
            local c, s = cos(phase * p[9]), sin(phase * p[9])
            ca, sa = ca * c - sa * s, sa * c + ca * s
        end
        local x, y, z = project((p[1] * ca + p[3] * sa) * p[6], (p[2] * ca + p[4] * sa) * p[6], p[5] * sa * p[6])
        local depth = clamp((z / p[6] + 1) / 2, 0, 1)
        if p[9] == 0 then
            dot(x, y, z, max(size * 0.015, 0.9 * scale), 0.72, 0.5 * (0.4 + 0.6 * depth))
        else
            dot(x, y, z, max(size * 0.015, (1.2 + 1.6 * depth) * scale), 0.3 - 0.22 * depth, 1)
        end
    end
end

local function latticeDots(data, size, phase, state, scale)
    projectSetup(size, phase, 0.38 + 0.06 * sin(phase), size * (state == "listening" and 0.437 or 0.41))
    -- Latitude-wide wave/twist work is shared by every longitude particle.
    for ringIndex = 0, data[#data][4] do
        local motion = ringMotion[ringIndex]
        motion.wave, motion.active = 0, 0
        if state == "solving" then
            local band = sin(phase * 2 + ringIndex * 0.8)
            motion.c, motion.s, motion.active = cos(band * math.pi / 4), sin(band * math.pi / 4), abs(band)
        elseif state == "listening" then
            motion.wave = 0.62 * sin(phase * 3 - ringIndex * 0.52) + 0.38 * sin(phase * 2 + ringIndex * 0.83)
        end
    end
    for _, p in ipairs(data) do
        local x, y, z, ringIndex, longitude = p[1], p[2], p[3], p[4], p[5]
        local motion = ringMotion[ringIndex]
        local wave, active = motion.wave, motion.active
        if state == "solving" then
            x, z = x * motion.c - z * motion.s, x * motion.s + z * motion.c
        elseif state == "listening" then
            local wobble = 1 + 0.105 * wave
            x, y, z = x * wobble, y * wobble, z * wobble
        end
        local px, py, depthZ = project(x, y, z)
        local depth = clamp((depthZ + 1) / 2, 0, 1)
        if state == "searching" then
            local delta = math.atan2(sin(longitude - phase * 3), cos(longitude - phase * 3))
            local scan = math.exp(-delta * delta / 0.18) * max(0, depthZ)
            dot(px, py, depthZ, (0.6 + 1.7 * depth + scan) * scale, 0.62 - 0.54 * depth, 0.45 + 0.55 * scan)
        else
            local crest = state == "listening" and max(0, wave) or 0
            dot(px, py, depthZ, (0.6 + 1.7 * depth + 0.3 * active) * (1 + 0.4 * crest) * scale,
                0.66 - 0.56 * depth - 0.1 * crest - 0.14 * active, 1)
        end
    end
end

local function webDots(data, cells, size, phase, scale)
    projectSetup(size, phase, 0.32, size * 0.4)
    for i, p in ipairs(data.points) do
        local index = i - 1
        local x, y, z = p[1] + 0.3 * sin(phase + index * 0.31),
            p[2] + 0.3 * sin(phase * 2 + index * 0.53), p[3] + 0.3 * sin(phase * 3 + index * 0.77)
        local length, node = sqrt(x * x + y * y + z * z), nodes[i]
        node[1], node[2], node[3] = x / length, y / length, z / length
        node[4], node[5], node[6] = project(node[1], node[2], node[3])
    end
    for _, edge in ipairs(data.edges) do
        local a, b = nodes[edge[1]], nodes[edge[2]]
        local distance = sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
        local depth = clamp(((a[6] + b[6]) + 1) / 2, 0, 1)
        line(cells, size, a[4], a[5], b[4], b[5], max(size * 0.015, 0.8 * scale / 2.2), "#949494",
            max(0, 1 - distance / 0.72) * (0.3 + 0.55 * depth), edge[3])
    end
    for i = 1, #data.points do
        local p = nodes[i]
        local depth, pulse = (p[6] + 1) / 2, 1 + 0.25 * sin(phase * 2 + (i - 1) * 2.7)
        dot(p[4], p[5], p[6], (1.4 + 1.8 * depth) * pulse * scale, 0.55 - 0.45 * depth, 1)
    end
    for signal = 0, (size <= 24 and 1 or 2) do
        local a, b = nodes[signal % #data.points + 1], nodes[(signal * 7 + 3) % #data.points + 1]
        -- Ping-pong travel avoids the old fractional-phase teleport at endpoints.
        local progress = 0.5 - 0.5 * cos(phase * (1 + signal % 3) + signal / 5 * TAU)
        local x, y, z = a[1] + (b[1] - a[1]) * progress, a[2] + (b[2] - a[2]) * progress, a[3] + (b[3] - a[3]) * progress
        local length = max(0.000001, sqrt(x * x + y * y + z * z))
        local px, py, depthZ = project(x / length, y / length, z / length)
        local depth = (depthZ + 1) / 2
        dot(px, py, depthZ, (2.1 + 1.8 * depth) * scale, 0.05, 0.5 + 0.5 * depth)
    end
end

local function braidDots(data, size, phase, scale)
    projectSetup(size, phase, 0.3, size * 0.38)
    for i, p in ipairs(data.points) do
        if i <= data.background then
            local x, y, z = project(p[1], p[2], p[3])
            local depth = (z + 1) / 2
            dot(x, y, z, max(size * 0.015, 0.8 * scale / 2.2), 0.78, 0.1 + 0.22 * depth)
        else
            -- Smooth travel through the strand tips instead of modulo-wrapping.
            local u, offset = 0.96 * sin(p[1] + phase), p[2]
            local surface, angle = sqrt(max(0, 1 - u * u)), u * math.pi * 3 + offset
            local weave = 1 + 0.075 * sin(u * math.pi * 6 + offset * 2 + phase * 2)
            local x, y, z = project(cos(angle) * surface * weave, u * weave, sin(angle) * surface * weave)
            local depth = clamp((z + 1) / 2, 0, 1)
            dot(x, y, z, (1.2 + 1.8 * depth) * scale, 0.55 - 0.45 * depth,
                min(1, (1 - abs(u)) / 0.1) * (0.45 + 0.55 * depth))
        end
    end
end

local function ribbonDots(data, size, phase, state, scale)
    local faceOn = state == "breathing"
    projectSetup(size, faceOn and 0 or phase, faceOn and 0 or 0.3, size * 0.39)
    for _, p in ipairs(data) do
        local wobble = (0.16 * sin(p[3] * 3 - phase * 3 + p[6] * 0.22) + 0.07 * sin(p[3] * 5 + phase * 2)) * (faceOn and 0.58 or 1)
        local z = p[4] + (faceOn and 0 or wobble)
        local length = sqrt(1 + z * z)
        local radius = faceOn and (1 + wobble) or 1
        local px, py, depthZ = project(p[1] / length * radius, p[2] / length * radius, z / length * radius)
        local depth = clamp((depthZ + 1) / 2, 0, 1)
        dot(px, py, depthZ, (1.1 + 1.7 * depth) * (1 - 0.25 * p[5]) * scale,
            0.52 - 0.44 * depth + 0.18 * p[5], 0.4 + 0.6 * depth)
    end
end

local function doneDots(data, size, phase, scale)
    projectSetup(size, phase, 0.34, size * 0.38)
    for i, p in ipairs(data) do
        local x, y, z = project(p[1], p[2], p[3])
        local depth = (z + 1) / 2
        local sparkle = 0.85 + 0.15 * sin(phase * 3 + (i - 1) * 2.7)
        dot(x, y, z, (0.9 + 1.25 * depth) * scale, 0.62 - 0.42 * depth, (0.38 + 0.5 * depth) * sparkle)
    end
end

local function shapeDots(data, size, phase)
    projectSetup(size, 0, 0, size)
    local slot = (phase / TAU % 1) * 3
    local first = math.floor(slot) + 1
    local blend = smooth(slot - math.floor(slot))
    local pulse = 1 + 0.02 * sin(phase * 3)
    for _, p in ipairs(data) do
        local a, b = p[first], p[first % 3 + 1]
        dot(size / 2 + (a[1] + (b[1] - a[1]) * blend) * size * 1.45 * pulse,
            size / 2 + (a[2] + (b[2] - a[2]) * blend) * size * 1.45 * pulse,
            0, size * 0.021 * 1.35 * 2.2, 0.1, 1)
    end
end

local function depthOrder(a, b)
    if a.z == b.z then return a.key < b.key end
    return a.z < b.z
end

local function root(props, cells, size)
    return ui.column({ key = props.key, width = size, height = size, gap = -size,
        opacity = clamp(props.opacity == nil and 1 or props.opacity, 0, 1) }, cells)
end

local function render(props)
    local size, phase = max(0, props.size or 20), (props.time or 0) * math.pi
    local state, data, cells = props.state or "working", size <= 24 and small or large, {}
    local previousCount = #dots
    dotCount = 0
    local urgent = props.attention
    if state == "waiting" or state == "blocked" then urgent = state end
    if urgent == "waiting" or urgent == "blocked" then attention(cells, size, phase, urgent) end
    local scale = (size / 300) ^ 0.6 * 2.2
    if state == "working" then orbitDots(data.orbit, size, phase, scale)
    elseif state == "searching" or state == "solving" or state == "listening" then latticeDots(data.lattice, size, phase, state, scale)
    elseif state == "connecting" then webDots(data.web, cells, size, phase, scale)
    elseif state == "weaving" then braidDots(data.braid, size, phase, scale)
    elseif state == "composing" or state == "breathing" then ribbonDots(data.ribbon, size, phase, state, scale)
    elseif state == "done" then doneDots(data.done, size, phase, scale)
    elseif state ~= "waiting" and state ~= "blocked" then shapeDots(data.shape, size, phase)
    end
    for i = dotCount + 1, previousCount do dots[i] = nil end
    table.sort(dots, depthOrder)
    for _, d in ipairs(dots) do
        local diameter = d.radius * 2
        place(cells, size, d.x - d.radius, d.y - d.radius, diameter, diameter, ui.box({
            key = d.key, width = diameter, height = diameter, radius = d.radius,
            fill = d.color, opacity = d.alpha,
        }), d.key)
    end
    return root(props, cells, size)
end

local function progress(props)
    local size, value, cells = max(0, props.size or 20), clamp(props.value or 0, 0, 1), {}
    local count = size <= 24 and 32 or 48
    ring(cells, size, size * 0.375, size * 0.125, "#787878", 0.45, count, "track-")
    ring(cells, size, size * 0.375, size * 0.125, "#ebebeb", 1, count, "progress-", value)
    -- Native discs supply the original round arc caps. Fade the zero-length
    -- arc in continuously, rather than popping a full-width dot at value > 0.
    local capRadius, capOpacity = size * 0.0625, min(1, value * count)
    local endAngle = -math.pi / 2 - value * TAU
    local capX, capY = size / 2 + cos(endAngle) * size * 0.375, size / 2 + sin(endAngle) * size * 0.375
    place(cells, size, size / 2 - capRadius, size * 0.125 - capRadius, capRadius * 2, capRadius * 2,
        ui.box({ key = "progress-start", width = capRadius * 2, height = capRadius * 2,
            radius = capRadius, fill = "#ebebeb", opacity = capOpacity }), "progress-start")
    place(cells, size, capX - capRadius, capY - capRadius, capRadius * 2, capRadius * 2,
        ui.box({ key = "progress-end", width = capRadius * 2, height = capRadius * 2,
            radius = capRadius, fill = "#ebebeb", opacity = capOpacity }), "progress-end")
    return root(props, cells, size)
end

return { render = render, progress = progress }
