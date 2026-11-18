--!nonstrict
-- UI → service commands over shared state (spec §9.3, D30).
--
-- A state-watch event can be dropped when the receiving entry's queue is full (spike S5),
-- so commands are acknowledged and retried:
-- - every sender has a unique id (`from`) and numbers its commands with an increasing
--   `seq`; it publishes its unacknowledged commands on `shift.cmd` as `{ from, cmds }`;
-- - the service handles each `(from, seq)` at most once and publishes
--   `shift.ack = { [from] = { seq, ok, error } }` with the last handled seq;
-- - the sender drops acknowledged commands and re-publishes the rest after 1 s, up to
--   5 attempts, then gives up and reports the failure.
--
-- All senders share the `shift.cmd` key: every `set` fires the watch (no deduplication),
-- so a value overwritten by another sender has already been delivered, or was dropped
-- and will be retried. Command types are idempotent, so a command handled again after
-- a service reload (which forgets the handled seqs) changes nothing.

local Types = require("./types.luau")

type Command = Types.Command
type Host = Types.Host
type Result = Types.Result

export type Sender = {
  from: string,
  send: (cmd: { [string]: any }) -> number,
  tick: () -> (),
  pendingCount: () -> number,
}

type Pending = { cmd: Command, attempts: number, sentAtMs: number }

local Commands = {}

Commands.KEY = "shift.cmd"
Commands.ACK_KEY = "shift.ack"

local RETRY_MS = 1000
local MAX_ATTEMPTS = 5
local ACK_TTL_MS = 60 * 1000

-- Sender ---------------------------------------------------------------------

-- `kind` names the entry ("bar", "dashboard", "tile"). Every runtime gets its own `from`,
-- made of its load time and a random number, so two bar widgets, or a widget before and
-- after a reload, never share a seq sequence even if their random generators did.
--
-- `onFailure(cmd, error)` is called when a command is rejected by the service
-- (`error` is its code) or never acknowledged (`error` is "timeout").
function Commands.sender(host: Host, kind: string, onFailure: ((cmd: Command, error: string?) -> ())?): Sender
  local from = string.format("%s.%x-%x", kind, host.nowMs(), math.random(0, 0xffffff))
  local seq = 0
  local pending: { Pending } = {}

  local function publish()
    local cmds = {}
    for _, entry in pending do
      table.insert(cmds, entry.cmd)
    end
    host.state.set(Commands.KEY, { from = from, cmds = cmds })
  end

  host.state.watch(Commands.ACK_KEY, function(acks)
    local ack = type(acks) == "table" and acks[from]
    if type(ack) ~= "table" or type(ack.seq) ~= "number" then
      return
    end
    local kept = {}
    for _, entry in pending do
      if entry.cmd.seq > ack.seq then
        table.insert(kept, entry)
      elseif entry.cmd.seq == ack.seq and not ack.ok and onFailure then
        onFailure(entry.cmd, ack.error)
      end
    end
    pending = kept
  end)

  local sender = { from = from } :: Sender

  -- Sends a command such as `{ type = "checkin" }`; returns its seq.
  function sender.send(cmd: { [string]: any }): number
    seq += 1
    local message = table.clone(cmd)
    message.seq = seq
    table.insert(pending, { cmd = message, attempts = 1, sentAtMs = host.nowMs() })
    publish()
    return seq
  end

  -- Retries unacknowledged commands; call it from the entry's update().
  function sender.tick(): ()
    local now, retry = host.nowMs(), false
    local kept = {}
    for _, entry in pending do
      if now - entry.sentAtMs < RETRY_MS then
        table.insert(kept, entry)
      elseif entry.attempts < MAX_ATTEMPTS then
        entry.attempts += 1
        entry.sentAtMs = now
        retry = true
        table.insert(kept, entry)
      elseif onFailure then
        onFailure(entry.cmd, "timeout")
      end
    end
    pending = kept
    if retry then
      publish()
    end
  end

  function sender.pendingCount(): number
    return #pending
  end

  return sender
end

-- Receiver -------------------------------------------------------------------

-- `handle(cmd, from)` applies a command and returns `{ ok, error? }`. An error raised by
-- the handler is logged and acknowledged as `internal`, so the sender stops retrying.
function Commands.receiver(host: Host, handle: (cmd: Command, from: string) -> Result)
  local lastSeq: { [string]: number } = {}
  local acks: { [string]: { seq: number, ok: boolean, error: string?, atMs: number } } = {}

  local function publishAcks()
    local now = host.nowMs()
    local value = {}
    for from, ack in acks do
      if now - ack.atMs > ACK_TTL_MS then
        acks[from] = nil
      else
        value[from] = { seq = ack.seq, ok = ack.ok, error = ack.error }
      end
    end
    host.state.set(Commands.ACK_KEY, value)
  end

  host.state.watch(Commands.KEY, function(message)
    if type(message) ~= "table" or type(message.from) ~= "string" or type(message.cmds) ~= "table" then
      return
    end
    local from = message.from
    for _, cmd in message.cmds do
      if type(cmd) == "table" and type(cmd.seq) == "number" and cmd.seq > (lastSeq[from] or 0) then
        lastSeq[from] = cmd.seq
        local ok, result = pcall(handle, cmd, from)
        if not ok then
          host.log(string.format("command %s from %s failed: %s", tostring(cmd.type), from, tostring(result)))
          result = { ok = false, error = "internal" }
        end
        acks[from] = { seq = cmd.seq, ok = result.ok, error = result.error, atMs = host.nowMs() }
      end
    end
    -- Re-acknowledge even when nothing was new: the sender is retrying because it
    -- missed the previous acknowledgement.
    if acks[from] then
      acks[from].atMs = host.nowMs()
      publishAcks()
    end
  end)
end

return Commands
