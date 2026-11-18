--!nonstrict
-- Ambient colour temperature -> panel warmth, via Noctalia's own night light.
--
-- Route chosen after experiment 0.6 (see docs/DESIGN.md): Noctalia's night light
-- is the only gamma owner on this box that we can drive from a plugin, and it
-- responds to `temperature_day` / `temperature_night` plus
-- `noctalia msg config-reload` at runtime -- verified on hardware. Driving it
-- keeps a single writer of zwlr_gamma_control_v1, which matters because two
-- writers would fight over the same LUT. wl-gammarelay-rs was the fallback and
-- would have introduced a second owner.
--
-- The panel CCT historically tracks the ambient CCT, so the mapping is a clamped
-- linear interpolation between two configurable anchors. It is deliberately not
-- a night-light *schedule* (that is what Noctalia already does); this reacts to
-- the light in the room.
--
-- Everything here is pure, including the config-file edit: splicing is text in,
-- text out, so it is unit-tested without touching a real settings.toml.

local M = {}

M.MAP_DEFAULTS = {
  -- The mapping itself is now the `curve_temperature` setting, evaluated by
  -- curve.luau. Phase 2 removed the two-anchor linear ramp that used to live here:
  -- it was a second, hard-coded curve that the owner could not see or change, and
  -- two curves for one job is how they drift apart.
  min_k = 2500,
  max_k = 6500,

  -- Only rewrite the config when the target moves this far, and never more often
  -- than this. A config reload is cheap but not free, and this is not a
  -- millisecond-scale control loop.
  step_k = 150,
  min_interval_s = 120,
}

--- Clamp a panel temperature into the range this display can actually use.
-- The curve supplies the shape; the clamp is the guard rail, and it stays here
-- rather than in the curve so that an over-eager node cannot command a
-- temperature the panel has no gamma table for.
function M.clamp_k(value, cfg)
  cfg = cfg or M.MAP_DEFAULTS
  if value == nil then return nil end
  if value < cfg.min_k then return cfg.min_k end
  if value > cfg.max_k then return cfg.max_k end
  return value
end

--- Worth rewriting the config for?
function M.should_apply(applied_k, target_k, last_applied_s, now_s, cfg)
  cfg = cfg or M.MAP_DEFAULTS
  if applied_k == nil then return true end
  if math.abs(target_k - applied_k) < cfg.step_k then return false end
  if last_applied_s ~= nil and (now_s - last_applied_s) < cfg.min_interval_s then
    return false
  end
  return true
end

--- Splice the night-light settings into a TOML document as TEXT.
--
-- Never parse-and-reserialise: a TOML round trip would silently delete every
-- comment and reorder every key in a file the user owns. Same discipline as
-- nri-idle's marked-block splice. Only the three keys below are touched, and
-- only inside [nightlight].
--
-- Returns new_text, changed. When nothing needs to change, new_text is the
-- original string byte-for-byte and changed is false, so the caller can skip
-- the write entirely.
function M.splice(text, kelvin)
  local wanted = {
    enabled = "true",
    force = "true",
    temperature_night = tostring(math.floor(kelvin)),
  }

  local had_trailing_newline = text:sub(-1) == "\n"
  local body = had_trailing_newline and text:sub(1, -2) or text
  local lines = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  -- Locate [nightlight] and any of the keys we care about inside it.
  local header_index, in_section
  local present = {}
  for i, line in ipairs(lines) do
    local trimmed = line:gsub("^%s+", "")
    if trimmed:match("^%[") then
      in_section = (trimmed == "[nightlight]")
      if in_section and header_index == nil then header_index = i end
    elseif in_section then
      for key in pairs(wanted) do
        if trimmed:match("^" .. key .. "%s*=") then present[key] = i end
      end
    end
  end

  if header_index == nil then
    -- No night light configured yet: append a fresh section. Appending at EOF is
    -- the only insertion that cannot land inside somebody else's table.
    lines[#lines + 1] = ""
    lines[#lines + 1] = "[nightlight]"
    for _, key in ipairs({ "enabled", "force", "temperature_night" }) do
      lines[#lines + 1] = key .. " = " .. wanted[key]
    end
  else
    -- Rewrite existing keys IN PLACE first. Insertion shifts every later line
    -- number, so recording indices and then inserting would make the rewrites
    -- land one line too high -- which wrote the night temperature over
    -- temperature_day. Order is load-bearing.
    for _, key in ipairs({ "enabled", "force", "temperature_night" }) do
      local index = present[key]
      if index ~= nil then
        local indent = lines[index]:match("^(%s*)")
        lines[index] = indent .. key .. " = " .. wanted[key]
      end
    end

    local missing = {}
    for _, key in ipairs({ "enabled", "force", "temperature_night" }) do
      if present[key] == nil then missing[#missing + 1] = key end
    end
    for i = #missing, 1, -1 do
      local key = missing[i]
      table.insert(lines, header_index + 1, key .. " = " .. wanted[key])
    end
  end

  -- Reproduce the original's trailing-newline state exactly. Forcing one on
  -- would edit a byte outside [nightlight] in a file the user owns, and the
  -- whole point of this function is that it touches nothing it was not asked to.
  local new_text = table.concat(lines, "\n")
  if had_trailing_newline then new_text = new_text .. "\n" end
  if new_text == text then return text, false end
  return new_text, true
end

return M
