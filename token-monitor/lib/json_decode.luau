-- Partition large JSON containers; native JSON still validates every key/value.
-- For bodies larger than 32 KiB, no scalar/key or decoded fragment exceeds
-- 32 KiB, nesting is at most 64, and there are at most 262144 container/comma units.
-- Smaller bodies retain the existing native fast path and its validation policy.
local Json = {}
local CHUNK, SCAN, MAX_DEPTH, MAX_NODES = 32768, 1024, 64, 262144

function Json.decode(body, nativeDecode, step, clock)
  if type(body) ~= "string" then return nil, "invalid_response" end
  if #body > 4 * 1024 * 1024 then return nil, "too_large" end
  if #body <= CHUNK then
    local value, error = nativeDecode(body)
    return value, error ~= nil and "invalid_response" or nil
  end
  clock = clock or os.clock
  local failure, scanned, nodes = nil, 0, 1
  local sliceStarted = clock()
  local function yieldWork()
    if step then step() end
    sliceStarted = clock()
  end
  local function checkpoint(amount)
    scanned += amount
    if scanned >= SCAN then
      scanned = 0
      if clock() - sliceStarted >= 0.008 then yieldWork() end
    end
  end
  local function reject(code) failure = failure or code; return nil end
  local function whitespace(position, last)
    while position <= last do
      local byte = body:byte(position)
      if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then break end
      position += 1; checkpoint(1)
    end
    return position
  end
  -- Bounded string searches check an 8 ms slice through long strings/whitespace. Escapes
  -- are only skipped structurally here; their exact JSON grammar stays native.
  local ends = {}
  local window, windowFirst, windowLast = "", 0, -1
  local function special(position, last, pattern)
    while position <= last do
      if position < windowFirst or position > windowLast then
        windowFirst, windowLast = position, math.min(position + SCAN - 1, #body)
        window = body:sub(windowFirst, windowLast)
      end
      local finish = math.min(windowLast, last)
      local at = window:find(pattern, position - windowFirst + 1)
      local found = at and windowFirst + at - 1 or nil
      if found and found <= finish then checkpoint(found - position + 1); return found end
      checkpoint(finish - position + 1); position = finish + 1
    end
    return nil
  end
  local function stringEnd(position, last)
    if ends[position] then
      if ends[position] <= last then return ends[position] end
      return reject("invalid_response")
    end
    local cursor = position + 1
    while cursor <= last do
      local at = special(cursor, last, '["\\%z\1-\31]')
      if not at then return reject("invalid_response") end
      local byte = body:byte(at)
      if byte == 34 then ends[position] = at; return at end
      if byte ~= 92 or at == last then return reject("invalid_response") end
      local escaped = body:byte(at + 1)
      if escaped < 32 then return reject("invalid_response") end
      cursor = at + 2
    end
    return reject("invalid_response")
  end
  local function node()
    nodes += 1
    if nodes > MAX_NODES then reject("too_large"); return false end
    return true
  end
  local function valueEnd(position, last, depth, countNodes)
    if ends[position] then
      if ends[position] <= last then return ends[position] end
      return reject("invalid_response")
    end
    local first = body:sub(position, position)
    if first == '"' then return stringEnd(position, last) end
    if first ~= "{" and first ~= "[" then
      local at = special(position, last, '[,}%]]')
      return (at or last + 1) - 1
    end
    local stack, starts = {first}, {position}
    if depth + #stack > MAX_DEPTH then return reject("too_large") end
    local cursor = position + 1
    while cursor <= last do
      local at = special(cursor, last, '[%[%]{}",\\%z\1-\31]')
      if not at then return reject("invalid_response") end
      local char = body:sub(at, at)
      if char == '"' then
        local finish = stringEnd(at, last)
        if not finish then return nil end
        cursor = finish + 1
      elseif char == "{" or char == "[" then
        stack[#stack + 1] = char
        starts[#starts + 1] = at
        if depth + #stack > MAX_DEPTH then return reject("too_large") end
        if countNodes and not node() then return nil end
        cursor = at + 1
      elseif char == "}" or char == "]" then
        if stack[#stack] ~= (char == "}" and "{" or "[") then return reject("invalid_response") end
        ends[starts[#starts]] = at
        table.remove(starts)
        table.remove(stack)
        if #stack == 0 then return at end
        cursor = at + 1
      elseif char == "," then
        if countNodes and not node() then return nil end
        cursor = at + 1
      elseif char == "\\" or (body:byte(at) < 32 and char ~= "\t" and char ~= "\n" and char ~= "\r") then
        return reject("invalid_response")
      else cursor = at + 1 end
    end
    return reject("invalid_response")
  end
  local function native(fragment)
    -- Native parse/conversion gets a new callback budget, without scanner work.
    yieldWork()
    local value, error = nativeDecode(fragment)
    -- The native call started in a fresh callback. Its time remains charged to
    -- this slice, so subsequent scanning yields at 8 ms including native work.
    if error ~= nil then return reject("invalid_response") end
    return value
  end
  local parse
  parse = function(first, last, depth)
    first = whitespace(first, last)
    while last >= first do
      local byte = body:byte(last)
      if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then break end
      last -= 1; checkpoint(1)
    end
    if first > last then return reject("invalid_response") end
    if last - first + 1 <= CHUNK then return native(body:sub(first, last)) end
    local opening = body:sub(first, first)
    if opening ~= "{" and opening ~= "[" then return reject("too_large") end
    if depth >= MAX_DEPTH then return reject("too_large") end
    local closing = opening == "{" and "}" or "]"
    if body:sub(last, last) ~= closing then return reject("invalid_response") end
    local object = opening == "{"
    local result, fragments, size, nextIndex = {}, {}, 2, 0
    local function append(key, value)
      if object then result[key] = value else nextIndex += 1; result[nextIndex] = value end
    end
    local function flush()
      if #fragments == 0 then return true end
      local decoded = native("[" .. table.concat(fragments, ",") .. "]")
      if failure then return false end
      for index = 1, #fragments do
        if object then
          local pair = decoded[index]
          append(pair[1], pair[2])
        else append(nil, decoded[index]) end
        checkpoint(1)
      end
      fragments, size = {}, 2
      return true
    end
    local cursor = whitespace(first + 1, last)
    if cursor == last then return result end
    while cursor < last do
      local keyFirst, keyLast
      if object then
        if body:sub(cursor, cursor) ~= '"' then return reject("invalid_response") end
        keyFirst, keyLast = cursor, stringEnd(cursor, last - 1)
        if not keyLast then return nil end
        if keyLast - keyFirst + 1 > CHUNK then return reject("too_large") end
        cursor = whitespace(keyLast + 1, last)
        if body:sub(cursor, cursor) ~= ":" then return reject("invalid_response") end
        cursor = whitespace(cursor + 1, last)
      end
      if cursor >= last then return reject("invalid_response") end
      local valueFirst = cursor
      local valueLast = valueEnd(cursor, last - 1, depth + 1, false)
      if not valueLast then return nil end
      while valueLast >= valueFirst do
        local byte = body:byte(valueLast)
        if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then break end
        valueLast -= 1; checkpoint(1)
      end
      if valueLast < valueFirst then return reject("invalid_response") end
      local entryLength = valueLast - valueFirst + 1 + (object and keyLast - keyFirst + 4 or 0)
      if entryLength + 2 > CHUNK then
        if not flush() then return nil end
        local key = object and native(body:sub(keyFirst, keyLast)) or nil
        if failure then return nil end
        local value = parse(valueFirst, valueLast, depth + 1)
        if failure then return nil end
        append(key, value)
      else
        if size + entryLength + (#fragments > 0 and 1 or 0) > CHUNK and not flush() then return nil end
        fragments[#fragments + 1] = object and ("[" .. body:sub(keyFirst, keyLast) .. "," .. body:sub(valueFirst, valueLast) .. "]")
          or body:sub(valueFirst, valueLast)
        size += entryLength + (#fragments > 1 and 1 or 0)
      end
      cursor = whitespace(valueLast + 1, last)
      local delimiter = body:sub(cursor, cursor)
      if cursor == last and delimiter == closing then break end
      if delimiter ~= "," then return reject("invalid_response") end
      cursor = whitespace(cursor + 1, last)
      if cursor >= last then return reject("invalid_response") end
    end
    if not flush() then return nil end
    return result
  end
  -- Validate the whole structural envelope before decoding any small fragments;
  -- count every container/comma once, not again during recursive partitioning.
  local first = whitespace(1, #body)
  local last = valueEnd(first, #body, 0, true)
  if not last then return nil, failure end
  if whitespace(last + 1, #body) <= #body then return nil, "invalid_response" end
  local value = parse(first, last, 0)
  return value, failure
end
return Json
