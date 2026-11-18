--!nonstrict
-- 8-bit RGB rasters and the binary PPM (P6) reader used for grim captures.

export type Rgb8 = { w: number, h: number, data: buffer }

local ru8, wu8 = buffer.readu8, buffer.writeu8

local budget = require("./budget.luau")

local M = {}

function M.new(w: number, h: number): Rgb8
	return { w = w, h = h, data = buffer.create(w * h * 3) }
end

function M.get(img: Rgb8, x: number, y: number): (number, number, number)
	local o = (y * img.w + x) * 3
	return ru8(img.data, o), ru8(img.data, o + 1), ru8(img.data, o + 2)
end

function M.set(img: Rgb8, x: number, y: number, r: number, g: number, b: number)
	local o = (y * img.w + x) * 3
	wu8(img.data, o, r)
	wu8(img.data, o + 1, g)
	wu8(img.data, o + 2, b)
end

local function isSpace(c)
	return c == 32 or c == 9 or c == 10 or c == 13
end

function M.parse(s: string?): (Rgb8?, string?)
	if type(s) ~= "string" or string.sub(s, 1, 2) ~= "P6" then
		return nil, "not a P6 PPM"
	end
	local n = #s
	local pos = 3
	local fields = {}
	while #fields < 3 do
		while pos <= n do
			local c = string.byte(s, pos)
			if isSpace(c) then
				pos += 1
			elseif c == 35 then
				while pos <= n and string.byte(s, pos) ~= 10 do
					pos += 1
				end
			else
				break
			end
		end
		local start = pos
		while pos <= n do
			local c = string.byte(s, pos)
			if c < 48 or c > 57 then
				break
			end
			pos += 1
		end
		if pos == start then
			return nil, "bad header"
		end
		table.insert(fields, tonumber(string.sub(s, start, pos - 1)))
	end
	if pos > n or not isSpace(string.byte(s, pos)) then
		return nil, "bad header"
	end
	pos += 1
	local w, h, maxval = fields[1], fields[2], fields[3]
	if maxval ~= 255 then
		return nil, "unsupported maxval"
	end
	if w <= 0 or h <= 0 then
		return nil, "bad size"
	end
	local need = w * h * 3
	if n - pos + 1 < need then
		return nil, "truncated"
	end
	local img = M.new(w, h)
	buffer.copy(img.data, 0, buffer.fromstring(s), pos - 1, need)
	return img
end

function M.transpose(img: Rgb8): Rgb8
	local out = M.new(img.h, img.w)
	for y = 0, img.h - 1 do
		budget.check()
		for x = 0, img.w - 1 do
			buffer.copy(out.data, (x * out.w + y) * 3, img.data, (y * img.w + x) * 3, 3)
		end
	end
	return out
end

return M
