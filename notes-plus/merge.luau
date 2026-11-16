-- 3-way merge resolver for the data-loss fix (flush must not overwrite a note
-- changed externally). Pure function: no side effects, no I/O.
--
-- base: what was last loaded/saved by the panel.
-- localBuf: what the user currently has in the editor (possibly dirty).
-- remote: what is on disk right now.
--
-- Returns {status, content} where status is one of:
--   "same"     -> localBuf == remote: nothing to do.
--   "local"    -> remote == base: only the local changed -> save localBuf.
--   "remote"   -> localBuf == base: only the remote changed -> adopt remote.
--   "merged"   -> both changed but compatibly (appends) -> merged content.
--   "conflict" -> both changed incompatibly -> keep localBuf, do not write.

local M = {}

local function isPrefix(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function M.resolve(base, localBuf, remote)
  if localBuf == remote then
    return { status = "same", content = remote }
  end
  if remote == base then
    return { status = "local", content = localBuf }
  end
  if localBuf == base then
    return { status = "remote", content = remote }
  end
  -- Both changed: only combinable if both only appended at the end
  -- (base is a prefix of both). An edit in the middle -> conflict.
  -- An empty base is special: the note was empty, so the two texts are two
  -- different things, not two additions. Merging them would invent a text
  -- that nobody wrote.
  if base ~= "" and isPrefix(localBuf, base) and isPrefix(remote, base) then
    local ls = localBuf:sub(#base + 1)
    local rs = remote:sub(#base + 1)
    if ls == rs then
      return { status = "merged", content = localBuf }
    end
    if isPrefix(rs, ls) then
      return { status = "merged", content = base .. rs }
    end
    if isPrefix(ls, rs) then
      return { status = "merged", content = base .. ls }
    end
    -- Distinct appends: keep both, nothing is lost.
    return { status = "merged", content = base .. ls .. rs }
  end
  return { status = "conflict", content = localBuf }
end

return M
