--!nonstrict
-- Cooperative time slicing. Noctalia stops any script callback that runs for
-- more than ~25 ms of CPU, so long computations call check() between rows.
-- The engine installs a hook that yields the running coroutine once its
-- slice is used up; with no hook (tests, quick calls) check() does nothing.

local M = {}

M.hook = nil

function M.check()
	local h = M.hook
	if h then
		h()
	end
end

return M
