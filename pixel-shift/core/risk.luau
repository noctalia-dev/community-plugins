--!nonstrict
-- Visible burn-in risk: wear that differs from its neighbourhood, at a fine
-- scale (strokes, icon edges) and a coarse scale (blocks, band edges).

local image = require("./image.luau")
local wear = require("./wear.luau")


local budget = require("./budget.luau")
local K = require("./kernels.luau")

local M = {}

M.FINE_R = 1
M.COARSE_R = 10
M.COARSE_W = 0.5
M.BINS = 1024

export type Hist = { bins: { number }, n: number, cap: number }

function M.map(E: image.Image): image.Image
	local g1 = image.gauss3(E, M.FINE_R)
	local g2 = image.gauss3(E, M.COARSE_R)
	local R = image.new(E.w, E.h)
	K.riskCombine(E.data, g1.data, g2.data, R.data, E.w * E.h * 4, M.COARSE_W)
	return R
end

-- Centre weight of three passes of a (2r+1) box: the number of ways three
-- offsets in [-r, r] sum to zero, over (2r+1)^3.
function M.centerWeight(r: number): number
	return (3 * r * r + 3 * r + 1) / (2 * r + 1) ^ 3
end

-- Risk of a 1 px pure-white line on black without shifting: the 100 mark.
-- Closed form of risk.map on that line (horizontal passes leave it alone).
function M.reference(p): number
	local w = wear.white(p)
	return w * ((1 - M.centerWeight(M.FINE_R)) + M.COARSE_W * (1 - M.centerWeight(M.COARSE_R)))
end

-- The engine installs its fast copy of the kernels (see kernels.luau).
function M.install(kernels)
	K = kernels
end

function M.newHist(cap: number): Hist
	return { bins = table.create(M.BINS, 0), n = 0, cap = cap }
end

function M.accumulate(h: Hist, R: image.Image, y0: number, y1: number, x0: number, x1: number)
	local scale = M.BINS / h.cap
	local bins = h.bins
	local top = M.BINS - 1
	local a, b = math.max(x0, 0), math.min(x1, R.w)
	for y = math.max(y0, 0), math.min(y1, R.h) - 1 do
		budget.check()
		if b > a then
			K.histogram(bins, R.data, (y * R.w + a) * 4, b - a, scale, top)
		end
		h.n += math.max(b - a, 0)
	end
end

function M.merge(dst: Hist, src: Hist)
	assert(dst.cap == src.cap, "histogram caps differ")
	K.mergeBins(dst.bins, src.bins, M.BINS)
	dst.n += src.n
end

function M.percentile(h: Hist, q: number): number
	if h.n == 0 then
		return 0
	end
	local target = q * h.n
	local acc = 0
	local width = h.cap / M.BINS
	for i = 1, M.BINS do
		acc += h.bins[i]
		if acc >= target then
			return (i - 0.5) * width
		end
	end
	return h.cap
end

function M.score(h: Hist, rref: number): number
	return 100 * M.percentile(h, 0.99) / rref
end

return M
