local root_dir = vim.fn.getcwd()

return {
    cmd = {
        "luau-lsp",
        "lsp",
        "--definitions:@noctalia=" .. root_dir .. "/noctalia.d.luau",
    },
    settings = {
        ["luau-lsp"] = {
            ignoreGlobs = { "**/*.d.luau" },
            platform = {
                type = "standard",
            },
            sourcemap = {
                enabled = false,
            },
        },
    },
}
