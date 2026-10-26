--!nonstrict
-- lib/state.luau (Phase 1)
-- Client half of the command protocol shared by the panel and the launcher.
-- One outstanding command per entry; the reply arrives on "evt.<sender>" and
-- is matched by seq. A seq high-water published by the service lets a
-- reloaded entry jump ahead instead of having its first command dropped.
local M = {}

local WATCHDOG_MS = 30000

function M.new(sender)
	local self = { sender = sender, seq = 0, pending = nil }

	-- Reserve the next seq, honouring the service's high-water mark so a
	-- reloaded entry does not restart below what the service already saw.
	function self.reserve()
		local svcs = noctalia.state.get("svc_seq")
		if type(svcs) == "table" and type(svcs[sender]) == "number" and svcs[sender] >= self.seq then
			self.seq = svcs[sender]
		end
		self.seq = self.seq + 1
		return self.seq
	end

	-- Returns false when a command is already in flight.
	function self.send(op, args)
		if self.pending ~= nil then
			return false
		end
		local s = self.reserve()
		self.pending = { seq = s, op = op, since = noctalia.nowMs() }
		noctalia.state.set("cmd." .. sender, { seq = s, op = op, args = args })
		return true
	end

	function self.busy()
		return self.pending ~= nil
	end

	-- Consume a reply that matches the in-flight command; returns the op name
	-- (so the caller can dispatch) or nil when the message is not ours.
	function self.take(msg)
		if type(msg) ~= "table" or self.pending == nil then
			return nil
		end
		if msg.seq ~= self.pending.seq then
			return nil
		end
		local op = self.pending.op
		self.pending = nil
		return op
	end

	-- The service restarted: our in-flight command died with the old VM.
	function self.abandon()
		self.pending = nil
	end

	-- Returns true when an overdue command was cleared.
	function self.watchdog()
		if self.pending ~= nil and (noctalia.nowMs() - (self.pending.since or 0)) > WATCHDOG_MS then
			self.pending = nil
			return true
		end
		return false
	end

	return self
end

return M
