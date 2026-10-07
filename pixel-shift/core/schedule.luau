--!nonstrict
-- Offsets as a function of wall-clock time. Each slot walks 0..W and back,
-- one pixel per step, dwelling equally on every offset (the endpoints repeat
-- once), which is exactly the uniform distribution the simulator assumes.

local M = {}

M.MULTIPLIERS = { 1.0, 1.154, 1.304, 1.446, 1.593, 1.737, 1.879, 2.021 }
M.VERTICAL_STEP = 1800

function M.triangle(t: number, step: number, W: number): number
	if W <= 0 or step <= 0 then
		return 0
	end
	local period = 2 * (W + 1)
	local k = math.floor(t / step) % period
	return if k <= W then k else period - 1 - k
end

function M.stepSeconds(baseMinutes: number, index: number): number
	return baseMinutes * 60 * M.MULTIPLIERS[(index - 1) % #M.MULTIPLIERS + 1]
end

function M.offsets(strategy, slotOrder, t: number, baseMinutes: number)
	local out = {}
	for i, slot in ipairs(slotOrder) do
		out[slot] = M.triangle(t, M.stepSeconds(baseMinutes, i), strategy.ranges[slot] or 0)
	end
	return out
end

function M.vertical(V: number?, t: number): number
	return M.triangle(t, M.VERTICAL_STEP, V or 0)
end

return M
