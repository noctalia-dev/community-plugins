--!strict

-- Pure-Luau SHA-1 (FIPS 180-1), uint32 math via bit32.
-- Generic primitive shared by auth hashing and content-addressed filenames.

local bit = bit32

local function sha1(msg: string): string
	local mod32 = 0xFFFFFFFF
	local function hex32(n: number)
		local h = "0123456789abcdef"
		local out = {}
		for i = 1, 8 do
			local d = n % 16
			out[9 - i] = h:sub(d + 1, d + 1)
			n = math.floor(n / 16)
		end
		return table.concat(out)
	end
	local bytes = { string.byte(msg, 1, -1) }
	local bits = #bytes * 8
	table.insert(bytes, 0x80)
	while #bytes % 64 ~= 56 do
		table.insert(bytes, 0)
	end
	for i = 1, 8 do
		local shift = (8 - i) * 8
		table.insert(bytes, math.floor(bits / (2 ^ shift)) % 256)
	end

	local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

	for pos = 1, #bytes, 64 do
		local w = {}
		for i = 0, 15 do
			local o = pos + i * 4
			w[i] = bit.bor(
				bit.lshift(bytes[o], 24),
				bit.lshift(bytes[o + 1], 16),
				bit.lshift(bytes[o + 2], 8),
				bytes[o + 3]
			)
		end
		for i = 16, 79 do
			w[i] = bit.lrotate(bit.bxor(bit.bxor(w[i - 3], w[i - 8]), bit.bxor(w[i - 14], w[i - 16])), 1)
		end
		local a, b, c, d, e = h0, h1, h2, h3, h4
		for i = 0, 79 do
			local f, k
			if i <= 19 then
				f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
				k = 0x5A827999
			elseif i <= 39 then
				f = bit.bxor(bit.bxor(b, c), d)
				k = 0x6ED9EBA1
			elseif i <= 59 then
				f = bit.bor(bit.bor(bit.band(b, c), bit.band(b, d)), bit.band(c, d))
				k = 0x8F1BBCDC
			else
				f = bit.bxor(bit.bxor(b, c), d)
				k = 0xCA62C1D6
			end
			local temp = (bit.lrotate(a, 5) + f + e + k + w[i]) % (mod32 + 1)
			e, d, c, b, a = d, c, bit.lrotate(b, 30), a, temp
		end
		h0 = (h0 + a) % (mod32 + 1)
		h1 = (h1 + b) % (mod32 + 1)
		h2 = (h2 + c) % (mod32 + 1)
		h3 = (h3 + d) % (mod32 + 1)
		h4 = (h4 + e) % (mod32 + 1)
	end

	return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3) .. hex32(h4)
end

do
	local abc = sha1("abc")
	assert(abc == "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 self-test failed")
end

return {
	sha1 = sha1,
}
