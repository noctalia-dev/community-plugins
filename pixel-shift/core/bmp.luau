--!nonstrict
-- 24-bit uncompressed BMP encoder (bottom-up rows, 4-byte row padding).

local budget = require("./budget.luau")

local M = {}

function M.encode(img): string
	local w, h = img.w, img.h
	local rowSize = (w * 3 + 3) // 4 * 4
	local size = 54 + rowSize * h
	local b = buffer.create(size)
	buffer.writeu8(b, 0, 66)
	buffer.writeu8(b, 1, 77)
	buffer.writeu32(b, 2, size)
	buffer.writeu32(b, 10, 54)
	buffer.writeu32(b, 14, 40)
	buffer.writei32(b, 18, w)
	buffer.writei32(b, 22, h)
	buffer.writeu16(b, 26, 1)
	buffer.writeu16(b, 28, 24)
	buffer.writeu32(b, 34, rowSize * h)
	buffer.writei32(b, 38, 2835)
	buffer.writei32(b, 42, 2835)
	local src = img.data
	for y = 0, h - 1 do
		budget.check()
		local dst = 54 + (h - 1 - y) * rowSize
		for x = 0, w - 1 do
			local s = (y * w + x) * 3
			local d = dst + x * 3
			buffer.writeu8(b, d, buffer.readu8(src, s + 2))
			buffer.writeu8(b, d + 1, buffer.readu8(src, s + 1))
			buffer.writeu8(b, d + 2, buffer.readu8(src, s))
		end
	end
	return buffer.tostring(b)
end

return M
