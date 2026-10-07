import assert from "node:assert/strict"
import test from "node:test"

import {
  deduplicateOpenCodeCredentials,
  parseUsageResponse,
  sortAccounts,
} from "../scripts/get-omniroute-quota.mjs"

function jwt(payload) {
  return `x.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.x`
}

test("normalizes Codex 5-hour and weekly windows", () => {
  const result = parseUsageResponse({
    plan_type: "plus",
    rate_limit: {
      limit_reached: false,
      primary_window: { used_percent: 42, reset_at: 1787726107 },
      secondary_window: { used_percent: 7, reset_at: 1788312907 },
    },
  })

  assert.equal(result.plan, "plus")
  assert.equal(result.windows.length, 2)
  assert.deepEqual(result.windows.map((window) => window.remainingPercent), [58, 93])
  assert.equal(result.windows[0].key, "session")
  assert.equal(result.windows[0].resetEpoch, 1787726107)
  assert.equal(result.windows[1].key, "weekly")
})

test("clamps malformed percentages", () => {
  const result = parseUsageResponse({
    rate_limit: {
      primary_window: { used_percent: 120 },
      secondary_window: { used_percent: -4 },
    },
  })

  assert.deepEqual(result.windows.map((window) => window.remainingPercent), [0, 100])
})

test("deduplicates OpenCode credentials by account and keeps the newest generation", () => {
  const accountClaim = "https://api.openai.com/auth"
  const rows = [
    {
      label: "old alias",
      active: 0,
      time_updated: 10,
      value: JSON.stringify({
        type: "oauth",
        access: jwt({ email: "one@example.com", iat: 100, exp: 200, [accountClaim]: { chatgpt_account_id: "account-1" } }),
        refresh: "old",
      }),
    },
    {
      label: "one@example.com",
      active: 1,
      time_updated: 20,
      value: JSON.stringify({
        type: "oauth",
        access: jwt({ email: "one@example.com", iat: 150, exp: 250, [accountClaim]: { chatgpt_account_id: "account-1" } }),
        refresh: "new",
      }),
    },
    {
      label: "two@example.com",
      active: 0,
      value: {
        type: "oauth",
        access: jwt({ email: "two@example.com", iat: 120, exp: 220, [accountClaim]: { chatgpt_account_id: "account-2" } }),
      },
    },
    { label: "broken", value: "not JSON" },
  ]

  const credentials = deduplicateOpenCodeCredentials(rows)
  assert.equal(credentials.length, 2)
  assert.equal(credentials.find((item) => item.accountId === "account-1").refresh, "new")
  assert.equal(credentials.find((item) => item.accountId === "account-1").selected, true)
})

test("sorts usable accounts by their most restrictive remaining quota", () => {
  const accounts = [
    { name: "error", active: true, windows: [], error: "HTTP 401" },
    { name: "exhausted", active: true, windows: [{ remainingPercent: 0 }], error: null },
    { name: "lower", active: true, windows: [{ remainingPercent: 40 }, { remainingPercent: 20 }], error: null },
    { name: "higher", active: true, windows: [{ remainingPercent: 70 }, { remainingPercent: 60 }], error: null },
    { name: "inactive", active: false, windows: [{ remainingPercent: 90 }], error: null },
  ]

  assert.deepEqual(sortAccounts(accounts).map((account) => account.name), [
    "higher", "lower", "exhausted", "inactive", "error",
  ])
})

test("sorts account names alphabetically when configured", () => {
  const accounts = [
    { name: "Zulu", windows: [], error: "HTTP 401" },
    { name: "alpha", windows: [{ remainingPercent: 90 }], error: null },
    { name: "Bravo", windows: [{ remainingPercent: 10 }], error: null },
  ]
  assert.deepEqual(sortAccounts(accounts, "alphabetical").map((account) => account.name), [
    "alpha", "Bravo", "Zulu",
  ])
})
