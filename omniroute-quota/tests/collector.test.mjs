import assert from "node:assert/strict"
import test from "node:test"

import { parseUsageResponse } from "../scripts/get-omniroute-quota.mjs"

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
