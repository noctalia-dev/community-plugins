local icon = require("../lib/status_icon")
local t = require("./testlib")

local function fixture()
    local f = { enabled = false, cache = nil, info = nil, path = nil, image = nil, glyph = nil, role = nil }
    f.host = {
        getConfig = function(key)
            t.expectEqual(key, "use_themed_logos")
            return f.enabled
        end,
        getenv = function(name)
            t.expectEqual(name, "XDG_CACHE_HOME")
            return f.cache
        end,
        expandPath = function(path)
            t.expectEqual(path, "~/.cache")
            return "/home/test/.cache"
        end,
        fileInfo = function(path)
            f.path = path
            if f.info == nil then
                return nil, "File not found"
            end
            return { size = f.info.size, isDir = f.info.isDir, mtime = 0 }, nil
        end,
    }
    f.widget = {
        setGlyph = function(name)
            f.glyph = name
            f.image = nil
        end,
        setGlyphColor = function(role, mode)
            f.role = role
            t.expectEqual(mode, "script")
        end,
        setImage = function(path, watch, width, height)
            f.image = path
            f.glyph = nil
            t.expectEqual(watch, true)
            t.expectEqual(width, 28)
            t.expectEqual(height, 28)
        end,
    }
    return f
end

t.test("icon defaults to snowflake with matching palette roles and no file checks", function()
    local f = fixture()
    for state, role in pairs({ idle = "on_surface", unconfigured = "on_surface", checking = "on_surface",
        current = "on_surface", updates = "primary", error = "error" }) do
        icon.show(f.host, f.widget, state)
        t.expectEqual(f.glyph, "snowflake")
        t.expectEqual(f.role, role)
        t.expectNil(f.path)
    end
end)

t.test("themed icons select state variants using XDG cache home", function()
    local f = fixture()
    f.enabled = true
    f.cache = "/custom/cache"
    f.info = { size = 120, isDir = false }
    for state, filename in pairs({ current = "nix-logo.svg", updates = "nix-logo-updates.svg",
        error = "nix-logo-error.svg" }) do
        icon.show(f.host, f.widget, state)
        t.expectEqual(f.image, "/custom/cache/noctalia/" .. filename)
    end
end)

t.test("themed icons default unset or empty XDG cache home to home cache", function()
    local f = fixture()
    f.enabled = true
    f.info = { size = 120, isDir = false }
    icon.show(f.host, f.widget, "idle")
    t.expectEqual(f.image, "/home/test/.cache/noctalia/nix-logo.svg")
    f.cache = ""
    icon.show(f.host, f.widget, "idle")
    t.expectEqual(f.image, "/home/test/.cache/noctalia/nix-logo.svg")
end)

t.test("missing empty or directory logo falls back to the state-colored glyph", function()
    local f = fixture()
    f.enabled = true
    icon.show(f.host, f.widget, "error")
    t.expectEqual(f.glyph, "snowflake")
    t.expectEqual(f.role, "error")
    for _, info in ipairs({ { size = 0, isDir = false }, { size = 120, isDir = true } }) do
        f.info = info
        icon.show(f.host, f.widget, "updates")
        t.expectEqual(f.glyph, "snowflake")
        t.expectEqual(f.role, "primary")
    end
end)

t.test("icon recovers when a logo appears and falls back when removed or disabled", function()
    local f = fixture()
    f.enabled = true
    icon.show(f.host, f.widget, "current")
    t.expectEqual(f.glyph, "snowflake")
    f.info = { size = 120, isDir = false }
    icon.show(f.host, f.widget, "current")
    t.expectTruthy(f.image)
    f.info = nil
    icon.show(f.host, f.widget, "current")
    t.expectNil(f.image)
    t.expectEqual(f.glyph, "snowflake")
    f.info = { size = 120, isDir = false }
    icon.show(f.host, f.widget, "current")
    f.enabled = false
    icon.show(f.host, f.widget, "current")
    t.expectNil(f.image)
    t.expectEqual(f.glyph, "snowflake")
end)

return true
