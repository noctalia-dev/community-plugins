--!nonstrict
-- The provider adapter contract.
--
-- A provider is a module under providers/<id>/ that returns provider.define{...}.
-- It knows one vendor: where its credentials live, which endpoint reports usage
-- and how to translate that response into model.Snapshot. It never touches the
-- `noctalia` global; everything it may do arrives through the Context, which
-- keeps adapters testable with fakes and makes their side effects reviewable.
--
-- Adding a provider: see CONTRIBUTING.md ("Adding a provider").

local model = require("./model.luau")

local M = {}

export type Context = {
  now: () -> number, -- Unix seconds
  env: (name: string) -> string?,
  expandPath: (path: string) -> string,
  fileExists: (path: string) -> boolean,
  readFile: (path: string) -> string?,
  readJson: (path: string) -> (any, string?), -- table, or (nil, err)
  decodeJson: (text: string) -> (any, string?),
  -- GET a JSON document. done(data) on success, done(nil, ProviderError) otherwise.
  getJson: (url: string, headers: { [string]: string }, done: (any, model.ProviderError?) -> ()) -> (),
  -- classify(status, body) -> ErrorCode? maps vendor-specific error bodies.
  postJson: (url: string, headers: { [string]: string }, body: string, done: (any, model.ProviderError?) -> (), classify: ((number, string) -> string?)?) -> (),
  -- Runs a program directly (argv, no shell). done(nil) when it could not start.
  -- Adapters that spawn must say why in their header comment and in the README.
  run: (argv: { string }, timeoutMs: number, done: (result: { exitCode: number, stdout: string }?) -> ()) -> (),
  which: (name: string) -> boolean, -- is `name` on PATH?
  duration: (seconds: number) -> string, -- "3h 12m", localized
  tr: (key: string, subst: { [string]: any }?) -> string,
  userAgent: string, -- "headroom-noctalia/<version>"; identify honestly to vendors
  -- The account being fetched (providers with `accounts` only, see below).
  home: string?, -- its config folder: read credentials from here
  inHome: (argv: { string }) -> { string }, -- points a CLI command at that folder
  mayRenew: boolean, -- false: never run the CLI to renew this account's session
}

export type Brand = {
  logo: string, -- plugin-relative SVG; monochrome, tinted at runtime
  tint: string, -- logo color: "#rrggbb" or a palette role ("on_surface")
  glyph: string, -- Tabler glyph fallback where an image cannot be used
  dashboard: string?, -- the vendor's usage page, opened from the panel card
}

-- For providers whose CLI keeps its sign-in in a config folder that an
-- environment variable can move. With it, Headroom shows one account per folder
-- (see lib/accounts.luau) and can add accounts through the CLI's own login.
export type Accounts = {
  env: string, -- the variable the CLI reads its folder from ("CLAUDE_CONFIG_DIR")
  default: string, -- the folder when the variable is unset ("~/.claude")
  siblingPrefix: string, -- other folders in $HOME that hold accounts (".claude-")
  command: string, -- the CLI
  fallbacks: { string }?, -- where the CLI may live when it is not on PATH
  login: { string }, -- its interactive login arguments ({ "auth", "login" })
  -- Who is signed in at ctx.home: a stable id (to spot the same account in two
  -- folders) and the email for tooltips. nil when unknown. Local reads only.
  identity: (ctx: Context) -> { id: string, email: string? }?,
}

export type Provider = {
  id: string, -- lowercase, stable; used in settings, state and IPC
  name: string, -- display name (a brand, so not translated)
  brand: Brand,
  -- Cheap local check: are credentials present at all? Runs every tick, so it
  -- must not do network or heavy I/O.
  isConfigured: (ctx: Context) -> boolean,
  -- Fetch and normalize. Call done exactly once.
  fetch: (ctx: Context, done: (model.Snapshot?, model.ProviderError?) -> ()) -> (),
  -- How to fix a not_configured / expired / auth state, already translated.
  signInHint: (ctx: Context) -> string,
  -- Optional: several accounts, one per config folder.
  accounts: Accounts?,
  -- Optional: the pure vendor-JSON -> Snapshot step, exposed for fixture tests.
  parse: ((...any) -> (model.Snapshot?, model.ProviderError?))?,
}

local REQUIRED = { "id", "name", "brand", "isConfigured", "fetch", "signInHint" }

function M.define(spec): Provider
  for _, key in REQUIRED do
    assert(spec[key] ~= nil, `provider is missing required field '{key}'`)
  end
  assert(spec.id:match("^[a-z0-9][a-z0-9_-]*$"), `provider id '{spec.id}' must be lowercase [a-z0-9_-]`)
  for _, key in { "logo", "tint", "glyph" } do
    assert(spec.brand[key] ~= nil, `provider '{spec.id}' brand is missing '{key}'`)
  end
  if spec.accounts then
    for _, key in { "env", "default", "siblingPrefix", "command", "login", "identity" } do
      assert(spec.accounts[key] ~= nil, `provider '{spec.id}' accounts is missing '{key}'`)
    end
  end
  return spec
end

return M
