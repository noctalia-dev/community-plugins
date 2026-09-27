--!nonstrict
-- The engine's policy as pure functions: when a scan counts, when to retry,
-- optimise, apply and persist, and what the vertical player does. The engine
-- owns the side effects; these only decide.

local M = {}

M.RETRY_MIN = 60 -- s before the first retry of a failed scan
M.RETRY_MAX = 3600
M.MISMATCHES = 3 -- agreeing mismatched samples before the bar is measured again
M.PERSIST_EVERY = 6 -- samples between writes of the exposure file
M.LAYOUT_FORMAT = 1 -- bump when the saved layout changes shape

function M.backoff(attempt: number): number
	return math.min(M.RETRY_MIN * 2 ^ (math.max(attempt, 1) - 1), M.RETRY_MAX)
end

function M.anyMoving(layout): boolean
	if type(layout) ~= "table" or type(layout.slots) ~= "table" then
		return false
	end
	for _, info in pairs(layout.slots) do
		if info.moves then
			return true
		end
	end
	return false
end

-- A scan where no spacer moves anything shows something other than the bar
-- (a lock screen, a fullscreen app) or badly placed spacers. It never
-- replaces a scan that worked; a first scan is kept so the lab can explain.
function M.acceptScan(layout, hadGood: boolean): boolean
	return M.anyMoving(layout) or not hadGood
end

-- Only a layout where something moves can produce a strategy worth applying:
-- on an idle layout every range comes out 0 and shifting would stop.
function M.autoApply(layout): boolean
	return M.anyMoving(layout)
end

function M.scanOutcome(layout, hadGood: boolean, attempt: number)
	local moving = M.anyMoving(layout)
	return {
		accept = moving or not hadGood,
		optimize = moving,
		retryIn = if moving then nil else M.backoff(attempt),
	}
end

-- Samples that do not match the scan. Only a run of mismatches that agree
-- with each other (a new look, or something covering the bar) leads to a new
-- measurement; changing content that merely fails the match starts over.
function M.mismatch(count: number, agrees: boolean): (number, boolean)
	local n = if agrees and count > 0 then count + 1 else 1
	if n >= M.MISMATCHES then
		return 0, true
	end
	return n, false
end

function M.pickOutput(current: string?, outputs): string?
	if current and outputs[current] then
		return current
	end
	local names = {}
	for name in pairs(outputs) do
		table.insert(names, name)
	end
	table.sort(names)
	return names[1]
end

-- st: scanning, allowed, paused, v (scheduled offset), last (applied offset,
-- -1 = unknown), fileActive, driftDue (a minute since the last repair
-- check). Returns the action and the new `last`.
function M.verticalAction(st): (string, number)
	if st.scanning then
		return "hold", -1 -- the scan removed the override; apply again after it
	end
	if not st.allowed or st.paused then
		return if st.fileActive then "clear" else "none", 0
	end
	if st.v ~= st.last then
		return "apply", st.v
	end
	if st.driftDue and st.fileActive ~= (st.v > 0) then
		return "apply", st.v -- the file was deleted, or is left over
	end
	return "none", st.last
end

-- The user's own margin and thickness, read only while no override is in
-- effect and Noctalia has reloaded since the last change.
function M.verticalBase(base, bar, fileActive: boolean, settled: boolean)
	if fileActive or not settled then
		return base
	end
	if base and base.bar == bar.name and base.margin == bar.margin and base.thickness == bar.rawThickness then
		return base
	end
	return { bar = bar.name, margin = bar.margin, thickness = bar.rawThickness }
end

function M.persistExposure(n: number): boolean
	return n == 1 or n % M.PERSIST_EVERY == 0
end

-- The protection level an automatic run uses: the one the user applied, not
-- a slider position they only previewed.
function M.autoLevel(active, sliderT: number): number
	return (active and active.lambdaT) or sliderT
end

function M.sameStrategy(a, b): boolean
	if type(a) ~= "table" or type(b) ~= "table" or (a.vertical or 0) ~= (b.vertical or 0) then
		return false
	end
	local ra, rb = a.ranges or {}, b.ranges or {}
	for k, v in pairs(ra) do
		if (rb[k] or 0) ~= v then
			return false
		end
	end
	for k, v in pairs(rb) do
		if (ra[k] or 0) ~= v then
			return false
		end
	end
	return true
end

function M.validLayout(l, base): boolean
	return type(l) == "table"
		and l.format == M.LAYOUT_FORMAT
		and type(l.groups) == "table"
		and type(l.slots) == "table"
		and type(l.barRows) == "table"
		and type(l.scoreRows) == "table"
		and base ~= nil
		and l.w == base.w
		and l.h == base.h
end

-- Spacers move widgets only from the outer edge of a section: first in the
-- start section, last in the end section, first or last in the centre.
function M.placement(sections, isSpacer: (string) -> boolean)
	local issues = {}
	local function check(list, want: string, ok: (number, number) -> boolean)
		if type(list) ~= "table" then
			return
		end
		for i, name in ipairs(list) do
			if type(name) == "string" and isSpacer(name) and not ok(i, #list) then
				table.insert(issues, { widget = name, want = want })
			end
		end
	end
	check(sections.start, "start", function(i)
		return i == 1
	end)
	check(sections.center, "center", function(i, n)
		return i == 1 or i == n
	end)
	check(sections["end"], "end", function(i, n)
		return i == n
	end)
	return issues
end

return M
