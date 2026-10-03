-- Pure Luau implementation of SHA-256.
-- Uses standard bit32 library (built-in in Luau).

local b32 = bit32
local band = b32.band
local bor = b32.bor
local bxor = b32.bxor
local bnot = b32.bnot
local rrotate = b32.rrotate
local rshift = b32.rshift
local lshift = b32.lshift

local table_create = table.create or function(n, val)
    local t = {}
    for i = 1, n do
        t[i] = val
    end
    return t
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function add(a, b)
    return (a + b) % 4294967296
end

local function add3(a, b, c)
    return (a + b + c) % 4294967296
end

local function add4(a, b, c, d)
    return (a + b + c + d) % 4294967296
end

local function add5(a, b, c, d, e)
    return (a + b + c + d + e) % 4294967296
end

local function sha256_hex(msg)
    local len = #msg
    local bit_len = len * 8

    -- Padding: message + 0x80 + zeros + 64-bit length
    local pad_len = (56 - (len + 1) % 64) % 64
    local pad = "\128" .. string.rep("\0", pad_len)
    
    local high_bits = math.floor(bit_len / 4294967296)
    local low_bits = bit_len % 4294967296
    local len_bytes = string.char(
        rshift(high_bits, 24),
        band(rshift(high_bits, 16), 0xff),
        band(rshift(high_bits, 8), 0xff),
        band(high_bits, 0xff),
        rshift(low_bits, 24),
        band(rshift(low_bits, 16), 0xff),
        band(rshift(low_bits, 8), 0xff),
        band(low_bits, 0xff)
    )
    local full_msg = msg .. pad .. len_bytes

    local h0 = 0x6a09e667
    local h1 = 0xbb67ae85
    local h2 = 0x3c6ef372
    local h3 = 0xa54ff53a
    local h4 = 0x510e527f
    local h5 = 0x9b05688c
    local h6 = 0x1f83d9ab
    local h7 = 0x5be0cd19

    local w = table_create(64, 0)
    local total_len = #full_msg

    for chunk_start = 1, total_len, 64 do
        for i = 0, 15 do
            local pos = chunk_start + i * 4
            local b1, b2, b3, b4 = string.byte(full_msg, pos, pos + 3)
            w[i + 1] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
        end

        for i = 16, 63 do
            local w15 = w[i - 15 + 1]
            local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
            local w2 = w[i - 2 + 1]
            local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19), rshift(w2, 10))
            w[i + 1] = add4(w[i - 16 + 1], s0, w[i - 7 + 1], s1)
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7

        for i = 0, 63 do
            local s1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = add5(h, s1, ch, K[i + 1], w[i + 1])
            local s0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = add(s0, maj)

            h = g
            g = f
            f = e
            e = add(d, temp1)
            d = c
            c = b
            b = a
            a = add(temp1, temp2)
        end

        h0 = add(h0, a)
        h1 = add(h1, b)
        h2 = add(h2, c)
        h3 = add(h3, d)
        h4 = add(h4, e)
        h5 = add(h5, f)
        h6 = add(h6, g)
        h7 = add(h7, h)
    end

    return string.format(
        "%08x%08x%08x%08x%08x%08x%08x%08x",
        h0, h1, h2, h3, h4, h5, h6, h7
    )
end

return {
    hex = sha256_hex
}
