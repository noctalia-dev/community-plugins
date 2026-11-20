--!nonstrict
-- LED colors. Every color the user leaves empty is derived from the theme's
-- primary color: the read (or shared) LED is primary itself, the write LED a
-- variant of the read color mixed toward on_surface, so it is lighter on dark
-- themes and darker on light ones.
--
-- Color specs are palette roles ("primary", "primary/0.8") or hex values
-- ("#RRGGBB", "#RRGGBBAA"). `lookup(role)` returns a role's "#RRGGBB", as
-- noctalia.getColor does.

local M = {}

-- How far the write LED moves from the read color toward on_surface.
M.VARIANT_MIX = 0.45

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.isEmpty(spec)
	return trim(spec) == ""
end

local function hexToRgb(hex)
	local r, g, b = tostring(hex or ""):match("^#(%x%x)(%x%x)(%x%x)")
	if r == nil then
		return nil
	end
	return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

-- The spec as "#RRGGBB", nil when it cannot be resolved.
function M.resolve(spec, lookup)
	local clean = trim(spec)
	local hex = clean:match("^(#%x%x%x%x%x%x)")
	if hex ~= nil then
		return hex:upper()
	end
	local role = clean:match("^([^/]+)")
	if role == nil then
		return nil
	end
	local value = lookup(role)
	if value == nil then
		return nil
	end
	return tostring(value):sub(1, 7):upper()
end

-- a mixed toward b by t (0-1); nil when either does not resolve.
function M.mix(a, b, t)
	local ar, ag, ab = hexToRgb(a)
	local br, bg, bb = hexToRgb(b)
	if ar == nil or br == nil then
		return nil
	end
	local function channel(x, y)
		return math.floor(x + (y - x) * t + 0.5)
	end
	return string.format("#%02X%02X%02X", channel(ar, br), channel(ag, bg), channel(ab, bb))
end

-- The write-LED variant of a read color.
function M.variant(spec, lookup)
	local base = M.resolve(spec, lookup)
	local toward = lookup("on_surface")
	return M.mix(base, toward, M.VARIANT_MIX) or spec
end

-- Parses one per-disk entry: "read" or "read,write". Empty parts are nil.
function M.parseDiskEntry(value)
	local read, write = tostring(value or ""):match("^([^,]*),?(.*)$")
	read, write = trim(read), trim(write)
	return read ~= "" and read or nil, write ~= "" and write or nil
end

-- Read and write color for one disk. Per-disk entries win over the global
-- colors; an empty read color is primary, an empty write color the variant
-- of whatever read color applies.
function M.forDisk(entry, globalRead, globalWrite, lookup)
	local entryRead, entryWrite = M.parseDiskEntry(entry)
	local read = entryRead
	if read == nil then
		read = M.isEmpty(globalRead) and "primary" or trim(globalRead)
	end
	local write = entryWrite
	if write == nil then
		-- A disk with its own read color gets its own variant, not the
		-- global write color, so its pair stays one color family.
		if entryRead == nil and not M.isEmpty(globalWrite) then
			write = trim(globalWrite)
		else
			write = M.variant(read, lookup)
		end
	end
	return read, write
end

return M
