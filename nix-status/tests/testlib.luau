local tests = {}

local function fail(message)
    error(message, 2)
end

local function test(name, callback)
    table.insert(tests, {
        name = name,
        callback = callback,
    })
end

local function expectEqual(actual, expected, message)
    if actual ~= expected then
        fail(
            (message or "Values differ")
                .. "\nExpected: "
                .. tostring(expected)
                .. "\nActual: "
                .. tostring(actual)
        )
    end
end

local function expectNil(actual, message)
    if actual ~= nil then
        fail((message or "Expected nil") .. "\nActual: " .. tostring(actual))
    end
end

local function expectContains(actual, expected, message)
    if type(actual) ~= "string" or not actual:find(expected, 1, true) then
        fail(
            (message or "String does not contain expected text")
                .. "\nExpected to find: "
                .. expected
                .. "\nActual: "
                .. tostring(actual)
        )
    end
end

local function expectTruthy(actual, message)
    if not actual then
        fail(message or "Expected a truthy value")
    end
end

local function run()
    local failures = 0

    for _, entry in ipairs(tests) do
        local passed, err = pcall(entry.callback)
        if passed then
            print("PASS " .. entry.name)
        else
            failures += 1
            print("FAIL " .. entry.name)
            print("     " .. tostring(err):gsub("\n", "\n     "))
        end
    end

    print("")
    print(tostring(#tests - failures) .. "/" .. tostring(#tests) .. " tests passed")

    if failures > 0 then
        error(tostring(failures) .. " test(s) failed", 0)
    end
end

return {
    test = test,
    expectEqual = expectEqual,
    expectNil = expectNil,
    expectContains = expectContains,
    expectTruthy = expectTruthy,
    run = run,
}
