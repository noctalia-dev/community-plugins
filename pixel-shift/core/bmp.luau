--!nonstrict
-- 24-bit uncompressed BMP encoder (bottom-up rows, 4-byte row padding).

local K = require("./kernels.luau")

local M = {}

-- The row loop lives in kernels.luau; the engine swaps in its own fast copy.
function M.install(kernels)
	K = kernels
end

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
	K.bmpRows(img.data, w, h, b, 54, rowSize)
	return buffer.tostring(b)
end

return M
