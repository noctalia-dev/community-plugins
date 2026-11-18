--!nonstrict
-- Small pure helpers shared by the entries: config paths, fingerprints,
-- capture geometry, registry upkeep. No Noctalia globals.

local M = {}

function M.configDir(getenv: (string) -> string?): string
	local dir = getenv("NOCTALIA_CONFIG_HOME")
	if dir and dir ~= "" then
		return dir
	end
	local xdg = getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then
		return xdg .. "/noctalia"
	end
	return (getenv("HOME") or "~") .. "/.config/noctalia"
end

-- Stable text form of a value (sorted keys) for hashing.
function M.stableEncode(v): string
	if type(v) == "table" then
		local keys = {}
		for k in pairs(v) do
			table.insert(keys, k)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local parts = table.create(#keys)
		for _, k in ipairs(keys) do
			table.insert(parts, tostring(k) .. "=" .. M.stableEncode(v[k]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return tostring(v)
end

-- 32-bit FNV-1a. 16777619 = 2^24 + 403 keeps every product exact in a double.
function M.fnv1a(s: string): string
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = (h * 403 + bit32.lshift(h, 24)) % 4294967296
	end
	return string.format("%08x", h)
end

function M.fingerprint(v): string
	return M.fnv1a(M.stableEncode(v))
end

-- Output (logical px) + bar settings -> grim geometry and orientation.
-- The capture covers the bar plus `contextPx` physical px on its inner side.
function M.captureGeometry(out, bar, contextPx: number?)
	local s = out.scale or 1
	local ctx = math.ceil((contextPx or 8) / s)
	local T, m = bar.thickness, bar.margin or 0
	local pos = bar.position or "top"
	local x, y, w, h
	if pos == "top" then
		x, y, w, h = out.x, out.y + m, out.width, T + ctx
	elseif pos == "bottom" then
		x, y, w, h = out.x, out.y + out.height - m - T - ctx, out.width, T + ctx
	elseif pos == "left" then
		x, y, w, h = out.x + m, out.y, T + ctx, out.height
	else
		x, y, w, h = out.x + out.width - m - T - ctx, out.y, T + ctx, out.height
	end
	local flipped = pos == "bottom" or pos == "right"
	return {
		geometry = string.format("%d,%d %dx%d", x, y, w, h),
		transpose = pos == "left" or pos == "right",
		flipped = flipped,
		barPx = math.floor(T * s + 0.5),
		vDir = if flipped then -1 else 1,
		scale = s,
	}
end

-- Physical row ranges {y0, y1} of the bar and of the scored band (bar + the
-- 2 rows of its inner edge) in an image with `rows` rows.
function M.rowLayout(flipped: boolean, rows: number, barPx: number)
	local b = math.min(barPx, rows)
	if flipped then
		local c = rows - b
		return { c, rows }, { math.max(c - 2, 0), rows }
	end
	return { 0, b }, { 0, math.min(b + 2, rows) }
end

function M.pruneRegistry(reg, now: number, stale: number)
	local out, changed = {}, false
	for id, info in pairs(reg) do
		if now - (info.t or 0) <= stale then
			out[id] = info
		else
			changed = true
		end
	end
	return out, changed
end

-- Physical px each group is displaced by, for spacer offsets (logical px).
function M.displacements(layout, offsets)
	local out = {}
	for gi, g in ipairs(layout.groups) do
		local d = 0
		for slot, f in pairs(g.factors) do
			d += (offsets[slot] or 0) * f
		end
		out[gi] = math.floor(d + 0.5)
	end
	return out
end

local function tomlString(s: string): string
	local escaped = string.gsub(string.gsub(s, "\\", "\\\\"), '"', '\\"')
	return '"' .. escaped .. '"'
end

function M.verticalToml(barName: string, margin: number, thickness: number): string
	return table.concat({
		"# Written by the Pixel Shift plugin (mgeldi/pixel-shift) while vertical shift is on.",
		"# It moves the bar content by a pixel or two; the plugin removes this file when",
		"# vertical shift is turned off. Safe to delete.",
		"[bar." .. tomlString(barName) .. "]",
		string.format("margin_edge = %d", margin),
		string.format("thickness = %d", thickness),
		"",
	}, "\n")
end

function M.side(x: number, w: number): string
	if x < w / 3 then
		return "left"
	elseif x < 2 * w / 3 then
		return "center"
	end
	return "right"
end

return M
