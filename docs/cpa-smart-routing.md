# CPA Smart Routing

This document defines the product boundary between the official Codex CLI, Codex Auth, and CLIProxyAPI (CPA).

## Product Boundary

- The official Codex CLI remains the terminal client. Codex Auth launches it and supplies a custom provider only for that process.
- Smart launch creates a new Codex session so an older project session cannot retain pre-authorization context. Direct launch keeps its existing resume behavior.
- Smart launch explicitly bypasses HTTP proxies for localhost in its child process so the CPA base URL cannot be intercepted by a system proxy.
- Account-pool selection, health state, and failover are Codex Auth + CPA features. They are not described as native Codex account selection.
- Existing account switching remains available for direct sessions and affects only newly started direct Codex CLI sessions.
- Smart launch never falls back to direct mode silently. A missing or unhealthy CPA runtime produces an actionable error.

The official Codex configuration reference supports custom model providers and invocation-only `--config/-c key=value` overrides. Smart launch therefore uses one-process overrides instead of modifying the user's global configuration.

- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Codex CLI command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli)

## Ownership and Isolation

Codex Auth maintains one logical account catalog containing stable identity, alias, plan, quota snapshots, and routing membership. Direct Codex sessions and CPA sessions keep independent authentication state and never write each other's files.

Linking the same logical account across both paths uses stable account identity after independent authentication. Codex Auth does not continuously copy refreshed OAuth tokens in either direction. This avoids two runtimes racing to rotate or overwrite the same refresh token.

## Registry Schema 5

Each account stores the Boolean field `smart_pool_enabled`.

- Existing records without the field and newly added accounts default to `false`.
- Users may explicitly exclude an account without deleting it or changing direct-session behavior.
- The field is routing metadata only. It does not imply that a CPA account session has already been connected or is healthy.
- Authentication snapshots and filename conventions are unchanged.

## Runtime Contract

The managed runtime is pinned to CLIProxyAPI `7.2.109`. The installer verifies the
official release archive SHA-256 before placing the binary and starting a user-level
LaunchAgent.

- Runtime root: `~/Library/Application Support/Codex Auth/CPA`
- CPA configuration: `config.yaml`, mode `0600`
- App client configuration: `client.json`, mode `0600`
- CPA OAuth sessions: `auth/`, separate from `~/.codex`
- Service: `~/Library/LaunchAgents/com.boyan.codex-auth-cpa.plist`

The runtime:

- Bind proxy and management traffic to localhost.
- Authenticate management requests and keep management access separate from client access.
- Use a dedicated CPA authentication directory.
- Enable usage statistics only when incremental event consumption is configured.
- Prefer round-robin routing with session affinity and fail over only when the bound account becomes unavailable.

Enabling smart routing for a ChatGPT account first looks for a reusable CPA OAuth
session with the exact same email. If none exists, the app starts CPA's native Codex
OAuth flow, opens the browser, polls the management status endpoint, and verifies the
resulting auth-file identity. Only a successful identity match commits
`smart_pool_enabled=true`. A mismatch is disabled and reported to the user.

Disabling smart routing marks the matching CPA auth file disabled through the
management API but retains the independent grant, so re-enabling normally needs no
browser login. Direct `auth.json` switching, refresh failures, and re-login never copy,
overwrite, disable, or restore CPA OAuth files. Startup reconciliation only removes
legacy deterministic files created by older Codex Auth versions and resets those
accounts to excluded so the next enable action starts independent authorization.
CPA-created OAuth files and non-JSON runtime files are preserved. API Key connections remain managed
through CPA's authenticated management endpoint.
The desktop health check accepts CPA as connected only when the authenticated
`/v1/models` response contains at least one model; an HTTP 200 with an empty catalog is
treated as unavailable instead of allowing a terminal session that cannot be routed.

CPA's primary repository documents localhost binding, management authentication, a dedicated authentication directory, usage statistics, quota behavior, round-robin routing, and session-sticky routing:

- [CLIProxyAPI example configuration](https://github.com/router-for-me/CLIProxyAPI/blob/main/config.example.yaml)
- [CLIProxyAPI management API](https://github.com/router-for-me/CLIProxyAPI/blob/main/MANAGEMENT_API.md)

CPA is a third-party dependency. Codex Auth validates the installed version and supported endpoints at runtime instead of assuming every release has the same management API.

## Refresh Contract

- Opening the menu requests one full refresh covering account quota, reset credits, and local Token usage.
- Concurrent full-refresh requests coalesce.
- The refresh coordinator accepts CPA request events as incremental local file-scan triggers; it never adds Token counts directly.
- A full refresh has write priority. Incremental requests arriving during it set a dirty flag and produce at most one follow-up incremental pass.
- A monotonically increasing generation prevents older results from replacing newer state.
- A quota-exceeded response schedules an authoritative quota refresh for the affected account.
- Existing quota and Token accounting semantics remain unchanged.

The desktop app polls the authenticated CPA `usage-queue` endpoint every five seconds.
An empty queue or temporary polling failure leaves the current UI state untouched.
Any event triggers an incremental local Token scan; a record with HTTP 429 also queues
the existing authoritative quota refresh. The management values never enter a launched
Codex terminal process.

## Interface Contract

- The menu has one primary action: smart launch Codex.
- The selected direct account is conveyed by row color and check state, without a “direct” label.
- An available selection is blue; an invalid selection is red.
- Accounts are flat and status-sorted. Version 1 does not include user-defined groups.
- Accounts, routing, and settings share one reusable management window. Add, relogin, and delete flows use sheets.
- The menu shows today's Token consumption. A 5-hour window appears only when returned by the usage API; 5-hour and 7-day reset times render independently. Reset opportunities always show a count, including zero, and only show the nearest expiry when one exists.
