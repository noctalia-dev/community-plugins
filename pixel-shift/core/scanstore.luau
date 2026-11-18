--!nonstrict
-- Binary form of a scan: baseline and background, each as linear RGB f32.

local image = require("./image.luau")

local M = {}
M.MAGIC = "PSS1"
local HEADER = "<c4I4I4"

function M.encode(base, bg): string
	local parts = { string.pack(HEADER, M.MAGIC, base.w, base.h) }
	for _, lin in ipairs({ base, bg }) do
		for _, ch in ipairs({ lin.r, lin.g, lin.b }) do
			table.insert(parts, buffer.tostring(ch.data))
		end
	end
	return table.concat(parts)
end

function M.decode(s: string?)
	if type(s) ~= "string" or #s < string.packsize(HEADER) then
		return nil
	end
	local magic, w, h, pos = string.unpack(HEADER, s)
	if magic ~= M.MAGIC or w <= 0 or h <= 0 then
		return nil
	end
	local plane = w * h * 4
	if #s ~= pos - 1 + 6 * plane then
		return nil
	end
	local src = buffer.fromstring(s)
	local out = {}
	for i = 1, 2 do
		local lin = image.rgbNew(w, h)
		for _, ch in ipairs({ lin.r, lin.g, lin.b }) do
			buffer.copy(ch.data, 0, src, pos - 1, plane)
			pos += plane
		end
		out[i] = lin
	end
	return out[1], out[2]
end

return M
