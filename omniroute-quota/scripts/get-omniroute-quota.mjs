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

function jwtPayload(token) {
  try {
    return JSON.parse(Buffer.from(String(token).split(".")[1], "base64url").toString("utf8"))
  } catch {
    return {}
  }
}

function authIdentity(auth) {
  const value = asObject(auth)
  const claims = jwtPayload(value.access)
  const openaiAuth = asObject(claims["https://api.openai.com/auth"])
  const profile = asObject(claims["https://api.openai.com/profile"])
  const metadata = asObject(value.metadata)
  const email = String(claims.email || profile.email || metadata.email || "").trim().toLowerCase()
  const accountId = String(value.accountId || metadata.accountID || metadata.accountId ||
    openaiAuth.chatgpt_account_id || "").trim()
  const issuedAt = number(claims.iat) * 1000
  const expiresAt = number(value.expires) || number(claims.exp) * 1000
  return { accountId, email, issuedAt, expiresAt }
}

function credentialKey(credential) {
  if (credential.accountId) return `id:${credential.accountId}`
  if (credential.email) return `email:${credential.email}`
  return ""
}

function credentialRank(credential) {
  return Math.max(number(credential.issuedAt), number(credential.expiresAt), number(credential.updatedAt))
}

export function deduplicateOpenCodeCredentials(rows) {
  const unique = new Map()
  for (const row of rows || []) {
    let auth
    try {
      auth = typeof row.value === "string" ? JSON.parse(row.value) : asObject(row.value)
    } catch {
      continue
    }
    if (auth.type !== "oauth" || !auth.access) continue
    const identity = authIdentity(auth)
    const key = credentialKey(identity)
    if (!key) continue
    const credential = {
      ...identity,
      access: auth.access,
      refresh: auth.refresh || "",
      label: String(row.label || identity.email || "OpenAI account"),
      selected: Boolean(row.active),
      updatedAt: number(row.time_updated ?? row.updatedAt),
    }
    const previous = unique.get(key)
    if (!previous || credentialRank(credential) > credentialRank(previous)) unique.set(key, credential)
  }
  return [...unique.values()]
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
  const openCodeDataDir = path.join(process.env.XDG_DATA_HOME || path.join(home, ".local", "share"), "opencode")
  const configuredOpenCodeDb = process.env.OPENCODE_DB || "opencode.db"
  return {
    databasePath: path.join(dataDir, "storage.sqlite"),
    encryptionKey: process.env.STORAGE_ENCRYPTION_KEY || env.STORAGE_ENCRYPTION_KEY || "",
    openCodeDatabasePath: path.isAbsolute(configuredOpenCodeDb)
      ? configuredOpenCodeDb
      : path.join(openCodeDataDir, configuredOpenCodeDb),
    openCodeAuthPath: path.join(openCodeDataDir, "auth.json"),
  }
}

