local policy = require("../lib/presentation.luau")
local function equal(actual, expected, message)
    assert(actual == expected, (message or "unexpected value") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function percent(value, kind) return { metric = "percent", value = value, kind = kind or "session" } end
local empty = { metric = "unknown", kind = "session" }
local balance = { metric = "balance", value = 0, unit = "USD", kind = "billing" }
local account = { provider = "codex", accountLabel = "private@example.test", windows = { empty, balance, percent(62, "weekly"), percent(0) } }
local other = { provider = "deepseek", windows = { balance }, stale = true }
local providers = { account, other, { provider = "codex", windows = { percent(70) } } }

-- Used display inverts only percentages; warning policy always considers remaining.
equal(policy.percentage(percent(0), "used"), 100, "exhausted means fully used")
equal(policy.percentage(percent(62), "used"), 38)
equal(policy.percentage(percent(62), "remaining"), 62)
equal(policy.percentage(balance, "used"), nil, "balance must not become a percentage")
equal(policy.percentage(empty, "remaining"), nil, "unknown must not become zero")
equal(policy.low(percent(0), 0), true, "zero is low even at threshold zero")
equal(policy.low(percent(20), 20), true, "threshold is inclusive")
equal(policy.low(percent(21), 20), false)
equal(policy.low(balance, 100), false)
equal(policy.low(empty, 100), false)

-- A missing requested account/window must not silently borrow a different one.
local selected, count = policy.account(providers, "codex", 2)
equal(selected, providers[3]); equal(count, 2)
equal(policy.account(providers, "codex", 3), nil)
equal(policy.window(account, "first"), empty)
equal(policy.window(account, "weekly"), account.windows[3])
equal(policy.window(other, "weekly"), nil)
equal(policy.window(other, "lowest"), nil)
equal(policy.window(account, "lowest"), account.windows[4], "zero is lower than unknown and balances")

-- Privacy must apply equally to any caller, including the bar tooltip.
equal(policy.accountLabel(account, false, "Account 1"), "Account 1")
equal(policy.accountLabel(account, true, "Account 1"), "private@example.test")
equal(policy.accountLabel(other, true, "Unnamed account"), "Unnamed account")

local filtered = policy.filtered(providers, "codex")
equal(#filtered, 2); equal(filtered[2].index, 3, "filtered cards retain source identity")
local summary = policy.summary(policy.filtered(providers, "all"), 20)
equal(summary.accounts, 3); equal(summary.low, 1); equal(summary.stale, 1)
equal(policy.summary(policy.filtered(providers, "deepseek"), 20).low, 0)
local page, pages, first, last = policy.pagination(#filtered, 9, 1)
equal(page, 2); equal(pages, 2); equal(first, 2); equal(last, 2)
page, pages, first, last = policy.pagination(0, 9, 4)
equal(page, 1); equal(pages, 1); equal(first, 1); equal(last, 0)
page = policy.pagination(1, 2, 4)
equal(page, 1, "data shrink clamps current page")

local config = { auto_refresh = false, show_account_names = false, accounts_per_page = 200,
    warning_threshold = -10, bar_account_index = 0, percentage_mode = "bogus" }
local settings = policy.settings(function(key) return config[key] end)
equal(settings.auto_refresh, false, "false must survive defaults")
equal(settings.show_account_names, false)
equal(settings.accounts_per_page, 8); equal(settings.warning_threshold, 0)
equal(settings.bar_account_index, 1); equal(settings.percentage_mode, "remaining")
print("presentation cases passed")
