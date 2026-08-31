local current = nil

local function set(fn)
    current = fn
end

local function call()
    if current then current() end
end

return {
    set = set,
    call = call
}