function readOpenCodeCredentials(config) {
  const rows = []
  if (fs.existsSync(config.openCodeDatabasePath)) {
    let db
    try {
      db = new DatabaseSync(config.openCodeDatabasePath, { readOnly: true })
      rows.push(...db.prepare(`
        SELECT label, value, active, time_updated
        FROM credential
        WHERE integration_id = 'openai'
      `).all())
    } catch {
      // Missing, locked, or older databases must not break OmniRoute fallback.
    } finally {
      if (db) db.close()
    }
  }
  if (rows.length === 0 && fs.existsSync(config.openCodeAuthPath)) {
    try {
      const auth = JSON.parse(fs.readFileSync(config.openCodeAuthPath, "utf8")).openai
      if (auth) rows.push({ label: "OAuth", value: auth, active: 1, time_updated: 0 })
    } catch {
      // A malformed or concurrently replaced legacy file must not break OmniRoute fallback.
    }
  }
  return deduplicateOpenCodeCredentials(rows)
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

  const accountId = row.openCodeCredential?.accountId || providerData.workspaceId ||
    providerData.chatgptAccountId ||
    providerData.chatgpt_account_id ||
    ""

  const base = {
    id: row.id,
    name: row.email || row.name || row.openCodeCredential?.email ||
      (row.openCodeCredential?.label !== "OAuth" ? row.openCodeCredential?.label : "") || "Codex account",
    active: Boolean(row.is_active),
    source: row.openCodeCredential ? "opencode" : "omniroute",
    localUsage: localUsage(db, row.id),
  }

  try {
    const accessToken = row.openCodeCredential?.access || decryptCredential(row.access_token, encryptionKey)
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

function normalizedAccountName(account) {
  return String(account.name || "").trim().toLowerCase()
}

function availability(account) {
  const remaining = (account.windows || [])
    .map((window) => Number(window.remainingPercent))
    .filter(Number.isFinite)
  const hasQuota = !account.error && remaining.length > 0
  const usable = account.active !== false && hasQuota && remaining.every((value) => value > 0)
  return {
    tier: usable ? 3 : account.active !== false && hasQuota ? 2 : hasQuota ? 1 : 0,
    remaining: remaining.length > 0 ? Math.min(...remaining) : -1,
  }
}

export function sortAccounts(accounts, order = "availability") {
  const sorted = [...(accounts || [])]
  sorted.sort((left, right) => {
    const leftName = normalizedAccountName(left)
    const rightName = normalizedAccountName(right)
    if (order !== "alphabetical") {
      const leftAvailability = availability(left)
      const rightAvailability = availability(right)
      if (leftAvailability.tier !== rightAvailability.tier) {
        return rightAvailability.tier - leftAvailability.tier
      }
      if (leftAvailability.remaining !== rightAvailability.remaining) {
        return rightAvailability.remaining - leftAvailability.remaining
      }
    }
    if (leftName < rightName) return -1
    if (leftName > rightName) return 1
    return 0
  })
  return sorted
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
    const openCodeCredentials = readOpenCodeCredentials(config)
    const byAccountId = new Map(openCodeCredentials.filter((item) => item.accountId)
      .map((item) => [item.accountId, item]))
    const byEmail = new Map(openCodeCredentials.filter((item) => item.email)
      .map((item) => [item.email, item]))
    const matched = new Set()

    for (const row of rows) {
      let storedAccess = ""
      try {
        storedAccess = decryptCredential(row.access_token, config.encryptionKey)
      } catch {
        // Let fetchAccount report the original OmniRoute credential error if no OpenCode match exists.
      }
      const identity = authIdentity({ access: storedAccess })
      const rowEmail = String(row.email || row.name || "").trim().toLowerCase()
      const credential = (identity.accountId && byAccountId.get(identity.accountId)) ||
        (identity.email && byEmail.get(identity.email)) ||
        (rowEmail && byEmail.get(rowEmail))
      if (credential) {
        row.openCodeCredential = credential
        matched.add(credentialKey(credential))
      }
    }

    for (const credential of openCodeCredentials) {
      const key = credentialKey(credential)
      if (matched.has(key)) continue
      rows.push({
        id: `opencode:${key}`,
        name: credential.email || (credential.label !== "OAuth" ? credential.label : "OpenAI account"),
        email: credential.email || null,
        is_active: 1,
        access_token: "",
        provider_specific_data: "{}",
        openCodeCredential: credential,
      })
    }

    const accounts = []
    for (const row of rows) {
      accounts.push(await fetchAccount(row, config.encryptionKey, db))
    }

    const sortedAccounts = sortAccounts(accounts, options.sortOrder)
    const remaining = sortedAccounts.flatMap((account) =>
      account.windows.map((window) => window.remainingPercent)
    )
    return {
      ok: true,
      updatedAt: new Date().toISOString(),
      accounts: sortedAccounts,
      summary: {
        accountCount: sortedAccounts.length,
        availableCount: sortedAccounts.filter((account) => account.windows.length > 0).length,
        openCodeAccountCount: openCodeCredentials.length,
        worstRemainingPercent: remaining.length > 0 ? Math.min(...remaining) : null,
      },
    }
  } finally {
    db.close()
  }
}

async function main() {
  const showInactive = process.argv.includes("--show-inactive")
  const sortIndex = process.argv.indexOf("--sort")
  const sortOrder = sortIndex >= 0 && process.argv[sortIndex + 1] === "alphabetical"
    ? "alphabetical"
    : "availability"
  try {
    console.log(JSON.stringify(await collect({ showInactive, sortOrder })))
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
