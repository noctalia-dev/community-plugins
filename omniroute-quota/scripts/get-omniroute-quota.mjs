#!/usr/bin/env node

import {
  createDecipheriv,
  scryptSync,
} from "node:crypto"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { DatabaseSync } from "node:sqlite"
import { pathToFileURL } from "node:url"

const ENCRYPTION_PREFIX = "enc:v1:"
const ENCRYPTION_SALT = "omniroute-field-encryption-v1"
const USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"

function parseEnv(source) {
  const values = {}
  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith("#") || !line.includes("=")) continue
    const separator = line.indexOf("=")
    const key = line.slice(0, separator).trim()
    let value = line.slice(separator + 1).trim()
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1)
    }
    values[key] = value
  }
  return values
}

export function decryptCredential(value, secret) {
  if (!value || !value.startsWith(ENCRYPTION_PREFIX)) return value || ""
  if (!secret) throw new Error("STORAGE_ENCRYPTION_KEY is missing")

  const parts = value.slice(ENCRYPTION_PREFIX.length).split(":")
  if (parts.length !== 3) throw new Error("Malformed encrypted credential")

  const [ivHex, ciphertextHex, authTagHex] = parts
  const key = scryptSync(secret, ENCRYPTION_SALT, 32)
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(ivHex, "hex"), {
    authTagLength: 16,
  })
  decipher.setAuthTag(Buffer.from(authTagHex, "hex"))
  return decipher.update(ciphertextHex, "hex", "utf8") + decipher.final("utf8")
}

function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {}
}

function number(value, fallback = 0) {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : fallback
}

function resetAt(window) {
  const timestamp = number(window.reset_at ?? window.resetAt)
  if (timestamp > 0) return new Date(timestamp * 1000).toISOString()
  const remaining = number(window.reset_after_seconds ?? window.resetAfterSeconds)
  return remaining > 0 ? new Date(Date.now() + remaining * 1000).toISOString() : null
}

function parseWindow(key, label, value) {
  const window = asObject(value)
  if (Object.keys(window).length === 0) return null
  const usedPercent = Math.max(0, Math.min(100, number(window.used_percent ?? window.usedPercent)))
  const reset = resetAt(window)
  return {
    key,
    label,
    usedPercent,
    remainingPercent: 100 - usedPercent,
    resetAt: reset,
    resetEpoch: reset ? Math.floor(new Date(reset).getTime() / 1000) : null,
    durationSeconds: number(window.limit_window_seconds ?? window.limitWindowSeconds),
  }
}

export function parseUsageResponse(payload) {
  const data = asObject(payload)
  const rateLimit = asObject(data.rate_limit ?? data.rateLimit)
  const windows = [
    parseWindow("session", "5 hours", rateLimit.primary_window ?? rateLimit.primaryWindow),
    parseWindow("weekly", "Weekly", rateLimit.secondary_window ?? rateLimit.secondaryWindow),
  ].filter(Boolean)

  return {
    plan: data.plan_type ?? data.planType ?? null,
    limitReached: Boolean(rateLimit.limit_reached ?? rateLimit.limitReached),
    windows,
  }
}

function readConfiguration(home) {
  const dataDir = process.env.OMNIROUTE_DATA_DIR || path.join(home, ".omniroute")
  const envPath = path.join(dataDir, ".env")
  const env = fs.existsSync(envPath) ? parseEnv(fs.readFileSync(envPath, "utf8")) : {}
  return {
    databasePath: path.join(dataDir, "storage.sqlite"),
    encryptionKey: process.env.STORAGE_ENCRYPTION_KEY || env.STORAGE_ENCRYPTION_KEY || "",
  }
}

function accountRows(db, showInactive) {
  return db.prepare(`
    SELECT id, name, email, is_active, access_token, provider_specific_data
    FROM provider_connections
    WHERE provider = 'codex' AND (? = 1 OR is_active = 1)
    ORDER BY priority ASC, created_at ASC
  `).all(showInactive ? 1 : 0)
}

function localUsage(db, connectionId) {
  const query = (modifier) => db.prepare(`
    SELECT
      COUNT(*) AS requests,
      COALESCE(SUM(tokens_in), 0) AS input_tokens,
      COALESCE(SUM(tokens_out), 0) AS output_tokens,
      COALESCE(SUM(tokens_cache_read), 0) AS cache_tokens
    FROM call_logs
    WHERE connection_id = ?
      AND status >= 200 AND status < 300
      AND datetime(timestamp) >= datetime('now', ?)
  `).get(connectionId, modifier)

  const normalize = (row) => ({
    requests: number(row.requests),
    inputTokens: number(row.input_tokens),
    outputTokens: number(row.output_tokens),
    cacheTokens: number(row.cache_tokens),
  })
  return {
    today: normalize(query("start of day")),
    week: normalize(query("-7 days")),
  }
}

async function fetchAccount(row, encryptionKey, db) {
  let providerData = {}
  try {
    providerData = JSON.parse(row.provider_specific_data || "{}")
  } catch {
    providerData = {}
  }

  const accountId = providerData.workspaceId ||
    providerData.chatgptAccountId ||
    providerData.chatgpt_account_id ||
    ""

  const base = {
    id: row.id,
    name: row.email || row.name || "Codex account",
    active: Boolean(row.is_active),
    localUsage: localUsage(db, row.id),
  }

  try {
    const accessToken = decryptCredential(row.access_token, encryptionKey)
    if (!accessToken) throw new Error("No access token")

    const headers = {
      Authorization: `Bearer ${accessToken}`,
      Accept: "application/json",
    }
    if (accountId) headers["chatgpt-account-id"] = accountId

    const response = await fetch(USAGE_URL, {
      headers,
      signal: AbortSignal.timeout(8000),
    })
    if (!response.ok) throw new Error(`Quota API returned HTTP ${response.status}`)

    return { ...base, ...parseUsageResponse(await response.json()), error: null }
  } catch (error) {
    return {
      ...base,
      plan: providerData.workspacePlanType || providerData.chatgptPlanType || null,
      limitReached: false,
      windows: [],
      error: error instanceof Error ? error.message : String(error),
    }
  }
}

export async function collect(options = {}) {
  const home = options.home || os.homedir()
  const config = readConfiguration(home)
  if (!fs.existsSync(config.databasePath)) {
    throw new Error(`OmniRoute database not found: ${config.databasePath}`)
  }

  const db = new DatabaseSync(config.databasePath, { readOnly: true })
  try {
    const rows = accountRows(db, Boolean(options.showInactive))
    const accounts = []
    for (const row of rows) {
      accounts.push(await fetchAccount(row, config.encryptionKey, db))
    }

    const remaining = accounts.flatMap((account) =>
      account.windows.map((window) => window.remainingPercent)
    )
    return {
      ok: true,
      updatedAt: new Date().toISOString(),
      accounts,
      summary: {
        accountCount: accounts.length,
        availableCount: accounts.filter((account) => account.windows.length > 0).length,
        worstRemainingPercent: remaining.length > 0 ? Math.min(...remaining) : null,
      },
    }
  } finally {
    db.close()
  }
}

async function main() {
  const showInactive = process.argv.includes("--show-inactive")
  try {
    console.log(JSON.stringify(await collect({ showInactive })))
  } catch (error) {
    console.log(JSON.stringify({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      accounts: [],
    }))
    process.exitCode = 1
  }
}

const invokedPath = process.argv[1] && fs.existsSync(process.argv[1])
  ? fs.realpathSync(process.argv[1])
  : process.argv[1] || ""

if (import.meta.url === pathToFileURL(invokedPath).href) {
  await main()
}
